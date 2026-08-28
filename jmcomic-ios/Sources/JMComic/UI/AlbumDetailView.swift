import SwiftUI
import UIKit

/// 专辑详情页（iOS 版）。
///
/// Mac 版三栏排版在 iPhone 上放不下：改为纵向堆叠——
/// 封面+信息头部 / 操作区（阅读·下载·收藏）/ 简介 / 标签 / 章节 / 相关作品（续作）/ 预览。
/// 阅读器从 sheet 改为 fullScreenCover（触屏沉浸阅读惯例）；
/// 复制 ID 用 UIPasteboard；下载格式选择改用确认菜单。
struct AlbumDetailView: View {

    let meta: AlbumMeta
    @Binding var path: [Route]

    @StateObject private var library = LibraryStore.shared
    @StateObject private var downloads = DownloadStore.shared
    @StateObject private var favorites = FavoriteStore.shared
    @State private var album: Album?
    @State private var previews: [CGImage] = []
    @State private var loading = true
    @State private var error: String?
    /// 正在阅读的章节上下文（item 驱动 fullScreenCover）
    @State private var reading: Album?
    @State private var readingChapter = 0
    // 下载格式确认菜单
    @State private var showFormatDialog = false
    // 预览查看器
    @State private var showPreviewViewer = false
    @State private var previewIndex = 0
    @State private var previewFailed = false

    init(meta: AlbumMeta, path: Binding<[Route]>) {
        self.meta = meta
        _path = path
    }

