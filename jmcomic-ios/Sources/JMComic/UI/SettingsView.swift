import SwiftUI

/// 设置页（iOS 版）。
///
/// 与 Mac 版的差异：
/// - 去除「隐私快捷键」（NSEvent 键盘监听是 macOS 专有）
/// - 去除「GitHub 同步」（依赖 git CLI，iOS 不存在）；局域网同步服务端属于 Mac 端
/// - 「数据备份」的 NSSavePanel/NSOpenPanel 导出导入暂缓（后续可用 ShareLink/fileImporter 补）
/// - 保留并落实：无痕模式、阅读器默认单页、**断点续读开关**、内容过滤（不感兴趣标签，
///   生效于热门/最新/分类/推荐列表）、图片缓存清理
/// - 「桌面同步」入口（Settings → Sync/DesktopSyncView）：扫码/手动配对、元数据双向合并、
///   Mac 已下载漫画传输
struct SettingsView: View {

    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var favorites = FavoriteStore.shared
    @ObservedObject private var downloads = DownloadStore.shared

    @State private var notice: String?
    @State private var isError = false

    // 阅读器默认单页模式
    @State private var defaultSinglePage = UserDefaults.standard.bool(forKey: "readerSinglePage") {
        didSet { UserDefaults.standard.set(defaultSinglePage, forKey: "readerSinglePage") }
    }
    // 断点续读开关（默认开）
    @State private var resumeReading = UserDefaults.standard.object(forKey: "resumeReadingEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(resumeReading, forKey: "resumeReadingEnabled") }
    }
    // 读完自动接下一话（默认关）
    @State private var autoNextChapter = UserDefaults.standard.object(forKey: "readerAutoNext") as? Bool ?? false {
        didSet { UserDefaults.standard.set(autoNextChapter, forKey: "readerAutoNext") }
    }

