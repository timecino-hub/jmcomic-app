import Foundation
import Compression

/// 最小 ZIP 写入器（仅 store 模式，不压缩）。
///
/// 为什么不压缩：装进去的是 JPEG/PNG，本身已经是压缩数据，
/// 再 deflate 一遍通常只省 1~2%，却要多花几倍 CPU。漫画归档一律 store 是通行做法。
///
/// 为什么不调用 /usr/bin/zip：要先把几百个文件落到临时目录再打包，
/// 等于把整话写两遍盘。这里边下边写，内存里只留当前一页。
///
/// 只实现 CBZ 需要的部分：不支持加密、不支持 zip64（单话不可能超 4GB）。
final class ZipWriter {

    private let handle: FileHandle
    private var entries: [(name: String, crc: UInt32, size: UInt32, offset: UInt32)] = []
    private var offset: UInt32 = 0

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    /// 追加一个文件。name 用 / 分隔，不能以 / 开头。
    func add(name: String, data: Data) throws {
        let nameBytes = Array(name.utf8)
        let crc = Self.crc32(data)
        let size = UInt32(data.count)
        let localOffset = offset

        var header = Data()
        header.append(le32(0x0403_4B50))       // local file header 签名
        header.append(le16(10))                // 解压所需版本 2.0
        header.append(le16(1 << 11))           // bit 11: 文件名是 UTF-8
        header.append(le16(0))                 // 压缩方法 0 = store
        header.append(le16(0))                 // 修改时间 00:00
        header.append(le16(Self.dosEpoch))     // 修改日期 1980-01-01
        header.append(le32(crc))
        header.append(le32(size))              // 压缩后大小 = 原始大小
        header.append(le32(size))
        header.append(le16(UInt16(nameBytes.count)))
        header.append(le16(0))                 // 扩展字段长度
        header.append(contentsOf: nameBytes)

        handle.write(header)
        handle.write(data)
        offset += UInt32(header.count) + size
        entries.append((name, crc, size, localOffset))
    }

    /// 写中央目录并关闭。必须调用，否则文件不是合法 zip。
    func finish() throws {
        let directoryStart = offset
        var directory = Data()

        for e in entries {
            let nameBytes = Array(e.name.utf8)
            directory.append(le32(0x0201_4B50))   // central directory 签名
            directory.append(le16(0x031E))        // 创建版本：Unix
            directory.append(le16(10))
            directory.append(le16(1 << 11))
            directory.append(le16(0))             // store
            directory.append(le16(0))             // 时间
            directory.append(le16(Self.dosEpoch)) // 日期
            directory.append(le32(e.crc))
            directory.append(le32(e.size))
            directory.append(le32(e.size))
            directory.append(le16(UInt16(nameBytes.count)))
            directory.append(le16(0))             // 扩展字段
            directory.append(le16(0))             // 注释
            directory.append(le16(0))             // 起始磁盘号
            directory.append(le16(0))             // 内部属性
            directory.append(le32(0o644 << 16))   // 外部属性：Unix 权限
            directory.append(le32(e.offset))
            directory.append(contentsOf: nameBytes)
        }

        var end = Data()
        end.append(le32(0x0605_4B50))             // end of central directory
        end.append(le16(0))
        end.append(le16(0))
        end.append(le16(UInt16(entries.count)))
        end.append(le16(UInt16(entries.count)))
        end.append(le32(UInt32(directory.count)))
        end.append(le32(directoryStart))
        end.append(le16(0))                       // 注释长度

        handle.write(directory)
        handle.write(end)
        try handle.close()
    }

    // MARK: - 小端写入

    /// 合法 DOS 日期的最小值。置 0 会是 1980-0-0，严格实现可能拒读。
    private static let dosEpoch: UInt16 = 33   // 0x21 = 1980-01-01

    private func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    // MARK: - CRC32

    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
            }
        }
        return c ^ 0xFFFF_FFFF
    }
}

// MARK: - 读取

enum ZipError: LocalizedError {
    case badArchive(String)

    var errorDescription: String? {
        switch self {
        case .badArchive(let why): return "ZIP 归档无效：\(why)"
        }
    }
}

/// 最小 ZIP 读取器：解压 CBZ 用。
///
/// iOS 没有命令行 unzip/ditto（Mac 版 LocalReaderView 靠 Process 调 ditto），
/// 这里手写中央目录解析，store 与 deflate 两种压缩方法都支持，
/// 覆盖本 App 自产 CBZ（store）与外部导入的常见 CBZ（deflate）。
/// 不支持加密、zip64、分卷——漫画归档用不到。
enum ZipReader {

