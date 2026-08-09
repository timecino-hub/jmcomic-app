import Foundation
import CoreGraphics
import ImageIO
import AppKit

/// 图片仓库：内存 LRU + 磁盘缓存 + 请求合并。
///
/// 磁盘缓存是「加载慢」的真正解药：第二次看同一话直接读本地，不再走网络。
/// 存的是解重组后的 PNG，下次连解重组都省了。
actor ImageStore {

    static let shared = ImageStore()

    /// 网络并发上限：首屏几十张封面同时请求会被服务端限流拖慢，限制到 6 个连接更稳
    private var networkSlots = 6
    private var networkWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireNetwork() async {
        if networkSlots > 0 {
            networkSlots -= 1
        } else {
            await withCheckedContinuation { networkWaiters.append($0) }
        }
    }

    private func releaseNetwork() {
        if let w = networkWaiters.first {
            networkWaiters.removeFirst()
            w.resume()
        } else {
            networkSlots += 1
        }
    }

    private var memory: [String: CGImage] = [:]
    private var order: [String] = []
    private var memoryBytes = 0
    /// 解码后一页约 9MB，128MB 够覆盖视口 + 前后预读
    private let memoryBudget = 128 * 1024 * 1024

    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    /// 已知的宽高比，用于在图片到达前就把版面撑到正确高度
    private var aspectRatios: [String: CGFloat] = [:]

    private let client: JmClient
    private let cacheDir: URL

    init(client: JmClient = .shared) {
        self.client = client
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.cacheDir = base.appendingPathComponent("JMComic/images", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        // 私密数据：只允许当前用户访问，并排除出 Time Machine / iCloud 备份
        Self.harden(cacheDir)
        Self.excludeFromBackup(cacheDir)
        self.aspectRatios = Self.loadRatios()
    }

    /// 目录设为 700（macOS 下创建时默认 755，其他账户可读）
    static func harden(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// 排除出备份：本地阅读记录属于隐私数据，不应随备份离开本机
    static func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    // MARK: - 宽高比

    private static var ratiosFile: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JMComic/ratios.json")
    }

    private static func loadRatios() -> [String: CGFloat] {
        guard let data = try? Data(contentsOf: ratiosFile),
              let dict = try? JSONDecoder().decode([String: CGFloat].self, from: data)
        else { return [:] }
        return dict
    }

    private func persistRatios() {
        guard let data = try? JSONEncoder().encode(aspectRatios) else { return }
        try? data.write(to: Self.ratiosFile)
    }

    /// 页面高宽比。未知时返回禁漫最常见的 1280x1807。
    func aspectRatio(for page: ComicPage) -> CGFloat {
        aspectRatios[page.id] ?? (1807.0 / 1280.0)
    }

    // MARK: - 读取

    private func diskURL(_ key: String) -> URL {
        cacheDir.appendingPathComponent("\(Self.stableHash(key)).png")
    }

    /// FNV-1a 64。
    ///
    /// 不能用 Swift 的 Hasher：它每个进程用随机种子，同一个 URL 每次启动算出的
    /// 文件名都不同 —— 磁盘缓存跨重启永远不命中，旧文件还会无限堆积。
    static func stableHash(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    func cached(_ key: String) -> CGImage? {
        memory[key]
    }

    /// 取一页漫画。内存 → 磁盘 → 网络，逐级回落。
    func page(_ page: ComicPage) async -> CGImage? {
        let key = page.id
        if let hit = memory[key] {
            touch(key)
            return hit
        }
        if let task = inFlight[key] { return await task.value }

        let task = Task<CGImage?, Never> { [weak self] in
            guard let self else { return nil }
            // 磁盘
            if let img = await self.readDisk(key) {
                await self.store(key, img, writeDisk: false)
                return img
            }
            // 网络（并发受限，避免首屏几十张同时请求被限流）
            await self.acquireNetwork()
            let data = try? await self.client.fetchData(from: page.url)
            await self.releaseNetwork()
            guard let data,
                  let img = ImagePipeline.process(data, page: page)
            else { return nil }
            await self.store(key, img, writeDisk: true)
            return img
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    /// 取封面。封面小，不做解重组。
    func cover(albumId: String) async -> CGImage? {
        let key = "cover:\(albumId)"
        if let hit = memory[key] { touch(key); return hit }
        if let task = inFlight[key] { return await task.value }

        let task = Task<CGImage?, Never> { [weak self] in
            guard let self else { return nil }
            if let img = await self.readDisk(key) {
                await self.store(key, img, writeDisk: false)
                return img
            }
            guard let url = await self.client.coverURL(albumId: albumId) else { return nil }
            // 网络（并发受限）
            await self.acquireNetwork()
            let data = try? await self.client.fetchData(from: url)
            await self.releaseNetwork()
            guard let data,
                  let img = ImagePipeline.decode(data)
            else { return nil }
            await self.store(key, img, writeDisk: true)
            return img
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    private func readDisk(_ key: String) -> CGImage? {
        let url = diskURL(key)
        guard let data = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        return img
    }

    private func writeDisk(_ key: String, _ image: CGImage) {
        let url = diskURL(key)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    private func store(_ key: String, _ image: CGImage, writeDisk shouldWrite: Bool) {
        aspectRatios[key] = CGFloat(image.height) / CGFloat(image.width)
        persistRatios()

        let size = image.width * image.height * 4
        memory[key] = image
        order.removeAll { $0 == key }
        order.append(key)
        memoryBytes += size

        while memoryBytes > memoryBudget, order.count > 1 {
            let victim = order.removeFirst()
            if let old = memory.removeValue(forKey: victim) {
                memoryBytes -= old.width * old.height * 4
            }
        }
        if shouldWrite {
            let img = image
            Task.detached(priority: .background) { [weak self] in
                await self?.writeDiskAsync(key, img)
            }
        }
    }

    private func writeDiskAsync(_ key: String, _ image: CGImage) {
        writeDisk(key, image)
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    /// 预取，用于阅读时提前拉后面几页
    func prefetch(_ pages: [ComicPage]) {
        for p in pages where memory[p.id] == nil && inFlight[p.id] == nil {
            Task { _ = await self.page(p) }
        }
    }

    func clearDisk() {
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        memory.removeAll()
        order.removeAll()
        memoryBytes = 0
    }

    func diskSize() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}

extension JmClient {
    static let shared = JmClient()
}
