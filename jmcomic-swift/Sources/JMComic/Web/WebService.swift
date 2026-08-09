import Foundation
import CoreGraphics
import UniformTypeIdentifiers

/// 局域网 web 服务的路由。
///
/// 图片一律在 Mac 侧解扰后再发出，浏览器收到的就是正常图 ——
/// 前端零解扰代码，手机也省电。代价是 Mac 要做图像处理，但它本来就在做。
///
/// 访问门禁（见 WebAuth）：没有有效入场 token 的一切请求都返回 404，
/// 登录页"不存在"；token 一次一换，扫码/手输后拿到 5 分钟 preauth 才能看到登录页。
@MainActor
final class WebService: ObservableObject {

    static let shared = WebService()

    @Published private(set) var isRunning = false
    @Published var port: UInt16 = {
        let saved = UserDefaults.standard.integer(forKey: "webPort")
        return saved > 0 && saved < 65536 ? UInt16(saved) : WebService.defaultPort
    }() {
        didSet { UserDefaults.standard.set(Int(port), forKey: "webPort") }
    }

    /// HTTPS 开关。开启后首次会生成自签证书（见 TLSCert），手机需点一次"继续访问"。
    @Published var useHTTPS: Bool = UserDefaults.standard.bool(forKey: "webHTTPS") {
        didSet { UserDefaults.standard.set(useHTTPS, forKey: "webHTTPS") }
    }

    /// 扫码自动登录：开启后扫码直接进主页，跳过登录页和密码；关闭则维持密码登录。
    @Published var scanAutoLogin: Bool = UserDefaults.standard.bool(forKey: "scanAutoLogin") {
        didSet { UserDefaults.standard.set(scanAutoLogin, forKey: "scanAutoLogin") }
    }

    /// 本机免登录：127.0.0.1/::1 直接放行，不用输密码/扫码；其他设备照旧要认证。
    /// 风险：同机上的进程/被 DNS rebinding 的恶意网页可能直接访问。
    @Published var localAutoLogin: Bool = UserDefaults.standard.bool(forKey: "webLocalAuto") {
        didSet { UserDefaults.standard.set(localAutoLogin, forKey: "webLocalAuto") }
    }

    /// 避开常见开发端口（3000/5000/8000/8080），减少冲突
    static let defaultPort: UInt16 = 8973
    @Published private(set) var addresses: [String] = []
    @Published private(set) var lastError: String?

    /// 当前入场 token 与轮换计数（拼二维码/文本）。消费后自动更新，UI 据此刷新二维码。
    @Published private(set) var entryToken = ""
    @Published private(set) var entryTokenEpoch = 0

    /// 在线设备快照（供 Mac 端管理面板）。每 5 秒最多刷新一次，避免图片请求刷屏。
    struct Device: Identifiable {
        var id: String          // session token，仅内部用于踢出/信任设置
        var name: String
        var ip: String
        var lastSeen: Date
        var lastPath: String
        var trusted: Bool
    }
    @Published private(set) var activeDevices: [Device] = []

    private var server: HTTPServer?
    private var lastDevicePublish = Date.distantPast
    private var tlsIdentity: sec_identity_t?

    private init() {}

    var scheme: String { useHTTPS ? "https" : "http" }

    /// HTTPS 下给 cookie 加 Secure，防止被降级到明文链路
    private var secureFlag: String { useHTTPS ? "; Secure" : "" }

    /// 当前入口 URL（二维码内容）。地址取第一个局域网 IP，多网卡时由 UI 选。
    func entryURL(ip: String? = nil) -> String? {
        guard !entryToken.isEmpty, let ip = ip ?? addresses.first else { return nil }
        return "\(scheme)://\(ip):\(port)/?t=\(entryToken)"
    }

    func start() {
        // HTTPS 首次启用时生成证书；生成失败则退回明文并提示
        tlsIdentity = useHTTPS ? TLSCert.identity() : nil
        if useHTTPS && tlsIdentity == nil {
            lastError = "自签证书生成失败，已退回明文 HTTP"
            useHTTPS = false
        }
        let s = HTTPServer { [weak self] req in
            guard let self else { return .text("gone", status: 500) }
            return await self.route(req)
        }
        do {
            try s.start(port: port, tls: tlsIdentity)
            server = s
            isRunning = true
            addresses = HTTPServer.localAddresses()
            lastError = nil
            Task { await refreshEntryToken() }
        } catch {
            lastError = error.localizedDescription
            isRunning = false
        }
    }

    func stop() {
        server?.stop()
        server = nil
        isRunning = false
        activeDevices = []
    }