    var body: some View {
        ScrollView {
            if let album {
                detail(album)
            } else if loading {
                ProgressView("加载中…").padding(60)
            } else if let error {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text(error).foregroundStyle(.secondary)
                    Button("重试") { Task { await load() } }
                }
                .padding(60)
            }
        }
        .navigationTitle(meta.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        // 预览只读图，不写历史/进度（见 loadPreviews）
        .task(id: album?.id) {
            if let album { await loadPreviews(album) }
        }
        .fullScreenCover(item: $reading) { current in
            ReaderView(album: current, chapterIndex: readingChapter)
                // id 变化强制重建：修「点第 10 话却打开第 1 话」（presentation 相同时复用旧实例）
                .id(readingChapter)
        }
        // 预览查看器：与阅读器完全隔离，只读图，不写历史/进度
        .fullScreenCover(isPresented: $showPreviewViewer) {
            PreviewViewer(images: previews, startIndex: previewIndex)
        }
        .confirmationDialog("选择下载格式",
                            isPresented: $showFormatDialog,
                            titleVisibility: .visible) {
            Button("CBZ 单文件") { startDownload(.cbz) }
            Button("散图文件夹") { startDownload(.folder) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("散图为 PNG 无损，适合二次处理；CBZ 为 JPEG 归档更省空间。")
        }
    }

    private func startDownload(_ format: DownloadFormat) {
        guard let album else { return }
        downloads.format = format
        downloads.start(album: album)
    }

    // MARK: - 版面

    private func detail(_ album: Album) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header(album)

            HStack(spacing: 10) {
                readingButtons(album)
            }

            downloadRow(album)

            if !album.description.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("简介").font(.subheadline.weight(.semibold))
                    Text(album.description)
                        .font(.callout)
                        .lineLimit(8)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if !album.tags.isEmpty {
                FlowTags(tags: album.tags)
            }

            chaptersSection(album)

            relatedSection(album)

            previewSection
        }
        .padding(16)
    }

    private func header(_ album: Album) -> some View {
        HStack(alignment: .top, spacing: 14) {
            CoverImage(albumId: album.id, width: 110)

            VStack(alignment: .leading, spacing: 7) {
                Text(album.title).font(.title3.weight(.semibold)).lineLimit(3)
                Text(album.authorText).font(.footnote).foregroundStyle(.secondary)

                // 专辑 ID：可选中 / 一键复制（方便搜索、分享）
                HStack(spacing: 6) {
                    Text("ID \(album.id)")
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = album.id
                    } label: { Image(systemName: "doc.on.doc").font(.caption) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("复制专辑 ID")
                }

                HStack(spacing: 14) {
                    stat("eye", album.views)
                    stat("hand.thumbsup", album.likes)
                    stat("text.bubble", "\(album.commentCount)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// 收藏/取消收藏（本地分组，见 FavoriteStore）
    private var favoriteButton: some View {
        Button {
            if let album {
                favorites.toggle(album)
            }
        } label: {
            Label(favorites.contains(meta.id) ? "已收藏" : "收藏",
                  systemImage: favorites.contains(meta.id) ? "heart.fill" : "heart")
        }
        .buttonStyle(.bordered)
        .foregroundStyle(favorites.contains(meta.id) ? .pink : .primary)
    }

    @ViewBuilder
    private func readingButtons(_ album: Album) -> some View {
        Button {
            readingChapter = resumeChapterIndex(album)
            reading = album
        } label: {
            Label(resumeLabel(album), systemImage: "book")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)

        favoriteButton

        if library.position(for: album.id) != nil {
            Button("从头开始") {
                readingChapter = 0
                reading = album
            }
            .buttonStyle(.bordered)
        }
    }

    /// 下载三态：未下载 → 下载中（进度+取消）→ 已下载
    @ViewBuilder
    private func downloadRow(_ album: Album) -> some View {
        if let task = downloads.task(for: album.id) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    ProgressView(value: task.progress)
                    Text("\(Int(task.progress * 100))%")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Button("取消") { downloads.cancel(album.id) }
                        .font(.caption)
                }
                Text(task.currentChapter.isEmpty ? "下载中…" : task.currentChapter)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
                if let err = task.error {
                    Text(err).font(.caption2).foregroundStyle(.red)
                }
                if task.failed > 0 {
                    Text("\(task.failed) 页失败").font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else if downloads.isDownloaded(album.id) {
            Label("已下载 · 可在「本地库」离线阅读", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
        } else {
            Button {
                showFormatDialog = true
            } label: {
                Label("下载整本", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func chaptersSection(_ album: Album) -> some View {
        if !album.chapters.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(album.chapters.count > 1 ? "章节 (\(album.chapters.count))" : "章节")
                    .font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                    ForEach(Array(album.chapters.enumerated()), id: \.element.id) { i, c in
                        Button {
                            readingChapter = i
                            reading = album
                        } label: {
                            Text(c.displayTitle)
                                .font(.footnote)
                                .lineLimit(1)
                                .padding(.vertical, 9)
                                .frame(maxWidth: .infinity)
                        }
                        .background(readMark(album, c) ? Color.accentColor.opacity(0.18)
                                                      : Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// 「续作 / 相关作品」——服务端 related_list 直接给，不需要自己算
    @ViewBuilder
    private func relatedSection(_ album: Album) -> some View {
        if !album.related.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("相关作品 / 续作").font(.headline)
                    if album.isSeries {
                        Text("同系列").font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(album.related) { rel in
                            Button {
                                path.append(.album(rel))
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    CoverImage(albumId: rel.id, width: 96)
                                    Text(rel.title).font(.caption2).lineLimit(2)
                                        .frame(width: 96, alignment: .leading)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    /// 预览：从第一章中间区域随机 3 页（避开封面/目录页），只读图不写历史进度
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("预览").font(.headline)
            if previews.isEmpty {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.05))
                    .frame(height: 110)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        if previewFailed {
                            Text("预览不可用").font(.caption).foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(previews.enumerated()), id: \.offset) { i, img in
                            Button {
                                previewIndex = i
                                showPreviewViewer = true
                            } label: {
                                Image(decorative: img, scale: 1.0)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 120, height: 90)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func stat(_ icon: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(value.isEmpty ? "-" : value)
        }
    }

    // MARK: - 逻辑

    private func readMark(_ album: Album, _ c: ChapterMeta) -> Bool {
        library.position(for: album.id)?.chapterId == c.id
    }

    private func resumeChapterIndex(_ album: Album) -> Int {
        guard let saved = library.position(for: album.id),
              let idx = album.chapters.firstIndex(where: { $0.id == saved.chapterId })
        else { return 0 }
        return idx
    }

    private func resumeLabel(_ album: Album) -> String {
        guard let saved = library.position(for: album.id) else { return "开始阅读" }
        return "继续第 \(saved.pageIndex + 1) 页"
    }

    private func load() async {
        // 打开详情即记入「最近浏览」（持久化，进程被杀也不丢）
        library.recordView(meta)
        if let cached = library.album(meta.id) {
            album = cached
            loading = false
        }
        do {
            let fresh = try await JmClient.shared.album(id: meta.id)
            album = fresh
            library.cache(fresh)
            loading = false
        } catch {
            if album == nil {
                self.error = error.localizedDescription
                loading = false
            }
        }
    }

    /// 从第一章中间区域（跳过开头封面/目录）随机 3 页，并发解码；不写历史/进度
    private func loadPreviews(_ album: Album) async {
        guard previews.isEmpty, !previewFailed,
              let ch = album.chapters.first else { return }
        guard let chapter = try? await JmClient.shared.chapter(id: ch.id, sort: ch.sort,
                                                              title: ch.displayTitle)
        else {
            await MainActor.run { previewFailed = true }
            return
        }
        let n = chapter.pages.count
        // 从第 5 页之后随机（开头几页常是封面/目录/广告），避开最后一页
        let lo = min(4, max(0, n - 1))
        let hi = max(lo + 1, n - 1)
        let pool = Array(lo..<hi)
        let chosen = pool.shuffled().prefix(min(3, pool.count)).sorted()
        guard !chosen.isEmpty else { return }
        var imgs: [CGImage?] = Array(repeating: nil, count: chosen.count)
        await withTaskGroup(of: (Int, CGImage?).self) { group in
            for (i, idx) in chosen.enumerated() {
                group.addTask { (i, await ImageStore.shared.page(chapter.pages[idx])) }
            }
            for await (i, img) in group { imgs[i] = img }
        }
        await MainActor.run {
            previews = imgs.compactMap { $0 }
            previewFailed = previews.isEmpty
        }
    }
}

/// 预览查看器：与阅读器完全隔离的看图窗口。
///
/// 只显示已解码的预览图：TabView 分页滑动、双击放大，**不调任何 record**——
/// 不会写历史、不会写进度、不会污染任何阅读状态。
private struct PreviewViewer: View {
    let images: [CGImage]
    @State var startIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var zoomed = false

    init(images: [CGImage], startIndex: Int) {
        self.images = images
        _index = State(initialValue: min(max(startIndex, 0), max(images.count - 1, 0)))
        _startIndex = State(initialValue: startIndex)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if !images.isEmpty {
                TabView(selection: $index) {
                    ForEach(Array(images.enumerated()), id: \.offset) { i, img in
                        Image(decorative: img, scale: 1.0)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .scaleEffect(zoomed && i == index ? 2 : 1)
                            .onTapGesture(count: 2) { zoomed.toggle() }
                            .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
                .onChange(of: index) { _, _ in zoomed = false }
            }

            // 顶部信息条：计数 + 关闭
            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .padding(9)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                    Text("预览 \(index + 1) / \(max(images.count, 1))")
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
            }
        }
    }
}
