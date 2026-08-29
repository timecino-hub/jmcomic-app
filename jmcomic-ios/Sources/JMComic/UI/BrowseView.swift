import SwiftUI
import UIKit

/// 浏览页（iOS 版）。
///
/// Mac 版是 NavigationSplitView 侧栏结构；iPhone 上没有侧栏：
/// - 热门 / 最新 / 历史 改为导航栏里的分段选择器
/// - 分类 / 为你推荐 / 最近浏览 从列表顶部入口行推入（Route 二级页）
/// - 滚动位置恢复不再操作 NSScrollView：用 representable 找到底层 UIScrollView
///   直接 setContentOffset（懒加载场景比 scrollTo 更可靠），逻辑与 Mac 版等价
struct BrowseView: View {

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private enum Feed: String, CaseIterable, Identifiable {
        case hot = "热门"
        case latest = "最新"
        case history = "历史"
        var id: String { rawValue }
    }

    /// 每个 feed 完全独立的浏览状态：切走不丢、重启后也从缓存恢复
    private struct FeedState {
        var items: [AlbumMeta] = []
        var page = 1
        var totalPages = 1
        var scrollOffset: Double = 0
        var loading = false
        var error: String?

        init() {}
        func toCache() -> FeedCacheEntry {
            FeedCacheEntry(items: items, page: page, totalPages: totalPages,
                           scrollID: nil, scrollOffset: scrollOffset)
        }
        init(from c: FeedCacheEntry) {
            items = c.items
            page = c.page
            totalPages = c.totalPages
            scrollOffset = c.scrollOffset ?? 0
        }
    }

    @State private var mode: Feed = .hot
    /// 绑定自 App 的 NavigationStack：程序化推入（点卡片/入口行）依赖这个绑定
    @Binding var path: [Route]
    @State private var states: [Feed: FeedState] = [:]

    /// 当前滚动偏移（像素）与精确恢复目标（非 nil 时消费后置空）
    @State private var scrollOffset: Double = 0
    @State private var restoreTarget: Double?
    @State private var restoreToken = 0

    // 搜索（防抖）：临时视图不进 tab 缓存，避免污染热门/最新已加载内容
    @State private var query = ""
    @State private var searching = false
    @State private var searchItems: [AlbumMeta] = []
    @FocusState private var searchFieldFocused: Bool

    @StateObject private var library = LibraryStore.shared
    @StateObject private var downloads = DownloadStore.shared

    init(path: Binding<[Route]>) {
        _path = path
    }

