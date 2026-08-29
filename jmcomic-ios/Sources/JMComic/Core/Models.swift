import Foundation

/// 列表页里的本子摘要
struct AlbumMeta: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let authors: [String]

    var authorText: String { authors.isEmpty ? "未知作者" : authors.joined(separator: ", ") }
}

/// 章节摘要
struct ChapterMeta: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let sort: Int

    var displayTitle: String {
        title.trimmingCharacters(in: .whitespaces).isEmpty ? "第 \(sort) 话" : title
    }
}

/// 本子详情
struct Album: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let description: String
    let authors: [String]
    let tags: [String]
    let likes: String
    let views: String
    let commentCount: Int
    let totalPhotos: Int
    let chapters: [ChapterMeta]
    /// 服务端 related_list：同系列续作 / 相关作品，无需自己算
    let related: [AlbumMeta]
    let seriesId: String

    var authorText: String { authors.isEmpty ? "未知作者" : authors.joined(separator: ", ") }
    var isSeries: Bool { seriesId != "0" && !seriesId.isEmpty }
}

/// 一页漫画
struct ComicPage: Identifiable, Hashable, Sendable {
    let id: String          // 用 URL 作为唯一标识，天然可做缓存键
    let url: URL
    let photoId: Int
    let scrambleId: Int
    let filenameWithoutExtension: String
    let isGif: Bool

    var segmentCount: Int {
        isGif ? 0 : JmCrypto.segmentCount(scrambleId: scrambleId,
                                          photoId: photoId,
                                          filenameWithoutExtension: filenameWithoutExtension)
    }
}

/// 章节详情
struct Chapter: Sendable {
    let id: String
    let title: String
    let sort: Int
    let pages: [ComicPage]
}

/// 分页结果
struct PagedAlbums: Sendable {
    let items: [AlbumMeta]
    let totalPages: Int
    let page: Int

    var hasMore: Bool { page < totalPages }
}

// MARK: - JM 账号与云端收藏

/// 登录后用于界面展示的最小账号资料。密码永不进入该模型。
struct JmAccountProfile: Codable, Hashable, Sendable {
    let uid: String
    let username: String
    let email: String
    let cloudFavoriteCount: Int
}

/// 登录接口返回的会话。Cookie 只会由 JmAccountStore 写入钥匙串。
struct JmLoginResult: Sendable {
    let profile: JmAccountProfile
    let cookies: [String: String]
    let preferredHost: String
}

struct JmFavoriteFolder: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
}

struct JmFavoritePage: Sendable {
    let items: [AlbumMeta]
    let folders: [JmFavoriteFolder]
    let total: Int
    let pageSize: Int
    let page: Int

    var hasMore: Bool {
        guard !items.isEmpty else { return false }
        let size = max(pageSize, items.count)
        if total > 0 { return total > page * size }
        return pageSize > 0 && items.count >= pageSize
    }
}

/// 已完整拉取、等待一次性写入本地收藏的数据。
struct JmCloudFavorite: Sendable {
    let meta: AlbumMeta
    let folderName: String
}