    /// 把归档里的所有文件条目解到 destDir（已存在则覆盖），返回写入的文件 URL。
    /// 目录条目扁平化（只取文件名），同时跳过 __MACOSX / 点开头等垃圾条目与 zip-slip 攻击路径。
    static func extract(archiveAt src: URL, into destDir: URL) throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        let data = try Data(contentsOf: src)
        guard data.count >= 22 else { throw ZipError.badArchive("文件太短") }

        // 从末尾向前扫 EOCD（注释最长 65535 + 固定 22 字节）
        var eocd = -1
        let lowest = max(0, data.count - 22 - 65535)
        var i = data.count - 22
        while i >= lowest {
            if Self.u32(data, i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.badArchive("找不到中央目录结尾") }
        let count = Int(Self.u16(data, eocd + 10))
        var p = Int(Self.u32(data, eocd + 16))

        var written: [URL] = []
        var usedNames: Set<String> = []
        for _ in 0..<count {
            guard p + 46 <= data.count, Self.u32(data, p) == 0x0201_4B50 else { break }
            let method     = Int(Self.u16(data, p + 10))
            let compSize   = Int(Self.u32(data, p + 20))
            let uncompSize = Int(Self.u32(data, p + 24))
            let nameLen    = Int(Self.u16(data, p + 28))
            let extraLen   = Int(Self.u16(data, p + 30))
            let cmtLen     = Int(Self.u16(data, p + 32))
            let localOff   = Int(Self.u32(data, p + 42))
            guard p + 46 + nameLen <= data.count else {
                throw ZipError.badArchive("中央目录越界")
            }
            let name = String(decoding: data[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            p += 46 + nameLen + extraLen + cmtLen

            // 跳过目录、macOS 打包垃圾、隐藏文件
            let fileName = (name as NSString).lastPathComponent
            guard !fileName.isEmpty,
                  !name.hasSuffix("/"),
                  !name.contains("__MACOSX/"),
                  !fileName.hasPrefix(".")
            else { continue }

            // 定位 local header 后的数据区
            guard localOff + 30 <= data.count,
                  Self.u32(data, localOff) == 0x0403_4B50
            else { throw ZipError.badArchive("局部头损坏：\(fileName)") }
            let lhNameLen  = Int(Self.u16(data, localOff + 26))
            let lhExtraLen = Int(Self.u16(data, localOff + 28))
            let start = localOff + 30 + lhNameLen + lhExtraLen
            guard start + compSize <= data.count else {
                throw ZipError.badArchive("数据区越界：\(fileName)")
            }
            let payload = data.subdata(in: start..<(start + compSize))

            let plain: Data
            switch method {
            case 0:
                plain = payload
            case 8:
                guard let inflated = Self.inflate(payload, expected: uncompSize) else {
                    continue   // 单个坏条目不拖垮整个归档
                }
                plain = inflated
            default:
                continue       // 不认识的压缩方法跳过
            }

            // 扁平化 + 同名去重
            var finalName = fileName
            if usedNames.contains(finalName) {
                let ext = (fileName as NSString).pathExtension
                let stem = ext.isEmpty ? fileName : String(fileName.dropLast(ext.count + 1))
                var seq = 2
                while true {
                    let candidate = "\(stem)-\(seq)" + (ext.isEmpty ? "" : ".\(ext)")
                    if !usedNames.contains(candidate) { finalName = candidate; break }
                    seq += 1
                }
            }
            usedNames.insert(finalName)
            let out = destDir.appendingPathComponent(finalName)
            try plain.write(to: out, options: .atomic)
            written.append(out)
        }
        guard !written.isEmpty else { throw ZipError.badArchive("没有可解出的图片条目") }
        return written
    }

    /// zip 的 deflate 是裸 DEFLATE（RFC1951），正是 Compression 的 COMPRESSION_ZLIB
    private static func inflate(_ input: Data, expected: Int) -> Data? {
        guard expected > 0, expected < 1 << 30 else { return nil }
        var dst = Data(count: expected)
        let written = dst.withUnsafeMutableBytes { dbuf -> Int in
            input.withUnsafeBytes { sbuf -> Int in
                guard let d = dbuf.bindMemory(to: UInt8.self).baseAddress,
                      let s = sbuf.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, expected, s, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written == expected ? dst : nil
    }

    private static func u16(_ d: Data, _ offset: Int) -> UInt16 {
        var v: UInt16 = 0
        for k in 0..<2 {
            v |= UInt16(d[d.startIndex + offset + k]) << (8 * k)
        }
        return v
    }

    private static func u32(_ d: Data, _ offset: Int) -> UInt32 {
        var v: UInt32 = 0
        for k in 0..<4 {
            v |= UInt32(d[d.startIndex + offset + k]) << (8 * k)
        }
        return v
    }
}