    private var state: FeedState {
        get { states[mode] ?? FeedState() }
        nonmutating set { states[mode] = newValue }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ScrollOffsetProbe()
                    .frame(height: 0)

                entryRow
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .jmCentered(alignment: .leading)

                gridContent
                    .padding(.top, 12)

                bottomSection
                    .jmCentered()
            }
            .coordinateSpace(name: "jmfeed")
            .onPreferenceChange(ScrollProbeKey.self) { minY in
                // 内容顶相对视口顶的偏移（向下滚为正）
                scrollOffset = -minY
            }
            .overlay(alignment: .bottomTrailing) {
                if scrollOffset > 220 {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("entry-row", anchor: .top)
                        }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .background(Color.accentColor.opacity(0.9))
                            .foregroundStyle(.white)
                            .clipShape(Circle())
                            .shadow(radius: 4)
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle(mode.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 固定在左上角的搜索框：不随滚动收起（替代 .searchable 的下沉式搜索）
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("搜索本子或作者", text: $query)
                        .textFieldStyle(.plain)
                        .font(.footnote)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.search)
                        .focused($searchFieldFocused)
                        .onSubmit {
                            searchFieldFocused = false
                            Task { await runSearch(immediate: true) }
                        }
                    if !query.isEmpty {
                        Button {
                            query = ""
                            searchFieldFocused = false
                            exitSearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .frame(width: horizontalSizeClass == .regular ? 220 : 132)
            }
            ToolbarItem(placement: .principal) {
                Picker("源", selection: $mode) {
                    ForEach(Feed.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await reload(mode) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(searching || mode == .history)
            }
        }
        // 防抖：停止输入 0.5s 后自动搜；每次按键重置计时
        .task(id: query) {
            guard !query.isEmpty else {
                if searching { exitSearch() }
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await runSearch(immediate: false)
        }
        // 切换 热门/最新/历史：保存离开时的位置，恢复目标源的位置
        .onChange(of: mode) { old, _ in
            if var s = states[old], !s.items.isEmpty {
                s.scrollOffset = scrollOffset
                states[old] = s
                library.saveFeedCache(old.rawValue, s.toCache())
            }
            if searching { exitSearch() }
            if let st = states[mode], !st.items.isEmpty {
                kickRestore(to: st.scrollOffset)
            } else if let cached = library.cachedFeed(mode.rawValue), !cached.items.isEmpty {
                kickRestore(to: cached.scrollOffset ?? 0)
            }
            Task { await restoreOrLoad(mode) }
        }
        // 精确恢复：直接驱动底层 UIScrollView，懒加载也不受影响
        .background(
            ScrollRestorer(token: restoreToken, targetY: restoreTarget) {
                restoreTarget = nil
            }
        )
        .navigationDestination(for: Route.self) { route in
            // 整个浏览栈只在这里注册一次 Route 目标页；
            // 二级页（分类/推荐/最近）共用同一个 path 绑定推入详情
            switch route {
            case .album(let meta):
                AlbumDetailView(meta: meta, path: $path)
            case .categories:
                CategoriesView(path: $path)
            case .personalized:
                PersonalizedView(path: $path)
            case .recent:
                RecentView(path: $path)
            }
        }
        .task { await restoreOrLoad(.hot) }
    }

    // MARK: - 顶部入口（Mac 版侧栏 → 推入式导航）

    private var entryRow: some View {
        HStack(spacing: 10) {
            entryButton("分类", "square.grid.2x2") { path.append(.categories) }
            entryButton("为你推荐", "sparkles") { path.append(.personalized) }
            entryButton("最近浏览", "clock", badge: library.recentlyViewed.count) {
                path.append(.recent)
            }
        }
        .id("entry-row")
    }

    private func entryButton(_ title: String, _ icon: String,
                             badge: Int = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption)
                Text(title).font(.footnote)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.25))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(Color.primary.opacity(0.06))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 网格内容

    /// 历史走本地库（与热门/最新网络源完全隔离）；搜索是临时视图
    private var shownItems: [AlbumMeta] {
        if searching { return searchItems }
        if mode == .history { return library.history }
        return state.items
    }

    @ViewBuilder
    private var gridContent: some View {
        let shown = shownItems
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 16) {
            ForEach(shown) { meta in
                Button { path.append(.album(meta)) } label: {
                    AlbumCard(meta: meta)
                }
                .buttonStyle(.plain)
                .id(meta.id)
            }
        }
        .padding(.horizontal, 16)
        .jmCentered()
    }

    @ViewBuilder
    private var bottomSection: some View {
        VStack(spacing: 10) {
            if state.loading {
                ProgressView().padding(.bottom, 24)
            } else if canLoadMore {
                Button("加载更多") { Task { await loadMore() } }
                    .padding(.bottom, 26)
            }
            if let error = state.error, shownItems.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                    Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("重试") { Task { await reload(mode) } }
                }
                .padding(40)
            } else if shownItems.isEmpty && !state.loading {
                VStack(spacing: 8) {
                    if searching {
                        Text("没有找到「\(query)」的结果")
                    } else if mode == .history {
                        Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary)
                        Text("还没有阅读记录").foregroundStyle(.secondary)
                    } else {
                        Text("没有结果").foregroundStyle(.secondary)
                    }
                }
                .font(.footnote)
                .padding(50)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func exitSearch() {
        searching = false
        searchItems = []
    }

    // MARK: - 数据

    private var canLoadMore: Bool {
        !searching && mode != .history && state.page < state.totalPages
    }

    /// 恢复或加载：磁盘缓存优先（回到上次浏览位置），否则网络拉取
    private func restoreOrLoad(_ f: Feed) async {
        guard states[f] == nil else { return }
        if let cached = library.cachedFeed(f.rawValue), !cached.items.isEmpty {
            let s = FeedState(from: cached)
            states[f] = s
            if f == mode {
                kickRestore(to: s.scrollOffset)
            }
            return
        }
        await reload(f)
    }

