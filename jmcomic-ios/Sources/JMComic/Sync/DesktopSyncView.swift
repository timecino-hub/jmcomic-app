import SwiftUI
import UIKit

// MARK: - 桌面同步页
//
// 三块状态：
//   未配对 → 扫码 / 手动输入配对（成功后自动拉取清单）
//   已配对 → 连接状态卡（解绑）+ 元数据双向合并同步 + Mac 已下载漫画传输
// 传输由独立的 TransferManager 驱动：同时仅一本、可取消、失败单文件重试、
// 整本完成后按清单校验文件数与大小再注册进 DownloadStore。

struct DesktopSyncView: View {

    @StateObject private var model = DesktopSyncModel()
    @State private var showScanner = false
    @State private var confirmUnpair = false

    var body: some View {
        Form {
            if model.session == nil {
                unpairedSections
            } else {
                pairedSections
            }
        }
        .navigationTitle("桌面同步")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                PairingScannerView { raw in
                    showScanner = false
                    Task { await model.pair(withConfigString: raw) }
                }
            }
        }
        .confirmationDialog("解绑后会话立即失效，需重新扫码配对。本地已传输的漫画不受影响。",
                            isPresented: $confirmUnpair,
                            titleVisibility: .visible) {
            Button("解绑", role: .destructive) { model.unpair() }
        }
    }

    // MARK: 未配对态

    private var unpairedSections: some View {
        Section {
            Button {
                showScanner = true
            } label: {
                Label("扫码配对", systemImage: "qrcode.viewfinder")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)

            if let notice = model.pairNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(model.pairFailed ? Color.orange : Color.green)
            }

            ManualPairForm { cfg in
                Task { await model.pair(cfg) }
            }

            Text("先在 Mac 端 打开 设置 → iPhone 同步 开启服务，再扫码或输入其显示的 IP、端口与配对码。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 已配对态

    @ViewBuilder
    private var pairedSections: some View {
        if let s = model.session {
            connectionSection(s)
            syncSection
            downloadsSection
        }
    }

    private func connectionSection(_ s: SyncSession) -> some View {
        Section("已配对桌面端") {
            LabeledContent("目标 Mac", value: s.addressText)
                .textSelection(.enabled)
            LabeledContent("本机名称", value: s.deviceName)
            LabeledContent("配对时间", value: s.pairedAt.formatted(date: .abbreviated, time: .shortened))
            Button("解绑（清除本机会话）", role: .destructive) {
                confirmUnpair = true
            }
        }
    }

    private var syncSection: some View {
        Section("元数据同步") {
            Button {
                Task { await model.syncMetadata() }
            } label: {
                HStack {
                    Label("同步元数据（拉取合并 + 推送）", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if model.syncing { ProgressView() }
                }
            }
            .disabled(model.syncing)

            if let r = model.syncResult {
                Text(r)
                    .font(.caption)
                    .foregroundStyle(model.syncFailed ? Color.orange : Color.green)
            }

            Text("从 Mac 拉取收藏/历史/进度并入本机（收藏按 id 合并、进度按时间新者赢），再把本机全量推送回 Mac 由其合并。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var downloadsSection: some View {
        Section {
            HStack {
                Text("Mac 已下载漫画").font(.headline)
                Spacer()
                if model.albumsLoading { ProgressView() }
                Button("刷新") { Task { await model.refreshDownloads() } }
                    .font(.caption)
                    .disabled(model.albumsLoading)
            }

            if let err = model.albumsError {
                Text("清单获取失败：\(err)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if model.albums.isEmpty && !model.albumsLoading && model.albumsError == nil {
                Text("Mac 端还没有已下载的漫画。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(model.albums) { album in
                AlbumTransferRow(album: album, model: model)
            }

            Text("传输按清单顺序逐文件进行；取消后已写入文件保留，可继续续传。完成后本子会出现在「本地库」。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 单本专辑行（含传输状态机展示）

private struct AlbumTransferRow: View {

    let album: LanDownloadAlbum
    @ObservedObject var model: DesktopSyncModel

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(album.totalBytes), countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(album.title).font(.subheadline.weight(.medium))
                Spacer()
                control
            }
            Text("\(album.files.count) 个文件 · \(sizeText)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let t = model.transfer.active, t.albumId == album.albumId {
                statusDetail(t)
            }
        }
        .padding(.vertical, 2)
    }

    // 右侧主控按钮：传输中=取消；空闲=传输/续传；其它本在传则禁用
    @ViewBuilder
    private var control: some View {
        if let t = model.transfer.active {
            if t.albumId == album.albumId {
                if t.phase == .running {
                    Button("取消", role: .destructive) { model.transfer.cancel() }
                        .font(.caption)
                } else {
                    Button("重新传输") { model.transfer.start(album: album, client: model.client) }
                        .font(.caption)
                }
            } else {
                Button("传输") { model.transfer.start(album: album, client: model.client) }
                    .font(.caption)
                    .disabled(t.phase == .running)
            }
        } else {
            Button("传输") { model.transfer.start(album: album, client: model.client) }
                .font(.caption)
        }
    }

    // 传输状态明细：进度条 + 当前文件 + 结果/操作
    @ViewBuilder
    private func statusDetail(_ t: TransferManager.TransferState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if t.phase == .running {
                ProgressView(value: t.total == 0 ? 0 : Double(t.done) / Double(t.total))
                Text(t.currentFile.isEmpty
                     ? "准备中…"
                     : "\(t.done)/\(t.total) · \(t.currentFile)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            switch t.phase {
            case .finished:
                Label("传输完成，已入库校验通过", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .cancelled:
                Label("已取消（已落盘 \(t.done)/\(t.total) 个文件保留）", systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(.secondary)
            case .failed(let msg):
                Text("失败：\(msg)").font(.caption).foregroundStyle(.orange)
            case .running, .idle:
                EmptyView()
            }
        }
    }
}

// MARK: - 传输管理器（@MainActor，同时仅一本）

@MainActor
final class TransferManager: ObservableObject {

    enum Phase: Equatable {
        case idle
        case running
        case finished
        case cancelled
        case failed(String)
    }

    struct TransferState {
        let album: LanDownloadAlbum
        var total: Int
        var done = 0
        var currentFile = ""
        var phase: Phase = .running
        /// 失败文件在清单中的下标（重试起点；之前的文件已落盘，靠 size 匹配跳过）
        var failedIndex: Int?

        var albumId: String { album.albumId }
    }

    @Published private(set) var active: TransferState?

    private var runTask: Task<Void, Never>?

    /// 启动/续传同一本：running 中忽略；失败/取消后再点从断点文件继续
    func start(album: LanDownloadAlbum, client: LanSyncClient) {
        if let a = active, a.phase == .running { return }   // 同时仅一本
        let resumeFrom = (active?.albumId == album.albumId) ? (active?.failedIndex ?? 0) : 0
        runTask?.cancel()
        active = TransferState(album: album, total: album.files.count)
        runTask = Task { await run(album: album, from: resumeFrom, client: client) }
    }

    /// 取消：已落盘文件保留
    func cancel() {
        runTask?.cancel()
    }

    /// 解绑/退出时清理
    func reset() {
        runTask?.cancel()
        runTask = nil
        active = nil
    }

    // MARK: 传输主循环

    private func run(album: LanDownloadAlbum, from startIndex: Int, client: LanSyncClient) async {
        guard var st = active, st.albumId == album.albumId else { return }
        let root = DownloadStore.shared.root
        let fm = FileManager.default

        for (i, file) in album.files.enumerated() {
            guard i >= startIndex else {
                st.done += 1
                continue
            }
            if Task.isCancelled {
                st.phase = .cancelled
                active = st
                return
            }
            guard let comps = Self.safeComponents(file.path) else {
                st.phase = .failed("清单含非法路径：\(file.path)")
                active = st
                return
            }
            let dest = root.appendingPathComponent(comps.joined(separator: "/"))

            // 断点跳过：已存在且大小一致视为完成（重试/续传时快速越过）
            if let attrs = try? fm.attributesOfItem(atPath: dest.path),
               let size = attrs[.size] as? UInt64, Int(size) == file.size {
                st.done += 1
                st.currentFile = comps.last ?? file.path
                active = st
                continue
            }

            st.currentFile = comps.last ?? file.path
            active = st

            do {
                let data = try await client.downloadFile(file.path)
                guard data.count == file.size else {
                    throw LanSyncError.sizeMismatch("\(file.path)（收到 \(data.count) 字节）")
                }
                let dir = dest.deletingLastPathComponent()
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: dest, options: .atomic)
                st.done += 1
                active = st
            } catch is CancellationError {
                st.phase = .cancelled
                active = st
                return
            } catch let urlErr as URLError where urlErr.code == .cancelled {
                st.phase = .cancelled
                active = st
                return
            } catch {
                st.phase = .failed("\(comps.last ?? file.path)：\(error.localizedDescription)")
                st.failedIndex = i
                active = st
                return
            }
        }

        // 整本完成：按清单一一校验文件数与大小
        if let bad = Self.verify(files: album.files, root: root) {
            st.phase = .failed("校验未通过：\(bad)")
            active = st
            return
        }

        // 注册进 DownloadStore 本地记录，LocalLibraryView / LocalReaderView 即可发现
        if let record = Self.buildRecord(album: album, root: root) {
            DownloadStore.shared.recordSyncedAlbum(record)
        }
        st.phase = .finished
        active = st
    }

    // MARK: 路径与校验（纯函数）

    /// 客户端侧防穿越：拒绝 ".."、".."、反斜杠、空字节等；返回安全的路径组件
    nonisolated static func safeComponents(_ relative: String) -> [String]? {
        guard !relative.contains("\0") else { return nil }
        let comps = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !comps.isEmpty else { return nil }
        for c in comps where c == ".." || c == "." || c.contains("\\") { return nil }
        return comps
    }

    /// 完成校验：清单每个文件都存在且大小一致
    private nonisolated static func verify(files: [LanDownloadFile], root: URL) -> String? {
        let fm = FileManager.default
        for f in files {
            guard let comps = safeComponents(f.path) else { return "非法路径 \(f.path)" }
            let dest = root.appendingPathComponent(comps.joined(separator: "/"))
            guard let attrs = try? fm.attributesOfItem(atPath: dest.path),
                  let size = attrs[.size] as? UInt64, Int(size) == f.size
            else { return "\(f.path) 缺失或大小不符" }
        }
        return nil
    }

    /// 从清单重建 DownloadStore 记录：
    /// 「专辑/章节.cbz」→ 单文件章；「专辑/章节目录/页图」→ 聚合为散图目录章。
    /// chapterId 用本地落盘路径哈希（与扫描导入一致），专辑 id 沿用 Mac 真实 albumId。
    nonisolated static func buildRecord(album: LanDownloadAlbum, root: URL) -> DownloadedAlbum? {
        struct Draft { var title: String; var dest: URL; var format: DownloadFormat; var pageCount: Int }
        var drafts: [Draft] = []
        var dirIndex: [String: Int] = [:]

        for f in album.files {
            guard let comps = safeComponents(f.path), comps.count >= 2 else { continue }
            let dest = root.appendingPathComponent(comps.joined(separator: "/"))
            let rest = Array(comps.dropFirst())
            if rest.count == 1, dest.pathExtension.lowercased() == "cbz" {
                drafts.append(Draft(title: dest.deletingPathExtension().lastPathComponent,
                                    dest: dest, format: .cbz, pageCount: 0))
            } else if rest.count >= 2 {
                let key = rest[0]
                if let idx = dirIndex[key] {
                    drafts[idx].pageCount += 1
                } else {
                    dirIndex[key] = drafts.count
                    drafts.append(Draft(title: key,
                                        dest: dest.deletingLastPathComponent(),
                                        format: .folder, pageCount: 1))
                }
            }
        }
        guard !drafts.isEmpty else { return nil }

        var chapters: [DownloadedChapter] = []
        for (i, d) in drafts.enumerated() {
            chapters.append(DownloadedChapter(chapterId: DownloadStore.fallbackID(d.dest.path),
                                              chapterTitle: d.title, sort: i + 1,
                                              path: d.dest.path, pageCount: d.pageCount,
                                              format: d.format))
        }
        let meta = AlbumMeta(id: album.albumId, title: album.title, authors: [])
        return DownloadedAlbum(meta: meta, chapters: chapters, completedAt: Date())
    }
}

// MARK: - 页面模型（配对 / 同步 / 清单）

@MainActor
final class DesktopSyncModel: ObservableObject {

    @Published private(set) var session: SyncSession?
    @Published var pairNotice: String?
    @Published var pairFailed = false
    @Published var syncing = false
    @Published var syncResult: String?
    @Published var syncFailed = false
    @Published private(set) var albums: [LanDownloadAlbum] = []
    @Published private(set) var albumsLoading = false
    @Published private(set) var albumsError: String?

    let client = LanSyncClient()
    let transfer = TransferManager()

    init() {
        // 启动恢复：钥匙串里有会话即视为已配对
        if let s = LanSyncClient.loadSession() {
            session = s
            client.session = s
        }
    }

    /// 扫码识别出原始配置串后的统一入口
    func pair(withConfigString raw: String) async {
        switch LanSyncClient.parseConfig(raw) {
        case .failure(let err):
            pairFailed = true
            pairNotice = err.localizedDescription
        case .success(let cfg):
            await pair(cfg)
        }
    }

    /// 执行配对：成功即保存钥匙串并自动拉取清单
    func pair(_ cfg: SyncConfig) async {
        do {
            let rec = try await client.pair(config: cfg, deviceName: UIDevice.current.name)
            LanSyncClient.saveSession(rec)
            client.session = rec
            session = rec
            pairFailed = false
            pairNotice = "配对成功：\(rec.addressText)"
            await refreshDownloads()
        } catch {
            pairFailed = true
            pairNotice = error.localizedDescription
        }
    }

    /// 解绑：清钥匙串 + 清页面状态（Mac 端设备记录需在 Mac 上撤销）
    func unpair() {
        LanSyncClient.clearSession()
        client.session = nil
        session = nil
        albums = []
        albumsError = nil
        syncResult = nil
        pairNotice = nil
        transfer.reset()
    }

    /// 元数据双向合并：pull → 本地 stores 合并 → 打包本地全量 → push
    func syncMetadata() async {
        guard session != nil, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            let remote = try await client.pullMetadata()
            let favAdded = FavoriteStore.shared.importJSON(remote.favorites)
            let posUpdated = LibraryStore.shared.importState(remote.state)

            guard let fav = FavoriteStore.shared.exportJSON(),
                  let state = LibraryStore.shared.exportState() else {
                throw LanSyncError.crypto("本地元数据打包失败")
            }
            try await client.pushMetadata(favorites: fav, state: state)

            syncFailed = false
            syncResult = "同步完成：收藏 +\(favAdded) 条、进度更新 \(posUpdated) 条，本地全量已推送"
        } catch {
            syncFailed = true
            syncResult = error.localizedDescription
        }
    }

    /// 拉取 Mac 已下载清单
    func refreshDownloads() async {
        guard session != nil else { return }
        albumsLoading = true
        albumsError = nil
        defer { albumsLoading = false }
        do {
            albums = try await client.fetchDownloadsList()
        } catch {
            albumsError = error.localizedDescription
        }
    }
}
