import Foundation

/// 版本检查结果
struct UpdateInfo: Equatable {
    let latestVersion: String      // 规整后的版本号（去掉 v 前缀），如 "1.2.0"
    let htmlURL: URL               // release 页面地址
    let releaseName: String        // release 名称/标题，用于弹窗展示
}

/// GitHub Releases 版本检查器。
/// 仓库：https://github.com/yxxbc/jmcomic-app/releases
/// 当前版本取自 Bundle.main CFBundleShortVersionString。
enum UpdateChecker {

    static let repoReleasesURL = URL(string: "https://github.com/yxxbc/jmcomic-app/releases")!
    private static let apiURL = URL(string: "https://api.github.com/repos/yxxbc/jmcomic-app/releases/latest")!

    /// 当前 app 版本（来自 Info.plist），规整后用于比较
    static var currentVersion: String {
        normalize((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0")
    }

    /// 拉取最新 release 并与本地版本比较。有新版本返回 UpdateInfo，否则返回 nil。
    /// 任何网络/解析错误一律返回 nil（静默失败，不打扰用户）。
    static func checkForUpdate() async -> UpdateInfo? {
        var req = URLRequest(url: apiURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("jmcomic-ios", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.timeoutInterval = 10
        let session = URLSession(configuration: .ephemeral)
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawTag = obj["tag_name"] as? String, !rawTag.isEmpty
            else { return nil }
            let latest = normalize(rawTag)
            guard !latest.isEmpty, isNewer(latest, than: currentVersion) else { return nil }
            let name = (obj["name"] as? String) ?? rawTag
            let htmlStr = (obj["html_url"] as? String) ?? UpdateChecker.repoReleasesURL.absoluteString
            guard let url = URL(string: htmlStr) else { return nil }
            return UpdateInfo(latestVersion: latest, htmlURL: url, releaseName: name)
        } catch {
            return nil
        }
    }

    /// 规整版本号：去掉前导 v/V、首尾空白
    private static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        return t
    }

    /// 语义化版本比较：按 "." 分段数值比较。如 "1.2.0" > "1.1.9"。
    /// 非数字段按 0 处理；长度不等时短的补 0。
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
