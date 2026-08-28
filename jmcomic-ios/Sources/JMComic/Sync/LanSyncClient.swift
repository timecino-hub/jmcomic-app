import Foundation
import CryptoKit
import CommonCrypto
import Security

// MARK: - 桌面同步客户端（iOS 端）
//
// 与 Mac 端 LanSyncServer 对应的协议实现：
//   1. POST /pair            X-Pair-Token: <配对码> + {"deviceName":...} → {"sessionToken","deviceId"}
//   2. GET  /metadata/pull   application/octet-stream，PBKDF2+AES-GCM 加密包
//   3. POST /metadata/push   同密钥同格式上传，服务端合并进本地 stores
//   4. GET  /downloads/list  已下载专辑清单 JSON
//   5. GET  /downloads/file?path=<相对路径>  单文件二进制
//
// 加密格式与 Mac SyncStore / LanSyncServer 完全同构：
//   PBKDF2-SHA256(配对码, salt16, 210000 轮) → 32B AES-256 密钥
//   包格式 salt(16)‖nonce(12)‖ciphertext‖tag(16)，明文为 {"favorites":b64,"state":b64}
//
// 注意：服务端对同 IP 鉴权失败 ≥5 次封禁 10 分钟，所以 401 一律直接报错返回，
// 客户端绝不做自动重试。

/// 二维码配置串解析结果：jmsync|v1|<ip>|<port>|<pairCode>
struct SyncConfig: Equatable {
    var host: String
    var port: UInt16
    var pairCode: String
}

enum LanSyncError: LocalizedError {
    /// 配对码错误（/pair 返回 401）
    case badPairCode
    /// 会话无效/已被 Mac 撤销（业务端点返回 401）——不要重试，重新配对
    case unauthorized
    /// 路径被拒绝或触发服务端限流封禁（403）
    case forbidden(String)
    /// push 数据无法被服务端解密（400）
    case badPayload
    /// 清单/文件大小与声明不符
    case sizeMismatch(String)
    /// 服务端返回其它状态码
    case http(Int)
    /// 本地构造请求失败（URL 非法等）
    case badRequest(String)
    /// 加解密/打包失败
    case crypto(String)

    var errorDescription: String? {
        switch self {
        case .badPairCode:
            return "配对码无效。请确认 Mac 端显示的 8 位配对码（连续输错会触发限流封禁）。"
        case .unauthorized:
            return "会话已失效（可能被 Mac 端撤销），请解绑后重新扫码配对。"
        case .forbidden(let detail):
            return "被服务端拒绝：\(detail)"
        case .badPayload:
            return "Mac 端无法解密推送的数据包。"
        case .sizeMismatch(let p):
            return "文件大小与清単不符：\(p)"
        case .http(let code):
            return "服务端返回错误（HTTP \(code)）。"
        case .badRequest(let why):
            return why
        case .crypto(let why):
            return "数据加解密失败：\(why)"
        }
    }
}

/// 会话持久化记录（钥匙串一条 GenericPassword，JSON 编码）。
/// pairCode 必须随会话一起保存：pull/push 的派生密钥用的是「配对那一刻」的配对码，
/// 即使 Mac 端后来重新生成配对码也不影响已配对会话。
struct SyncSession: Codable, Equatable {
    var sessionToken: String
    var deviceId: String
    var pairCode: String
    var host: String
    var port: UInt16
    var deviceName: String     // 配对时上报给 Mac 的本机名称
    var pairedAt: Date

    /// 「ip:端口」展示文本
    var addressText: String { "\(host):\(port)" }
}

/// 已下载专辑清单条目（与服务端 LanDownloadAlbum 同构）
struct LanDownloadFile: Codable, Hashable {
    /// 相对下载根目录路径，「/」分隔
    let path: String
    let size: Int
}

struct LanDownloadAlbum: Codable, Hashable, Identifiable {
    let albumId: String
    let title: String
    let files: [LanDownloadFile]

    var id: String { albumId }
    /// 总字节数（列表展示用）
    var totalBytes: Int { files.reduce(0) { $0 + $1.size } }
}

// MARK: - 元数据包封 / 拆（与 LanSyncServer.sealPayload/openPayload 完全同构）

enum SyncPayload {