    /// 触发一次偏移恢复：换 token 保证同值也能再次生效
    private func kickRestore(to offset: Double) {
        restoreTarget = max(offset, 0)
        restoreToken += 1
    }

    private func reload(_ f: Feed) async {
        guard f != .history else { return }
        searching = false
        var s = states[f] ?? FeedState()
        s.page = 1
        s.items = []
        states[f] = s
        await fetch(f, reset: true)
    }

    private func loadMore() async {
        let f = mode
        guard !searching, f != .history else { return }
        states[f]?.page = (states[f]?.page ?? 1) + 1
        await fetch(f, reset: false)
    }

    /// 抓取时锁定当时的 feed，切走也不会写错 tab
    private func fetch(_ f: Feed, reset: Bool) async {
        guard f != .history else { return }
        states[f]?.loading = true
        states[f]?.error = nil
        let page = states[f]?.page ?? 1
        do {
            let result: PagedAlbums
            switch f {
            case .hot: result = try await JmClient.shared.hot(page: page)
            case .latest: result = try await JmClient.shared.latest(page: page)
            case .history: return
            }
            if reset {
                states[f]?.items = await library.filterByExclusions(result.items)
            } else {
                var cur = states[f]?.items ?? []
                cur += await library.filterByExclusions(result.items)
                states[f]?.items = cur
            }
            states[f]?.totalPages = max(result.totalPages, 1)
            // 拉取完成即落盘，重启后可恢复
            if let st = states[f] {
                library.saveFeedCache(f.rawValue, st.toCache())
            }
        } catch {
            states[f]?.error = error.localizedDescription
        }
        states[f]?.loading = false
    }

    /// 搜索（onSubmit 立即执行；task(id: query) 防抖执行）
    private func runSearch(immediate: Bool) async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            searching = false
            return
        }
        // 纯数字输入：视为专辑 ID，直接打开详情（搜索接口不认 ID）；
        // 防抖路径不响应纯数字，避免逐键弹出详情
        if text.allSatisfy(\.isNumber) {
            guard immediate else { return }
            searching = false
            path.append(.album(AlbumMeta(id: text, title: "专辑 \(text)", authors: [])))
            return
        }
        searching = true
        searchItems = []
        states[mode]?.loading = true
        states[mode]?.error = nil
        do {
            let result = try await JmClient.shared.search(text, page: 1)
            searchItems = result.items
        } catch {
            states[mode]?.error = error.localizedDescription
        }
        states[mode]?.loading = false
    }
}

// MARK: - 滚动探测与恢复（UIScrollView 兜底，替代 Mac 版的 NSScrollView 直操）

private struct ScrollProbeKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 滚动偏移探测：把本坐标系的 minY 通过 preference 抛出去
private struct ScrollOffsetProbe: View {
    var body: some View {
        GeometryReader { g in
            Color.clear.preference(key: ScrollProbeKey.self,
                                   value: g.frame(in: .named("jmfeed")).minY)
        }
    }
}

/// 直接把底层 UIScrollView 滚到指定偏移。
/// scrollTo 对懒加载视口外的目标不可靠，这是最终兜底：
/// token 变化即定位一次（消费后置 nil），不干扰后续用户滚动。
private struct ScrollRestorer: UIViewRepresentable {
    var token: Int
    var targetY: Double?
    let onRestored: () -> Void

    func makeUIView(context: Context) -> UIView { UIView() }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let targetY, context.coordinator.lastToken != token else { return }
        context.coordinator.lastToken = token
        guard let scroll = Self.findScrollView(uiView) else { return }
        let y = CGFloat(targetY)
        if abs(scroll.contentOffset.y - y) > 1 {
            scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        }
        DispatchQueue.main.async { onRestored() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastToken = -1
    }

    private static func findScrollView(_ v: UIView) -> UIScrollView? {
        var cur: UIView? = v
        while let c = cur {
            if let s = c as? UIScrollView { return s }
            cur = c.superview
        }
        return nil
    }
}
