import Foundation
import Network
import Security

/// 极简 HTTP/1.1 服务器，基于系统 Network.framework，无第三方依赖。
///
/// 只实现自用所需：GET/POST、路径与查询解析、Cookie、二进制响应、Range 忽略。
/// 不支持 keep-alive 流水线、分块上传、WebSocket —— 用不到。
///
/// 传入 tls 身份时走 HTTPS（自签证书，见 TLSCert），否则明文 HTTP。
final class HTTPServer: @unchecked Sendable {

    struct Request {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var body: Data
        var clientIP: String

        var cookies: [String: String] {
            guard let raw = headers["cookie"] else { return [:] }
            var out: [String: String] = [:]
            for part in raw.split(separator: ";") {
                let kv = part.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                out[kv[0].trimmingCharacters(in: .whitespaces)] =
                    kv[1].trimmingCharacters(in: .whitespaces)
            }
            return out
        }
    }

    struct Response {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: Data = Data()

        static func json(_ obj: Any, status: Int = 200) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
            return Response(status: status,
                            headers: ["Content-Type": "application/json; charset=utf-8"],
                            body: data)
        }

        static func html(_ s: String) -> Response {
            Response(headers: ["Content-Type": "text/html; charset=utf-8"],
                     body: Data(s.utf8))
        }

        static func image(_ data: Data, type: String = "image/jpeg") -> Response {
            Response(headers: [
                "Content-Type": type,
                // 图片按内容寻址，可以长缓存；移动端流量敏感，这一项收益明显
                "Cache-Control": "private, max-age=604800",
            ], body: data)
        }

        static func text(_ s: String, status: Int = 200) -> Response {
            Response(status: status,
                     headers: ["Content-Type": "text/plain; charset=utf-8"],
                     body: Data(s.utf8))
        }

        static func redirect(_ to: String) -> Response {
            Response(status: 302, headers: ["Location": to])
        }
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "jm.http", attributes: .concurrent)
    private let handler: (Request) async -> Response

    private(set) var port: UInt16 = 0
    private(set) var isRunning = false

    init(handler: @escaping (Request) async -> Response) {
        self.handler = handler
    }

    func start(port desired: UInt16, tls: sec_identity_t? = nil) throws {
        stop()
        // 只监听本机网络接口；不做 NAT 穿透，外网进不来
        let params: NWParameters
        if let tls {
            let tlsOpts = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tlsOpts.securityProtocolOptions, tls)
            params = NWParameters(tls: tlsOpts)
        } else {
            params = NWParameters.tcp
        }
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: desired) else {
            throw NSError(domain: "jm.http", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "端口无效"])
        }
        let l = try NWListener(using: params, on: nwPort)
        l.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.isRunning = true
            case .cancelled, .failed: self?.isRunning = false
            default: break
            }
        }
        l.start(queue: queue)
        listener = l
        port = desired
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let chunk { buf.append(chunk) }

            if error != nil {
                conn.cancel()
                return
            }

            // 头部还没收全，继续收
            guard let headerEnd = Self.findHeaderEnd(buf) else {
                if isComplete { conn.cancel() } else { self.receive(conn, buffer: buf) }
                return
            }

            let headerData = buf.prefix(headerEnd)
            guard var req = Self.parseHead(headerData, conn: conn) else {
                self.send(conn, .text("Bad Request", status: 400), close: true)
                return
            }

            // 有 body 的话要等够长度
            let contentLength = Int(req.headers["content-length"] ?? "0") ?? 0
            let bodyStart = headerEnd + 4
            let available = buf.count - bodyStart
            if available < contentLength {
                if isComplete { conn.cancel() } else { self.receive(conn, buffer: buf) }
                return
            }
            if contentLength > 0 {
                req.body = buf.subdata(in: bodyStart..<(bodyStart + contentLength))
            }

            let finalReq = req
            Concurrency.detached {
                let resp = await self.handler(finalReq)
                self.send(conn, resp, close: true)
            }
        }
    }

    private static func findHeaderEnd(_ d: Data) -> Int? {
        guard d.count >= 4 else { return nil }
        let pattern: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        for i in 0...(d.count - 4) where Array(d[d.startIndex + i..<d.startIndex + i + 4]) == pattern {
            return i
        }
        return nil
    }

    private static func parseHead(_ data: Data, conn: NWConnection) -> Request? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0])
        let target = String(parts[1])
        var path = target
        var query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<q])
            let qs = String(target[target.index(after: q)...])
            for pair in qs.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let v = kv.count > 1
                    ? (String(kv[1]).replacingOccurrences(of: "+", with: " ")
                        .removingPercentEncoding ?? String(kv[1]))
                    : ""
                query[k] = v
            }
        }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let c = line.firstIndex(of: ":") else { continue }
            let k = line[line.startIndex..<c].lowercased()
            let v = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
            headers[k] = v
        }

        var ip = "unknown"
        if case .hostPort(let host, _) = conn.endpoint {
            ip = "\(host)".components(separatedBy: "%").first ?? "unknown"
        }

        return Request(method: method, path: path, query: query,
                       headers: headers, body: Data(), clientIP: ip)
    }

    private func send(_ conn: NWConnection, _ resp: Response, close: Bool) {
        var head = "HTTP/1.1 \(resp.status) \(Self.reason(resp.status))\r\n"
        var headers = resp.headers
        headers["Content-Length"] = String(resp.body.count)
        headers["Connection"] = close ? "close" : "keep-alive"
        // 本地自用服务，禁止被其他站点嵌套或探测
        headers["X-Content-Type-Options"] = "nosniff"
        headers["X-Frame-Options"] = "DENY"
        headers["Referrer-Policy"] = "no-referrer"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"

        var out = Data(head.utf8)
        out.append(resp.body)
        conn.send(content: out, completion: .contentProcessed { _ in
            if close { conn.cancel() }
        })
    }

    private static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 302: return "Found"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }

    /// 列出本机在局域网上的地址，方便在设置界面显示扫码/输入地址
    static func localAddresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                           &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.isEmpty, ip != "127.0.0.1" { result.append(ip) }
            }
        }
        return result
    }
}
