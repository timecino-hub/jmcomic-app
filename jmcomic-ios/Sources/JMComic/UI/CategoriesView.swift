import SwiftUI

/// 分类/标签浏览页（iOS 版）。
///
/// Mac 版是左右两栏（固定分类栏 + 内容栏）；iPhone 竖屏放不下双栏：
/// 改为「标签选择卡（可折叠，多选）+ 应用筛选按钮 + 结果网格」。
/// 多选精准语义与 Mac 版一致：
/// - 纯标签：逐个标签单独搜索取 **id 交集**（都包含）
/// - 混选分类：各分类拉取 + 标签搜索，并集去重
struct CategoriesView: View {

    /// 标签项：分类 slug 走官方筛选，关键词走搜索
    private enum SideItem: Hashable {
        case category(slug: String, name: String)
        case keyword(String)
        var name: String {
            switch self {
            case .category(_, let name): return name
            case .keyword(let k): return k
            }
        }
    }

    private static let categories: [(String, String)] = [
        ("doujin", "同人"), ("single", "单本"), ("short", "短篇"),
        ("hanman", "韩漫"), ("meiman", "美漫"),
        ("doujin_cosplay", "cosplay"), ("3D", "3D"), ("another", "其他"),
    ]
    private static let subCategories: [(String, String)] = [
        ("chinese", "中文"), ("japanese", "日语"), ("CG", "CG"),
        ("youth", "青年漫"), ("other", "其他"),
    ]
    /// 常用分类词（服务端没有全量标签接口，用搜索覆盖常用标签）
    private static let keywords: [String] = [
        "純愛", "NTR", "百合", "偽娘", "獸人", "觸手",
        "科幻", "奇幻", "校園", "辦公室", "兄妹", "老師",
        "偶像", "足控", "癡女", "人妻", "女僕", "亂倫",
        "中出", "全彩", "AI繪圖",
    ]

    @State private var selected: Set<SideItem> = []
    @State private var items: [AlbumMeta] = []
    @State private var hasSearched = false
    @State private var loading = false
    @State private var error: String?
    @State private var hotTags: [String] = []
    /// 与浏览栈根共享同一 path（Route 目标页由 BrowseView 统一注册）
    @Binding var path: [Route]
    @StateObject private var library = LibraryStore.shared
    /// 请求序号：防快速切换时旧请求覆盖新结果（竞态）
    @State private var loadSeq = 0

    init(path: Binding<[Route]>) {
        _path = path
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                selectorCard
                resultHeader
                if loading {
                    ProgressView("正在按条件筛选…")
                        .frame(maxWidth: .infinity)
                        .padding(40)
                } else if items.isEmpty && hasSearched {
                    VStack(spacing: 8) {
                        Image(systemName: "square.grid.2x2").font(.largeTitle).foregroundStyle(.secondary)
                        Text("没有符合条件的作品").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(40)
                } else {
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
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
            .jmCentered(alignment: .leading)
        }
        .navigationTitle("分类")
        .navigationBarTitleDisplayMode(.inline)
        // Route 目标页已在浏览栈根（BrowseView）统一注册，这里不再重复声明
        .task { await loadTags() }
    }

    // MARK: - 选择卡

    @ViewBuilder
    private var selectorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(selected.isEmpty ? "选择分类 / 标签" : "已选 \(selected.count) 项")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !selected.isEmpty {
                    Button("清除") {
                        selected.removeAll()
                        items = []
                        hasSearched = false
                        error = nil
                    }
                    .font(.caption)
                }
            }