    /// PBKDF2-SHA256，210000 轮，输出 32 字节 AES-256 密钥
    static func deriveKey(password: String, salt: Data) -> SymmetricKey {
        var keyData = Data(count: 32)
        let pw = Array(password.utf8)
        _ = keyData.withUnsafeMutableBytes { outBuf in
            salt.withUnsafeBytes { saltBuf in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     pw, pw.count,
                                     saltBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                     salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                     210_000,
                                     outBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                     32)
            }
        }
        return SymmetricKey(data: keyData)
    }

    /// 打包 {"favorites":b64,"state":b64}，输出 salt(16)‖nonce(12)‖ciphertext‖tag(16)
    static func seal(favorites: Data, state: Data, password: String) throws -> Data {
        let payload: [String: Any] = [
            "favorites": favorites.base64EncodedString(),
            "state": state.base64EncodedString(),
        ]
        guard let plain = try? JSONSerialization.data(withJSONObject: payload) else {
            throw LanSyncError.crypto("元数据序列化失败")
        }
        var salt = Data(count: 16)
        let saltOK = salt.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        guard saltOK == errSecSuccess else { throw LanSyncError.crypto("随机数生成失败") }
        let key = deriveKey(password: password, salt: salt)
        guard let sealed = try? AES.GCM.seal(plain, using: key) else {
            throw LanSyncError.crypto("AES-GCM 加密失败")
        }
        var out = salt
        out.append(contentsOf: sealed.nonce.withUnsafeBytes { Data($0) })
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    /// 拆 seal 的产物。密码错误/被篡改/结构不对抛 crypto 错误。
    static func open(_ data: Data, password: String) throws -> (favorites: Data, state: Data) {
        // 格式：salt(16) || nonce(12) || ciphertext || tag(16)，绝对索引切片防越界
        guard data.count > 16 + 12 + 16 else { throw LanSyncError.crypto("数据包结构不对") }
        let salt = data.prefix(16)
        let nonceData = data[16..<28]
        let ciphertext = data[28..<(data.count - 16)]
        let tag = data.suffix(16)
        let key = deriveKey(password: password, salt: salt)
        guard let nonce = try? AES.GCM.Nonce(data: nonceData),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag),
              let plain = try? AES.GCM.open(box, using: key)
        else { throw LanSyncError.crypto("解密失败（配对码不匹配或数据被篡改）") }
        guard let obj = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
              let favB64 = obj["favorites"] as? String,
              let stB64 = obj["state"] as? String,
              let fav = Data(base64Encoded: favB64),
              let st = Data(base64Encoded: stB64)
        else { throw LanSyncError.crypto("解密后的数据格式无法解析") }
        return (fav, st)
    }
}

// MARK: - HTTP 客户端

final class LanSyncClient: @unchecked Sendable {

    /// iOS 端钥匙串 service（与 Mac 端 local.jmcomic-lansync 区分）
    static let keychainService = "local.jmcomic-ios-lansync"
    private static let keychainAccount = "session"

    /// 服务端配对码字母表（校验手动输入用，与 LanSyncServer.pairAlphabet 一致）
    static let pairAlphabet = Set("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    /// 一次性配置（当前会话的目标地址），由 DesktopSyncModel 在恢复/配对后设置
    var session: SyncSession?

    /// ephemeral HTTP 会话（不共享 cookie/缓存）
    private let http: URLSession

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5      // 连接/相邻数据包空闲上限（局域网足够）
        cfg.timeoutIntervalForResource = 60    // 单请求总时长上限
        cfg.waitsForConnectivity = false
        http = URLSession(configuration: cfg)
    }

    // MARK: 配置串解析

