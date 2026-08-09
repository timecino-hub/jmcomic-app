import Foundation
import CommonCrypto

/// 局域网访问的认证。
///
/// 威胁模型：同一局域网内的其他人（室友、同事、公共 WiFi 邻居）不该能打开。
/// 不防的是能抓包的攻击者 —— 明文 HTTP 下密码和 token 在网线上是可见的。
/// 这是选「访问控制优先」的已知取舍，要防抓包需要开 HTTPS。
///
/// 访问要过三道门：
/// 1. 入场 token（一次性）：扫码/手输进入。每次消费自动轮换，旧 token 立即作废。
///    没有有效入场 token 时，服务端对一切路径返回 404 —— 登录页"不存在"。
/// 2. preauth 短时凭证：入场 token 换来的 5 分钟通行证，绑定来源 IP，
///    只够走到登录页并提交密码。
/// 3. 密码 + 会话：PBKDF2 校验（失败按 IP 限流），会话 cookie 绑定 IP，
///    带设备元信息供 Mac 端在线设备管理。
///
/// 实现要点：
/// - 密码只存 PBKDF2 派生值，不存明文，也不存可逆密文
/// - token 用 SecRandomCopyBytes，不用 UUID（UUID 不保证密码学强度）
/// - 比较一律常数时间，避免用响应耗时逐字节猜
/// - 登录失败限流，防止局域网内暴力枚举
actor WebAuth {

    static let shared = WebAuth()

    private struct Stored: Codable {
        var salt: Data
        var hash: Data
        var rounds: UInt32
    }

    /// 一个已登录设备（在线会话）。字段供 Mac 端设备管理面板展示与踢出。
    struct Session {
        var token: String
        var ip: String
        var userAgent: String
        var deviceName: String
        var createdAt: Date
        var lastSeen: Date
        var lastPath: String
        /// 受信任设备才能写数据（进度/收藏）；默认信任，设备管理里可取消勾选降级为只读
        var trusted: Bool
    }

    private var stored: Stored?
    private var sessions: [String: Session] = [:]
    private let sessionTTL: TimeInterval = 7 * 24 * 3600

    /// preauth：入场 token 换来的短时通行证，值本身是随机串，绑定来源 IP
    private var preauth: [String: (expiry: Date, ip: String)] = [:]
    private let preauthTTL: TimeInterval = 300

    /// 一次性入场 token。每次消费即轮换，旧 token 立刻失效。
    private var bootToken: String = WebAuth.randomToken()
    /// 轮换计数器，用于让 UI 感知"被用过一次"（对 UI 只暴露增量，不暴露 token 本身）
    private var bootTokenEpoch = 0

    /// 失败计数与锁定，按来源 IP 分别记
    private var failures: [String: (count: Int, until: Date)] = [:]
    private let maxFailures = 5
    private let lockout: TimeInterval = 300

    private let file: URL

    init() {
        // 开发副本用独立目录，避免和正式版共用 webauth.json
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("JMComicDev", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("webauth.json")
        if let data = try? Data(contentsOf: file),
           let s = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = s
        }
    }

    var hasPassword: Bool { stored != nil }

    static func randomToken() -> String {
        var raw = Data(count: 32)
        _ = raw.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        return raw.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 密码

    func setPassword(_ plain: String) {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let rounds: UInt32 = 210_000     // OWASP 对 PBKDF2-HMAC-SHA256 的建议量级
        let hash = Self.derive(plain, salt: salt, rounds: rounds)
        let s = Stored(salt: salt, hash: hash, rounds: rounds)
        stored = s
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: file.path)
        }
        invalidateAllCredentials()
    }

    func clearPassword() {
        stored = nil
        try? FileManager.default.removeItem(at: file)
        invalidateAllCredentials()
    }

    /// 改密/清密后：旧会话、preauth、入场 token 全部作废
    private func invalidateAllCredentials() {
        sessions.removeAll()
        preauth.removeAll()
        failures.removeAll()
        rotateBootToken()
    }

    private static func derive(_ password: String, salt: Data, rounds: UInt32) -> Data {
        var out = Data(count: 32)
        let pw = Array(password.utf8)
        _ = out.withUnsafeMutableBytes { outBuf in
            salt.withUnsafeBytes { saltBuf in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     pw, pw.count,
                                     saltBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                     salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                     rounds,
                                     outBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                     32)
            }
        }
        return out
    }

    /// 两个等长字节序列的常数时间比较
    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    // MARK: - 入场 token（一次性，每次消费轮换）

    /// 当前有效的入场 token（拼进二维码/文本让设备进入）
    var currentBootToken: String { bootToken }

    /// token + 轮换计数，供 UI 一次性拉取
    var bootTokenInfo: (token: String, epoch: Int) { (bootToken, bootTokenEpoch) }

    /// 手动换一个（主动作废已泄露的二维码/截图）。返回新 token 与轮换计数。
    @discardableResult
    func rotateBootToken() -> (token: String, epoch: Int) {
        bootToken = WebAuth.randomToken()
        bootTokenEpoch += 1
        return (bootToken, bootTokenEpoch)
    }

    /// 校验并消费入场 token。成功则轮换并返回新 token；失败返回 nil。
    func consumeBootToken(_ candidate: String) -> (token: String, epoch: Int)? {
        guard Self.constantTimeEqual(Data(candidate.utf8), Data(bootToken.utf8)) else { return nil }
        return rotateBootToken()
    }

    // MARK: - preauth（入场后的短时通行证）

    func grantPreauth(ip: String) -> String {
        let t = WebAuth.randomToken()
        preauth[t] = (Date().addingTimeInterval(preauthTTL), ip)
        return t
    }

    func validatePreauth(token: String?, ip: String) -> Bool {
        guard let token, let p = preauth[token] else { return false }
        guard p.expiry > Date() else {
            preauth[token] = nil
            return false
        }
        guard p.ip == ip else { return false }
        return true
    }

    func consumePreauth(token: String?) {
        if let token { preauth[token] = nil }
    }

    // MARK: - 登录

    enum LoginResult {
        case ok(token: String)
        case wrong
        case locked(retryAfter: Int)
        case notConfigured
    }

    func login(password: String, from ip: String,
               userAgent: String, deviceName: String) -> LoginResult {
        if let f = failures[ip], f.count >= maxFailures {
            if f.until > Date() {
                return .locked(retryAfter: Int(f.until.timeIntervalSinceNow))
            }
            // 锁定期已过：清零重新计数。
            // 不清的话计数会一直停在上限，之后随便打错一次就又锁 5 分钟。
            failures[ip] = nil
        }
        guard let s = stored else { return .notConfigured }

        let candidate = Self.derive(password, salt: s.salt, rounds: s.rounds)
        guard Self.constantTimeEqual(candidate, s.hash) else {
            var f = failures[ip] ?? (0, .distantPast)
            f.count += 1
            if f.count >= maxFailures { f.until = Date().addingTimeInterval(lockout) }
            failures[ip] = f
            return .wrong
        }

        failures[ip] = nil
        let token = WebAuth.randomToken()
        let now = Date()
        sessions[token] = Session(token: token, ip: ip, userAgent: userAgent,
                                  deviceName: deviceName, createdAt: now,
                                  lastSeen: now, lastPath: "/", trusted: true)
        return .ok(token: token)
    }

    /// 扫码自动登录：入场 token 直接换会话（设置里可关，关掉后走 preauth → 密码）。
    /// 风险提示：此模式下拿到二维码的人无需密码即可进入，等同把 token 当钥匙。
    func createSession(ip: String, userAgent: String) -> String {
        let token = WebAuth.randomToken()
        let now = Date()
        sessions[token] = Session(token: token, ip: ip, userAgent: userAgent,
                                  deviceName: Self.deviceName(from: userAgent),
                                  createdAt: now, lastSeen: now, lastPath: "/",
                                  trusted: true)
        return token
    }

    /// 设置设备信任状态（取消勾选后该设备只能读不能写）
    func setTrusted(token: String, trusted: Bool) {
        sessions[token]?.trusted = trusted
    }

    /// 会话是否受信任（校验存在 + IP 一致 + 信任标记）
    func isTrusted(token: String?, ip: String) -> Bool {
        guard let token, let s = sessions[token] else { return false }
        return s.ip == ip && s.trusted
    }

    /// 校验会话：token 有效 + 未过期 + IP 一致（会话绑定来源 IP，防止 cookie 被别处重放）。
    /// 校验通过时顺带更新最近活跃信息。
    func validate(token: String?, ip: String, path: String, userAgent: String) -> Bool {
        guard let token, var s = sessions[token] else { return false }
        guard s.createdAt.addingTimeInterval(sessionTTL) > Date() else {
            sessions[token] = nil
            return false
        }
        guard s.ip == ip else { return false }
        s.lastSeen = Date()
        s.lastPath = path
        if !userAgent.isEmpty { s.userAgent = userAgent; s.deviceName = Self.deviceName(from: userAgent) }
        sessions[token] = s
        return true
    }

    func logout(token: String?) {
        if let token { sessions[token] = nil }
    }

    func revokeSession(token: String) {
        sessions[token] = nil
    }

    func revokeAllSessions() {
        sessions.removeAll()
        preauth.removeAll()
        rotateBootToken()
    }

    /// 在线设备快照（token 本身不暴露给 UI，只用于踢出时的定位）
    func activeSessions() -> [Session] {
        let now = Date()
        // 顺手清掉过期会话，避免列表越攒越长
        sessions = sessions.filter { $0.value.createdAt.addingTimeInterval(sessionTTL) > now }
        return Array(sessions.values)
    }

    // MARK: - 设备名粗解析

    /// 从 User-Agent 里猜一个人类可读的设备名。只用于管理面板展示，猜错无所谓。
    static func deviceName(from ua: String) -> String {
        var os = "?"
        if ua.contains("iPhone") || ua.contains("iPad") || ua.contains("iPod") { os = "iOS" }
        else if ua.contains("Android") { os = "Android" }
        else if ua.contains("Macintosh") { os = "Mac" }
        else if ua.contains("Windows") { os = "Windows" }
        else if ua.contains("Linux") { os = "Linux" }

        var app = "浏览器"
        if ua.contains("MicroMessenger") { app = "微信" }
        else if ua.contains("Edg/") { app = "Edge" }
        else if ua.contains("Chrome") { app = "Chrome" }
        else if ua.contains("Safari") { app = "Safari" }
        else if ua.contains("Firefox") { app = "Firefox" }

        return app == "浏览器" ? os : "\(app) · \(os)"
    }
}
