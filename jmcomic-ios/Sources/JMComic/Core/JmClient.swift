import Foundation

enum JmError: LocalizedError {
    case noDomain
    case badResponse(Int)
    case decryptFailed
    case parseFailed(String)
    case invalidCredentials(String)
    case sessionExpired
    case api(String)

    var errorDescription: String? {
        switch self {
        case .noDomain: return "没有可用域名，请检查网络或代理设置"
        case .badResponse(let code): return "服务器返回 HTTP \(code)"
        case .decryptFailed: return "响应解密失败"
        case .parseFailed(let what): return "解析失败：\(what)"
        case .invalidCredentials(let message):
            return message.isEmpty ? "用户名或密码错误" : "登录失败：\(message)"
        case .sessionExpired: return "JM 登录状态已失效，请重新登录"
        case .api(let message): return message.isEmpty ? "JM 接口返回错误" : message
        }
    }
}

/// 禁漫移动端 API 客户端。
///
/// 与 Java 版的差异：这里不用「占位域名 + 拦截器改写」那套，
/// 直接在发请求时挑当前最优域名，失败就换下一个。行为等价但少一层间接。
actor JmClient {

    private let session: URLSession
    private var domains: [String] = JmConstants.fallbackDomains
    private var failures: [String: Int] = [:]
    private var didBootstrap = false
    /// 缓存排序后的域名列表，仅在 failures 变化时重新计算
    private var _cachedOrderedDomains: [String]?
    private var _failuresVersion = 0
    private var _lastFailuresMutation = 0

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["user-agent": JmConstants.userAgent]
        /*
         * 关掉 URLSession 自带的磁盘缓存。
         * 它会在 Caches 下另建 Cache.db，把每张封面/页面的完整 URL（含本子 ID）
         * 明文记下来，而且 ImageStore.clearDisk() 根本清不到，等于绕过「清除本地数据」。
         * 图片缓存由 ImageStore 统一管，这里只要不留第二份。
         */
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 不使用系统共享 Cookie 仓库。账号会话由 JmAccountStore 单独存钥匙串，
        // 仅在收藏等认证请求中手工附加，匿名浏览不会留下会话痕迹。
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpMaximumConnectionsPerHost = 6
        self.session = URLSession(configuration: config)
    }

    // MARK: - 域名

    /// 从域名服务器拉取最新可用域名。只做一次。
    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        for server in JmConstants.domainServers {
            guard let url = URL(string: server) else { continue }
            do {
                let (data, _) = try await session.data(from: url)
                guard let body = String(data: data, encoding: .utf8) else { continue }
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let plain = JmCrypto.decrypt(base64: trimmed, timestamp: "",
                                                   secret: JmConstants.domainServerSecret),
                      let obj = try? JSONSerialization.jsonObject(with: plain) as? [String: Any]
                else { continue }
                // 服务端字段为 Server / Setting，取并集
                let list = ((obj["Server"] as? [String]) ?? []) + ((obj["Setting"] as? [String]) ?? [])
                let unique = Array(NSOrderedSet(array: list)) as? [String] ?? []
                if !unique.isEmpty {
                    domains = unique
                    failures.removeAll()
                    return
                }
            } catch {
                continue
            }
        }
    }

    /// 失败次数最少的域名优先（缓存排序结果，仅在 failures 变化时重算）
    private var orderedDomains: [String] {
        if let cached = _cachedOrderedDomains, _failuresVersion == _lastFailuresMutation {
            return cached
        }
        let sorted = domains.sorted { (failures[$0] ?? 0) < (failures[$1] ?? 0) }
        _cachedOrderedDomains = sorted
        _lastFailuresMutation = _failuresVersion
        return sorted
    }

    // MARK: - 请求

    private struct JSONResponse {
        let json: [String: Any]
        let cookies: [String: String]
        let host: String
    }

    /// 发签名 GET / POST 并返回解密后的对象。Cookie 不进入系统共享仓库。
    private func requestJSON(path: String,
                             query: [URLQueryItem] = [],
                             form: [URLQueryItem]? = nil,
                             cookies: [String: String] = [:],
                             preferredHost: String? = nil,
                             authenticated: Bool = false,
                             secret: String = JmConstants.tokenSecret) async throws -> JSONResponse {
        await bootstrap()
        var lastError: Error = JmError.noDomain

        var hosts = orderedDomains
        if let preferredHost, let index = hosts.firstIndex(of: preferredHost) {
            hosts.remove(at: index)
            hosts.insert(preferredHost, at: 0)
        } else if let preferredHost, !preferredHost.isEmpty {
            hosts.insert(preferredHost, at: 0)
        }

        for host in hosts {
            var comps = URLComponents()
            comps.scheme = "https"
            comps.host = host
            comps.path = "/" + path
            comps.queryItems = query.isEmpty ? nil : query
            guard let url = comps.url else { continue }

            let ts = String(Int(Date().timeIntervalSince1970))
            let t = JmCrypto.token(timestamp: ts, secret: secret, appVersion: JmConstants.appVersion)
            var req = URLRequest(url: url)
            req.setValue(t.token, forHTTPHeaderField: "token")
            req.setValue(t.param, forHTTPHeaderField: "tokenparam")
            if let form {
                req.httpMethod = "POST"
                var body = URLComponents()
                body.queryItems = form
                let encoded = (body.percentEncodedQuery ?? "").replacingOccurrences(of: "%20", with: "+")
                req.httpBody = Data(encoded.utf8)
                req.setValue("application/x-www-form-urlencoded; charset=utf-8",
                             forHTTPHeaderField: "Content-Type")
            }
            let safeCookies = cookies.filter { name, value in
                !name.isEmpty && !name.contains(";") && !name.contains("\n")
                    && !value.contains(";") && !value.contains("\n")
            }
            if !safeCookies.isEmpty {
                let header = safeCookies.keys.sorted().compactMap { name in
                    safeCookies[name].map { "\(name)=\($0)" }
                }.joined(separator: "; ")
                req.setValue(header, forHTTPHeaderField: "Cookie")
            }

            do {
                let (data, response) = try await session.data(for: req)
                guard let http = response as? HTTPURLResponse else {
                    throw JmError.parseFailed("无法读取 HTTP 响应")
                }
                let code = http.statusCode
                guard code == 200 else {
                    if path == "login", code == 401 || code == 403 {
                        throw JmError.invalidCredentials("")
                    }
                    if authenticated, code == 401 || code == 403 {
                        lastError = JmError.sessionExpired
                        continue
                    }
                    failures[host, default: 0] += 1
                    _failuresVersion += 1
                    lastError = JmError.badResponse(code)
                    continue
                }
                guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    failures[host, default: 0] += 1
                    _failuresVersion += 1
                    lastError = JmError.parseFailed("响应结构异常")
                    continue
                }
                let apiCode: Int
                if let value = envelope["code"] as? Int {
                    apiCode = value
                } else if let value = envelope["code"] as? String, let parsed = Int(value) {
                    apiCode = parsed
                } else {
                    // 缺失或非数字 code 表示当前镜像响应损坏，不是业务错误。
                    // 记录为主机级故障并尝试下一个域名，避免一个异常镜像阻断全部请求。
                    failures[host, default: 0] += 1
                    _failuresVersion += 1
                    lastError = JmError.parseFailed("响应缺少有效 code 字段")
                    continue
                }
                guard apiCode == 200, let encoded = envelope["data"] as? String else {
                    let message = (envelope["errorMsg"] as? String)
                        ?? (envelope["message"] as? String)
                        ?? ""
                    if path == "login" { throw JmError.invalidCredentials(message) }
                    // 只有服务端明确返回认证状态码时才删除本机会话。
                    // 普通业务错误即使提到 login/member，也不能据此判定 Cookie 失效。
                    if authenticated, apiCode == 401 || apiCode == 403 {
                        lastError = JmError.sessionExpired
                        continue
                    }
                    throw JmError.api(message)
                }
                guard let plain = JmCrypto.decrypt(base64: encoded, timestamp: ts,
                                                   secret: JmConstants.dataSecret),
                      let obj = try? JSONSerialization.jsonObject(with: plain) else {
                    lastError = JmError.decryptFailed
                    continue
                }
                failures[host] = 0
                _failuresVersion += 1
                let json: [String: Any]
                if let dict = obj as? [String: Any] {
                    json = dict
                } else if let arr = obj as? [Any] {
                    json = ["list": arr]
                } else {
                    throw JmError.parseFailed("未知的 JSON 结构")
                }

                let headerFields = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                    guard let key = pair.key as? String else { return }
                    result[key] = String(describing: pair.value)
                }
                let responseCookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
                let cookieMap = responseCookies.reduce(into: [String: String]()) { result, cookie in
                    result[cookie.name] = cookie.value
                }
                return JSONResponse(json: json, cookies: cookieMap, host: host)
            } catch let error as JmError {
                switch error {
                case .invalidCredentials, .api:
                    throw error
                case .sessionExpired:
                    lastError = error
                    continue
                default:
                    failures[host, default: 0] += 1
                    _failuresVersion += 1
                    lastError = error
                    continue
                }
            } catch {
                failures[host, default: 0] += 1
                _failuresVersion += 1
                lastError = error
                continue
            }
        }
        throw lastError
    }

    /// 保留匿名业务接口的简洁调用形式。
    private func getJSON(path: String, query: [URLQueryItem] = [],
                         secret: String = JmConstants.tokenSecret) async throws -> [String: Any] {
        try await requestJSON(path: path, query: query, secret: secret).json
    }

    /// 下载原始字节（图片、封面）。不签名、不解密。
    func fetchData(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw JmError.badResponse(code) }
        return data
    }

    func coverURL(albumId: String) async -> URL? {
        await bootstrap()
        guard let host = orderedDomains.first else { return nil }
        return URL(string: "https://\(host)/media/albums/\(albumId)_3x4.jpg")
    }

    // MARK: - 业务接口

    func login(username: String, password: String) async throws -> JmLoginResult {
        let response = try await requestJSON(path: "login", form: [
            .init(name: "username", value: username),
            .init(name: "password", value: password),
        ])
        let profile = try JmParser.parseAccount(response.json, fallbackUsername: username)
        guard let avs = response.json["s"] as? String, !avs.isEmpty else {
            throw JmError.invalidCredentials("登录响应缺少会话信息")
        }
        var cookies = response.cookies
        cookies["AVS"] = avs
        return JmLoginResult(profile: profile, cookies: cookies, preferredHost: response.host)
    }

    func favoritePage(page: Int, folderID: String,
                      cookies: [String: String], preferredHost: String) async throws -> JmFavoritePage {
        let response = try await requestJSON(path: "favorite", query: [
            .init(name: "page", value: String(page)),
            .init(name: "folder_id", value: folderID),
            .init(name: "o", value: "mr"),
        ], cookies: cookies, preferredHost: preferredHost, authenticated: true)
        return JmParser.parseFavoritePage(response.json, page: page)
    }

    func hot(page: Int) async throws -> PagedAlbums {
        let json = try await getJSON(path: "search", query: [
            .init(name: "main_tag", value: "0"),
            .init(name: "search_query", value: ""),
            .init(name: "o", value: "mv"),
            .init(name: "t", value: "w"),
            .init(name: "page", value: String(page)),
        ])
        return JmParser.parsePaged(json, page: page)
    }

    func latest(page: Int) async throws -> PagedAlbums {
        let json = try await getJSON(path: "latest", query: [
            .init(name: "page", value: String(page)),
        ])
        return JmParser.parsePaged(json, page: page)
    }

    func search(_ text: String, page: Int) async throws -> PagedAlbums {
        let json = try await getJSON(path: "search", query: [
            .init(name: "main_tag", value: "0"),
            .init(name: "search_query", value: text),
            .init(name: "page", value: String(page)),
        ])
        return JmParser.parsePaged(json, page: page)
    }

    /// 热门标签（服务端真实数据；纯数组/{"list":[...]} 两种格式都被归一化）
    func hotTags() async throws -> [String] {
        let json = try await getJSON(path: "hot_tags")
        guard let list = json["list"] as? [Any] else { return [] }
        return list.compactMap { $0 as? String }
    }

    /// 分类筛选：c 为大类 slug（doujin/single/short/hanman/meiman/cosplay/3D 等），
    /// o 为排序（mv=最多观看）。与 Java 版 getCategories 对齐。
    func categories(_ category: String, order: String = "mv", page: Int) async throws -> PagedAlbums {
        let json = try await getJSON(path: "categories/filter", query: [
            .init(name: "page", value: String(page)),
            .init(name: "order", value: ""),
            .init(name: "c", value: category),
            .init(name: "o", value: order),
        ])
        return JmParser.parsePaged(json, page: page)
    }

    func album(id: String) async throws -> Album {
        let json = try await getJSON(path: "album", query: [
            .init(name: "comicName", value: ""),
            .init(name: "id", value: id),
        ])
        return try JmParser.parseAlbum(json, fallbackId: id)
    }

    private var chapterCache: [String: Chapter] = [:]
    private var chapterCacheOrder: [String] = []
    private let chapterCacheLimit = 50

    func chapter(id: String, sort: Int, title: String) async throws -> Chapter {
        if let cached = chapterCache[id] { return cached }
        let json = try await getJSON(path: "chapter", query: [
            .init(name: "id", value: id),
        ])
        let chapter = try JmParser.parseChapter(json, id: id, sort: sort, title: title)
        chapterCache[id] = chapter
        chapterCacheOrder.append(id)
        // LRU 淘汰
        while chapterCacheOrder.count > chapterCacheLimit {
            let oldest = chapterCacheOrder.removeFirst()
            chapterCache.removeValue(forKey: oldest)
        }
        return chapter
    }

    /// 章节列表可能很长，不要让它们占住内存不放；也顺带清掉缓存中的过期条目
    func clearChapterCache() {
        chapterCache.removeAll()
        chapterCacheOrder.removeAll()
    }
}
