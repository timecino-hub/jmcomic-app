import SwiftUI
import CoreGraphics
import ImageIO

/// 本地章节阅读器（iOS 版，CBZ / 散图文件夹）。
///
/// 不走网络：图片直接由 ImageIO 从本地文件解码。
/// 与 Mac 版的唯一结构性差异：CBZ 解压不用 /usr/bin/ditto（iOS 没有该可执行文件），
/// 改用 Core 的 ZipReader 手写解包，缓存目录同为 Application Support/JMComic/LocalCache，
/// 解压一次后直接读缓存。
///
/// 与在线阅读器相同的触屏体验：单击显隐控制栏 / 双击放大 / 跳页条 / 单页模式 /
/// 断点续读（进度与在线阅读共用同一份历史）。
struct LocalReaderView: View {

    let chapter: DownloadedChapter
    /// 所属本子（本地阅读进度与在线阅读共用同一份历史）
    let meta: AlbumMeta

    @Environment(\.dismiss) private var dismiss
    @StateObject private var library = LibraryStore.shared
    @State private var pages: [URL] = []
    @State private var failed: String?
    @State private var visiblePage = 0
    /// scrollPosition 锚点（定位完成后才开始记录翻页，避免覆盖旧进度）
    @State private var scrollTarget: Int?
    @State private var restoredPage: Int?
    @State private var allowRecord = false

    // 沉浸控制栏：隐藏后保持隐藏，单击才唤出
    @State private var chromeVisible = true
    // 跳页
    @State private var jumpTarget: Int?
    @State private var sliderPage = 1.0
    // 滑条拖动中的页面预览
    @State private var sliderEditing = false
    @State private var sliderPreviewIndex: Int?
    // 滑条看门狗（与在线阅读器一致）：松手回调丢失时强制收起预览
    @State private var sliderWatchdog: Task<Void, Never>?
    // 单页模式（偏好持久化：设置页可永久设置默认）
    @State private var singlePage = UserDefaults.standard.bool(forKey: "readerSinglePage") {
        didSet { UserDefaults.standard.set(singlePage, forKey: "readerSinglePage") }
    }

    var body: some View {
        ZStack {
            content
                .background(Color(intensity: 0.11))
        }
        // 沉浸模式：内容真正铺满全屏（与在线阅读器一致）
        .ignoresSafeArea(.all, edges: chromeVisible ? [] : .all)
        .contentShape(Rectangle())
        // 单击任意处：切换控制栏显隐（双击放大优先识别）
        .onTapGesture(count: 1) {
            withAnimation(.easeInOut(duration: 0.18)) { chromeVisible.toggle() }
        }
        // 控制栏「真移除」：隐藏时彻底不在视图层级（与在线阅读器一致）
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
        // 滑条预览：常驻挂载 + opacity 显隐（不依赖条件卸载，杜绝残留）
        .overlay(alignment: .bottom) {
            sliderPreview
                .opacity(sliderEditing ? 1 : 0)
                .animation(.easeInOut(duration: 0.12), value: sliderEditing)
                .allowsHitTesting(false)
        }
        // 控制栏一隐藏就强制收起滑条预览
        .onChange(of: chromeVisible) { _, visible in
            if !visible { forceEndSliderEditing() }
        }
        // SwiftUI 的 .statusBarHidden 在部分容器组合下不生效，嵌入 VC 兜底（见 ReaderView）
        .statusBarHidden(!chromeVisible)
        .overlay { StatusBarHider(hidden: !chromeVisible) }
        .persistentSystemOverlays(chromeVisible ? .visible : .hidden)
        .task { await prepare() }
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

            Text(chapter.chapterTitle)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            if !pages.isEmpty {
                Text("\(min(visiblePage + 1, pages.count)) / \(pages.count)")
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
        // Slider 的 range 不能是 1...1（Normalizing 断言会崩），只有一页时不渲染
        Group {
            if pages.count > 1 {
                HStack(spacing: 10) {
                    Image(systemName: "book")
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value: $sliderPage, in: 1...Double(pages.count), step: 1) { editing in
                        if editing {
                            beginSliderEditing()
                        } else {
                            endSliderEditing(jump: true)
                        }
                    }
                    Text("\(Int(sliderPage)) / \(pages.count)")
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
                    guard sliderEditing, !pages.isEmpty else { return }
                    sliderPreviewIndex = min(max(Int(v) - 1, 0), pages.count - 1)
                    petSliderWatchdog()
                }
            }
        }
    }

