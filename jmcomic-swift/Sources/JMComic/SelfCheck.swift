import Foundation
import CoreGraphics

/// `swift run JMComic --selfcheck`
///
/// 只盯最容易静默出错的两处：切块数、解重组的坐标系。
/// 解重组坐标算错时输出尺寸依然正确，光看图片大小查不出来，
/// 所以这里直接断言「每一行来自原图的哪一行」，与 Java 的映射逐行对齐。
enum SelfCheck {

    private static var failed = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok {
            print("  ✓ \(name)")
        } else {
            print("  ✗ \(name) \(detail)")
            failed += 1
        }
    }

    static func run() -> Never {

        print("md5 / 签名")
        check("md5(abc)", JmCrypto.md5Hex("abc") == "900150983cd24fb0d6963f7d28e17f72")
        let t = JmCrypto.token(timestamp: "1700000000", secret: JmConstants.tokenSecret,
                              appVersion: "2.0.30")
        check("token 长度 32", t.token.count == 32, t.token)
        check("tokenparam 格式", t.param == "1700000000,2.0.30", t.param)

        print("切块数（对齐 JmImageTool.calculateNumSegments）")
        // photoId < scrambleId：老本子未加密
        check("photoId < scrambleId -> 0",
              JmCrypto.segmentCount(scrambleId: 220980, photoId: 100000,
                                    filenameWithoutExtension: "00001") == 0)
        // scrambleId <= photoId < 268850：固定 10
        check("scrambleId <= id < 268850 -> 10",
              JmCrypto.segmentCount(scrambleId: 220980, photoId: 250000,
                                    filenameWithoutExtension: "00001") == 10)
        // 268850 以上按 md5 末位取模：(c % x) * 2 + 2，x=10 时上限 20
        let mid = JmCrypto.segmentCount(scrambleId: 220980, photoId: 300000,
                                        filenameWithoutExtension: "00001")
        check("268850 <= id < 421926 -> 2...20 偶数",
              mid >= 2 && mid <= 20 && mid % 2 == 0, "\(mid)")
        // x=8 时上限 16
        let hi = JmCrypto.segmentCount(scrambleId: 220980, photoId: 500000,
                                       filenameWithoutExtension: "00001")
        check("id >= 421926 -> 2...16 偶数", hi >= 2 && hi <= 16 && hi % 2 == 0, "\(hi)")
        // 与线上实测值锁死：1459360/00001 在 Java 版算出 6
        check("实测样本 1459360/00001 -> 6",
              JmCrypto.segmentCount(scrambleId: 220980, photoId: 1459360,
                                    filenameWithoutExtension: "00001") == 6)

        print("解重组行映射（与 Java AwtImageProcessor 对齐）")
        for (h, n) in [(1807, 6), (1807, 2), (1000, 10), (999, 4), (64, 8)] {
            check("h=\(h) segments=\(n)", mappingMatchesJava(height: h, segments: n))
        }
        check("segments=0 原样返回", mappingMatchesJava(height: 200, segments: 0))

        print("scramble_id 兜底")
        // 曾写成 int(json,"scramble_id") 得到 0，于是「photoId < scrambleId」永假，
        // 未加扰的老本子被当成需要 10 段重排 —— 表现就是「腿在上、头在下」。
        // 服务端实测确实不返回 scramble_id，所以这条路径每次都会走到。
        do {
            let missing: [String: Any] = ["id": "100000", "name": "t",
                                          "images": ["00001.webp"]]
            let ch = try JmParser.parseChapter(missing, id: "100000", sort: 1, title: "t")
            check("缺失 -> 兜底 220980（不是 0）",
                  ch.pages.first?.scrambleId == JmConstants.defaultScrambleId,
                  "\(ch.pages.first?.scrambleId ?? -1)")
            check("老本子因此不分段", ch.pages.first?.segmentCount == 0)

            let explicit: [String: Any] = ["id": "400000", "name": "t",
                                           "scramble_id": 268850,
                                           "images": ["00001.webp"]]
            let ch2 = try JmParser.parseChapter(explicit, id: "400000", sort: 1, title: "t")
            check("显式值不被兜底覆盖", ch2.pages.first?.scrambleId == 268850)

            let gif: [String: Any] = ["id": "999999", "name": "t", "images": ["00001.gif"]]
            let ch3 = try JmParser.parseChapter(gif, id: "999999", sort: 1, title: "t")
            check("gif 不分段", ch3.pages.first?.segmentCount == 0)
        } catch {
            check("parseChapter", false, "\(error)")
        }

        print("磁盘缓存键跨进程稳定")
        // 曾用 Swift 的 Hasher()：种子每进程随机，同一 URL 每次启动算出不同文件名，
        // 缓存跨重启永不命中，且旧文件无限堆积。参考值独立实现，避免自证。
        let key = "https://example.com/a/00001.webp"
        check("FNV-1a 与独立实现一致", ImageStore.stableHash(key) == referenceFNV1a(key))
        check("同输入同输出", ImageStore.stableHash(key) == ImageStore.stableHash(key))
        check("不同输入不同输出",
              ImageStore.stableHash(key) != ImageStore.stableHash(key + "x"))

        print("CBZ 合法性")
        check("zip 结构与 CRC", cbzIsValid(), cbzFailure)

        print("扫描导入（DownloadStore.scanFolder）")
        checkScanFolder()

        print("LAN 同步全链路（配对→pull→下载→封禁→关停）")
        runLanCheck()

        print(failed == 0 ? "\n全部通过" : "\n\(failed) 项失败")
        exit(failed == 0 ? 0 : 1)
    }

    // MARK: - LAN 同步自检
    //
    // 必须静默无 UI、绝不能污染用户数据，所以分两层：
    //  A. 纯函数层：配对码/payload 加解密/HTTP 解析/路径越权防护，不起服务零副作用；
    //  B. 真实服务层：独立实例绑 127.0.0.1 随机端口 + 临时下载目录 + 隔离 UserDefaults
    //     和独立钥匙串 service，走完 pair→pull→(push 守卫)→list→file→封禁→关停。
    //  push 不往共享 stores 真 merge（会改用户真实收藏/历史），只验证其解密守卫拒绝坏包；
    //  解密正确性与落盘合并逻辑由 A 层往返断言 + Store 自身导入函数保证。
    private static func runLanCheck() {
        // 整段跑在主线程（App init 调用链），用泵驱动 MainActor 任务后取结果
        MainActor.assumeIsolated {
            let runner = LanCheckRunner()
            Task { await runner.go() }
            // 泵主队列驱动 Swift Concurrency 的 MainActor 任务（命令行进程无事件循环）
            while !runner.finished {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            for r in runner.results { check(r.name, r.ok, r.detail) }
        }
    }

    @MainActor
    private final class LanCheckRunner {
        struct Result { let name: String; let ok: Bool; let detail: String }
        private(set) var results: [Result] = []
        private(set) var finished = false

        func record(_ name: String, _ ok: Bool, _ detail: String = "") {
            results.append(Result(name: name, ok: ok, detail: detail))
        }

        func go() async {
            defer { finished = true }
            pureFunctionChecks()
            await liveServerChecks()
        }

        // MARK: A. 纯函数层

        private func pureFunctionChecks() {
            // --- 配对码 ---
            let code = LanSyncServer.generatePairCode()
            record("配对码 8 位且去混淆字符集", LanSyncServer.isValidPairCode(code), code)
            record("配对码随机（两次生成不同）", code != LanSyncServer.generatePairCode())

            // --- 元数据包加解密（与 SyncStore 同构：PBKDF2 210000 + AES-GCM）---
            let fav = Data("{\"entries\":[{\"id\":\"100\"}],\"folders\":[\"默认\"]}".utf8)
            let st = Data("{\"positions\":{\"p\":{\"pageIndex\":3}},\"history\":[]}".utf8)
            guard let sealed = LanSyncServer.sealPayload(favorites: fav, state: st, password: "A2C3E4F5")
            else {
                record("payload 加密封包", false)
                return
            }
            record("payload 密文头部 salt‖nonce 结构（≥44B）", sealed.count > 16 + 12 + 16, "\(sealed.count)B")
            if let (f, s) = LanSyncServer.openPayload(sealed, password: "A2C3E4F5") {
                record("payload 解包往返逐字节一致", f == fav && s == st)
            } else {
                record("payload 解包往返逐字节一致", false)
            }
            record("错误密码解包被拒", LanSyncServer.openPayload(sealed, password: "ZZZZ9999") == nil)
            var tampered = sealed
            tampered[tampered.count - 1] ^= 0xFF    // 翻转 GCM tag 一位
            record("密文被篡改解包被拒", LanSyncServer.openPayload(tampered, password: "A2C3E4F5") == nil)

            // --- HTTP 请求解析 ---
            let fullGet = Data("GET /metadata/pull HTTP/1.1\r\nHost: m\r\nAuthorization: Bearer tok123\r\n\r\n".utf8)
            switch LanSyncServer.parseRequest(fullGet) {
            case .complete(let r):
                record("请求解析 method/path/Bearer",
                       r.method == "GET" && r.path == "/metadata/pull" && r.bearerToken == "tok123")
            default:
                record("请求解析 method/path/Bearer", false, "未完整解析")
            }
            // 分片到达：先半截 needMore，补齐后 complete 且 headers/body 正确
            let body = Data("{\"deviceName\":\"SC\"}".utf8)
            var partial = Data("POST /pair HTTP/1.1\r\nX-Pair-Token: AB23CD56\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
            partial.append(body.prefix(7))
            if case .needMore = LanSyncServer.parseRequest(partial) {
                record("半截请求判定 needMore", true)
            } else {
                record("半截请求判定 needMore", false)
            }
            partial.append(body.dropFirst(7))
            switch LanSyncServer.parseRequest(partial) {
            case .complete(let r):
                record("补齐后解析出 method/header/body",
                       r.method == "POST" && r.headers["x-pair-token"] == "AB23CD56"
                           && String(decoding: r.body, as: UTF8.self) == "{\"deviceName\":\"SC\"}")
            default:
                record("补齐后解析出 method/header/body", false)
            }
            if case .invalid = LanSyncServer.parseRequest(Data("GARBAGE\r\n\r\n".utf8)) {
                record("垃圾字节流判定 invalid", true)
            } else {
                record("垃圾字节流判定 invalid", false)
            }

            // --- downloads/file 路径越权防护（含符号链接逃逸）---
            let fm = FileManager.default
            let root = fm.temporaryDirectory
                .appendingPathComponent("jm-safepath-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: root) }
            try? fm.createDirectory(at: root.appendingPathComponent("a"),
                                    withIntermediateDirectories: true)
            fm.createFile(atPath: root.appendingPathComponent("a/b.cbz").path, contents: Data([1]))
            func safe(_ rel: String) -> Bool {
                LanSyncServer.resolveSafeDownloadPath(root: root, relative: rel) != nil
            }
            record("合法相对路径可解析", safe("a/b.cbz"))
            record(".. 组件拒绝", !safe("../../etc/passwd") && !safe("a/../../x"))
            record("空/根路径拒绝", !safe("") && !safe("/"))
            // symlink 指向根目录之外：canonical 化后被拒
            try? fm.createSymbolicLink(at: root.appendingPathComponent("jump"),
                                       withDestinationURL: fm.temporaryDirectory)
            record("符号链接逃逸拒绝", !safe("jump/whatever"))
        }

        // MARK: B. 真实服务层（loopback:0，全程零污染）

        private func liveServerChecks() async {
            let fm = FileManager.default
            let root = fm.temporaryDirectory
                .appendingPathComponent("jm-lan-\(UUID().uuidString)", isDirectory: true)
            // 造一本下载专辑：<root>/本子X/第1话.cbz + 散图一章
            try? fm.createDirectory(at: root.appendingPathComponent("本子X/第1话"),
                                    withIntermediateDirectories: true)
            let planted = Data((0..<2048).map { UInt8($0 % 251) })
            let cbzAbs = root.appendingPathComponent("本子X/第1话.cbz")
            _ = fm.createFile(atPath: cbzAbs.path, contents: planted)
            _ = fm.createFile(atPath: root.appendingPathComponent("本子X/第1话/00001.jpg").path,
                              contents: Data([9, 9, 9]))

            // 隔离三件套：独立 UserDefaults suite / 独立钥匙串 service / 临时下载根
            let suite = "jm-selfcheck-lan-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else {
                record("自检隔离环境", false, "UserDefaults suite 创建失败"); return
            }
            let server = LanSyncServer(defaults: defaults, downloadsRoot: root,
                                       keychainServiceOverride: suite)
            record("静态清单扫描识别出专辑与文件",
                   verifyScanList(LanSyncServer.scanDownloads(root: root)))

            server.beginListening(loopbackOnly: true)
            // 等 listener ready 拿到实际端口（最长 5s）
            let deadline = Date().addingTimeInterval(5)
            while server.listeningPort == nil && Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            guard let port = server.listeningPort else {
                record("服务启动于 loopback 随机端口", false, "超时未 ready")
                server.shutdownForTests(suiteName: suite)
                return
            }
            record("服务启动于 loopback 随机端口", true, "\(port)")
            let base = "http://127.0.0.1:\(port)"

            func send(_ method: String, _ pathAndQuery: String,
                      headers: [String: String] = [:], body: Data = Data()) async
                -> (status: Int, data: Data, contentType: String?) {
                guard let url = URL(string: base + pathAndQuery) else { return (-1, Data(), nil) }
                var req = URLRequest(url: url)
                req.httpMethod = method
                req.httpBody = body
                for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
                do {
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    let http = resp as? HTTPURLResponse
                    return (http?.statusCode ?? 0, data,
                            http?.value(forHTTPHeaderField: "Content-Type"))
                } catch {
                    return (-1, Data(), nil)
                }
            }

            // --- 鉴权门槛 ---
            let (s1, _, _) = await send("GET", "/metadata/pull")
            record("无凭访问元数据 → 401", s1 == 401, "\(s1)")
            let (s2, _, _) = await send("GET", "/metadata/pull",
                                        headers: ["Authorization": "Bearer deadbeef"])
            record("无效会话 pull → 401", s2 == 401, "\(s2)")
            let (s3, _, _) = await send("POST", "/pair",
                                        headers: ["X-Pair-Token": "AAAAAAAA",
                                                  "Content-Type": "application/json"],
                                        body: Data("{\"deviceName\":\"SC\"}".utf8))
            record("错误配对码 /pair → 401", s3 == 401, "\(s3)")
            let (s4, _, _) = await send("GET", "/nope")
            record("无凭访问任意路径 → 401", s4 == 401, "\(s4)")

            // --- 正确配对换会话 ---
            let (sp, pd, _) = await send("POST", "/pair",
                                         headers: ["X-Pair-Token": server.pairCode,
                                                   "Content-Type": "application/json"],
                                         body: Data("{\"deviceName\":\"SelfCheck-iPhone\"}".utf8))
            var sessionToken: String?
            var deviceId: String?
            if sp == 200,
               let obj = (try? JSONSerialization.jsonObject(with: pd)) as? [String: Any],
               let tok = obj["sessionToken"] as? String, tok.count >= 32,
               let did = obj["deviceId"] as? String, !did.isEmpty {
                sessionToken = tok
                deviceId = did
            }
            record("正确配对码换得 sessionToken/deviceId",
                   sessionToken != nil && deviceId != nil, "status=\(sp)")

            guard let token = sessionToken, let devId = deviceId else {
                server.shutdownForTests(suiteName: suite)
                return
            }
            let auth = ["Authorization": "Bearer \(token)"]

            // --- pull：模拟 iPhone 视角独立解密（密码只来自「扫码得到的配对码」）---
            let (sg, gd, ctg) = await send("GET", "/metadata/pull", headers: auth)
            var pullOK = sg == 200
            var structureOK = false
            if pullOK {
                pullOK = ctg?.hasPrefix("application/octet-stream") ?? false
                // iPhone 侧只有配置串 jmsync|v1|ip|port|pairCode，用其中的 pairCode 派生密钥
                let phonePassword = server.pairCode
                if let (fav, st) = LanSyncServer.openPayload(gd, password: phonePassword),
                   let favObj = (try? JSONSerialization.jsonObject(with: fav)) as? [String: Any],
                   let stObj = (try? JSONSerialization.jsonObject(with: st)) as? [String: Any],
                   favObj["entries"] is [Any], stObj["positions"] is [String: Any] {
                    structureOK = true
                }
            }
            record("pull 返回加密流且 iPhone 视角可独立解密", pullOK, "status=\(sg)")
            record("pull 解出 favorites/state 双层 base64 结构", structureOK)

            // --- push：仅验证坏包守卫（真合并走不到用户 stores，零污染）---
            let garbage = Data(repeating: 0xAB, count: 96)
            let (sx, _, _) = await send("POST", "/metadata/push", headers: auth, body: garbage)
            record("push 坏密文守卫 → 400 不落盘", sx == 400, "\(sx)")
            let (_, sd, _) = await send("GET", "/metadata/pull", headers: auth)
            if let p = LanSyncServer.openPayload(sd, password: server.pairCode) {
                record("坏 push 未写入（本地导出仍可打开）", !p.favorites.isEmpty)
            } else {
                record("坏 push 未写入（本地导出仍可打开）", false)
            }

            // --- downloads/list ---
            let (sl, ld, ctl) = await send("GET", "/downloads/list", headers: auth)
            var listOK = sl == 200 && ctl?.contains("json") == true
            var foundCBZ = false
            if listOK,
               let arr = (try? JSONSerialization.jsonObject(with: ld)) as? [[String: Any]] {
                for album in arr {
                    guard let files = album["files"] as? [[String: Any]] else { continue }
                    for f in files where (f["path"] as? String)?.hasSuffix("第1话.cbz") == true {
                        foundCBZ = ((f["size"] as? Int) ?? 0) == planted.count
                    }
                }
                listOK = arr.contains { ($0["albumId"] as? String)?.isEmpty == false
                                     && ($0["title"] as? String) == "本子X" }
            } else {
                listOK = false
            }
            record("downloads/list 返回可解析清单", listOK)
            record("清单含预置 CBZ 且 size 一致", foundCBZ)

            // --- downloads/file 单文件回传 ---
            let encoded = "本子X/第1话.cbz".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            let (sf, fd, ctf) = await send("GET", "/downloads/file?path=\(encoded)", headers: auth)
            record("file 回传字节与源一致", sf == 200 && fd == planted && ctf == "application/octet-stream",
                   "status=\(sf) bytes=\(fd.count)")

            // --- 路径穿越拒绝 ---
            let (st2, _, _) = await send("GET", "/downloads/file?path=../../etc/passwd", headers: auth)
            record("文件路径穿越被拒", st2 == 403, "\(st2)")

            // --- 撤销设备后会话失效 ---
            server.revoke(devId)
            let (sr, _, _) = await send("GET", "/metadata/pull", headers: auth)
            record("撤销设备后旧 token → 401", sr == 401, "\(sr)")

            // --- 限流封禁：连续失败 ≥5 次 → 10 分钟封禁 ---
            for _ in 0..<4 {
                _ = await send("GET", "/metadata/pull",
                               headers: ["Authorization": "Bearer wrongwrongwrong"])
            }
            let (sb, _, _) = await send("GET", "/metadata/pull",
                                        headers: ["Authorization": "Bearer wrongwrongwrong"])
            record("连续失败达到阈值后封禁", sb == 403, "\(sb)")
            let (sb2, _, _) = await send("GET", "/metadata/pull", headers: auth)
            record("封禁期内有效会话也被拒", sb2 == 403, "\(sb2)")

            // --- 关停后端口不可达 ---
            server.shutdownForTests(suiteName: suite)
            record("关停后 running/port 复位", !server.running && server.listeningPort == nil)
            let (sAfter, _, _) = await send("GET", "/metadata/pull", headers: auth)
            record("关停后端口不可达（连接被拒）", sAfter == -1, "\(sAfter)")

            try? fm.removeItem(at: root)
        }

        /// 校验扫描清单：识别出「本子X」，含 CBZ 与散图两张
        private func verifyScanList(_ albums: [LanDownloadAlbum]) -> Bool {
            guard albums.count == 1, let a = albums.first, a.title == "本子X" else { return false }
            guard a.files.contains(where: { $0.path == "本子X/第1话.cbz" && $0.size > 0 }),
                  a.files.contains(where: { $0.path == "本子X/第1话/00001.jpg" })
            else { return false }
            return a.files.allSatisfy { !$0.path.hasPrefix("/") && !$0.path.contains("\\") }
        }
    }

    private static func checkScanFolder() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("jm-scan-\(UUID().uuidString)",
                                                               isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        try? fm.createDirectory(at: tmp.appendingPathComponent("本子A", isDirectory: true),
                                withIntermediateDirectories: true)
        try? fm.createDirectory(at: tmp.appendingPathComponent("本子B/第2话", isDirectory: true),
                                withIntermediateDirectories: true)
        fm.createFile(atPath: tmp.appendingPathComponent("本子A/第1话.cbz").path,
                      contents: Data())
        fm.createFile(atPath: tmp.appendingPathComponent("本子B/第2话/0001.png").path,
                      contents: Data())
        fm.createFile(atPath: tmp.appendingPathComponent("本子B/第2话/0002.jpg").path,
                      contents: Data())
        // 干扰项：无图片的子目录不该被当成章节
        try? fm.createDirectory(at: tmp.appendingPathComponent("本子A/说明", isDirectory: true),
                                withIntermediateDirectories: true)

        let scanned = DownloadStore.scanFolder(tmp)
        check("识别出 2 本", scanned.count == 2, "实际 \(scanned.count)")
        let a = scanned.first { $0.meta.title == "本子A" }
        check("CBZ 本 1 章", a?.chapters.count == 1, "\(a?.chapters.count ?? -1)")
        check("CBZ 格式正确", a?.chapters.first?.format == .cbz)
        let b = scanned.first { $0.meta.title == "本子B" }
        check("散图本 1 章 2 页", b?.chapters.first?.pageCount == 2,
              "\(b?.chapters.first?.pageCount ?? -1)")
        check("散图格式正确", b?.chapters.first?.format == .folder)
        check("无图目录不被识别为章节", a?.chapters.count == 1)
        check("id 稳定（路径哈希）",
              DownloadStore.scanFolder(tmp).first { $0.meta.title == "本子A" }?.meta.id
                == scanned.first { $0.meta.title == "本子A" }?.meta.id)
    }

    private static var cbzFailure = ""

    /// 手写 zip 曾把日期字段置 0，产出非法的 1980-00-00，严格阅读器会拒读。
    /// 走真实的 ZipWriter 落盘再读回，顺带覆盖 CRC 与中央目录。
    private static func cbzIsValid() -> Bool {
        let payload = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("selfcheck-\(getpid()).cbz")
        defer { try? FileManager.default.removeItem(at: tmp) }

        do {
            let w = try ZipWriter(url: tmp)
            try w.add(name: "00001.jpg", data: payload)
            try w.add(name: "00002.jpg", data: Data([0x01, 0x02]))
            try w.finish()
            let zip = try Data(contentsOf: tmp)

            guard zip.prefix(4).elementsEqual([0x50, 0x4B, 0x03, 0x04]) else {
                cbzFailure = "本地头魔数错"; return false
            }
            // 本地头 offset 12..<14 是 DOS 日期：月、日为 0 即非法
            let date = Int(zip[12]) | Int(zip[13]) << 8
            let month = (date >> 5) & 0x0F, day = date & 0x1F
            guard (1...12).contains(month), (1...31).contains(day) else {
                cbzFailure = "非法 DOS 日期 month=\(month) day=\(day)"; return false
            }
            let crc = UInt32(zip[14]) | UInt32(zip[15]) << 8
                    | UInt32(zip[16]) << 16 | UInt32(zip[17]) << 24
            guard crc == referenceCRC32(payload) else {
                cbzFailure = "CRC 不匹配"; return false
            }
            guard let e = findEOCD(zip) else {
                cbzFailure = "缺中央目录结束记录"; return false
            }
            let count = Int(zip[e + 10]) | Int(zip[e + 11]) << 8
            guard count == 2 else {
                cbzFailure = "条目数 \(count) != 2"; return false
            }
            return true
        } catch {
            cbzFailure = "\(error)"
            return false
        }
    }

    // MARK: - 独立参考实现
    //
    // 故意不复用被测代码：两边调同一个函数的话，函数改错断言也跟着错。

    private static func referenceFNV1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01B3
        }
        return h
    }

    private static func referenceCRC32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    /// 从尾部倒着找 EOCD 魔数 PK\05\06
    private static func findEOCD(_ d: Data) -> Int? {
        guard d.count >= 22 else { return nil }
        var i = d.count - 22
        while i >= 0 {
            if d[i] == 0x50, d[i + 1] == 0x4B, d[i + 2] == 0x05, d[i + 3] == 0x06 { return i }
            i -= 1
        }
        return nil
    }

    /// 造一张每行取值唯一的图，跑一遍 descramble，
    /// 再逐行核对是否等于 Java 的 dst[currentY+k] = src[ySrc+k]。
    private static func mappingMatchesJava(height: Int, segments: Int) -> Bool {
        let width = 4
        guard let source = gradient(width: width, height: height) else { return false }
        let result = ImagePipeline.descramble(source, segments: segments)
        guard result.width == width, result.height == height else { return false }
        let rows = rowValues(result, width: width, height: height)

        // Java 的映射：块从原图底部往上取，依次落到目标的顶部往下
        var expected = [Int](repeating: -1, count: height)
        if segments <= 0 || height < segments {
            for y in 0..<height { expected[y] = y }
        } else {
            let segmentHeight = height / segments
            let remainder = height % segments
            var currentY = 0
            for i in 0..<segments {
                var sliceHeight = segmentHeight
                let sourceY: Int
                if i == 0 {
                    sliceHeight += remainder
                    sourceY = height - sliceHeight
                } else {
                    sourceY = height - (segmentHeight * (i + 1)) - remainder
                }
                for k in 0..<sliceHeight {
                    expected[currentY + k] = sourceY + k
                }
                currentY += sliceHeight
            }
        }
        return rows == expected
    }

    /// 每行写入唯一可解码的值（两通道组合，支持到 251*251 行）
    private static func gradient(width: Int, height: Int) -> CGImage? {
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                buf[o] = UInt8(y % 251)
                buf[o + 1] = UInt8((y / 251) % 251)
                buf[o + 2] = 0
            }
        }
        return buf.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        }
    }

    /// 读回每行携带的原始行号（自上而下）
    private static func rowValues(_ img: CGImage, width: Int, height: Int) -> [Int] {
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        buf.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            ctx?.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (0..<height).map { y in
            let o = y * width * 4
            return Int(buf[o + 1]) * 251 + Int(buf[o])
        }
    }
}
