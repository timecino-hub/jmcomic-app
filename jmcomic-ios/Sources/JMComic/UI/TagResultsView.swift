import SwiftUI

/// JM 搜索接口支持的常用排序。原始值直接对应参数 o。
enum JmDiscoveryOrder: String, CaseIterable, Identifiable, Hashable {
    case latest = "mr"
    case views = "mv"
    case likes = "tf"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .latest: return "最新"
        case .views: return "观看"
        case .likes: return "喜欢"
        }
    }
}

/// JM 搜索接口支持的时间范围。原始值直接对应参数 t。
enum JmDiscoveryPeriod: String, CaseIterable, Identifiable, Hashable {
    case all = "a"
    case month = "m"
    case week = "w"
    case today = "t"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部时间"
        case .month: return "本月"
        case .week: return "本周"
        case .today: return "今天"
        }
    }
}

/// 精确检索字段。JM 的移动端 API 以 main_tag 区分标签与作者。
private enum JmExactSearchKind: Hashable {
    case tag
    case author

    var title: String {
        switch self {
        case .tag: return "标签"
        case .author: return "作者"
        }
    }

    var icon: String {
        switch self {
        case .tag: return "tag.fill"
        case .author: return "person.fill"
        }
    }

    var emptyIcon: String {
        switch self {
        case .tag: return "tag.slash"
        case .author: return "person.crop.circle.badge.questionmark"
        }
    }

    var explanation: String {
        switch self {
        case .tag: return "只检索漫画标签字段，不混入标题或作者中的同名词。"
        case .author: return "只检索漫画作者字段，不混入标题或标签中的同名词。"
        }
    }
}

/// 标签与作者共用的精确结果页，支持排序、时间范围和完整分页。
private struct ExactSearchResultsView: View {
    let query: String
    let kind: JmExactSearchKind
    @Binding var path: [Route]

    @StateObject private var library = LibraryStore.shared
    @State private var order: JmDiscoveryOrder = .latest
    @State private var period: JmDiscoveryPeriod = .all
    @State private var items: [AlbumMeta] = []
    @State private var page = 0
    @State private var totalPages = 1
    @State private var loading = false
    @State private var error: String?
    @State private var requestID = 0

    private var queryToken: String { "\(kind)|\(query)|\(order.rawValue)|\(period.rawValue)" }
    private var canLoadMore: Bool { page > 0 && page < totalPages }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                filterCard

                if items.isEmpty && loading {
                    ProgressView("正在搜索\(kind.title)…")
                        .frame(maxWidth: .infinity)
                        .padding(50)
                } else if items.isEmpty, let error {
                    errorView(error)
                } else if items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: kind.emptyIcon)
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("没有找到\(kind.title)为“\(query)”的漫画")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(50)
                } else {
                    resultGrid
                    bottomSection
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .navigationTitle("\(kind.title)：\(query)")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: queryToken) { await load(reset: true) }
        .refreshable { await load(reset: true) }
    }

    private var filterCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("精确\(kind.title)匹配", systemImage: kind.icon)
                .font(.subheadline.weight(.semibold))
            Text(kind.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Picker("排序", selection: $order) {
                    ForEach(JmDiscoveryOrder.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .pickerStyle(.segmented)

                Menu {
                    Picker("时间范围", selection: $period) {
                        ForEach(JmDiscoveryPeriod.allCases) { value in
                            Text(value.title).tag(value)
                        }
                    }
                } label: {
                    Label(period.title, systemImage: "calendar")
                        .font(.caption)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }

    private var resultGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 16) {
            ForEach(items) { meta in
                Button { path.append(.album(meta)) } label: {
                    AlbumCard(meta: meta)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var bottomSection: some View {
        VStack(spacing: 10) {
            if loading {
                ProgressView().padding(.top, 8)
            } else if canLoadMore {
                Button("加载更多（\(page) / \(totalPages)）") {
                    Task { await load(reset: false) }
                }
                .buttonStyle(.bordered)
                .padding(.top, 8)
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("重试") { Task { await load(reset: items.isEmpty) } }
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark").font(.largeTitle)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重试") { Task { await load(reset: true) } }
        }
        .frame(maxWidth: .infinity)
        .padding(45)
    }

    private func load(reset: Bool) async {
        if !reset && loading { return }
        if reset {
            requestID += 1
            items = []
            page = 0
            totalPages = 1
            error = nil
        }
        let currentRequest = requestID
        let targetPage = reset ? 1 : page + 1
        loading = true
        defer {
            if currentRequest == requestID { loading = false }
        }

        do {
            let result: PagedAlbums
            switch kind {
            case .tag:
                result = try await JmClient.shared.searchTag(
                    query,
                    order: order.rawValue,
                    time: period.rawValue,
                    page: targetPage
                )
            case .author:
                result = try await JmClient.shared.searchAuthor(
                    query,
                    order: order.rawValue,
                    time: period.rawValue,
                    page: targetPage
                )
            }
            guard currentRequest == requestID, !Task.isCancelled else { return }
            let filtered = await library.filterByExclusions(result.items)
            guard currentRequest == requestID, !Task.isCancelled else { return }

            if reset {
                items = filtered
            } else {
                var known = Set(items.map(\.id))
                items.append(contentsOf: filtered.filter { known.insert($0.id).inserted })
            }
            page = result.page
            totalPages = max(result.totalPages, 1)
            error = nil
        } catch is CancellationError {
            return
        } catch {
            guard currentRequest == requestID else { return }
            self.error = error.localizedDescription
        }
    }
}

/// 单标签结果页：使用 main_tag=3 精确检索。
struct TagResultsView: View {
    let tag: String
    @Binding var path: [Route]

    var body: some View {
        ExactSearchResultsView(query: tag, kind: .tag, path: $path)
    }
}

/// 单作者结果页：使用 main_tag=2 精确检索。
struct AuthorResultsView: View {
    let author: String
    @Binding var path: [Route]

    var body: some View {
        ExactSearchResultsView(query: author, kind: .author, path: $path)
    }
}