            if selected.isEmpty {
                Text("可多选：多个标签 = 组合搜索（取交集）；混选分类 = 并集。选好后点「应用筛选」。")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            chipSection("官方分类", Self.categories.map { SideItem.category(slug: $0.0, name: $0.1) })
            chipSection("子分类", Self.subCategories.map { SideItem.category(slug: $0.0, name: $0.1) })
            chipSection("常用", Self.keywords.map { SideItem.keyword($0) })
            if !hotTags.isEmpty {
                chipSection("热门标签", hotTags.map { SideItem.keyword($0) })
            }

            Button {
                Task { await load(selected) }
            } label: {
                Label(loading ? "筛选中…" : (hasSearched ? "重新应用筛选" : "应用筛选"),
                      systemImage: "line.3.horizontal.decrease.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selected.isEmpty || loading)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }

    private func chipSection(_ title: String, _ allItems: [SideItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            chips(allItems)
        }
    }

    /// 芯片多选行：点击切换选中态
    private func chips(_ allItems: [SideItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 6, alignment: .leading)],
                  alignment: .leading, spacing: 6) {
            ForEach(allItems, id: \.self) { item in
                let isOn = selected.contains(item)
                Button {
                    if isOn { selected.remove(item) } else { selected.insert(item) }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: isOn ? "checkmark" : "")
                            .font(.caption2.weight(.bold))
                        Text(item.name).font(.caption).lineLimit(1)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(isOn ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.08))
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 结果

    private var selectedNames: String {
        selected.map(\.name).sorted().joined(separator: " + ")
    }

    @ViewBuilder
    private var resultHeader: some View {
        if !items.isEmpty && hasSearched {
            Text(selectedNames)
                .font(.headline)
                .lineLimit(1)
                .padding(.horizontal, 16)
        } else if let error {
            VStack(spacing: 6) {
                Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                Text(error).font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(30)
        }
    }

    // MARK: - 加载

    private func loadTags() async {
        if let tags = try? await JmClient.shared.hotTags() {
            hotTags = Array(tags.prefix(30))
        }
    }

    /// 多选加载（seq 序号过期则丢弃结果，防竞态覆盖）
    private func load(_ sel: Set<SideItem>) async {
        guard !sel.isEmpty else { return }
        loadSeq += 1
        let seq = loadSeq
        loading = true
        error = nil
        defer { if seq == loadSeq { loading = false } }
        let keywords = sel.compactMap { item -> String? in
            if case .keyword(let k) = item { return k }
            return nil
        }
        let cats = sel.compactMap { item -> String? in
            if case .category(let s, _) = item { return s }
            return nil
        }
        do {
            let raw: [AlbumMeta]
            if cats.isEmpty {
                if keywords.count <= 1 {
                    let r = try await JmClient.shared.search(keywords.first ?? "", page: 1)
                    raw = r.items
                } else {
                    // 多标签：并发搜索，取 id 交集 = 全部标签都包含的作品
                    var results: [[AlbumMeta]] = []
                    await withTaskGroup(of: [AlbumMeta].self) { group in
                        for k in keywords {
                            group.addTask {
                                (try? await JmClient.shared.search(k, page: 1))?.items ?? []
                            }
                        }
                        for await r in group { results.append(r) }
                    }
                    guard seq == loadSeq else { return }
                    guard let first = results.first else {
                        raw = []
                        items = []
                        hasSearched = true
                        return
                    }
                    var common = Set(first.map(\.id))
                    for r in results.dropFirst() {
                        common.formIntersection(Set(r.map(\.id)))
                    }
                    raw = first.filter { common.contains($0.id) }
                }
            } else {
                // 含分类：各分类并集 + 标签并集
                var map: [String: AlbumMeta] = [:]
                for slug in cats {
                    if let r = try? await JmClient.shared.categories(slug, page: 1) {
                        for m in r.items { map[m.id] = m }
                    }
                    if seq != loadSeq { return }
                }
                if !keywords.isEmpty,
                   let r = try? await JmClient.shared.search(keywords.joined(separator: " "), page: 1) {
                    for m in r.items { map[m.id] = m }
                }
                raw = Array(map.values)
            }
            guard seq == loadSeq else { return }
            items = await library.filterByExclusions(raw)
            hasSearched = true
        } catch {
            if seq == loadSeq {
                self.error = error.localizedDescription
                hasSearched = true
            }
        }
    }
}
