import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 下载格式。
///
/// 注意 webp 只能解不能编（macOS ImageIO 不带 webp 编码器），
/// 所以无论选哪个都必须转码，没有「保持原样」这个选项。
enum DownloadFormat: String, Codable, CaseIterable {
    case cbz          // 单文件归档，内含 JPEG
    case folder       // 散图文件夹，内含 PNG

    var label: String { self == .cbz ? "CBZ 单文件" : "散图文件夹" }
}

struct DownloadedChapter: Codable, Hashable, Identifiable {
    var chapterId: String
    var chapterTitle: String
    var sort: Int
    var path: String          // cbz 文件或散图目录
    var pageCount: Int
    var format: DownloadFormat
    var id: String { chapterId }
}

struct DownloadedAlbum: Codable, Hashable, Identifiable {
    var meta: AlbumMeta
    var chapters: [DownloadedChapter]
    var completedAt: Date
    var id: String { meta.id }
    var totalPages: Int { chapters.reduce(0) { $0 + $1.pageCount } }
}

/// 下载任务与已下载库。
@MainActor
final class DownloadStore: ObservableObject {

    static let shared = DownloadStore()

    struct Task: Identifiable {
        let id: String                 // albumId
        var title: String
        var done: Int
        var total: Int
        var currentChapter: String
        var failed: Int
        var cancelled = false
        var error: String?
        var progress: Double { total == 0 ? 0 : Double(done) / Double(total) }
    }

    @Published private(set) var tasks: [Task] = []
    @Published private(set) var library: [DownloadedAlbum] = []

    /// 默认 CBZ，设置里可切散图
    @Published var format: DownloadFormat = {
        let raw = UserDefaults.standard.string(forKey: "downloadFormat") ?? ""
        return DownloadFormat(rawValue: raw) ?? .cbz
    }() {
        didSet { UserDefaults.standard.set(format.rawValue, forKey: "downloadFormat") }
    }

    /// 下载根目录，默认 Application Support/JMComic/downloads。
    /// iOS 适配：iOS 沙盒没有用户可见的 ~/Downloads（.downloadsDirectory 在 iOS 返回空数组，
    /// 下标会越界），按迁移规范统一落到 Application Support/JMComic/… 下重建目录结构。
    @Published var root: URL = {
        if let s = UserDefaults.standard.string(forKey: "downloadRoot") {
            return URL(fileURLWithPath: s)
        }
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return d.appendingPathComponent("JMComic", isDirectory: true)
            .appendingPathComponent("downloads", isDirectory: true)
    }() {
        didSet { UserDefaults.standard.set(root.path, forKey: "downloadRoot") }
    }

