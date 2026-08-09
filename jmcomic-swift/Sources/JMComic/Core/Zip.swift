import Foundation

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
