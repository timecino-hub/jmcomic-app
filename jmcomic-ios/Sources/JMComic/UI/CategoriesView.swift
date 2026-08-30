import SwiftUI

/// 分类与标签浏览：一个官方分类 + 任意多个精确标签，所有已选条件同时满足。
///
/// 移动端 API 不支持在标签搜索中直接附带分类，因此混合筛选以分类页为候选源，
/// 再分批读取详情验证标签；纯多标签则以第一个标签为候选源，再验证其余标签。
struct CategoriesView: View {
    private struct CategoryOption: Hashable, Identifiable {
        let slug: String
        let name: String
        var id: String { slug }
    }

    @Environment(\.jmAlbumGridColumnCount) private var albumGridColumnCount

    private struct AppliedQuery: Equatable {
        let category: CategoryOption?
        let tags: [String]
        let order: JmDiscoveryOrder
        let period: JmDiscoveryPeriod

        var sourceTag: String? { category == nil ? tags.first : nil }
        var title: String {
            ([category?.name].compactMap { $0 } + tags).joined(separator: " + ")
        }
    }

    private static let categories = [
        CategoryOption(slug: "doujin", name: "同人"),
        CategoryOption(slug: "single", name: "单本"),
        CategoryOption(slug: "short", name: "短篇"),
        CategoryOption(slug: "hanman", name: "韩漫"),
        CategoryOption(slug: "meiman", name: "美漫"),
        CategoryOption(slug: "doujin_cosplay", name: "cosplay"),
        CategoryOption(slug: "3D", name: "3D"),
        CategoryOption(slug: "another", name: "其他"),
    ]
    private static let subCategories = [
        CategoryOption(slug: "chinese", name: "中文"),
        CategoryOption(slug: "japanese", name: "日语"),
        CategoryOption(slug: "CG", name: "CG"),
        CategoryOption(slug: "youth", name: "青年漫"),
        CategoryOption(slug: "other", name: "其他"),
    ]
    private static let commonTags = [
        "純愛", "NTR", "百合", "偽娘", "獸人", "觸手",
        "科幻", "奇幻", "校園", "辦公室", "兄妹", "老師",
        "偶像", "足控", "癡女", "人妻", "女僕", "亂倫",
        "中出", "全彩", "AI繪圖",
    ]

    @Binding var path: [Route]
    @StateObject private var library = LibraryStore.shared

    @State private var selectedCategory: CategoryOption?
    @State private var selectedTags = Set<String>()
    @State private var customTag = ""
    @State private var authorQuery = ""
    @State private var hotTags: [String] = []
    @State private var order: JmDiscoveryOrder = .latest
    @State private var period: JmDiscoveryPeriod = .all

    @State private var appliedQuery: AppliedQuery?
    @State private var items: [AlbumMeta] = []
    @State private var page = 0
    @State private var totalPages = 1
    @State private var loading = false
    @State private var error: String?
    @State private var requestID = 0

    init(path: Binding<[Route]>) {
        _path = path
    }

