import Foundation

/// 把解密后的 JSON 解析成模型。字段与 jmcomic-core 的 ApiParser 保持对齐。
enum JmParser {

    // MARK: - 辅助

    private static func string(_ obj: [String: Any], _ key: String) -> String {
        if let value = obj[key] as? String { return value }
        if let value = obj[key] as? NSNumber { return value.stringValue }
        return ""
    }

    private static func int(_ obj: [String: Any], _ key: String) -> Int {
        optionalInt(obj, key) ?? 0
    }

    /// 区分「字段是 0」和「字段不存在」。解扰参数上这两者含义完全不同。
    private static func optionalInt(_ obj: [String: Any], _ key: String) -> Int? {
        if let n = obj[key] as? Int { return n }
        if let s = obj[key] as? String, let n = Int(s) { return n }
        return nil
    }

    private static func authorList(_ obj: [String: Any]) -> [String] {
        if let arr = obj["author"] as? [String] { return arr }
        if let s = obj["author"] as? String, !s.isEmpty {
            return s.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return []
    }

    /// tags 在服务端是数组（个别时候是空格分隔的字符串），两种都要兼容
    private static func tagList(_ obj: [String: Any]) -> [String] {
        if let arr = obj["tags"] as? [String] { return arr }
        if let s = obj["tags"] as? String, !s.isEmpty {
            return s.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        return []
    }

    private static func meta(_ obj: [String: Any]) -> AlbumMeta {
        AlbumMeta(id: string(obj, "id"),
                  title: string(obj, "name"),
                  authors: authorList(obj))
    }

    // MARK: - 分页列表

    /// search / latest 通用。latest 是裸数组。
    static func parsePaged(_ json: [String: Any], page: Int) -> PagedAlbums {
        let content: [AlbumMeta]
        if let arr = json["content"] as? [[String: Any]] {
            content = arr.map(meta)
        } else if let arr = json["list"] as? [[String: Any]] {
            content = arr.map(meta)
        } else {
            content = []
        }
        let total = int(json, "total")
        let totalPages = total == 0 ? (content.isEmpty ? 0 : 1) : Int(ceil(Double(total) / 80.0))
        return PagedAlbums(items: content, totalPages: totalPages, page: page)
    }

    // MARK: - JM 账号与云端收藏

    static func parseAccount(_ json: [String: Any], fallbackUsername: String) throws -> JmAccountProfile {
        let username = string(json, "username").isEmpty
            ? fallbackUsername
            : string(json, "username")
        guard !username.isEmpty, !string(json, "s").isEmpty else {
            let message = string(json, "message")
            throw JmError.invalidCredentials(message.isEmpty ? "登录响应缺少会话信息" : message)
        }
        return JmAccountProfile(
            uid: string(json, "uid"),
            username: username,
            email: string(json, "email"),
            cloudFavoriteCount: int(json, "album_favorites")
        )
    }

    static func parseFavoritePage(_ json: [String: Any], page: Int) -> JmFavoritePage {
        let items = (json["list"] as? [[String: Any]] ?? []).map(meta)
        let folders = (json["folder_list"] as? [[String: Any]] ?? []).compactMap { item in
            let id = string(item, "FID").isEmpty ? string(item, "id") : string(item, "FID")
            let name = string(item, "name")
            guard !id.isEmpty, !name.isEmpty else { return nil }
            return JmFavoriteFolder(id: id, name: name)
        }
        return JmFavoritePage(
            items: items,
            folders: folders,
            total: int(json, "total"),
            pageSize: int(json, "count"),
            page: page
        )
    }

    // MARK: - 本子详情

    static func parseAlbum(_ json: [String: Any], fallbackId: String) throws -> Album {
        let id = string(json, "id").isEmpty ? fallbackId : string(json, "id")

        // 章节：API 的 series 数组，或单章本退化为自身
        var chapters: [ChapterMeta] = []
        if let series = json["series"] as? [[String: Any]], !series.isEmpty {
            chapters = series.map { s in
                ChapterMeta(id: string(s, "id"), title: string(s, "name"), sort: int(s, "sort"))
            }
        } else {
            chapters = [ChapterMeta(id: id, title: string(json, "name"), sort: 1)]
        }

        var related: [AlbumMeta] = []
        if let list = json["related_list"] as? [[String: Any]] {
            related = list.map(meta)
        }

        let tags = tagList(json)

        return Album(id: id,
                     title: string(json, "name"),
                     description: string(json, "description"),
                     authors: authorList(json),
                     tags: tags,
                     likes: string(json, "likes"),
                     views: string(json, "total_views"),
                     commentCount: int(json, "comment_total"),
                     totalPhotos: int(json, "total_photos"),
                     chapters: chapters,
                     related: related,
                     seriesId: string(json, "series_id"))
    }

    // MARK: - 章节

    static func parseChapter(_ json: [String: Any], id: String, sort: Int, title: String) throws -> Chapter {
        let photoId = string(json, "id").isEmpty ? id : string(json, "id")
        /*
         * scramble_id 常常不在响应里。缺失时必须回落到 220980（与 Java 版一致），
         * 不能用 0：0 会让「photoId < scrambleId」这条老本子判定永远不成立，
         * 于是本来没加扰的旧图被当成 10 段去重排，看起来就是「腿在上、头在下」。
         */
        let scrambleId = optionalInt(json, "scramble_id") ?? JmConstants.defaultScrambleId
        let name = string(json, "name").isEmpty ? title : string(json, "name")

        var pages: [ComicPage] = []
        if let images = json["images"] as? [Any] {
            for (index, item) in images.enumerated() {
                let filename: String
                if let s = item as? String {
                    filename = s
                } else if let o = item as? [String: Any], let s = o["image"] as? String {
                    filename = s
                } else {
                    continue
                }
                // 图片 CDN 域名：多个里轮着用，避免单点
                let host = JmConstants.imageDomains[index % JmConstants.imageDomains.count]
                let url = URL(string: "https://\(host)/media/photos/\(photoId)/\(filename)")!
                let noExt = (filename as NSString).deletingPathExtension
                pages.append(ComicPage(id: url.absoluteString,
                                       url: url,
                                       photoId: Int(photoId) ?? 0,
                                       scrambleId: scrambleId,
                                       filenameWithoutExtension: noExt,
                                       isGif: filename.lowercased().hasSuffix(".gif")))
            }
        }
        return Chapter(id: photoId, title: name, sort: sort, pages: pages)
    }
}
