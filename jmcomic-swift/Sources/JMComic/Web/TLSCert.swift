import Foundation
import Security

/// 自签证书管理。首次启用 HTTPS 时用系统自带 openssl（LibreSSL）生成自签证书，
/// 转成 PKCS#12 后由 SecPKCS12Import 载入，交给 NWParameters.tls 使用。
///
/// 取舍：自签证书让手机首次访问弹"不受信任"警告，点继续即可；
/// 换来密码 / token / 图片全链路加密，抓包看不到任何内容。
/// 证书私钥只在本机生成、本机持有，不外发。
///
/// ponytail: 用系统 openssl 生成而不是手写 DER —— 后者约 100 行且出错不可见。
/// 依赖 /usr/bin/openssl 存在（macOS 全系自带 LibreSSL）。
enum TLSCert {

    private static let p12Password = "local-jmcomic-tls"
    private static var cachedIdentity: sec_identity_t?

    /// 返回本地身份（sec_identity_t）。首次调用会生成证书，失败返回 nil。
    static func identity() -> sec_identity_t? {
        if let cachedIdentity { return cachedIdentity }
        let d = dir()
        let p12 = d.appendingPathComponent("server.p12")
        let identity: sec_identity_t?
        if FileManager.default.fileExists(atPath: p12.path) {
            identity = loadP12(at: p12)
        } else {
            identity = generate() ? loadP12(at: p12) : nil
        }
        cachedIdentity = identity
        return identity
    }

    private static func dir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("JMComicDev/tls", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// openssl req -x509 -newkey rsa:2048 -config san.cnf → key.pem + cert.pem
    /// openssl pkcs12 -export → server.p12（自签证书无保密价值，固定密码足够）
    private static func generate() -> Bool {
        let d = dir()
        let key = d.appendingPathComponent("key.pem")
        let cert = d.appendingPathComponent("cert.pem")
        let p12 = d.appendingPathComponent("server.p12")
        let cfg = d.appendingPathComponent("san.cnf")

        // 浏览器要求证书带 SAN，否则即使是自签也会直接拒绝连接
        let cfgText = """
        [req]
        distinguished_name = dn
        x509_extensions = ext
        prompt = no
        [dn]
        CN = JMComic LAN
        [ext]
        subjectAltName = DNS:localhost, IP:127.0.0.1
        basicConstraints = critical,CA:FALSE
        keyUsage = critical,digitalSignature,keyEncipherment
        extendedKeyUsage = serverAuth
        """
        try? cfgText.write(to: cfg, atomically: true, encoding: .utf8)

        guard run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048",
                                       "-keyout", key.path, "-out", cert.path,
                                       "-days", "3650", "-nodes", "-config", cfg.path]),
              run("/usr/bin/openssl", ["pkcs12", "-export",
                                       "-inkey", key.path, "-in", cert.path,
                                       "-out", p12.path, "-passout", "pass:\(p12Password)"])
        else { return false }

        // 私钥只留在 p12 里，PEM 副本删掉
        try? FileManager.default.removeItem(at: key)
        try? FileManager.default.removeItem(at: cert)
        try? FileManager.default.removeItem(at: cfg)
        return true
    }

    private static func run(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch { return false }
        return p.terminationStatus == 0
    }

    private static func loadP12(at url: URL) -> sec_identity_t? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var items: CFArray?
        let opts = [kSecImportExportPassphrase as String: p12Password] as CFDictionary
        let status = SecPKCS12Import(data as CFData, opts, &items)
        guard status == errSecSuccess,
              let arr = items as? [[String: Any]],
              let identity = arr.first?[kSecImportItemIdentity as String]
        else { return nil }
        return sec_identity_create(identity as! SecIdentity)
    }
}
