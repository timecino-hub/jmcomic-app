import SwiftUI

/// 顶层功能区。iPad 用它驱动侧边栏，窄窗口和 iPhone 用它驱动 TabView。
private enum AppSection: String, CaseIterable, Identifiable {
    case browse = "浏览"
    case favorites = "收藏"
    case localLibrary = "本地库"
    case settings = "设置"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .browse: return "flame"
        case .favorites: return "heart"
        case .localLibrary: return "books.vertical"
        case .settings: return "gearshape"
        }
    }
}

/// iOS / iPadOS 通用入口。
///
/// - iPhone 与 iPad 分屏窄窗口：底部 TabView。
/// - 11 英寸 iPad 的常规宽度窗口：NavigationSplitView 侧边栏。
/// - 每个窗口都持有独立的选择和导航路径，支持 iPadOS 多窗口与台前调度。
@main
struct JMComicApp: App {
    var body: some Scene {
        WindowGroup {
            JMComicRootView()
        }
    }
}

private struct JMComicRootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var selection: AppSection = .browse
    @State private var browsePath: [Route] = []
    @State private var favoritePath: [Route] = []
    @State private var didStart = false

    // 版本更新检查
    @State private var updateInfo: UpdateInfo?
    private let skippedUpdateKey = "skippedUpdateVersion"

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                iPadLayout
            } else {
                compactLayout
            }
        }
        .onAppear {
            guard !didStart else { return }
            didStart = true
            // 与 Mac 端一致：启动即挑选最优域名，首屏请求更快。
            Task { await JmClient.shared.bootstrap() }
            // 独立检查版本更新，不阻塞 bootstrap。
            Task { await checkForUpdate() }
        }
        .alert("发现新版本",
               isPresented: Binding(get: { updateInfo != nil },
                                    set: { if !$0 { updateInfo = nil } })) {
            if let info = updateInfo {
                Button("前往下载") {
                    UIApplication.shared.open(UpdateChecker.repoReleasesURL)
                    updateInfo = nil
                }
                Button("稍后", role: .cancel) {
                    UserDefaults.standard.set(info.latestVersion, forKey: skippedUpdateKey)
                    updateInfo = nil
                }
            }
        } message: {
            if let info = updateInfo {
                Text("\(info.releaseName)\n当前版本 \(UpdateChecker.currentVersion) → 最新版本 \(info.latestVersion)")
            }
        }
    }

    /// iPad 常规宽度：稳定的侧边栏 + 内容区，适配 4:3 横竖屏。
    private var iPadLayout: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                ForEach(AppSection.allCases) { section in
                    Label(section.rawValue, systemImage: section.icon)
                        .tag(section)
                }
            }
            .navigationTitle("JMComic")
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            sectionView(selection)
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// List 的单选绑定是可选值；拒绝 nil，保证内容区始终有一个可见功能区。
    private var sidebarSelection: Binding<AppSection?> {
        Binding(
            get: { selection },
            set: { newValue in
                if let newValue { selection = newValue }
            }
        )
    }

    /// iPhone 或 iPad 窄窗口：保留熟悉的四标签结构。
    private var compactLayout: some View {
        TabView(selection: $selection) {
            sectionView(.browse)
                .tabItem { Label(AppSection.browse.rawValue, systemImage: AppSection.browse.icon) }
                .tag(AppSection.browse)

            sectionView(.favorites)
                .tabItem { Label(AppSection.favorites.rawValue, systemImage: AppSection.favorites.icon) }
                .tag(AppSection.favorites)

            sectionView(.localLibrary)
                .tabItem { Label(AppSection.localLibrary.rawValue, systemImage: AppSection.localLibrary.icon) }
                .tag(AppSection.localLibrary)

            sectionView(.settings)
                .tabItem { Label(AppSection.settings.rawValue, systemImage: AppSection.settings.icon) }
                .tag(AppSection.settings)
        }
    }

    @ViewBuilder
    private func sectionView(_ section: AppSection) -> some View {
        switch section {
        case .browse:
            NavigationStack(path: $browsePath) {
                BrowseView(path: $browsePath)
            }
        case .favorites:
            NavigationStack(path: $favoritePath) {
                FavoritesView(path: $favoritePath)
            }
        case .localLibrary:
            NavigationStack {
                LocalLibraryView()
            }
        case .settings:
            NavigationStack {
                SettingsView()
            }
        }
    }

    /// 启动时检查版本更新；若该版本已被用户跳过则不再弹窗。
    private func checkForUpdate() async {
        guard let info = await UpdateChecker.checkForUpdate() else { return }
        let skipped = UserDefaults.standard.string(forKey: skippedUpdateKey)
        guard skipped != info.latestVersion else { return }
        await MainActor.run { updateInfo = info }
    }
}