    /// 从 WebAuth 拉当前入场 token（服务刚启动 / 设置面板出现时用）
    func refreshEntryToken() async {
        let info = await WebAuth.shared.bootTokenInfo
        entryToken = info.token
        entryTokenEpoch = info.epoch
    }

    /// 手动换一个入场 token（作废旧二维码）
    func rotateEntryToken() {
        Task {
            let r = await WebAuth.shared.rotateBootToken()
            entryToken = r.token
            entryTokenEpoch = r.epoch
        }
    }

    func revokeDevice(id: String) {
        Task {
            await WebAuth.shared.revokeSession(token: id)
            await publishDevices()
        }
    }

    /// 设备信任开关：取消信任 = 该设备只读（不能写进度/收藏）
    func setTrusted(id: String, trusted: Bool) {
        Task {
            await WebAuth.shared.setTrusted(token: id, trusted: trusted)
            await publishDevices()
        }
    }

    func revokeAllDevices() {
        Task {
            await WebAuth.shared.revokeAllSessions()
            await publishDevices()
        }
    }

    private func publishDevices() async {
        let sessions = await WebAuth.shared.activeSessions()
        activeDevices = sessions.map {
            Device(id: $0.token, name: $0.deviceName, ip: $0.ip,
                   lastSeen: $0.lastSeen, lastPath: $0.lastPath,
                   trusted: $0.trusted)
        }
    }

    /// 写操作权限：本机免登录放行，或会话受信任
    private func isTrustedWriter(_ req: HTTPServer.Request) async -> Bool {
        if localAutoLogin, isLocalIP(req.clientIP) { return true }
        return await WebAuth.shared.isTrusted(token: req.cookies["jm_token"], ip: req.clientIP)
    }

    /// 限频的设备列表刷新：认证请求都会路过这里，图片密集请求时不能每次发布
    private func maybePublishDevices() {
        let now = Date()
        guard now.timeIntervalSince(lastDevicePublish) > 5 else { return }
        lastDevicePublish = now
        Task { await publishDevices() }
    }

    // MARK: - 路由

    private func route(_ req: HTTPServer.Request) async -> HTTPServer.Response {
        // 本机免登录：仅本机 IP + 开启开关 → 直接放行（不建会话，其他设备不受影响）
        if localAutoLogin, isLocalIP(req.clientIP) {
            // 防 DNS rebinding：带第三方 Origin 的跨站请求不放行
            if let origin = req.headers["origin"], !isLocalOrigin(origin) {
                return .text("Not Found", status: 404)
            }
            return await authedRoute(req)
        }

        let token = req.cookies["jm_token"]
        let authed = await WebAuth.shared.validate(token: token, ip: req.clientIP,
                                                   path: req.path, userAgent: req.headers["user-agent"] ?? "")
        if authed { maybePublishDevices() }

        // 入场：?t= 消费一次性 token → 发 preauth cookie → 去登录页
        // 消费后 token 立即轮换，旧 URL（截图/历史记录）第二次用即 404
        if let t = req.query["t"], req.path == "/" || req.path == "/entry" {
            guard let _ = await WebAuth.shared.consumeBootToken(t) else {
                return .text("Not Found", status: 404)
            }
            // token 被用了，设置面板的二维码/文本要跟着换
            Task { await self.refreshEntryToken() }

            // 扫码自动登录：token 直接换会话进主页，跳过密码
            if scanAutoLogin {
                let ua = req.headers["user-agent"] ?? ""
                let tok = await WebAuth.shared.createSession(ip: req.clientIP, userAgent: ua)
                await publishDevices()
                return HTTPServer.Response(
                    status: 302,
                    headers: ["Location": "/",
                              "Set-Cookie": "jm_token=\(tok); Path=/; Max-Age=604800; HttpOnly; SameSite=Strict\(secureFlag)"])
            }

            let pt = await WebAuth.shared.grantPreauth(ip: req.clientIP)
            return HTTPServer.Response(
                status: 302,
                headers: ["Location": "/login",
                          "Set-Cookie": "jm_preauth=\(pt); Path=/; Max-Age=300; HttpOnly; SameSite=Strict\(secureFlag)"])
        }

        let preauthCookie = req.cookies["jm_preauth"]
        var preauthed = false
        if let preauthCookie { preauthed = await WebAuth.shared.validatePreauth(token: preauthCookie, ip: req.clientIP) }
        // 带 preauth cookie 但已失效：只在登录页给提示，别的路径照旧 404
        let preauthExpired = preauthCookie != nil && !preauthed

        // 无任何有效凭证的陌生请求：一律 404，含 /login /api /img —— 登录页"不存在"
        guard authed || preauthed || (preauthExpired && req.path == "/login") else {
            return .text("Not Found", status: 404)
        }

        switch (req.method, req.path) {
        case ("GET", "/login"):
            if preauthed { return .html(WebUI.loginPage(error: nil)) }
            if preauthExpired { return .html(WebUI.loginPage(error: "入口已过期，请重新扫码")) }
            return .text("Not Found", status: 404)

        case ("POST", "/login"):
            guard preauthed else { return .text("Not Found", status: 404) }
            return await handleLogin(req, preauth: preauthCookie)

        case ("POST", "/logout"):
            guard authed else { return .text("Not Found", status: 404) }
            await WebAuth.shared.logout(token: token)
            await WebAuth.shared.consumePreauth(token: preauthCookie)
            await publishDevices()
            return HTTPServer.Response(
                status: 302,
                headers: ["Location": "/",
                          "Set-Cookie": "jm_token=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict\(secureFlag)"])

        default:
            guard authed else { return .text("Not Found", status: 404) }
            return await authedRoute(req)
        }
    }