    /// 严格解析「jmsync|v1|<ip>|<port>|<pairCode>」：必须恰好 5 段、版本 v1、
    /// 端口 1~65535、配对码 8 位且在服务端字母表内。任何一项不符即报错。
    static func parseConfig(_ raw: String) -> Result<SyncConfig, LanSyncError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.components(separatedBy: "|")
        guard parts.count == 5 else {
            return .failure(.badRequest("配置串格式不对：应为 jmsync|v1|IP|端口|配对码（5 段）"))
        }
        guard parts[0] == "jmsync" else {
            return .failure(.badRequest("不是本应用的配置串（前缀应为 jmsync）"))
        }
        guard parts[1] == "v1" else {
            return .failure(.badRequest("协议版本不支持：\(parts[1])"))
        }
        let host = parts[2].trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !host.contains(" "), !host.contains("/") else {
            return .failure(.badRequest("IP 地址不合法：\(parts[2])"))
        }
        guard let port = UInt16(parts[3].trimmingCharacters(in: .whitespaces)), port > 0 else {
            return .failure(.badRequest("端口不合法：\(parts[3])"))
        }
        let code = parts[4].trimmingCharacters(in: .whitespaces).uppercased()
        guard code.count == 8, code.allSatisfy({ pairAlphabet.contains($0) }) else {
            return .failure(.badRequest("配对码应为 8 位大写字母/数字（不含 I、L、O、0、1）"))
        }
        return .success(SyncConfig(host: host, port: port, pairCode: code))
    }

    // MARK: 钥匙串（参考 CryptoStore 的写法；一条 GenericPassword 存整个会话 JSON）

    static func loadSession() -> SyncSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(SyncSession.self, from: data)
    }

    static func saveSession(_ s: SyncSession) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(add as CFDictionary, nil) != errSecSuccess {
            // 写入失败不致命：下次配对可重建；这里静默（与全局错误提示通道解耦）
        }
    }

    static func clearSession() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ] as CFDictionary)
    }

    // MARK: 请求基础

    private func url(path: String, query: [String: String] = [:]) throws -> URL {
        var comps = URLComponents()
        comps.scheme = "http"
        guard let s = session else {
            throw LanSyncError.badRequest("尚未配对")
        }
        comps.host = s.host
        comps.port = Int(s.port)
        comps.path = path
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else {
            throw LanSyncError.badRequest("请求地址构造失败")
        }
        return url
    }

    /// 统一状态码检查：401/403/400 各给明确文案，其余抛 http(code)
    private func checkStatus(_ code: Int, context: String) throws {
        guard code == 200 else {
            switch code {
            case 401:
                throw context == "pair" ? LanSyncError.badPairCode : LanSyncError.unauthorized
            case 403:
                throw LanSyncError.forbidden("路径被拒绝或触发限流封禁（\(context)）")
            case 400:
                throw LanSyncError.badPayload
            default:
                throw LanSyncError.http(code)
            }
        }
    }

    // MARK: 1. 配对

    /// POST /pair：用配对码换长期会话。成功返回应保存的会话记录。
    func pair(config: SyncConfig, deviceName: String) async throws -> SyncSession {
        session = SyncSession(sessionToken: "", deviceId: "", pairCode: config.pairCode,
                              host: config.host, port: config.port,
                              deviceName: deviceName, pairedAt: Date())
        var req = try url(path: "/pair").request()
        req.httpMethod = "POST"
        req.setValue(config.pairCode, forHTTPHeaderField: "X-Pair-Token")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["deviceName": deviceName]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await http.data(for: req)
        try checkStatus((resp as? HTTPURLResponse)?.statusCode ?? 0, context: "pair")
        // 响应解析：{"sessionToken":..., "deviceId":...}，绝不强解包
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["sessionToken"] as? String, !token.isEmpty,
              let deviceId = obj["deviceId"] as? String, !deviceId.isEmpty
        else {
            throw LanSyncError.badRequest("配对响应格式无法解析")
        }
        let rec = SyncSession(sessionToken: token, deviceId: deviceId,
                              pairCode: config.pairCode, host: config.host,
                              port: config.port, deviceName: deviceName, pairedAt: Date())
        session = rec
        return rec
    }

    // MARK: 2. 拉取元数据

    /// GET /metadata/pull → 解密出 favorites/state 两段明文 JSON
    func pullMetadata() async throws -> (favorites: Data, state: Data) {
        guard let s = session else { throw LanSyncError.badRequest("尚未配对") }
        var req = try url(path: "/metadata/pull").request()
        req.httpMethod = "GET"
        req.setValue("Bearer \(s.sessionToken)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await http.data(for: req)
        try checkStatus((resp as? HTTPURLResponse)?.statusCode ?? 0, context: "metadata/pull")
        return try SyncPayload.open(data, password: s.pairCode)
    }

    // MARK: 3. 推送元数据

    /// POST /metadata/push：本地全量打包加密上传，Mac 端按合并语义落盘
    func pushMetadata(favorites: Data, state: Data) async throws {
        guard let s = session else { throw LanSyncError.badRequest("尚未配对") }
        let sealed = try SyncPayload.seal(favorites: favorites, state: state, password: s.pairCode)
        var req = try url(path: "/metadata/push").request()
        req.httpMethod = "POST"
        req.setValue("Bearer \(s.sessionToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = sealed

        let (data, resp) = try await http.data(for: req)
        try checkStatus((resp as? HTTPURLResponse)?.statusCode ?? 0, context: "metadata/push")
        // 服务端回 {"ok":true}；解析失败也仅提示，不视为传输失败
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["ok"] as? Bool != true {
            throw LanSyncError.badRequest("推送响应异常")
        }
    }

    // MARK: 4. 下载清单

    /// GET /downloads/list
    func fetchDownloadsList() async throws -> [LanDownloadAlbum] {
        guard let s = session else { throw LanSyncError.badRequest("尚未配对") }
        var req = try url(path: "/downloads/list").request()
        req.httpMethod = "GET"
        req.setValue("Bearer \(s.sessionToken)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await http.data(for: req)
        try checkStatus((resp as? HTTPURLResponse)?.statusCode ?? 0, context: "downloads/list")
        do {
            return try JSONDecoder().decode([LanDownloadAlbum].self, from: data)
        } catch {
            throw LanSyncError.badRequest("下载清单解析失败")
        }
    }

    // MARK: 5. 单文件下载

    /// GET /downloads/file?path=<相对路径>（URLComponents 自动做 query 编码）
    func downloadFile(_ path: String) async throws -> Data {
        guard let s = session else { throw LanSyncError.badRequest("尚未配对") }
        var req = try url(path: "/downloads/file", query: ["path": path]).request()
        req.httpMethod = "GET"
        req.setValue("Bearer \(s.sessionToken)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await http.data(for: req)
        try checkStatus((resp as? HTTPURLResponse)?.statusCode ?? 0, context: "downloads/file")
        return data
    }
}

private extension URL {
    func request() -> URLRequest {
        var req = URLRequest(url: self)
        req.timeoutInterval = 60   // 资源级超时兜底（会话级 60s 之外再保险）
        return req
    }
}
