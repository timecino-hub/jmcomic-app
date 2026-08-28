import SwiftUI

/// iOS 版入口。
///
/// 四个 tab：浏览 / 收藏 / 本地库 / 设置。每个 tab 各自一个 NavigationStack
/// （详情、分类、推荐、最近浏览等页面在各栈内推入；阅读器用 fullScreenCover 沉浸呈现）。
/// 无 Storyboard：LaunchScreen 由 GENERATE_INFOPLIST_FILE 的
/// INFOPLIST_KEY_UILaunchScreen_Generation=YES 自动生成；
/// SwiftUI lifecycle 场景清单由 INFOPLIST_KEY_UIApplicationSceneManifest_Generation=YES 自动生成。
@main
struct JMComicApp: App {
    // 导航栈的 path 必须由 NavigationStack 持有绑定：
    // 否则视图内 path.append 的程序化推入不会生效（只有 NavigationLink(value:) 才免绑定）。
    @State private var browsePath: [Route] = []
    @State private var favPath: [Route] = []

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack(path: $browsePath) {
                    BrowseView(path: $browsePath)
                }
                .tabItem { Label("浏览", systemImage: "flame") }

                NavigationStack(path: $favPath) {
                    FavoritesView(path: $favPath)
                }
                .tabItem { Label("收藏", systemImage: "heart") }

                NavigationStack {
                    LocalLibraryView()
                }
                .tabItem { Label("本地库", systemImage: "books.vertical") }

                NavigationStack {
                    SettingsView()
                }
                .tabItem { Label("设置", systemImage: "gearshape") }
            }
            .onAppear {
                // 与 Mac 端一致：启动即挑选最优域名，首屏请求更快
                Task { await JmClient.shared.bootstrap() }
            }
        }
    }
}
