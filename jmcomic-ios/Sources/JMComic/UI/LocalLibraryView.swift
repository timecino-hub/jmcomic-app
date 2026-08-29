import SwiftUI
import UniformTypeIdentifiers

/// 本地漫画库（iOS 版）。
///
/// 与 Mac 版差异：
/// - 「扫描导入」（NSOpenPanel 选目录）改为 `.fileImporter` 从「文件」App 选择 zip/CBZ 导入，
///   iOS 沙盒不能随便扫任意目录；解析/入库语义复用 DownloadStore 的记录结构。
/// - 「在 Finder 中显示」没有对应能力，去掉；删除走长按菜单 + 确认。
/// 阅读进度与在线阅读共用同一份历史（LibraryStore）。
struct LocalLibraryView: View {

    @Environment(\.jmAlbumGridColumnCount) private var albumGridColumnCount

    @ObservedObject private var downloads = DownloadStore.shared
    @State private var path: [DownloadedAlbum] = []
    @State private var showImporter = false
    @State private var importNotice: String?
    /// 待确认删除的本子
    @State private var pendingDelete: DownloadedAlbum?
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if downloads.library.isEmpty {
                empty
            } else {
                grid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("本地漫画")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showImporter = true
                } label: {
                    Label("导入", systemImage: "square.and.arrow.down")
                }
                .accessibilityLabel("导入 zip 或 CBZ")
            }
        }
        .navigationDestination(for: DownloadedAlbum.self) { album in
            LocalAlbumDetailView(album: album)
        }
        // Files 文件导入器：只允许 zip 类（.cbz 归档也归入 zip 一致性）
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.zip],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task {
                    importNotice = await downloads.importZIPFile(url)
                }
            }
        }
        .confirmationDialog("删除这本漫画？",
                            isPresented: $confirmDelete,
                            titleVisibility: .visible,
                            presenting: pendingDelete) { album in
            Button("删除（连文件）", role: .destructive) {
                downloads.delete(album.meta.id, removeFiles: true)
            }
        } message: { album in
            Text("将移除「\(album.meta.title)」的索引与磁盘文件，不可恢复。")
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.circle").font(.largeTitle).foregroundStyle(.secondary)
            Text("还没有下载。在本子详情页点「下载整本」，或右上角「导入」从文件 App 选择 zip/CBZ。")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let importNotice {
                Text(importNotice).font(.caption).foregroundStyle(.green)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        ScrollView {
            // 注意：用显式命名绑定，避免 if let 简写把 importNotice 遮蔽成局部常量而无法在 .task 里清空
            if let notice = importNotice {
                Text(notice).font(.caption).foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 8)
                    .task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        importNotice = nil
                    }
            }
            LazyVGrid(columns: JMLayout.albumGridColumns(count: albumGridColumnCount), spacing: 18) {
                ForEach(downloads.library) { album in
                    NavigationLink(value: album) {
                        AlbumCard(meta: album.meta,
                                  footer: "\(album.chapters.count) 话 · \(album.totalPages) 页")
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            pendingDelete = album
                            confirmDelete = true
                        } label: {
                            Label("删除（连文件）", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(16)
            .jmCentered()
        }
    }
}

/// 本地漫画详情页：样式与在线阅读详情页一致（封面/标题/继续阅读/章节列表），
/// 进度状态共用 LibraryStore —— 读完回来自动同步「继续阅读第 N 页」。
struct LocalAlbumDetailView: View {

    let album: DownloadedAlbum
    @Environment(\.jmUsesLargePadLayout) private var usesLargePadLayout
    @State private var reading: DownloadedChapter?
    @StateObject private var library = LibraryStore.shared

    var body: some View {
        let pos = library.position(for: album.meta.id)
        let currentChapterID = pos?.chapterId
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 14) {
                    CoverImage(albumId: album.meta.id, width: usesLargePadLayout ? 180 : 110)

                    VStack(alignment: .leading, spacing: 9) {
                        Text(album.meta.title).font(.title3.weight(.semibold)).lineLimit(3)
                        Text("本地漫画 · \(album.chapters.count) 话 · \(album.totalPages) 页")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if let pos,
                           let ch = album.chapters.first(where: { $0.chapterId == pos.chapterId }) {
                            Button {
                                reading = ch
                            } label: {
                                Label("继续阅读：第 \(min(pos.pageIndex + 1, max(ch.pageCount, 1))) 页",
                                      systemImage: "book")
                            }
                            .buttonStyle(.borderedProminent)
                        } else if let first = album.chapters.first {
                            Button {
                                reading = first
                            } label: {
                                Label("开始阅读", systemImage: "book")
                            }
                            .buttonStyle(.borderedProminent)
                            Text("还没读过，从第一话开始")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("章节 (\(album.chapters.count))").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)],
                              alignment: .leading, spacing: 12) {
                        ForEach(album.chapters) { c in
                            chapterRow(c, currentChapterID: currentChapterID)
                        }
                    }
                }
            }
            .padding(16)
            .jmCentered(maxWidth: JMLayout.detailMaxWidth, alignment: .leading)
        }
        .navigationTitle(album.meta.title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $reading) { chapter in
            NavigationStack {
                LocalReaderView(chapter: chapter, meta: album.meta)
            }
        }
    }

    private func chapterRow(_ c: DownloadedChapter, currentChapterID: String?) -> some View {
        Button {
            reading = c
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.chapterTitle).font(.callout).lineLimit(1)
                    Text(chapterInfo(c))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if currentChapterID == c.chapterId {
                    Image(systemName: "bookmark.fill")
                        .foregroundStyle(Color.accentColor)
                }
                Image(systemName: "book")
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    /// 导入的 CBZ 没数过页数，显示格式标识而不是 0 页
    private func chapterInfo(_ c: DownloadedChapter) -> String {
        let fmt = c.format == .cbz ? "CBZ" : "散图"
        return c.pageCount > 0 ? "\(c.pageCount) 页 · \(fmt)" : fmt
    }
}
