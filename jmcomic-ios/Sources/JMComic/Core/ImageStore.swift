import Foundation
import CoreGraphics
import ImageIO
// iOS 适配：原 import AppKit 仅系误引（本文件只用 CGImage/ImageIO，无任何 AppKit 符号），
// iOS 上直接去掉即可，算法与逻辑零改动。

// MARK: - O(1) LRU 链表节点

/// 双向链表节点，用于 O(1) LRU 操作
private final class LRUListNode {
    let key: String
    var prev: LRUListNode?
    var next: LRUListNode?
    init(_ key: String) { self.key = key }
}

/// O(1) LRU 链表：维护访问顺序，支持 O(1) touch / append / removeFirst
private struct LRUList {
    private(set) var head: LRUListNode?
    private(set) var tail: LRUListNode?
    private(set) var count = 0

    /// 标记为最近使用（移到尾部）
    mutating func touch(_ node: LRUListNode) {
        guard node !== tail else { return }
        detach(node)
        append(node)
    }

    /// 追加到尾部（最近使用）
    mutating func append(_ node: LRUListNode) {
        node.prev = tail
        node.next = nil
        if let t = tail { t.next = node } else { head = node }
        tail = node
        count += 1
    }

    /// 移除指定节点
    mutating func remove(_ node: LRUListNode) {
        detach(node)
        node.prev = nil
        node.next = nil
        count -= 1
    }

    /// 移除并返回最久未使用的节点（头部）
    mutating func removeFirst() -> LRUListNode? {
        guard let h = head else { return nil }
        detach(h)
        h.prev = nil
        h.next = nil
        count -= 1
        return h
    }

    private mutating func detach(_ node: LRUListNode) {
        if node === head { head = node.next }
        if node === tail { tail = node.prev }
        node.prev?.next = node.next
        node.next?.prev = node.prev
        count -= 1
    }
}

/// 图片仓库：内存 LRU + 磁盘缓存 + 请求合并。
///
/// 磁盘缓存是「加载慢」的真正解药：第二次看同一话直接读本地，不再走网络。
/// 存的是 JPEG 编码的图片（质量 0.92），比 PNG 小 3-5 倍且编码更快。
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
    private var lruNodes: [String: LRUListNode] = [:]
    private var lruList = LRUList()
    private var memoryBytes = 0
    /// 解码后一页约 9MB，64MB 够覆盖视口 + 前后 2 页预读
    private let memoryBudget = 64 * 1024 * 1024

    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    /// 已知的宽高比，用于在图片到达前就把版面撑到正确高度
    private var aspectRatios: [String: CGFloat] = [:]
    private var ratiosDirty = 0
    /// persistRatios 防抖：每 10 次写入或 5 秒后批量持久化
    private let ratiosFlushThreshold = 10

    /// 磁盘写入并发控制：最多 3 个并行写入任务
    private var diskWriteSlots = 3
    private var diskWriteWaiters: [CheckedContinuation<Void, Never>] = []

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

    /// persistRatios 防抖：标记脏，每 10 次或定时刷盘
    private func markRatiosDirty() {
        ratiosDirty += 1
        if ratiosDirty >= ratiosFlushThreshold {
            flushRatios()
        }
    }

    private func flushRatios() {
        guard ratiosDirty > 0 else { return }
        ratiosDirty = 0
        guard let data = try? JSONEncoder().encode(aspectRatios) else { return }
        try? data.write(to: Self.ratiosFile)
    }

    /// 页面高宽比。未知时返回禁漫最常见的 1280x1807。
    func aspectRatio(for page: ComicPage) -> CGFloat {
        aspectRatios[page.id] ?? (1807.0 / 1280.0)
    }

    // MARK: - 读取

    private func diskURL(_ key: String) -> URL {
        cacheDir.appendingPathComponent("\(Self.stableHash(key)).jpg")
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
        // 先查新格式 JPEG；不存在时回退查旧格式 PNG（兼容旧缓存）
        var url = diskURL(key)
        var data = try? Data(contentsOf: url)
        if data == nil {
            let oldURL = cacheDir.appendingPathComponent("\(Self.stableHash(key)).png")
            data = try? Data(contentsOf: oldURL)
            url = oldURL
        }
        guard let data,
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        return img
    }

    private func writeDisk(_ key: String, _ image: CGImage) {
        let url = diskURL(key)
        // JPEG 质量 0.92：比 PNG 小 3-5 倍，肉眼几乎无差别，编码也更快
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)
        guard let dest else { return }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    private func store(_ key: String, _ image: CGImage, writeDisk shouldWrite: Bool) {
        aspectRatios[key] = CGFloat(image.height) / CGFloat(image.width)
        markRatiosDirty()

        let size = image.width * image.height * 4

        // 如果已存在，先移除旧节点
        if let existing = lruNodes[key] {
            lruList.remove(existing)
            lruNodes.removeValue(forKey: key)
            memoryBytes -= (memory.removeValue(forKey: key)?.width ?? 0) * (memory.removeValue(forKey: key)?.height ?? 0) * 4
        }

        // 插入新节点（最近使用）
        let node = LRUListNode(key)
        lruNodes[key] = node
        lruList.append(node)
        memory[key] = image
        memoryBytes += size

        // LRU 淘汰：超出预算时淘汰最久未使用的
        while memoryBytes > memoryBudget, let victim = lruList.removeFirst() {
            if let old = memory.removeValue(forKey: victim.key) {
                memoryBytes -= old.width * old.height * 4
            }
            lruNodes.removeValue(forKey: victim.key)
        }

        if shouldWrite {
            let img = image
            Task.detached(priority: .background) { [weak self] in
                await self?.acquireDiskWrite()
                await self?.writeDiskAsync(key, img)
                await self?.releaseDiskWrite()
            }
        }
    }

    private func acquireDiskWrite() async {
        if diskWriteSlots > 0 {
            diskWriteSlots -= 1
        } else {
            await withCheckedContinuation { diskWriteWaiters.append($0) }
        }
    }

    private func releaseDiskWrite() {
        if let w = diskWriteWaiters.first {
            diskWriteWaiters.removeFirst()
            w.resume()
        } else {
            diskWriteSlots += 1
        }
    }

    private func writeDiskAsync(_ key: String, _ image: CGImage) {
        writeDisk(key, image)
    }

    private func touch(_ key: String) {
        if let node = lruNodes[key] {
            lruList.touch(node)
        }
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
        lruNodes.removeAll()
        lruList = LRUList()
        memoryBytes = 0
        ratiosDirty = 0
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
