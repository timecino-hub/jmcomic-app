import SwiftUI

/// 本地个性化推荐（iOS 版，逻辑与 Mac 版完全一致）。
///
/// 算法（刻意不用 ML，够用即可）：
/// 1. 画像：从「历史 + 收藏」的本子（本地缓存的 Album 带标签）统计标签/作者频次
/// 2. 候选：用 Top 标签走现有 search 接口各拉一页（不动热门/最新接口）
/// 3. 过滤：排除历史与收藏里已看过的 + 内容过滤标签
/// 4. 排序：与画像标签重合度高的优先
/// 数据全部本地计算，不上传。
struct PersonalizedView: View {

    @Environment(\.jmAlbumGridColumnCount) private var albumGridColumnCount

    @StateObject private var library = LibraryStore.shared
    @State private var items: [AlbumMeta] = []
    @State private var profileTags: [String] = []
    @State private var loading = true
    @State private var error: String?
    /// 与浏览栈根共享同一 path（Route 目标页由 BrowseView 统一注册）
    @Binding var path: [Route]

    init(path: Binding<[Route]>) {
        _path = path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if loading {
                ProgressView("正在按你的口味找…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                emptyHint
            } else {
                grid
            }
        }
        .navigationTitle("为你推荐")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 每次打开本来就会重算；想要立即刷新就点这里
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        // Route 目标页已在浏览栈根（BrowseView）统一注册，这里不再重复声明
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !profileTags.isEmpty {
                Text("根据你看过的：\(profileTags.joined(separator: " · "))")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.secondary)
            if let error {
                Text("推荐失败：\(error)").foregroundStyle(.secondary)
            } else if profileTags.isEmpty {
                Text("还没有足够的口味数据。多读几本、收藏几本，推荐会更准。")
                    .foregroundStyle(.secondary)
            } else {
                Text("没找到新的推荐，之后再来看看。").foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: JMLayout.albumGridColumns(count: albumGridColumnCount), spacing: 16) {
                ForEach(items) { meta in
                    Button { path.append(.album(meta)) } label: {
                        AlbumCard(meta: meta)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .jmCentered()
        }
    }

    // MARK: - 算法

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }

        let rec = await library.recommendations()
        profileTags = rec.profileTags
        items = rec.items
    }
}
