import SwiftUI
import CoreGraphics

/// 一页的显示单元。
///
/// 两种布局：
/// - 连续模式（viewport == nil）：宽度撑满、高度自适应真实比例——
///   细长页完整展开，不会被压缩成小尺子
/// - 单页模式（viewport 非 nil）：整页 fit 进视口——一屏一页、上下完整
///
/// 支持双击局部放大（×2，以点击位置为中心，再双击还原）。
private struct PageCell: View {
    let page: ComicPage
    let width: CGFloat
    let ratio: CGFloat
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
                    .fill(Color(white: 0.13))
                    .frame(width: viewport?.width ?? width,
                          height: viewport?.height ?? (width * ratio).rounded())
                    .overlay {
                        if failed {
                            VStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle")
                                Text("加载失败").font(.caption)
                                Button("重试") { failed = false; load() }
                                    .buttonStyle(.link)
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

/// 滚动偏移追踪（沉浸式顶栏用）
private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 连续滚动 / 单页翻页 阅读器。
///
/// 五个桌面阅读改进：
/// 1. 沉浸式顶栏：滚动时隐藏，停止滚动后出现
/// 2. 键盘：←/→ 翻页，空格下翻
/// 3. 底部跳页条：拖拽跳任意页
/// 4. 双击局部放大
/// 5. 连续滚动 / 单页翻页模式切换
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

    // 沉浸顶栏：隐藏后保持隐藏，动鼠标/单击才唤出（不自动弹）
    @State private var chromeVisible = true
    @State private var lastScrollTime = Date.distantPast
    // 键盘监听（含鼠标移动，用于唤出控制栏）
    @State private var keyboardMonitor: Any?
    // 跳页：统一入口（键盘/跳页条/翻页都写这里，pageList 里消费 scrollTo）
    @State private var jumpTarget: Int?
    @State private var sliderPage = 1.0
    /// 恢复锚点（scrollPosition 双保险定位，与本地阅读器一致）
    @State private var scrollTarget: Int?
    // 单页模式（偏好持久化：设置页可永久设置默认）
    @State private var singlePage = UserDefaults.standard.bool(forKey: "readerSinglePage") {
        didSet { UserDefaults.standard.set(singlePage, forKey: "readerSinglePage") }
    }

    private var chapterMeta: ChapterMeta { album.chapters[chapterIndex] }

    var body: some View {
        ZStack {
            content
                .background(Color(white: 0.11))
        }
        .contentShape(Rectangle())
        // 单击任意处：唤出控制栏（双击放大不受影响）
        .onTapGesture(count: 1) {
            withAnimation(.easeInOut(duration: 0.18)) { chromeVisible = true }
        }
        .overlay(alignment: .top) {
            toolbar
                .offset(y: chromeVisible ? 0 : -70)
                .animation(.easeOut(duration: 0.22), value: chromeVisible)
        }
        .overlay(alignment: .bottom) {
            jumpBar
                .offset(y: chromeVisible ? 0 : 90)
                .animation(.easeOut(duration: 0.22), value: chromeVisible)
        }
        .task(id: chapterIndex) { await loadChapter() }
        .onAppear { installKeyboard() }
        .onDisappear {
            if let m = keyboardMonitor { NSEvent.removeMonitor(m); keyboardMonitor = nil }
        }
    }

    // MARK: - 顶栏

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Label("关闭", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.escape, modifiers: [])

            Text(album.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(album.title)

            if album.chapters.count > 1 {
                Picker("", selection: $chapterIndex) {
                    ForEach(Array(album.chapters.enumerated()), id: \.offset) { i, c in
                        Text(c.displayTitle).tag(i)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }

            if let chapter {
                Text("\(min(visiblePage + 1, chapter.pages.count)) / \(chapter.pages.count)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            Button(singlePage ? "连续" : "单页") {
                singlePage.toggle()
                chromeVisible = true
            }
            .buttonStyle(.bordered)
            .font(.caption)
            .help(singlePage ? "切回连续滚动" : "切换为单页翻页模式（偏好会记住）")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
    }

    // MARK: - 底部跳页条

    private var jumpBar: some View {
        // Slider 的 range 不能是 1...1（Normalizing 断言会崩），章节没加载或只有一页时不渲染
        Group {
            if let count = chapter?.pages.count, count > 1 {
                HStack(spacing: 10) {
                    Image(systemName: "book")
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value: $sliderPage, in: 1...Double(count), step: 1) { editing in
                        if !editing {
                            jumpTarget = min(max(Int(sliderPage) - 1, 0), count - 1)
                        } else if editing {
                            chromeVisible = true
                        }
                    }
                    .frame(maxWidth: 300)
                    Text("\(Int(sliderPage)) / \(count)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 70, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
            }
        }
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
            // 单页最大宽度 1000，窗口更窄时按窗口走
            let width = min(geo.size.width, 1000)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        // 滚动偏移追踪：用于沉浸式顶栏（滚动隐藏，停止显示）
                        GeometryReader { g in
                            Color.clear.preference(
                                key: ScrollOffsetKey.self,
                                value: g.frame(in: .named("jmscroll")).minY)
                        }
                        .frame(height: 0)

                        ForEach(Array(chapter.pages.enumerated()), id: \.element.id) { index, page in
                            PageCell(page: page, width: width, ratio: ratio(page),
                                     viewport: singlePage ? geo.size : nil)
                                .id(index)
                                .onAppear {
                                    visiblePage = index
                                    sliderPage = Double(index + 1)
                                    prefetch(around: index, in: chapter)
                                    if allowRecord { save(page: index) }
                                }
                        }
                        nextChapterFooter
                    }
                    .frame(maxWidth: .infinity)
                    .scrollPosition(id: $scrollTarget)
                }
                .coordinateSpace(name: "jmscroll")
                .scrollIndicators(singlePage ? .hidden : .automatic)
                .onPreferenceChange(ScrollOffsetKey.self) { _ in
                    // 滚动中隐藏控制栏，记下时间（滚动停止后 0.5s 内不响应鼠标唤出）
                    withAnimation(.easeOut(duration: 0.18)) { chromeVisible = false }
                    lastScrollTime = Date()
                }
                .onChange(of: jumpTarget) { _, t in
                    guard let t else { return }
                    if singlePage {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(t, anchor: .top)
                        }
                    } else {
                        proxy.scrollTo(t, anchor: .top)
                    }
                    jumpTarget = nil
                }
                .onAppear {
                    if let target = restoreTo, target > 0 {
                        // 等首屏建好再跳，否则 LazyVStack 还没有那一行
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            proxy.scrollTo(target, anchor: .top)
                            restoreTo = nil
                        }
                        // 定位完成后才允许记录翻页进度
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            allowRecord = true
                        }
                    }
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
                    .padding(.vertical, 18)
            }
            .buttonStyle(.borderless)
            .onAppear {
                // 连续模式：滚到底（footer 露出）自动切下一话；
                // 切章后新话第一页 onAppear 会记录进度，历史自动同步
                guard !singlePage else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if chapterIndex + 1 < album.chapters.count {
                        chapterIndex += 1
                        chromeVisible = true
                    }
                }
            }
        } else {
            Text("已是最后一话")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 22)
        }
    }

    private func centered<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack { Spacer(); c(); Spacer() }.frame(maxWidth: .infinity)
    }

    // MARK: - 键盘

    private func installKeyboard() {
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .mouseMoved]) { ev in
            if ev.type == .mouseMoved {
                // 滚动刚停止时鼠标可能还在动，0.5s 内不响应，避免滚动中闪烁唤出
                if Date().timeIntervalSince(lastScrollTime) > 0.5 {
                    withAnimation(.easeIn(duration: 0.18)) { chromeVisible = true }
                }
                return ev
            }
            switch ev.keyCode {
            case 123:            // ← 上一页
                self.pageStep(-1)
                return nil
            case 124, 49:        // → / 空格 下一页
                self.pageStep(1)
                return nil
            default:
                return ev
            }
        }
    }

    private func pageStep(_ delta: Int) {
        let total = chapter?.pages.count ?? 1
        let target = max(0, min(visiblePage + delta, total - 1))
        guard target != visiblePage else { return }
        jumpTarget = target
        withAnimation(.easeOut(duration: 0.18)) { chromeVisible = false }
        lastScrollTime = Date()
    }

    // MARK: - 逻辑

    private func ratio(_ page: ComicPage) -> CGFloat {
        knownRatios[page.id] ?? (1807.0 / 1280.0)
    }

    @State private var knownRatios: [String: CGFloat] = [:]

    private func loadChapter() async {
        loading = true
        error = nil
        let meta = chapterMeta
        do {
            let c = try await JmClient.shared.chapter(id: meta.id, sort: meta.sort,
                                                     title: meta.displayTitle)
            // 恢复位置只在打开的第一话生效
            if let saved = library.position(for: album.id), saved.chapterId == meta.id {
                restoreTo = saved.pageIndex
                visiblePage = saved.pageIndex
                // scrollPosition 初始锚点（等布局后生效）
                DispatchQueue.main.async {
                    scrollTarget = saved.pageIndex
                }
                allowRecord = false
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

    private func prefetch(around index: Int, in chapter: Chapter) {
        let upper = min(index + 5, chapter.pages.count)
        guard index + 1 < upper else { return }
        let slice = Array(chapter.pages[(index + 1)..<upper])
        Task { await ImageStore.shared.prefetch(slice) }
    }

    private func save(page: Int) {
        library.record(album: album, chapter: chapterMeta, page: page)
    }
}
