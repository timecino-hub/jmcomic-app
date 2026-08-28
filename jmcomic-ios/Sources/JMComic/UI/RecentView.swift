import SwiftUI

/// 最近浏览（iOS 版）：打开过详情页的本子（即使没阅读也记），持久化到磁盘，
/// 进程被杀/重启也不丢。工具栏提供「清空」并带确认。
struct RecentView: View {

    @ObservedObject private var library = LibraryStore.shared
    /// 与浏览栈根共享同一 path（Route 目标页由 BrowseView 统一注册）
    @Binding var path: [Route]
    @State private var confirmClear = false

    init(path: Binding<[Route]>) {
        _path = path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if library.recentlyViewed.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock").font(.largeTitle).foregroundStyle(.secondary)
                    Text("打开过的本子会出现在这里（无需阅读）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 16) {
                        ForEach(library.recentlyViewed) { meta in
                            Button { path.append(.album(meta)) } label: {
                                AlbumCard(meta: meta)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("最近浏览")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(library.recentlyViewed.isEmpty)
                .accessibilityLabel("清空最近浏览")
            }
        }
        // Route 目标页已在浏览栈根（BrowseView）统一注册，这里不再重复声明
        .confirmationDialog("清空最近浏览？",
                            isPresented: $confirmClear,
                            titleVisibility: .visible) {
            Button("清空（不影响阅读进度）", role: .destructive) {
                library.clearRecentlyViewed()
            }
        }
    }
}
