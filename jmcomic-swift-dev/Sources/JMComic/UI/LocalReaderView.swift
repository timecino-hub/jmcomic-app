import SwiftUI
import CoreGraphics
import ImageIO

/// 本地章节阅读器（CBZ / 散图文件夹）。
///
/// 不走网络：图片直接由 ImageIO 从本地文件解码。
/// CBZ 先用系统 ditto 解压到缓存目录（Application Support/JMComic/LocalCache），
/// 解压一次后直接读缓存，不重复解压。
///
/// 与在线阅读器相同的五项体验：沉浸顶栏 / 键盘翻页 / 跳页条 / 双击放大 / 单页模式。
struct LocalReaderView: View {

    let chapter: DownloadedChapter
    /// 所属本子（本地阅读进度与在线阅读共用同一份历史）
    let meta: AlbumMeta

    @Environment(\.dismiss) private var dismiss
    @StateObject private var library = LibraryStore.shared
    @State private var pages: [URL] = []
    @State private var failed: String?
    @State private var visiblePage = 0
    /// 恢复进度：双保险（scrollPosition 初始锚点 + scrollTo 重试兜底），
    /// 定位完成后才开始记录翻页，避免覆盖旧进度
    @State private var scrollTarget: Int?
    @State private var restoredPage: Int?
    @State private var allowRecord = false

