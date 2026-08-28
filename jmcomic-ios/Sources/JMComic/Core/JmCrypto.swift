import Foundation
import CommonCrypto

/// 禁漫 API 的签名与解密。
///
/// 移植自 jmcomic-core 的 JmCryptoTool：
/// - token       = md5(timestamp + secret)
/// - tokenparam  = "timestamp,appVersion"
/// - 响应体 data = Base64 + AES-ECB，密钥为 md5(timestamp + dataSecret) 的 UTF8 字节
///
/// 密钥是 32 字符的十六进制字符串，按 UTF8 取字节即 32 字节，因此实际走 AES-256。
enum JmCrypto {

    static func md5Hex(_ input: String) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        let bytes = Array(input.utf8)
        CC_MD5(bytes, CC_LONG(bytes.count), &digest)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 生成请求头用的 token 与 tokenparam
    static func token(timestamp: String, secret: String, appVersion: String) -> (token: String, param: String) {
        (md5Hex(timestamp + secret), "\(timestamp),\(appVersion)")
    }

    /// 解密 API 响应体
    static func decrypt(base64: String, timestamp: String, secret: String) -> Data? {
        guard let cipher = Data(base64Encoded: base64), !cipher.isEmpty else { return nil }
        let key = Array(md5Hex(timestamp + secret).utf8)
        let capacity = cipher.count + kCCBlockSizeAES128
        var out = Data(count: capacity)
        var moved = 0
        let status: Int32 = out.withUnsafeMutableBytes { dst in
            cipher.withUnsafeBytes { src in
                CCCrypt(CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                        key, key.count, nil,
                        src.baseAddress, cipher.count,
                        dst.baseAddress, capacity, &moved)
            }
        }
        guard status == Int32(kCCSuccess) else { return nil }
        out.removeSubrange(moved...)
        return out
    }

    /// 图片被切成几条横条。photoId 小于 scrambleId 表示未加密。
    /// 与 jmcomic-core 的 JmImageTool.calculateNumSegments 保持一致。
    static func segmentCount(scrambleId: Int, photoId: Int, filenameWithoutExtension: String) -> Int {
        if photoId < scrambleId { return 0 }
        if photoId < JmConstants.scramble268850 { return 10 }
        let modulus = photoId < JmConstants.scramble421926 ? 10 : 8
        let hash = md5Hex("\(photoId)\(filenameWithoutExtension)")
        guard let last = hash.unicodeScalars.last else { return 0 }
        return (Int(last.value) % modulus) * 2 + 2
    }
}
