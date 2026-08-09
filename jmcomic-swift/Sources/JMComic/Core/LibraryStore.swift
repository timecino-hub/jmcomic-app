import Foundation

/// 阅读进度：记住每个本子读到哪一话的哪一页
struct ReadingPosition: Codable, Hashable, Sendable {
    var chapterId: String
    var chapterSort: Int
    var pageIndex: Int
    var updatedAt: Date
}

/// 热门/最新浏览位置缓存（重启后恢复浏览现场，见 BrowseView）
struct FeedCacheEntry: Codable {
    var items: [AlbumMeta]
    var page: Int
    var totalPages: Int
    var scrollID: String?
    /// 滚动偏移（像素，从顶部往下），恢复最可靠的手段
    var scrollOffset: Double?
}

/// 本地元数据库。
///
/// 这就是「把本子数据存成 JSON」那个思路的落地。收益分两块：
///  1. 详情页秒开 —— 省掉一次签名请求 + 解密（实测 300~800ms）
///  2. 让「记住阅读位置」「历史记录」这类功能有地方落脚
///
/// 注意它救不了图片加载速度，图片是几 MB 级的，元数据只有几 KB，
/// 真正管图片的是 ImageStore 的磁盘缓存。
@MainActor
final class LibraryStore: ObservableObject {

    static let shared = LibraryStore()

    @Published private(set) var positions: [String: ReadingPosition] = [:]
    @Published private(set) var history: [AlbumMeta] = []
    /// 最近浏览：打开过详情页的本子（即使没阅读也记），持久化防丢
    @Published private(set) var recentlyViewed: [AlbumMeta] = []
    @Published private(set) var feedCache: [String: FeedCacheEntry] = [:]

    private var albums: [String: Album] = [:]
    private let dir: URL

    private var albumsFile: URL { dir.appendingPathComponent("albums.json") }
    private var stateFile: URL { dir.appendingPathComponent("state.json") }
    private var feedCacheFile: URL { dir.appendingPathComponent("feed-cache.json") }

    private struct State: Codable {
        var positions: [String: ReadingPosition]
        var history: [AlbumMeta]
        var recentlyViewed: [AlbumMeta]?   // optional：兼容旧版本文件
    }