    private let indexFile: URL
    private var running: Set<String> = []

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("JMComic", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        indexFile = dir.appendingPathComponent("downloads.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexFile) else { return }
        let decoded: [DownloadedAlbum]?
        // 新格式：密文；旧格式：明文（解析成功即加密重写迁移）
        if let key = CryptoStore.key(),
           let plain = try? CryptoStore.decrypt(data, key: key) {
            decoded = try? JSONDecoder().decode([DownloadedAlbum].self, from: plain)
        } else {
            decoded = try? JSONDecoder().decode([DownloadedAlbum].self, from: data)
            if decoded != nil { save() }
        }
        guard let decoded else { return }
        // 先加载索引，文件存在性检查移到后台，避免阻塞主线程
        library = decoded
        Concurrency.detached { [weak self] in
            let filtered = decoded.compactMap { album -> DownloadedAlbum? in
                var a = album
                a.chapters = album.chapters.filter { FileManager.default.fileExists(atPath: $0.path) }
                return a.chapters.isEmpty ? nil : a
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if filtered.count != self.library.count {
                    self.library = filtered
                    self.save()
                }
            }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(library),
              let key = CryptoStore.key(),
              let enc = try? CryptoStore.encrypt(data, key: key)
        else { return }
        try? enc.write(to: indexFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: indexFile.path)
    }

    // MARK: - 查询

    func isDownloaded(_ albumId: String) -> Bool { library.contains { $0.meta.id == albumId } }

    func downloaded(_ albumId: String) -> DownloadedAlbum? {
        library.first { $0.meta.id == albumId }
    }

    func task(for albumId: String) -> Task? { tasks.first { $0.id == albumId } }

    func isDownloading(_ albumId: String) -> Bool { running.contains(albumId) }

    // MARK: - 下载

    /// chapters 传 nil 表示全本
    func start(album: Album, chapters selected: [ChapterMeta]? = nil) {
        guard !running.contains(album.id) else { return }
        running.insert(album.id)

        let list = selected ?? album.chapters
        tasks.append(Task(id: album.id, title: album.title, done: 0, total: 0,
                          currentChapter: "准备中…", failed: 0))

        Concurrency.detached { [weak self] in
            await self?.run(album: album, chapters: list)
        }
    }

    func cancel(_ albumId: String) {
        guard let i = tasks.firstIndex(where: { $0.id == albumId }) else { return }
        tasks[i].cancelled = true
    }

    private func update(_ albumId: String, _ body: (inout Task) -> Void) {
        guard let i = tasks.firstIndex(where: { $0.id == albumId }) else { return }
        body(&tasks[i])
    }

    private func run(album: Album, chapters metas: [ChapterMeta]) async {
        let dir = root.appendingPathComponent(Self.sanitize(album.title), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 先把所有章节的页数拉齐，进度条才有分母
        var loaded: [(ChapterMeta, Chapter)] = []
        for meta in metas {
            if task(for: album.id)?.cancelled == true { break }
            update(album.id) { $0.currentChapter = "读取 \(meta.displayTitle)" }
            do {
                let chapter = try await JmClient.shared.chapter(id: meta.id, sort: meta.sort,
                                                               title: meta.displayTitle)
                loaded.append((meta, chapter))
                update(album.id) { $0.total += chapter.pages.count }
            } catch {
                update(album.id) { $0.failed += 1 }
            }
        }

        var results: [DownloadedChapter] = []
        let fmt = format

        for (meta, chapter) in loaded {
            if task(for: album.id)?.cancelled == true { break }
            update(album.id) { $0.currentChapter = meta.displayTitle }
            if let done = await writeChapter(album: album, meta: meta, chapter: chapter,
                                             into: dir, format: fmt) {
                results.append(done)
            }
        }

        let cancelled = task(for: album.id)?.cancelled == true
        running.remove(album.id)
        tasks.removeAll { $0.id == album.id }

        guard !results.isEmpty else {
            if !cancelled { NotificationCenter.default.post(name: .jmDownloadFailed, object: nil) }
            return
        }

        let meta = AlbumMeta(id: album.id, title: album.title, authors: album.authors)
        var record = DownloadedAlbum(meta: meta, chapters: results.sorted { $0.sort < $1.sort },
                                     completedAt: Date())
        // 续下：合并已有章节，不覆盖
        if let existing = downloaded(album.id) {
            var merged = existing.chapters.filter { old in
                !record.chapters.contains { $0.chapterId == old.chapterId }
            }
            merged.append(contentsOf: record.chapters)
            record.chapters = merged.sorted { $0.sort < $1.sort }
            library.removeAll { $0.meta.id == album.id }
        }
        library.insert(record, at: 0)
        save()
    }

    /// 下一整话并落盘。返回 nil 表示这话完全失败。
    ///
    /// 两阶段实现，目的：用满 ImageStore 内部 networkSlots=6 的并发限流。
    /// - 阶段1：通过 TaskGroup 并发拉取本章所有页面，串行 await 时每页都要等
    ///   网络+解码才进下一页，并发槽根本用不满；这里同时发起全部请求，
    ///   由 ImageStore 自己控制并发度。结果按原页序存入 images[i]，
    ///   收集时按完成数更新进度，进度条实时刷新。
    /// - 阶段2：encode + 落盘放到 Task.detached 后台执行，
    ///   避免 CGImageDestination 逐页编码卡主线程。
    /// 取消：在阶段1的收集循环里检查 task.cancelled，取消则停止收集、
    ///   不进阶段2、不创建任何临时文件，直接返回 nil。
    private func writeChapter(album: Album, meta: ChapterMeta, chapter: Chapter,
                              into dir: URL, format fmt: DownloadFormat) async -> DownloadedChapter? {
        let name = Self.sanitize(meta.displayTitle)
        let total = chapter.pages.count
        let albumId = album.id   // 捕获到局部，子任务避免捕获 self

        // 阶段1：并发下载（保序收集）
        // addTask 闭包脱离 main actor，仅捕获 Sendable 的 page；
        // for await 迭代回到 main actor，可同步调用 self.update / task(for:)。
        var images: [CGImage?] = Array(repeating: nil, count: total)
        await withTaskGroup(of: (Int, CGImage?).self) { group in
            for (i, page) in chapter.pages.enumerated() {
                group.addTask {
                    let img = await ImageStore.shared.page(page)
                    return (i, img)
                }
            }
            for await (i, img) in group {
                // 取消：已取消则不再收集，结束整个 group（已下载的 images 不落盘）
                if task(for: albumId)?.cancelled == true {
                    group.cancelAll()
                    return
                }
                images[i] = img
                update(albumId) {
                    $0.done += 1
                    if img == nil { $0.failed += 1 }
                }
            }
        }
        // 下载被取消：未进入阶段2，无临时文件需清理
        guard task(for: album.id)?.cancelled != true else { return nil }

        // 阶段2：保序写入（后台线程，避免逐页 encode 卡 UI）
        // 捕获的全是值类型或不可变引用，Sendable 安全。
        let chapterId = meta.id
        let chapterTitle = meta.displayTitle
        let chapterSort = meta.sort
        let result: DownloadedChapter? = await _Concurrency.Task.detached(priority: .utility) { () -> DownloadedChapter? in
            switch fmt {
            case .cbz:
                // 先写 .part，成功后再改名，中断不会留下半个坏归档
                let target = dir.appendingPathComponent("\(name).cbz")
                let temp = dir.appendingPathComponent("\(name).cbz.part")
                guard let zip = try? ZipWriter(url: temp) else { return nil }
                var written = 0
                // 按 images 下标顺序写入，跳过下载失败的 nil 页
                for (i, img) in images.enumerated() {
                    guard let img, let data = Self.encode(img, as: .jpeg) else { continue }
                    let entry = String(format: "%04d.jpg", i + 1)
                    try? zip.add(name: entry, data: data)
                    written += 1
                }
                try? zip.finish()
                guard written > 0 else {
                    try? FileManager.default.removeItem(at: temp)
                    return nil
                }
                try? FileManager.default.removeItem(at: target)
                try? FileManager.default.moveItem(at: temp, to: target)
                return DownloadedChapter(chapterId: chapterId, chapterTitle: chapterTitle,
                                         sort: chapterSort, path: target.path,
                                         pageCount: written, format: .cbz)
            case .folder:
                let target = dir.appendingPathComponent(name, isDirectory: true)
                try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                var written = 0
                for (i, img) in images.enumerated() {
                    guard let img, let data = Self.encode(img, as: .png) else { continue }
                    let file = target.appendingPathComponent(String(format: "%04d.png", i + 1))
                    try? data.write(to: file, options: .atomic)
                    written += 1
                }
                guard written > 0 else { return nil }
                return DownloadedChapter(chapterId: chapterId, chapterTitle: chapterTitle,
                                         sort: chapterSort, path: target.path,
                                         pageCount: written, format: .folder)
            }
        }.value
        return result
    }

    // MARK: - 扫描导入（换机器/恢复备份：把外部目录里的 CBZ/散图重新纳入索引）

    /// 稳定路径哈希，替代网络 id（导入的本地文件没有网络 id）
    nonisolated static func fallbackID(_ path: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in path.utf8 {
            h ^= UInt64(b)
            h &*= 0x100000001b3
        }
        return String(h, radix: 16)
    }

    /// 扫描目录（无副作用，可自检）：与下载输出结构一致（本子目录/章节），
    /// CBZ 文件与"直接含图片的子目录"各作为一章，父目录作为一本。
    nonisolated static func scanFolder(_ url: URL) -> [DownloadedAlbum] {
        let fm = FileManager.default
        let imgExts = ["jpg", "jpeg", "png", "webp", "gif"]
        var albums: [String: (meta: AlbumMeta, chapters: [DownloadedChapter])] = [:]

        func isImageDir(_ d: URL) -> Bool {
            guard let items = try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)
            else { return false }
            return items.contains { imgExts.contains($0.pathExtension.lowercased()) }
        }

        guard let top = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        else { return [] }
        for albumDir in top where albumDir.hasDirectoryPath {
            var chapters: [DownloadedChapter] = []
            var sort = 1
            if let children = try? fm.contentsOfDirectory(at: albumDir,
                                                          includingPropertiesForKeys: nil) {
                for c in children {
                    if c.pathExtension.lowercased() == "cbz" {
                        let title = c.deletingPathExtension().lastPathComponent
                        chapters.append(DownloadedChapter(chapterId: Self.fallbackID(c.path),
                                                          chapterTitle: title, sort: sort,
                                                          path: c.path, pageCount: 0, format: .cbz))
                        sort += 1
                    } else if c.hasDirectoryPath && isImageDir(c) {
                        let count = (try? fm.contentsOfDirectory(at: c, includingPropertiesForKeys: nil))?
                            .filter { imgExts.contains($0.pathExtension.lowercased()) }.count ?? 0
                        chapters.append(DownloadedChapter(chapterId: Self.fallbackID(c.path),
                                                          chapterTitle: c.lastPathComponent, sort: sort,
                                                          path: c.path, pageCount: count, format: .folder))
                        sort += 1
                    }
                }
            }
            guard !chapters.isEmpty else { continue }
            let meta = AlbumMeta(id: Self.fallbackID(albumDir.path),
                                 title: albumDir.lastPathComponent, authors: [])
            albums[albumDir.path] = (meta, chapters.sorted { $0.sort < $1.sort })
        }
        return albums.values.map {
            DownloadedAlbum(meta: $0.meta, chapters: $0.chapters, completedAt: Date())
        }.sorted { $0.meta.title < $1.meta.title }
    }

    /// 从外部目录扫描导入，重建索引。返回导入的本子数。
    @discardableResult
    func importFolder(_ url: URL) -> Int {
        let scanned = Self.scanFolder(url)
        guard !scanned.isEmpty else { return 0 }
        var imported = 0
        for record in scanned {
            if let idx = library.firstIndex(where: { $0.meta.id == record.meta.id }) {
                for c in record.chapters where !library[idx].chapters.contains(where: { $0.chapterId == c.chapterId }) {
                    library[idx].chapters.append(c)
                }
                library[idx].chapters.sort { $0.sort < $1.sort }
            } else {
                library.insert(record, at: 0)
            }
            imported += 1
        }
        save()
        return imported
    }

    // MARK: - 局域网同步注册（桌面传输完成后入库）

    /// 桌面同步传输完成后的注册入口（同 id 先移除再插入，语义与 run() 落库一致）。
    /// 记录由 TransferManager 按传输清单重建，注册后 LocalLibraryView/LocalReaderView 即可发现。
    func recordSyncedAlbum(_ record: DownloadedAlbum) {
        library.removeAll { $0.meta.id == record.meta.id }
        library.insert(record, at: 0)
        save()
    }

    // MARK: - Files 导入（iOS：fileImporter 从「文件」App 导入 zip/CBZ）

    /// 导入一个 zip/CBZ 归档到本地库。
    ///
    /// 流程（复用扫描导入的记录语义）：安全作用域访问 → 拷贝进下载根目录（沙盒授权过期后仍可读）
    /// → 以目标路径哈希为 id 注册单章记录。重复导入同一文件按路径幂等覆盖。
    /// 返回用户可读的结果说明。
    @discardableResult
    func importZIPFile(_ src: URL) async -> String {
        let didScope = src.startAccessingSecurityScopedResource()
        defer { if didScope { src.stopAccessingSecurityScopedResource() } }

        // 名字与落点先在主线程算好，文件 IO 全部放到后台任务
        let title = Self.sanitize(src.deletingPathExtension().lastPathComponent)
        let importRoot = root.appendingPathComponent("导入", isDirectory: true)
        let chapterTitle = title

        // 本类型内嵌套了 struct Task（下载任务模型），需用模块全名引用并发的 Task
        let staged: DownloadedChapter? = await _Concurrency.Task.detached(priority: .utility) { () -> DownloadedChapter? in
            let fm = FileManager.default
            try? fm.createDirectory(at: importRoot, withIntermediateDirectories: true)
            let dest = importRoot.appendingPathComponent("\(title).cbz")
            if fm.fileExists(atPath: dest.path) {
                try? fm.removeItem(at: dest)
            }
            do {
                try fm.copyItem(at: src, to: dest)
            } catch {
                return nil
            }
            let id = Self.fallbackID(dest.path)
            return DownloadedChapter(chapterId: id, chapterTitle: chapterTitle, sort: 1,
                                     path: dest.path, pageCount: 0, format: .cbz)
        }.value

        guard let chapter = staged else { return "导入失败：无法读取所选文件" }

        let recordId = chapter.chapterId
        let meta = AlbumMeta(id: recordId, title: chapterTitle, authors: [])
        var record = DownloadedAlbum(meta: meta, chapters: [chapter], completedAt: Date())
        if let idx = library.firstIndex(where: { $0.meta.id == recordId }) {
            var merged = library[idx].chapters.filter { $0.chapterId != chapter.chapterId }
            merged.append(chapter)
            merged.sort { $0.sort < $1.sort }
            record.chapters = merged
            library[idx] = record
        } else {
            library.insert(record, at: 0)
        }
        save()
        return "已导入「\(chapterTitle)」"
    }

    // MARK: - 删除

    func delete(_ albumId: String, removeFiles: Bool) {
        guard let album = downloaded(albumId) else { return }
        if removeFiles {
            for c in album.chapters {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: c.path))
            }
            // 本子目录空了就一并收掉
            let parent = URL(fileURLWithPath: album.chapters.first?.path ?? "")
                .deletingLastPathComponent()
            if let rest = try? FileManager.default.contentsOfDirectory(atPath: parent.path),
               rest.isEmpty {
                try? FileManager.default.removeItem(at: parent)
            }
        }
        library.removeAll { $0.meta.id == albumId }
        save()
    }

    // MARK: - 编码

    /// JPEG 质量 0.92：比 PNG 小 5~8 倍，肉眼几乎看不出差别。
    /// 散图走 PNG 无损，因为选散图的人多半是要拿去二次处理。
    ///
    /// nonisolated：纯计算函数（仅局部的 NSMutableData + CGImageDestination C 调用，
    /// 入参 CGImage/UTType 均 Sendable），需在后台 detached task 里调用以避免卡主线程。
    nonisolated static func encode(_ image: CGImage, as type: UTType) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, type.identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = type == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: 0.92]
            : [:]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// 去掉路径分隔符和前后空白，避免标题里的 / 把目录结构劈开
    static func sanitize(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = cleaned.count > 80 ? String(cleaned.prefix(80)) : cleaned
        return limited.isEmpty ? "未命名" : limited
    }
}

extension Notification.Name {
    static let jmDownloadFailed = Notification.Name("jmDownloadFailed")
}

/// 包一层，避免和 SwiftUI 的 Task 视图类型重名导致歧义
enum Concurrency {
    static func detached(_ body: @escaping @Sendable () async -> Void) {
        _Concurrency.Task.detached(priority: .utility) { await body() }
    }
}
