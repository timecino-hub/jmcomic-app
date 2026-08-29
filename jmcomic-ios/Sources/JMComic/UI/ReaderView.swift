import SwiftUI
import UIKit

/// 一页的显示单元。
///
/// 两种布局：
/// - 连续模式（viewport == nil）：宽度撑满、高度自适应真实比例——细长页完整展开
/// - 单页模式（viewport 非 nil）：整页 fit 进视口——一屏一页、上下完整
///
/// 支持双击局部放大（×2，以点击位置为中心，再双击还原）。
private struct PageCell: View {
    let page: ComicPage
    let width: CGFloat
    let ratio: CGFloat        // 高/宽
    let viewport: CGSize?

    @State private var image: CGImage?
    @State private var failed = false
    @State private var zoomed = false
    @State private var zoomAnchor = UnitPoint(x: 0.5, y: 0.5)

    var body: some View {
        ZStack(alignment: .top) {
            if let image {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: viewport?.width ?? width,
                          height: viewport?.height)
                    .scaleEffect(zoomed ? 2 : 1, anchor: zoomAnchor)
                    .onTapGesture(count: 2, coordinateSpace: .local) { loc in
                        let h = max(viewport?.height ?? width * ratio, 1)
                        zoomAnchor = UnitPoint(x: loc.x / max(width, 1), y: loc.y / h)
                        zoomed.toggle()
                    }
            } else {
                Rectangle()
                    .fill(Color(intensity: 0.13))
                    .frame(width: viewport?.width ?? width,
                          height: viewport?.height ?? (width * ratio).rounded())
                    .overlay {
                        if failed {
                            VStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle")
                                Text("加载失败").font(.caption)
                                Button("重试") { failed = false; load() }
                                    .font(.caption)
                            }
                            .foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
            }
        }
        .clipped()
        .task(id: page.id) { load() }
    }

    private func load() {
        Task {
            let img = await ImageStore.shared.page(page)
            await MainActor.run {
                if let img { self.image = img } else { self.failed = true }
            }
        }
    }
}

/// 滚动偏移追踪（沉浸式顶栏用：滚动中隐藏控制栏）
private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 在线阅读器（iOS 版）。
///
/// 与 Mac 版的能力对齐与差异：
/// - 连续滚动 / 单页翻页两种模式（偏好持久化）
/// - 沉浸式控制栏：**单击任意处显隐**（Mac 是鼠标移动唤出 + 键盘翻页，触屏无这些事件，
///   全部换成手势）；双击放大不受影响
/// - 底部跳页滑条（拖动带目标页小预览）；下一话手动按钮 + 可选「读完自动接下一话」（设置开关，
///   默认关，避免误触）
/// - 断点续读：依赖 LibraryStore 进度持久化，「断点续读」设置关闭时不恢复页码
struct ReaderView: View {

    let album: Album
    @State var chapterIndex: Int

    @Environment(\.dismiss) private var dismiss
    @StateObject private var library = LibraryStore.shared

    @State private var chapter: Chapter?
    @State private var loading = true
    @State private var error: String?
    @State private var visiblePage = 0
    /// 打开时要恢复到的页码，恢复完清空
    @State private var restoreTo: Int?
    /// 恢复定位完成前不写进度，防止打开瞬间把旧进度覆盖成第一页
    @State private var allowRecord = true

    // 沉浸控制栏：隐藏后保持隐藏，单击才唤出（不自动弹）
    @State private var chromeVisible = true
    // 跳页：统一入口（滑条消费 scrollTo）
    @State private var jumpTarget: Int?
    @State private var sliderPage = 1.0
    // 滑条拖动中的页面预览
    @State private var sliderEditing = false
    @State private var sliderPreviewIndex: Int?
    // 滑条看门狗：个别系统版本松手后 onEditingChanged(false) 不回调，
    // 滑条 2.5s 无新动作就强制收起预览（不跳页，避免手指未离开时误跳）
    @State private var sliderWatchdog: Task<Void, Never>?
    // 自动接下一话：滚到本话最后一页停留片刻自动切章（设置可关）
    @State private var autoNextTask: Task<Void, Never>?
    @State private var autoNextHint = false
    /// scrollPosition 双保险定位锚点（与本地阅读器一致）
    @State private var scrollTarget: Int?
    // 单页模式（偏好持久化：设置页可永久设置默认）
    @State private var singlePage = UserDefaults.standard.bool(forKey: "readerSinglePage") {
        didSet { UserDefaults.standard.set(singlePage, forKey: "readerSinglePage") }
    }