    private var hasSelection: Bool { selectedCategory != nil || !selectedTags.isEmpty }
    private var canLoadMore: Bool { appliedQuery != nil && page > 0 && page < totalPages }
    private var customSelectedTags: [String] {
        let known = Self.commonTags + hotTags
        return selectedTags
            .filter { tag in !known.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) }
            .sorted()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                selectorCard
                resultHeader
                resultContent
                bottomSection
            }
            .padding(.top, 8)
            .padding(.bottom, 28)
            .jmCentered(alignment: .leading)
        }
        .navigationTitle("分类与标签")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadHotTags() }
    }

    // MARK: - 筛选卡

    private var selectorCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Label("组合筛选", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if hasSelection {
                    Button("清除", action: clearSelectionAndResults)
                    .font(.caption)
                }
            }

            Text("可选一个分类和多个标签；所有条件必须同时满足。标签使用精确字段检索。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("输入作者名", text: $authorQuery)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit { openAuthor() }
                Button("查作者", action: openAuthor)
                    .buttonStyle(.bordered)
                    .disabled(authorQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack(spacing: 8) {
                TextField("输入任意标签", text: $customTag)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit { addCustomTag() }
                Button("添加", action: addCustomTag)
                    .buttonStyle(.bordered)
                    .disabled(customTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            categorySection("官方分类", Self.categories)
            categorySection("子分类", Self.subCategories)
            tagSection("常用标签", Self.commonTags)
            if !hotTags.isEmpty { tagSection("热门标签", hotTags) }
            if !customSelectedTags.isEmpty { tagSection("自定义标签", customSelectedTags) }

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

            Button {
                Task { await applySelection() }
            } label: {
                Label(loading ? "筛选中…" : "应用筛选", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasSelection || loading)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }

    private func categorySection(_ title: String, _ options: [CategoryOption]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 6, alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                ForEach(options) { option in
                    let selected = selectedCategory == option
                    Button {
                        selectedCategory = selected ? nil : option
                    } label: {
                        chipLabel(option.name, selected: selected, radio: true)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func tagSection(_ title: String, _ tags: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 6, alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                ForEach(uniqueTags(tags), id: \.self) { tag in
                    let selected = containsTag(tag)
                    Button { toggleTag(tag) } label: {
                        chipLabel(tag, selected: selected, radio: false)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func chipLabel(_ text: String, selected: Bool, radio: Bool) -> some View {
        HStack(spacing: 3) {
            if selected {
                Image(systemName: radio ? "circle.inset.filled" : "checkmark")
                    .font(.caption2.weight(.bold))
            }
            Text(text).font(.caption).lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.08))
        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        .clipShape(Capsule())
    }

    // MARK: - 结果

    @ViewBuilder
    private var resultHeader: some View {
        if let query = appliedQuery {
            VStack(alignment: .leading, spacing: 3) {
                Text(query.title).font(.headline).lineLimit(2)
                Text("\(query.order.title) · \(query.period.title) · 已扫描第 \(page) / \(totalPages) 页")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var resultContent: some View {
        if loading && items.isEmpty {
            ProgressView("正在精确筛选…")
                .frame(maxWidth: .infinity)
                .padding(45)
        } else if let error, items.isEmpty {
            errorView(error)
        } else if appliedQuery != nil && items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tag.slash").font(.largeTitle).foregroundStyle(.secondary)
                Text(canLoadMore ? "当前页没有匹配结果，可以继续加载" : "没有符合全部条件的漫画")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(40)
        } else if !items.isEmpty {
            LazyVGrid(columns: JMLayout.albumGridColumns(count: albumGridColumnCount), spacing: 16) {
                ForEach(items) { meta in
                    Button { path.append(.album(meta)) } label: {
                        AlbumCard(meta: meta)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var bottomSection: some View {
        if appliedQuery != nil {
            VStack(spacing: 10) {
                if loading && !items.isEmpty {
                    ProgressView()
                } else if canLoadMore {
                    Button("加载更多（\(page) / \(totalPages)）") {
                        Task { await load(reset: false) }
                    }
                    .buttonStyle(.bordered)
                }
                if let error, !items.isEmpty {
                    Text(error).font(.caption).foregroundStyle(.red)
                    Button("重试") { Task { await load(reset: false) } }
                        .font(.caption)
                }
            }
            .frame(maxWidth: .infinity)
        }
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
        .padding(40)
    }

    // MARK: - 标签选择

    private func uniqueTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.filter { seen.insert($0.lowercased()).inserted }
    }

    private func containsTag(_ tag: String) -> Bool {
        selectedTags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }

    private func toggleTag(_ tag: String) {
        if let existing = selectedTags.first(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            selectedTags.remove(existing)
        } else {
            selectedTags.insert(tag)
        }
    }

    private func addCustomTag() {
        let tag = customTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        if !containsTag(tag) { selectedTags.insert(tag) }
        customTag = ""
    }

    private func openAuthor() {
        let author = authorQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !author.isEmpty else { return }
        authorQuery = ""
        path.append(.author(author))
    }

    private func clearSelectionAndResults() {
        requestID += 1
        selectedCategory = nil
        selectedTags.removeAll()
        appliedQuery = nil
        items = []
        page = 0
        totalPages = 1
        loading = false
        error = nil
    }

    // MARK: - 加载

    private func loadHotTags() async {
        if let tags = try? await JmClient.shared.hotTags() {
            hotTags = Array(uniqueTags(tags).prefix(30))
        }
    }

    private func applySelection() async {
        let tags = selectedTags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        guard selectedCategory != nil || !tags.isEmpty else { return }
        appliedQuery = AppliedQuery(category: selectedCategory, tags: tags, order: order, period: period)
        await load(reset: true)
    }

    private func load(reset: Bool) async {
        guard let query = appliedQuery else { return }
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
            if let category = query.category {
                result = try await JmClient.shared.categories(
                    category.slug,
                    order: query.order.rawValue,
                    time: query.period.rawValue,
                    page: targetPage
                )
            } else if let sourceTag = query.sourceTag {
                result = try await JmClient.shared.searchTag(
                    sourceTag,
                    order: query.order.rawValue,
                    time: query.period.rawValue,
                    page: targetPage
                )
            } else {
                return
            }
            guard currentRequest == requestID, !Task.isCancelled else { return }

            var filtered = result.items
            if query.category != nil || query.tags.count > 1 {
                filtered = await library.filterByRequiredTags(filtered, requiredTags: query.tags)
            }
            filtered = await library.filterByExclusions(filtered)
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
