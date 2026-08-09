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

        print(failed == 0 ? "\n全部通过" : "\n\(failed) 项失败")
        exit(failed == 0 ? 0 : 1)
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