    // 内容过滤
    private static let exclusionOptions = [
        "NTR", "觸手", "獸人", "偽娘", "百合", "純愛",
        "兄妹", "亂倫", "中出", "足控", "3D", "AI繪圖",
        "全彩", "血腥", "獵奇", "SM", "強暴", "睡奸",
    ]
    @State private var excluded: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "excludedTags") ?? [])
    private var initialExcluded: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "excludedTags") ?? [])
    }

    // 缓存清理
    @State private var cacheSizeText = "计算中…"
    @State private var localSizeText = "计算中…"

    // 版本更新检查
    @State private var updateInfo: UpdateInfo?
    @State private var checkingUpdate = false

    var body: some View {
        Form {
            preferenceSection
            filterSection
            storageSection
            desktopSyncSection
            aboutSection
        }
        .navigationTitle("设置")
        .overlay(alignment: .bottom) {
            if let notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(isError ? Color.orange : Color.green)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .task {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        self.notice = nil
                    }
                    .transition(.opacity)
            }
        }
        .task { await refreshCacheSize() }
        .alert("发现新版本",
               isPresented: Binding(get: { updateInfo != nil },
                                    set: { if !$0 { updateInfo = nil } })) {
            if let info = updateInfo {
                Button("前往下载") {
                    UIApplication.shared.open(info.htmlURL)
                    updateInfo = nil
                }
                Button("稍后", role: .cancel) { updateInfo = nil }
            }
        } message: {
            if let info = updateInfo {
                Text("\(info.releaseName)\n当前版本 \(UpdateChecker.currentVersion) → 最新版本 \(info.latestVersion)")
            }
        }
    }

    // MARK: - 本地偏好

    private var preferenceSection: some View {
        Section("本地偏好") {
            Toggle("无痕模式（不写历史/进度）", isOn: $library.privateMode)
            Toggle("阅读器默认单页模式", isOn: $defaultSinglePage)
            Toggle("断点续读（恢复上次页码）", isOn: $resumeReading)
            Toggle("读完自动接下一话", isOn: $autoNextChapter)
            Text("单页=一屏一页翻书；连续=长条滚动。阅读器里也能临时切换。")
                .font(.caption).foregroundStyle(.secondary)
            Text("「自动接下一话」：停在本话最后一页约 1 秒后自动进入下一话，往回滚即取消；最后一话不会自动切。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - 内容过滤（不感兴趣）

    private var filterSection: some View {
        Section("内容过滤（不感兴趣）") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 6)],
                      alignment: .leading, spacing: 6) {
                ForEach(Self.exclusionOptions, id: \.self) { t in
                    Button {
                        if excluded.contains(t) { excluded.remove(t) } else { excluded.insert(t) }
                    } label: {
                        Text(t).font(.caption)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(excluded.contains(t)
                                        ? Color.accentColor.opacity(0.3)
                                        : Color.primary.opacity(0.08))
                            .foregroundStyle(.secondary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)

            Text(excluded.isEmpty ? "未设置过滤" : "已排除：\(excluded.sorted().joined(separator: ", "))")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button("保存过滤") {
                    UserDefaults.standard.set(Array(excluded), forKey: "excludedTags")
                    flash("已保存：\(excluded.isEmpty ? "不过滤" : excluded.sorted().joined(separator: ", "))",
                          error: false)
                }
                .buttonStyle(.bordered)
                .font(.caption)
                .disabled(excluded == initialExcluded)

                Button("清空", role: .destructive) {
                    excluded.removeAll()
                }
                .font(.caption)
                .disabled(excluded.isEmpty)
            }
            Text("热门/最新/分类/推荐都会剔除含这些标签的作品。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - 存储与缓存

    private var storageSection: some View {
        Section("存储与缓存") {
            HStack {
                Text("图片缓存")
                Spacer()
                Text(cacheSizeText).foregroundStyle(.secondary).font(.caption)
            }
            Button("清理图片缓存") {
                Task {
                    await ImageStore.shared.clearDisk()
                    await JmClient.shared.clearChapterCache()
                    await refreshCacheSize()
                    flash("已清理图片缓存", error: false)
                }
            }
            HStack {
                Text("本地漫画占用")
                Spacer()
                Text(localSizeText).foregroundStyle(.secondary).font(.caption)
            }
            Text("下载格式（详情页下载时仍可选择）：\(downloads.format.label)")
                .font(.caption).foregroundStyle(.secondary)
            Picker("默认下载格式", selection: $downloads.format) {
                ForEach(DownloadFormat.allCases, id: \.self) { f in
                    Text(f.label).tag(f)
                }
            }
        }
    }

    /// 体积统计：进页时算一次（目录枚举量级可控），清理后重算缓存项
    private func refreshCacheSize() async {
        let size = await ImageStore.shared.diskSize()
        cacheSizeText = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        localSizeText = ByteCountFormatter.string(
            fromByteCount: downloadsSize(), countStyle: .file)
    }

    private func downloadsSize() -> Int64 {
        fmSize(downloads.root)
    }

    private func fmSize(_ url: URL) -> Int64 {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) else { return 0 }
        var total: Int64 = 0
        for item in items {
            let v = try? item.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if v?.isDirectory == true {
                total += fmSize(item)
            } else {
                total += Int64(v?.fileSize ?? 0)
            }
        }
        return total
    }

    // MARK: - 桌面同步

    private var desktopSyncSection: some View {
        Section("桌面同步") {
            NavigationLink {
                DesktopSyncView()
            } label: {
                Label("连接桌面端", systemImage: "laptopcomputer.and.iphone")
            }
            Text("与 Mac 局域网直连：扫码配对后双向合并收藏/历史/进度，并可整本传输桌面已下载的漫画。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section("关于") {
            HStack {
                Text("收藏")
                Spacer()
                Text("\(favorites.entries.count) 条").foregroundStyle(.secondary).font(.caption)
            }
            HStack {
                Text("阅读历史")
                Spacer()
                Text("\(library.history.count) 条").foregroundStyle(.secondary).font(.caption)
            }
            HStack {
                Text("本地漫画")
                Spacer()
                Text("\(downloads.library.count) 本").foregroundStyle(.secondary).font(.caption)
            }
            LabeledContent("当前版本", value: UpdateChecker.currentVersion)
            HStack {
                if checkingUpdate {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    Task { await checkForUpdate() }
                } label: {
                    Text(checkingUpdate ? "检查中…" : "检查更新")
                }
                .disabled(checkingUpdate)
            }
        }
    }

    /// 手动检查更新：有新版本则弹窗，无新版本或失败则用 flash 提示。
    private func checkForUpdate() async {
        checkingUpdate = true
        let result = await UpdateChecker.checkForUpdate()
        checkingUpdate = false
        if let info = result {
            updateInfo = info
        } else {
            flash("已是最新版本", error: false)
        }
    }

    // MARK: - 工具

    private func flash(_ msg: String, error: Bool) {
        notice = msg
        isError = error
    }
}