    /// 拖动滑条时显示的目标页小预览（常驻挂载，显隐由外层 opacity 控制）
    @ViewBuilder
    private var sliderPreview: some View {
        if let idx = sliderPreviewIndex, pages.indices.contains(idx) {
            VStack(spacing: 6) {
                LocalPageCell(url: pages[idx], width: 110, viewport: nil)
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

    // MARK: - 滑条编辑状态机（与在线阅读器一致）

    private func beginSliderEditing() {
        sliderEditing = true
        chromeVisible = true
        sliderPreviewIndex = min(max(Int(sliderPage) - 1, 0), pages.count - 1)
        startSliderWatchdog()
    }

    private func endSliderEditing(jump: Bool) {
        sliderWatchdog?.cancel()
        sliderWatchdog = nil
        let wasEditing = sliderEditing
        sliderEditing = false
        if jump, wasEditing, !pages.isEmpty {
            jumpTarget = min(max(Int(sliderPage) - 1, 0), pages.count - 1)
        }
    }

    private func startSliderWatchdog() {
        sliderWatchdog?.cancel()
        sliderWatchdog = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, sliderEditing else { return }
            endSliderEditing(jump: false)
        }
    }

    private func petSliderWatchdog() {
        guard sliderEditing else { return }
        startSliderWatchdog()
    }

    private func forceEndSliderEditing() {
        guard sliderEditing else { return }
        endSliderEditing(jump: false)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if let failed {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text(failed).font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(30)
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
        guard let urls, !urls.isEmpty else {
            failed = "本地文件读取失败（可能已被移动或删除）"
            return
        }
        pages = urls
        // 与在线阅读共用进度：同一话则从上次页码继续（「断点续读」开关关闭则不恢复）
        if AppPrefs.resumeReadingEnabled,
           let saved = library.position(for: meta.id),
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

    /// CBZ：解压到缓存目录（已解压则直接复用）。解压走 ZipReader（后台线程）。
    private func extractCBZ() async -> [URL]? {
        let src = URL(fileURLWithPath: chapter.path)
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let cacheDir = base.appendingPathComponent("JMComic/LocalCache", isDirectory: true)
        // 名字在主线程算好（sanitize 是 @MainActor 类的静态函数）
        let name = DownloadStore.sanitize(src.deletingPathExtension().lastPathComponent)
        let dest = cacheDir.appendingPathComponent(name, isDirectory: true)

        if let existing = Self.folderPages(dest), !existing.isEmpty {
            return existing
        }
        // iOS 没有 ditto/unzip：用 Core 的 ZipReader 手写解包，避免阻塞主线程
        return await Task.detached(priority: .utility) { () -> [URL]? in
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            do {
                _ = try ZipReader.extract(archiveAt: src, into: dest)
            } catch {
                return nil
            }
            return Self.folderPages(dest)
        }.value
    }

    /// 目标目录里的图片按文件名排序（下载时就是 0001.jpg 这样命名）
    /// nonisolated：纯文件 IO，detached 后台任务里也要能直接调，不占主线程
    private nonisolated static func folderPages(_ dir: URL) -> [URL]? {
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
            let pageWidth = singlePage
                ? geo.size.width
                : JMLayout.readerContinuousWidth(for: geo.size)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(pages.enumerated()), id: \.element) { index, url in
                            LocalPageCell(url: url, width: pageWidth,
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
                    .frame(width: pageWidth)
                    .frame(maxWidth: .infinity)
                    .scrollPosition(id: $scrollTarget)
                }
                .coordinateSpace(name: "jmscroll")
                .scrollIndicators(singlePage ? .hidden : .never)
                .onChange(of: jumpTarget) { _, t in
                    guard let t else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
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
}

/// 一页：本地文件解码。连续模式宽度撑满高度自适应；单页模式整页 fit 视口。
/// 支持双击局部放大。
private struct LocalPageCell: View {
    let url: URL
    let width: CGFloat
    let viewport: CGSize?

    @State private var image: CGImage?

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
                    .fill(Color(intensity: 0.13))
                    .frame(width: viewport?.width ?? width,
                          height: viewport?.height ?? (width * (1807.0 / 1280.0)).rounded())
                    .overlay { ProgressView().controlSize(.small) }
            }
        }
        .clipped()
        .task(id: url) { load() }
    }

    @State private var zoomed = false
    @State private var zoomAnchor = UnitPoint(x: 0.5, y: 0.5)

    private func load() {
        Task.detached(priority: .userInitiated) {
            let img = Self.decode(url)
            await MainActor.run { self.image = img }
        }
    }

    private nonisolated static func decode(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