    private var chapterMeta: ChapterMeta { album.chapters[chapterIndex] }

    var body: some View {
        ZStack {
            content
                .background(Color(intensity: 0.11))
        }
        // 沉浸模式：内容真正铺满全屏（顶部顶到状态栏、底部顶到 Home 条），
        // 而不是只在安全区里把控制栏滑出去
        .ignoresSafeArea(.all, edges: chromeVisible ? [] : .all)
        .contentShape(Rectangle())
        // 单击任意处：切换控制栏显隐（双击放大优先识别，不受影响）
        .onTapGesture(count: 1) {
            withAnimation(.easeInOut(duration: 0.18)) { chromeVisible.toggle() }
        }
        // 控制栏显隐改为「真移除」（条件挂载 + move 过渡）：
        // 隐藏时视图彻底不在层级里，不会出现 offset 方案那种半路闪回
        .overlay(alignment: .top) {
            if chromeVisible {
                toolbar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if chromeVisible {
                jumpBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // 滑条预览：常驻挂载 + opacity 显隐（不依赖条件卸载，杜绝「删不掉残留显示」）
        .overlay(alignment: .bottom) {
            sliderPreview
                .opacity(sliderEditing ? 1 : 0)
                .animation(.easeInOut(duration: 0.12), value: sliderEditing)
                .allowsHitTesting(false)
        }
        // 自动接下一话的轻提示
        .overlay(alignment: .bottom) {
            if autoNextHint {
                Label("即将自动进入下一话", systemImage: "forward.circle.fill")
                    .font(.caption)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 58)
                    .transition(.opacity)
            }
        }
        // 控制栏一隐藏就强制收起滑条预览（防止 Slider 松手回调丢失导致预览滞留）
        .onChange(of: chromeVisible) { _, visible in
            if !visible { forceEndSliderEditing() }
        }
        // SwiftUI 的 .statusBarHidden 在部分容器组合下不生效（fullScreenCover 已有实测失效），
        // 用嵌入 VC 的 prefersStatusBarHidden 做兜底，双保险
        .statusBarHidden(!chromeVisible)
        .overlay { StatusBarHider(hidden: !chromeVisible) }
        .persistentSystemOverlays(chromeVisible ? .visible : .hidden)
        .task(id: chapterIndex) { await loadChapter() }
        .onDisappear { library.flushState() }
    }

    // MARK: - 控制栏（顶部）

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("关闭")

            Text(album.title)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            if album.chapters.count > 1 {
                Menu {
                    Picker("章节", selection: $chapterIndex) {
                        ForEach(Array(album.chapters.enumerated()), id: \.offset) { i, c in
                            Text(c.displayTitle).tag(i)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "list.bullet")
                        Text(chapterMeta.displayTitle).lineLimit(1).frame(maxWidth: 120)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .font(.caption)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .layoutPriority(1)
            }

            if let chapter {
                Text("\(min(visiblePage + 1, chapter.pages.count)) / \(chapter.pages.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button(singlePage ? "连续" : "单页") {
                singlePage.toggle()
                chromeVisible = true
            }
            .buttonStyle(.bordered)
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: JMLayout.readerToolbarMaxWidth)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 10)
    }

    // MARK: - 跳页条（底部）

    private var jumpBar: some View {
        // Slider 的 range 不能是 1...1（Normalizing 断言会崩），章节没加载或只有一页时不渲染
        Group {
            if let count = chapter?.pages.count, count > 1 {
                HStack(spacing: 10) {
                    Image(systemName: "book")
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value: $sliderPage, in: 1...Double(count), step: 1) { editing in
                        if editing {
                            beginSliderEditing(count: count)
                        } else {
                            endSliderEditing(jump: true, count: count)
                        }
                    }
                    Text("\(Int(sliderPage)) / \(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 56, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: JMLayout.readerJumpBarMaxWidth)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                // 拖动中实时刷新预览页并喂看门狗
                .onChange(of: sliderPage) { _, v in
                    guard sliderEditing, let count = chapter?.pages.count, count > 0 else { return }
                    sliderPreviewIndex = min(max(Int(v) - 1, 0), count - 1)
                    petSliderWatchdog()
                }
            }
        }
    }

    /// 拖动滑条时显示的目标页小预览。
    /// 常驻挂载（显隐由外层 opacity 控制），索引只更新不清空——彻底避免条件卸载残留。
    @ViewBuilder
    private var sliderPreview: some View {
        if let chapter, let idx = sliderPreviewIndex,
           chapter.pages.indices.contains(idx) {
            VStack(spacing: 6) {
                PageCell(page: chapter.pages[idx], width: 110,
                         ratio: ratio(chapter.pages[idx]), viewport: nil)
                    .frame(width: 110, height: 156)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.45), radius: 8)
                Text("第 \(idx + 1) 页")
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(.bottom, 62)
        }
    }

    // MARK: - 滑条编辑状态机（预览显隐 + 看门狗兜底）

    private func beginSliderEditing(count: Int) {
        sliderEditing = true
        chromeVisible = true
        sliderPreviewIndex = min(max(Int(sliderPage) - 1, 0), count - 1)
        startSliderWatchdog()
    }

    private func endSliderEditing(jump: Bool, count: Int?) {
        sliderWatchdog?.cancel()
        sliderWatchdog = nil
        let wasEditing = sliderEditing
        sliderEditing = false
        // 只有确实处于拖动态才跳页：防止松手回调迟到/重复触发造成误跳
        if jump, wasEditing, let count = count ?? chapter?.pages.count {
            jumpTarget = min(max(Int(sliderPage) - 1, 0), count - 1)
        }
    }

    private func startSliderWatchdog() {
        sliderWatchdog?.cancel()
        sliderWatchdog = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, sliderEditing else { return }
            endSliderEditing(jump: false, count: nil)
        }
    }

    private func petSliderWatchdog() {
        guard sliderEditing else { return }
        startSliderWatchdog()
    }

    private func forceEndSliderEditing() {
        guard sliderEditing else { return }
        endSliderEditing(jump: false, count: nil)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if loading {
            centered { ProgressView("加载章节…") }
        } else if let error {
            centered {
                VStack(spacing: 10) {
                    Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                    Text(error).foregroundStyle(.secondary)
                    Button("重试") { Task { await loadChapter() } }
                }
            }
        } else if let chapter, !chapter.pages.isEmpty {
            pageList(chapter)
        } else {
            centered { Text("这一话没有图片").foregroundStyle(.secondary) }
        }
    }

    private func pageList(_ chapter: Chapter) -> some View {
        GeometryReader { geo in
            let pageWidth = singlePage
                ? geo.size.width
                : JMLayout.readerContinuousWidth(for: geo.size)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        GeometryReader { g in
                            Color.clear.preference(
                                key: ScrollOffsetKey.self,
                                value: g.frame(in: .named("jmscroll")).minY)
                        }
                        .frame(height: 0)

                        ForEach(Array(chapter.pages.enumerated()), id: \.element.id) { index, page in
                            PageCell(page: page,
                                     width: pageWidth,
                                     ratio: ratio(page),
                                     viewport: singlePage ? geo.size : nil)
                                .id(index)
                                .onAppear {
                                    visiblePage = index
                                    sliderPage = Double(index + 1)
                                    prefetch(around: index, in: chapter)
                                    if allowRecord { save(page: index) }
                                    // 停在本话最后一页 → 按设置决定是否自动接下一话；
                                    // 离开最后一页 → 取消等待
                                    if index >= chapter.pages.count - 1 {
                                        scheduleAutoNextIfEnabled(chapter)
                                    } else {
                                        cancelAutoNext()
                                    }
                                }
                        }
                        nextChapterFooter
                    }
                    .frame(width: pageWidth)
                    .frame(maxWidth: .infinity)
                    .scrollPosition(id: $scrollTarget)
                }
                .coordinateSpace(name: "jmscroll")
                .scrollIndicators(singlePage ? .hidden : .never)
                .onPreferenceChange(ScrollOffsetKey.self) { minY in
                    // 滚动中收起控制栏（顶到最上时不动，避免首屏闪烁）
                    guard minY < 0 else { return }
                    if chromeVisible {
                        withAnimation(.easeOut(duration: 0.18)) { chromeVisible = false }
                    }
                }
                .onChange(of: jumpTarget) { _, t in
                    guard let t else { return }
                    proxy.scrollTo(t, anchor: .top)
                    jumpTarget = nil
                }
            }
        }
    }

    @ViewBuilder
    private var nextChapterFooter: some View {
        if chapterIndex + 1 < album.chapters.count {
            Button {
                chapterIndex += 1
                chromeVisible = true
            } label: {
                Label("下一话：\(album.chapters[chapterIndex + 1].displayTitle)",
                      systemImage: "arrow.down.circle")
                    .padding(.vertical, 22)
            }
        } else {
            Text("已是最后一话")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 24)
        }
    }

    private func centered<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack { Spacer(); c(); Spacer() }.frame(maxWidth: .infinity)
    }

    // MARK: - 逻辑

    private func ratio(_ page: ComicPage) -> CGFloat {
        knownRatios[page.id] ?? (1807.0 / 1280.0)
    }

    @State private var knownRatios: [String: CGFloat] = [:]

    private func loadChapter() async {
        // 换章：清掉上一话遗留的自动切章等待与提示
        cancelAutoNext()
        loading = true
        error = nil
        let meta = chapterMeta
        do {
            let c = try await JmClient.shared.chapter(id: meta.id, sort: meta.sort,
                                                     title: meta.displayTitle)
            // 恢复位置只在打开的第一话生效（「断点续读」开关关闭则不恢复）
            if AppPrefs.resumeReadingEnabled,
               let saved = library.position(for: album.id),
               saved.chapterId == meta.id {
                restoreTo = saved.pageIndex
                visiblePage = saved.pageIndex
                // 等布局完成后再设锚点，确保 LazyVStack 已渲染目标行
                DispatchQueue.main.async {
                    scrollTarget = saved.pageIndex
                }
                allowRecord = false
                // 锚点失效的兜底：多次重试 scrollTo（本地阅读器同款策略）
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if restoreTo != nil { proxyJump(to: saved.pageIndex); allowRecordReset() }
                }
            } else {
                // 无进度：清掉上个章节残留的锚点，从第一页开始
                scrollTarget = nil
                allowRecord = true
            }
            var ratios: [String: CGFloat] = [:]
            for p in c.pages {
                ratios[p.id] = await ImageStore.shared.aspectRatio(for: p)
            }
            knownRatios = ratios
            chapter = c
            loading = false
            await ImageStore.shared.prefetch(Array(c.pages.prefix(4)))
        } catch {
            self.error = error.localizedDescription
            loading = false
        }
    }

    /// scrollTo 兜底需要拿到当前视图里的 ScrollViewReader，这里借助 jumpTarget 通道复用
    private func proxyJump(to target: Int) {
        jumpTarget = target
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            jumpTarget = nil
            restoreTo = nil
        }
    }

    private func allowRecordReset() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            allowRecord = true
        }
    }

    private func prefetch(around index: Int, in chapter: Chapter) {
        let upper = min(index + 5, chapter.pages.count)
        guard index + 1 < upper else { return }
        let slice = Array(chapter.pages[(index + 1)..<upper])
        Task { await ImageStore.shared.prefetch(slice) }
    }

    private func save(page: Int) {
        library.record(album: album, chapter: chapterMeta, page: page)
    }

    // MARK: - 自动接下一话

    /// 滚到/停在本话最后一页时，1.2 秒内没有回滚就自动进入下一话（设置可关）。
    /// 停留窗口的目的是避免快速翻到底时误触：期间往回滚就自动取消。
    private func scheduleAutoNextIfEnabled(_ chapter: Chapter) {
        guard AppPrefs.autoNextChapterEnabled,
              chapterIndex + 1 < album.chapters.count,
              autoNextTask == nil else { return }
        autoNextHint = true
        autoNextTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            // 等待期间用户已往回滚（visiblePage 变小）→ 放弃本次切换
            guard visiblePage >= chapter.pages.count - 1 else {
                cancelAutoNext()
                return
            }
            autoNextTask = nil
            autoNextHint = false
            chapterIndex += 1
            chromeVisible = true
        }
    }

    private func cancelAutoNext() {
        autoNextTask?.cancel()
        autoNextTask = nil
        if autoNextHint { autoNextHint = false }
    }
}

/// 状态栏隐藏兜底（在线/本地阅读器共用）。
///
/// SwiftUI 的 `.statusBarHidden` 在 NavigationStack/fullScreenCover 等容器组合下存在不生效的
/// 已知问题：这里嵌入一个真正的 UIViewController，让 UIKit 的状态栏决策链直接拿到
/// `prefersStatusBarHidden`，无论 SwiftUI 偏好如何传播都能生效。
struct StatusBarHider: UIViewControllerRepresentable {
    let hidden: Bool

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = HiderVC()
        // 关键：这层是纯透明工具层，绝不能参与命中测试，
        // 否则会挡住整个阅读器的触摸（上一版「打开就卡死」的根因）
        vc.view.isUserInteractionEnabled = false
        return vc
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {
        (vc as? HiderVC)?.setHidden(hidden)
    }

    final class HiderVC: UIViewController {
        private var hidden = false

        override var prefersStatusBarHidden: Bool { hidden }
        override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .slide }

        func setHidden(_ h: Bool) {
            guard h != hidden else { return }
            hidden = h
            setNeedsStatusBarAppearanceUpdate()
        }
    }
}