    /// 无痕模式：开启后不写历史、不写阅读进度。持久化在 UserDefaults，重启保持。
    @Published var privateMode: Bool = UserDefaults.standard.bool(forKey: "privateMode") {
        didSet { UserDefaults.standard.set(privateMode, forKey: "privateMode") }
    }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("JMComic", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ImageStore.harden(dir)
        ImageStore.excludeFromBackup(dir)
        // 早期版本用默认 umask 建的文件是 644，补一次权限，否则要等到下次写入才收紧
        for f in [albumsFile, stateFile] where FileManager.default.fileExists(atPath: f.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: f.path)
        }
        load()
    }

    private func load() {
        if let decoded: [String: Album] = readJSON(at: albumsFile) {
            albums = decoded
        }
        if let decoded: State = readJSON(at: stateFile) {
            positions = decoded.positions
            history = decoded.history
            recentlyViewed = decoded.recentlyViewed ?? []
        }
        if let decoded: [String: FeedCacheEntry] = readJSON(at: feedCacheFile) {
            feedCache = decoded
        }
    }

    // MARK: - 浏览位置缓存（热门/最新，重启后恢复）

    func cachedFeed(_ key: String) -> FeedCacheEntry? { feedCache[key] }

    func saveFeedCache(_ key: String, _ entry: FeedCacheEntry) {
        feedCache[key] = entry
        guard let data = try? JSONEncoder().encode(feedCache),
              let cryptoKey = CryptoStore.key(),
              let enc = try? CryptoStore.encrypt(data, key: cryptoKey)
        else { return }
        try? enc.write(to: feedCacheFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: feedCacheFile.path)
    }

    /// 读盘：优先解密（新格式）；解密失败时尝试明文（旧版本），成功即加密重写迁移。
    private func readJSON<T: Decodable>(at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let key = CryptoStore.key(),
           let plain = try? CryptoStore.decrypt(data, key: key),
           let decoded = try? JSONDecoder().decode(T.self, from: plain) {
            return decoded
        }
        // 旧明文格式：解析成功后立即加密重写，下次就是密文
        if let decoded = try? JSONDecoder().decode(T.self, from: data) {
            writePrivate(data, to: url)
            return decoded
        }
        return nil
    }

    /// 写盘：AES 加密后原子写入，权限 0600。
    /// 钥匙串不可用时放弃写盘（不落明文），旧文件保持原样。
    private func writePrivate(_ data: Data, to url: URL) {
        guard let key = CryptoStore.key(),
              let enc = try? CryptoStore.encrypt(data, key: key) else { return }
        try? enc.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func saveAlbums() {
        guard let data = try? JSONEncoder().encode(albums) else { return }
        writePrivate(data, to: albumsFile)
    }

    private func saveState() {
        guard let data = try? JSONEncoder().encode(State(positions: positions,
                                                         history: history,
                                                         recentlyViewed: recentlyViewed))
        else { return }
        writePrivate(data, to: stateFile)
    }

    /// 打开详情页即记录（不写阅读进度，只记浏览痕迹），最多 30 条
    func recordView(_ meta: AlbumMeta) {
        recentlyViewed.removeAll { $0.id == meta.id }
        recentlyViewed.insert(meta, at: 0)
        if recentlyViewed.count > 30 { recentlyViewed.removeLast(recentlyViewed.count - 30) }
        saveState()
    }

    // MARK: - 个性化推荐（Mac 端推荐页与 web 端 /api/personalized 共用）

    struct RecommendationResult {
        var profileTags: [String]
        var items: [AlbumMeta]
    }

    /// 本地画像 + 标签搜索 + 过滤（详见 PersonalizedView 注释）。
    /// 不写历史、不上传，纯本地计算。
    func recommendations() async -> RecommendationResult {
        let excluded = Set(UserDefaults.standard.stringArray(forKey: "excludedTags") ?? [])
        let favorites = FavoriteStore.shared
        let seenIDs = Set(history.map(\.id) + favorites.entries.map(\.id))
        var tagCount: [String: Int] = [:]
        var authorCount: [String: Int] = [:]

        // 画像：缓存 tags 优先；空（旧解析数据）实时拉详情补全
        var needFetch: [String] = []
        for id in seenIDs {
            if let cached = album(id), !cached.tags.isEmpty {
                for t in cached.tags where !excluded.contains(t) { tagCount[t, default: 0] += 1 }
                for a in cached.authors { authorCount[a, default: 0] += 1 }
            } else {
                needFetch.append(id)
            }
        }
        if !needFetch.isEmpty {
            var fetched: [Album?] = []
            await withTaskGroup(of: Album?.self) { group in
                for id in needFetch {
                    group.addTask { try? await JmClient.shared.album(id: id) }
                }
                for await a in group { fetched.append(a) }
            }
            for a in fetched {
                guard let a else { continue }
                cache(a)
                for t in a.tags where !excluded.contains(t) { tagCount[t, default: 0] += 1 }
                for au in a.authors { authorCount[au, default: 0] += 1 }
            }
        }
        let profileTags = Array(tagCount.sorted { $0.value > $1.value }.prefix(5).map(\.key))
        guard !profileTags.isEmpty else { return RecommendationResult(profileTags: [], items: []) }

        // 候选：Top 标签 + 作者名各搜一页
        let seeds = profileTags + authorCount.sorted { $0.value > $1.value }.prefix(2).map(\.key)
        var scored: [String: (meta: AlbumMeta, score: Int)] = [:]
        for seed in seeds {
            guard let result = try? await JmClient.shared.search(seed, page: 1) else { continue }
            for meta in result.items {
                let old = scored[meta.id]?.score ?? 0
                scored[meta.id] = (meta, old + 1)
            }
        }
        let items = scored.values
            .filter { !seenIDs.contains($0.meta.id) }
            .sorted { $0.score > $1.score }
            .map(\.meta)
        let filtered = await filterByExclusions(items)
        return RecommendationResult(profileTags: profileTags, items: filtered)
    }

    // MARK: - 不感兴趣过滤

    /// 按「内容过滤」配置剔除列表项（需要作品标签）：
    /// 缓存里有标签的秒判；没有的按 8 个一批并发拉详情（避免 80 个并发被限流）。
    /// 排除词为空时原样返回，零开销。
    func filterByExclusions(_ metas: [AlbumMeta]) async -> [AlbumMeta] {
        let excluded = UserDefaults.standard.stringArray(forKey: "excludedTags") ?? []
        guard !excluded.isEmpty, !metas.isEmpty else { return metas }
        let lowerEx = excluded.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard !lowerEx.contains(where: { $0.isEmpty }) else { return metas }

        var keep: [AlbumMeta] = []
        var needFetch: [AlbumMeta] = []
        for m in metas {
            if let cached = album(m.id), !cached.tags.isEmpty {
                if !cached.tags.contains(where: { lowerEx.contains($0.lowercased()) }) {
                    keep.append(m)
                }
            } else {
                needFetch.append(m)
            }
        }
        guard !needFetch.isEmpty else { return keep }

        for batch in stride(from: 0, to: needFetch.count, by: 8) {
            let slice = Array(needFetch[batch..<min(batch + 8, needFetch.count)])
            var results: [(AlbumMeta, [String])] = []
            await withTaskGroup(of: (AlbumMeta, [String]).self) { group in
                for m in slice {
                    group.addTask {
                        let tags = (try? await JmClient.shared.album(id: m.id))?.tags ?? []
                        return (m, tags)
                    }
                }
                for await r in group { results.append(r) }
            }
            for (m, tags) in results {
                if !tags.contains(where: { lowerEx.contains($0.lowercased()) }) {
                    keep.append(m)
                }
            }
        }
        return keep
    }

    // MARK: - 本子元数据

    func album(_ id: String) -> Album? { albums[id] }

    func cache(_ album: Album) {
        albums[album.id] = album
        saveAlbums()
    }

    // MARK: - 阅读进度

    func position(for albumId: String) -> ReadingPosition? { positions[albumId] }

    func record(album: Album, chapter: ChapterMeta, page: Int) {
        guard !privateMode else { return }
        positions[album.id] = ReadingPosition(chapterId: chapter.id,
                                              chapterSort: chapter.sort,
                                              pageIndex: page,
                                              updatedAt: Date())
        let meta = AlbumMeta(id: album.id, title: album.title, authors: album.authors)
        history.removeAll { $0.id == album.id }
        history.insert(meta, at: 0)
        if history.count > 60 { history.removeLast(history.count - 60) }
        saveState()
    }

    /// 本地漫画的阅读进度：与在线阅读共用同一份历史/进度（见 LocalReaderView）。
    func recordLocal(meta: AlbumMeta, chapter: DownloadedChapter, page: Int) {
        guard !privateMode else { return }
        positions[meta.id] = ReadingPosition(chapterId: chapter.chapterId,
                                             chapterSort: chapter.sort,
                                             pageIndex: page,
                                             updatedAt: Date())
        history.removeAll { $0.id == meta.id }
        history.insert(meta, at: 0)
        if history.count > 60 { history.removeLast(history.count - 60) }
        saveState()
    }

    /// web 端写回进度（受信任设备翻页时上报，见 WebService /api/progress）
    func recordByIDs(albumId: String, albumTitle: String, chapterId: String,
                     chapterSort: Int, page: Int) {
        guard !privateMode else { return }
        positions[albumId] = ReadingPosition(chapterId: chapterId,
                                             chapterSort: chapterSort,
                                             pageIndex: page,
                                             updatedAt: Date())
        // 作者：web 端没传时，用本地缓存的详情补全（避免「未知作者」）
        var authors: [String] = []
        if let cached = album(albumId) { authors = cached.authors }
        let meta = AlbumMeta(id: albumId, title: albumTitle, authors: authors)
        history.removeAll { $0.id == albumId }
        history.insert(meta, at: 0)
        if history.count > 60 { history.removeLast(history.count - 60) }
        saveState()
    }

    func clearHistory() {
        history.removeAll()
        positions.removeAll()
        saveState()
    }

    // MARK: - 导出 / 导入（替换正式版前导出，替换后导入；明文出口由用户主动触发）

    func exportState() -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? enc.encode(State(positions: positions, history: history))
    }

    /// 合并导入：进度按本子 id，导入的新进度覆盖旧的；历史按 id 去重合并。
    /// 返回实际更新的进度条数（用于提示）。
    func importState(_ data: Data) -> Int {
        guard let p = try? JSONDecoder().decode(State.self, from: data) else { return 0 }
        var updated = 0
        for (id, pos) in p.positions {
            if let old = positions[id], old.updatedAt >= pos.updatedAt { continue }
            positions[id] = pos
            updated += 1
        }
        var merged = p.history
        for h in history where !merged.contains(where: { $0.id == h.id }) {
            merged.append(h)
        }
        history = Array(merged.prefix(60))
        saveState()
        return updated
    }
}
