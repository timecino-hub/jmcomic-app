import Foundation

/// 本地收藏。
///
/// 刻意不走服务端收藏夹：不用登录、不受账号封禁影响、也不把口味上传。
/// 支持自建分组（服务端收藏夹要会员才能多建，本地没这限制）。
///
/// 文件就是普通 JSON，导出即备份，想同步到 GitHub 私有库直接拿这个文件。
@MainActor
final class FavoriteStore: ObservableObject {

    static let shared = FavoriteStore()

    struct Entry: Codable, Hashable, Identifiable {
        var meta: AlbumMeta
        var folder: String
        var addedAt: Date
        var id: String { meta.id }
    }

    @Published private(set) var entries: [Entry] = []
    /// 分组顺序由用户决定，所以单独存一份，空分组也要保留
    @Published private(set) var folders: [String] = ["默认"]

    private let dir: URL
    private var file: URL { dir.appendingPathComponent("favorites.json") }

    private struct Payload: Codable {
        var entries: [Entry]
        var folders: [String]
    }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("JMComic", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ImageStore.harden(dir)
        ImageStore.excludeFromBackup(dir)
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        // 新格式：密文；旧格式：明文（解析成功即加密重写迁移）
        if let key = CryptoStore.key(),
           let plain = try? CryptoStore.decrypt(data, key: key),
           let p = try? JSONDecoder().decode(Payload.self, from: plain) {
            entries = p.entries
            folders = p.folders.isEmpty ? ["默认"] : p.folders
        } else if let p = try? JSONDecoder().decode(Payload.self, from: data) {
            entries = p.entries
            folders = p.folders.isEmpty ? ["默认"] : p.folders
            save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Payload(entries: entries, folders: folders)),
              let key = CryptoStore.key(),
              let enc = try? CryptoStore.encrypt(data, key: key)
        else { return }
        try? enc.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    // MARK: - 查询

    func contains(_ id: String) -> Bool { entries.contains { $0.meta.id == id } }

    func folder(of id: String) -> String? { entries.first { $0.meta.id == id }?.folder }

    func entries(in folder: String) -> [Entry] {
        entries.filter { $0.folder == folder }.sorted { $0.addedAt > $1.addedAt }
    }

    func count(in folder: String) -> Int {
        entries.reduce(0) { $0 + ($1.folder == folder ? 1 : 0) }
    }

    // MARK: - 增删

    func toggle(_ album: Album, folder: String = "默认") {
        if contains(album.id) {
            remove(album.id)
        } else {
            add(AlbumMeta(id: album.id, title: album.title, authors: album.authors), folder: folder)
        }
    }

    func add(_ meta: AlbumMeta, folder: String = "默认") {
        guard !contains(meta.id) else { return }
        if !folders.contains(folder) { folders.append(folder) }
        entries.insert(Entry(meta: meta, folder: folder, addedAt: Date()), at: 0)
        save()
    }

    func remove(_ id: String) {
        entries.removeAll { $0.meta.id == id }
        save()
    }

    func move(_ id: String, to folder: String) {
        guard let i = entries.firstIndex(where: { $0.meta.id == id }) else { return }
        if !folders.contains(folder) { folders.append(folder) }
        entries[i].folder = folder
        save()
    }

    // MARK: - 分组

    func addFolder(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !folders.contains(n) else { return }
        folders.append(n)
        save()
    }

    /// 删除分组时把里面的条目退回「默认」，不连带删收藏
    func removeFolder(_ name: String) {
        guard name != "默认" else { return }
        folders.removeAll { $0 == name }
        for i in entries.indices where entries[i].folder == name {
            entries[i].folder = "默认"
        }
        save()
    }

    /// 分组改名：条目一起迁移。目标名已存在时把内容并入该分组。
    func renameFolder(_ old: String, to new: String) {
        let n = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, old != "默认", old != n else { return }
        let targetExists = folders.contains(n)
        for i in entries.indices where entries[i].folder == old {
            entries[i].folder = n
        }
        folders.removeAll { $0 == old }
        if !targetExists, !folders.contains(n) { folders.append(n) }
        save()
    }

    // MARK: - 导出 / 导入（备份、或塞进自己的 GitHub 私有库）

    func exportJSON() -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? enc.encode(Payload(entries: entries, folders: folders))
    }

    /// 按 id 合并，保留本地已有条目的分组，不覆盖
    func importJSON(_ data: Data) -> Int {
        guard let p = try? JSONDecoder().decode(Payload.self, from: data) else { return 0 }
        var added = 0
        for f in p.folders where !folders.contains(f) { folders.append(f) }
        for e in p.entries where !contains(e.meta.id) {
            entries.append(e)
            added += 1
        }
        entries.sort { $0.addedAt > $1.addedAt }
        save()
        return added
    }
}