    private func isLocalIP(_ ip: String) -> Bool {
        ip == "127.0.0.1" || ip == "::1" || ip == "localhost"
    }

    private func isLocalOrigin(_ origin: String) -> Bool {
        let host = origin
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .split(separator: "/").first
            .map(String.init) ?? ""
        return host.hasPrefix("127.0.0.1") || host.hasPrefix("localhost") || host.hasPrefix("[::1]")
    }

    private func handleLogin(_ req: HTTPServer.Request, preauth: String?) async -> HTTPServer.Response {
        let form = Self.parseForm(req.body)
        let password = form["password"] ?? ""
        let ua = req.headers["user-agent"] ?? ""
        let result = await WebAuth.shared.login(password: password, from: req.clientIP,
                                                userAgent: ua,
                                                deviceName: WebAuth.deviceName(from: ua))
        switch result {
        case .ok(let token):
            // preauth 只够用这一次，登录成功即作废（服务端侧；cookie 留着也无效）
            await WebAuth.shared.consumePreauth(token: preauth)
            await publishDevices()
            return HTTPServer.Response(
                status: 302,
                headers: ["Location": "/",
                          // HttpOnly 让 JS 读不到，降低 XSS 情况下的失窃风险
                          "Set-Cookie": "jm_token=\(token); Path=/; Max-Age=604800; HttpOnly; SameSite=Strict\(secureFlag)"])
        case .wrong:
            return .html(WebUI.loginPage(error: "密码错误"))
        case .locked(let retry):
            return .html(WebUI.loginPage(error: "尝试过多，请 \(max(retry, 1)) 秒后再试"))
        case .notConfigured:
            return .html(WebUI.loginPage(error: "尚未在 Mac 端设置访问密码"))
        }
    }

