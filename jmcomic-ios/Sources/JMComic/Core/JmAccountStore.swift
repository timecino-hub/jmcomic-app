import Combine
import Foundation
import Security

/// JM 账号会话与云端收藏下行同步。
///
/// 安全边界：密码只在 login 调用栈中短暂存在；钥匙串只保存用户名、账号摘要和会话 Cookie。
/// 同步只在用户点击后执行，完整拉取成功后才一次性并入本地收藏，不上传也不远程删除。
@MainActor
final class JmAccountStore: ObservableObject {

    static let shared = JmAccountStore()

    @Published private(set) var profile: JmAccountProfile?
    @Published private(set) var isLoggingIn = false
    @Published private(set) var isSyncing = false
    @Published private(set) var syncProgress: String?
    @Published private(set) var lastSyncDate: Date?

    var isLoggedIn: Bool { session != nil && profile != nil }

    private struct SessionRecord: Codable, Sendable {
        var profile: JmAccountProfile
        let cookies: [String: String]
        let preferredHost: String
    }

    private var session: SessionRecord?
    private let lastSyncKey = "jmAccountLastFavoriteSync"

    private init() {
        lastSyncDate = UserDefaults.standard.object(forKey: lastSyncKey) as? Date
        if let saved = SessionKeychain.load() {
            session = saved
            profile = saved.profile
        }
    }

    func login(username: String, password: String) async throws {
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUsername.isEmpty, !password.isEmpty else {
            throw JmError.invalidCredentials("请输入用户名和密码")
        }
        guard !isLoggingIn, !isSyncing else { return }

        isLoggingIn = true
        defer { isLoggingIn = false }
        let result = try await JmClient.shared.login(username: cleanUsername, password: password)
        let record = SessionRecord(profile: result.profile,
                                   cookies: result.cookies,
                                   preferredHost: result.preferredHost)
        guard SessionKeychain.save(record) else {
            throw JmError.api("登录成功，但无法将会话安全保存到钥匙串")
        }
        session = record
        profile = record.profile
    }

    func logout() {
        SessionKeychain.delete()
        session = nil
        profile = nil
        syncProgress = nil
    }

    /// 拉取全部收藏夹。自定义收藏夹先处理，最后处理 folder_id=0，避免“全部收藏”
    /// 与自定义分组内容重叠时把条目错误归入默认分组。
    func syncFavorites() async throws -> FavoriteStore.CloudImportResult {
        guard let session else { throw JmError.sessionExpired }
        guard !isSyncing, !isLoggingIn else {
            return FavoriteStore.CloudImportResult(added: 0, skipped: 0, foldersAdded: 0)
        }

        isSyncing = true
        syncProgress = "正在读取云端收藏夹…"
        defer {
            isSyncing = false
            syncProgress = nil
        }

        do {
            let seed = try await JmClient.shared.favoritePage(
                page: 1, folderID: "0", cookies: session.cookies,
                preferredHost: session.preferredHost)
            var folderIDs = Set<String>()
            let customFolders = seed.folders.filter { folder in
                folder.id != "0" && folderIDs.insert(folder.id).inserted
            }
            let targets = customFolders + [JmFavoriteFolder(id: "0", name: "默认")]

            var seenIDs = Set<String>()
            var snapshot: [JmCloudFavorite] = []
            var loadedPages = 0

            for folder in targets {
                var pageNumber = 1
                while true {
                    try Task.checkCancellation()
                    let page: JmFavoritePage
                    if customFolders.isEmpty, folder.id == "0", pageNumber == 1 {
                        page = seed
                    } else {
                        page = try await JmClient.shared.favoritePage(
                            page: pageNumber, folderID: folder.id,
                            cookies: session.cookies, preferredHost: session.preferredHost)
                    }
                    loadedPages += 1

                    for meta in page.items where !meta.id.isEmpty {
                        if seenIDs.insert(meta.id).inserted {
                            snapshot.append(JmCloudFavorite(meta: meta, folderName: folder.name))
                        }
                    }
                    syncProgress = "已读取 \(snapshot.count) 条 · \(folder.name) · 第 \(pageNumber) 页"

                    guard page.hasMore else { break }
                    pageNumber += 1
                    guard pageNumber <= 500, loadedPages <= 2_000 else {
                        throw JmError.parseFailed("云端收藏分页数量异常，已停止以避免重复请求")
                    }
                }
            }

            try Task.checkCancellation()
            let result = try FavoriteStore.shared.importCloudFavorites(snapshot)
            let now = Date()
            lastSyncDate = now
            UserDefaults.standard.set(now, forKey: lastSyncKey)
            return result
        } catch let error as JmError {
            if case .sessionExpired = error { logout() }
            throw error
        }
    }

    // MARK: - Keychain

    private enum SessionKeychain {
        static let service = "local.jmcomic.jm-account"
        static let account = "session-v1"

        static func load() -> SessionRecord? {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else { return nil }
            return try? JSONDecoder().decode(SessionRecord.self, from: data)
        }

        static func save(_ record: SessionRecord) -> Bool {
            guard let data = try? JSONEncoder().encode(record) else { return false }
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            let update: [String: Any] = [kSecValueData as String: data]
            let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if status == errSecSuccess { return true }
            guard status == errSecItemNotFound else { return false }

            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }

        static func delete() {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}