    // 沉浸顶栏：隐藏后保持隐藏，动鼠标/单击才唤出（不自动弹）
    @State private var chromeVisible = true
    @State private var lastScrollTime = Date.distantPast
    // 键盘监听（含鼠标移动，用于唤出控制栏）
    @State private var keyboardMonitor: Any?
    // 跳页
    @State private var jumpTarget: Int?
    @State private var sliderPage = 1.0
    // 单页模式（偏好持久化：设置页可永久设置默认）
    @State private var singlePage = UserDefaults.standard.bool(forKey: "readerSinglePage") {
        didSet { UserDefaults.standard.set(singlePage, forKey: "readerSinglePage") }
    }

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
        .task { await prepare() }
        .onAppear { installKeyboard() }
        .onDisappear {
            if let m = keyboardMonitor { NSEvent.removeMonitor(m); keyboardMonitor = nil }
        }
    }

    // MARK: - 顶栏

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: { Label("关闭", systemImage: "chevron.left") }
                .buttonStyle(.borderless)
                .keyboardShortcut(.escape, modifiers: [])
            Text(chapter.chapterTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !pages.isEmpty {
                Text("\(min(visiblePage + 1, pages.count)) / \(pages.count)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button(singlePage ? "连续" : "单页") {
                singlePage.toggle()
                chromeVisible = true
            }
            .buttonStyle(.bordered)
            .font(.caption)
            .help("偏好会记住，也可在设置页设置默认")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
    }

    // MARK: - 底部跳页条

    private var jumpBar: some View {
        // Slider 的 range 不能是 1...1（Normalizing 断言会崩），只有一页时不渲染
        Group {
            if pages.count > 1 {
                HStack(spacing: 10) {
                    Image(systemName: "book").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $sliderPage, in: 1...Double(pages.count), step: 1) { editing in
                        if !editing {
                            jumpTarget = min(max(Int(sliderPage) - 1, 0), pages.count - 1)
                        } else if editing {
                            chromeVisible = true
                        }
                    }
                    .frame(maxWidth: 300)
                    Text("\(Int(sliderPage)) / \(pages.count)")
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
        if let failed {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text(failed).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if pages.isEmpty {
            ProgressView("读取本地章节…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            pageList
        }
    }

    // MARK: - 图片列表准备

    private func prepare() async {
        let urls: [URL]?
        if chapter.format == .cbz {
            urls = await extractCBZ()
        } else {
            urls = Self.folderPages(URL(fileURLWithPath: chapter.path))
        }
        await MainActor.run {
            guard let urls, !urls.isEmpty else {
                failed = "本地文件读取失败（可能已被移动或删除）"
                return
            }
            pages = urls
            // 与在线阅读共用进度：同一话则从上次页码继续
            if let saved = library.position(for: meta.id),
               saved.chapterId == chapter.chapterId {
                let target = min(saved.pageIndex, max(0, urls.count - 1))
                restoredPage = target
                visiblePage = target
                // 布局完成后再设锚点，确保 LazyVStack 已渲染目标行
                DispatchQueue.main.async {
                    scrollTarget = target
                }
                allowRecord = false   // 定位完成前不记录，防止覆盖旧进度
            } else {
                allowRecord = true
            }
        }
    }

    /// CBZ：解压到缓存目录（已解压则直接复用）
    private func extractCBZ() async -> [URL]? {
        let src = URL(fileURLWithPath: chapter.path)
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let cache = base.appendingPathComponent("JMComic/LocalCache",
                                                isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let name = DownloadStore.sanitize(src.deletingPathExtension().lastPathComponent)
        let dest = cache.appendingPathComponent(name, isDirectory: true)

        let existing = Self.folderPages(dest)
        if existing == nil || existing!.isEmpty {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-xk", src.path, dest.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
                p.waitUntilExit()
            } catch { return nil }
            guard p.terminationStatus == 0 else { return nil }
        }
        return Self.folderPages(dest)
    }

    /// 目录里的图片按文件名排序（下载时就是 0001.jpg 这样命名）
    private static func folderPages(_ dir: URL) -> [URL]? {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return nil }
        let exts = ["jpg", "jpeg", "png", "webp", "gif"]
        return items
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - 阅读

    private var pageList: some View {
        GeometryReader { geo in
            let width = min(geo.size.width, 1000)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        GeometryReader { g in
                            Color.clear.preference(
                                key: ScrollOffsetKey.self,
                                value: g.frame(in: .named("jmscroll")).minY)
                        }
                        .frame(height: 0)

                        ForEach(Array(pages.enumerated()), id: \.element) { index, url in
                            LocalPageCell(url: url, width: width,
                                          viewport: singlePage ? geo.size : nil)
                                .id(index)
                                .onAppear {
                                    visiblePage = index
                                    sliderPage = Double(index + 1)
                                    if allowRecord {
                                        library.recordLocal(meta: meta, chapter: chapter, page: index)
                                    }
                                }
                        }
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
                    if let target = restoredPage, target > 0 {
                        // scrollPosition 未生效时的兜底：多次重试 scrollTo
                        for d in [0.05, 0.2, 0.5] {
                            DispatchQueue.main.asyncAfter(deadline: .now() + d) {
                                proxy.scrollTo(target, anchor: .top)
                            }
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
        let total = max(pages.count, 1)
        let target = max(0, min(visiblePage + delta, total - 1))
        guard target != visiblePage else { return }
        jumpTarget = target
        withAnimation(.easeOut(duration: 0.18)) { chromeVisible = false }
        lastScrollTime = Date()
    }
}

/// 一页：本地文件解码。连续模式宽度撑满高度自适应；单页模式整页 fit 视口。
/// 支持双击局部放大。
private struct LocalPageCell: View {
    let url: URL
    let width: CGFloat
    let viewport: CGSize?

    @State private var image: CGImage?
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
                        let h = max(viewport?.height ?? width * (1807.0 / 1280.0), 1)
                        zoomAnchor = UnitPoint(x: loc.x / max(width, 1), y: loc.y / h)
                        zoomed.toggle()
                    }
            } else {
                Rectangle()
                    .fill(Color(white: 0.13))
                    .frame(width: viewport?.width ?? width,
                          height: viewport?.height ?? (width * (1807.0 / 1280.0)).rounded())
                    .overlay { ProgressView().controlSize(.small) }
            }
        }
        .clipped()
        .task(id: url) { load() }
    }

    private func load() {
        Task {
            let img = await Self.decode(url)
            await MainActor.run { self.image = img }
        }
    }

    private static func decode(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

/// 滚动偏移追踪（沉浸式顶栏用）
private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