    private func authedRoute(_ req: HTTPServer.Request) async -> HTTPServer.Response {
        switch req.path {
        case "/":
            return .html(WebUI.appShell())

        case "/api/feed":
            let kind = req.query["kind"] ?? "hot"
            let page = Int(req.query["page"] ?? "1") ?? 1
            do {
                let result: PagedAlbums
                switch kind {
                case "latest": result = try await JmClient.shared.latest(page: page)
                case "search":
                    let q = req.query["q"] ?? ""
                    guard !q.isEmpty else { return .json(["items": [], "hasMore": false]) }
                    result = try await JmClient.shared.search(q, page: page)
                default: result = try await JmClient.shared.hot(page: page)
                }
                return .json([
                    "items": result.items.map { ["id": $0.id, "title": $0.title,
                                                 "author": $0.authorText] },
                    "hasMore": result.hasMore,
                ])
            } catch {
                return .json(["error": error.localizedDescription], status: 500)
            }

        case "/api/recent":
            // web 端最近浏览（打开过详情页的本子）
            return .json([
                "items": LibraryStore.shared.recentlyViewed.map {
                    ["id": $0.id, "title": $0.title, "author": $0.authorText]
                },
                "hasMore": false,
            ])

        case "/api/personalized":
            // web 端个性化推荐（与 Mac 端同算法）
            let rec = await LibraryStore.shared.recommendations()
            return .json([
                "items": rec.items.map { ["id": $0.id, "title": $0.title, "author": $0.authorText] },
                "tags": rec.profileTags,
                "hasMore": false,
            ])

        case "/api/favorites/toggle":
            // POST：表单 id + title → 收藏/取消收藏（web 端）。仅受信任设备可写。
            guard req.method == "POST" else { return .json(["error": "method"], status: 405) }
            guard await isTrustedWriter(req) else {
                return .json(["error": "readonly"], status: 403)
            }
            let form = Self.parseForm(req.body)
            guard let id = form["id"], !id.isEmpty else {
                return .json(["error": "missing id"], status: 400)
            }
            let title = form["title"] ?? ""
            let store = FavoriteStore.shared
            if store.contains(id) {
                store.remove(id)
                return .json(["favorited": false])
            } else {
                store.add(AlbumMeta(id: id, title: title, authors: []))
                return .json(["favorited": true])
            }

        case "/api/progress":
            // POST：web 端翻页写回进度（仅受信任设备，与 Mac 端双向同步）
            guard req.method == "POST" else { return .json(["error": "method"], status: 405) }
            guard await isTrustedWriter(req) else {
                return .json(["error": "readonly"], status: 403)
            }
            let form = Self.parseForm(req.body)
            guard let albumId = form["albumId"], !albumId.isEmpty,
                  let chapterId = form["chapterId"], !chapterId.isEmpty,
                  let sort = Int(form["sort"] ?? "1"),
                  let page = Int(form["page"] ?? "0"), page >= 0
            else { return .json(["error": "bad params"], status: 400) }
            LibraryStore.shared.recordByIDs(albumId: albumId,
                                            albumTitle: form["title"] ?? "",
                                            chapterId: chapterId,
                                            chapterSort: sort, page: page)
            return .json(["ok": true])

        case "/api/history":
            // 手机端看阅读历史（LibraryStore 存本机，最多 60 条）
            return .json([
                "items": LibraryStore.shared.history.map { ["id": $0.id, "title": $0.title,
                                                            "author": $0.authorText] },
                "hasMore": false,
            ])

        case "/api/album":
            guard let id = req.query["id"] else { return .json(["error": "missing id"], status: 400) }
            do {
                let a = try await JmClient.shared.album(id: id)
                // 附带本地阅读进度（web 详情页「继续阅读」用）与收藏状态
                let pos = LibraryStore.shared.position(for: id)
                return .json([
                    "id": a.id, "title": a.title, "author": a.authorText,
                    "description": a.description, "tags": a.tags,
                    "views": a.views, "likes": a.likes,
                    "favorited": FavoriteStore.shared.contains(id),
                    "position": pos.map {
                        ["chapterId": $0.chapterId, "pageIndex": $0.pageIndex,
                         "chapterSort": $0.chapterSort]
                    } ?? NSNull(),
                    "chapters": a.chapters.map { ["id": $0.id, "title": $0.displayTitle,
                                                  "sort": $0.sort] },
                    "related": a.related.map { ["id": $0.id, "title": $0.title] },
                ])
            } catch {
                return .json(["error": error.localizedDescription], status: 500)
            }

        case "/api/chapter":
            guard let id = req.query["id"] else { return .json(["error": "missing id"], status: 400) }
            let sort = Int(req.query["sort"] ?? "1") ?? 1
            do {
                let c = try await JmClient.shared.chapter(id: id, sort: sort, title: "")
                // 只把页序号给前端，真实 CDN 地址不外泄，图片统一走 /img/page
                return .json([
                    "id": c.id,
                    "title": c.title,
                    "pages": c.pages.enumerated().map { i, _ in
                        ["index": i, "src": "/img/page?chapter=\(id)&i=\(i)"]
                    },
                ])
            } catch {
                return .json(["error": error.localizedDescription], status: 500)
            }

        case "/img/cover":
            guard let id = req.query["id"] else { return .text("missing id", status: 400) }
            guard let img = await ImageStore.shared.cover(albumId: id),
                  let data = DownloadStore.encode(img, as: .jpeg) else {
                return .text("not found", status: 404)
            }
            return .image(data)

        case "/img/page":
            guard let chapterId = req.query["chapter"],
                  let index = Int(req.query["i"] ?? "") else {
                return .text("bad params", status: 400)
            }
            do {
                let c = try await JmClient.shared.chapter(id: chapterId, sort: 1, title: "")
                guard index >= 0, index < c.pages.count else {
                    return .text("out of range", status: 404)
                }
                // ImageStore.page 内部已完成解扰 + 磁盘缓存
                guard let img = await ImageStore.shared.page(c.pages[index]),
                      let data = DownloadStore.encode(img, as: .jpeg) else {
                    return .text("decode failed", status: 500)
                }
                return .image(data)
            } catch {
                return .text(error.localizedDescription, status: 500)
            }

        default:
            return .text("Not Found", status: 404)
        }
    }

    private static func parseForm(_ body: Data) -> [String: String] {
        guard let s = String(data: body, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let v = String(kv[1]).replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding ?? String(kv[1])
            out[k] = v
        }
        return out
    }
}
