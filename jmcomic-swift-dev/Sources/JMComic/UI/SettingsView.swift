import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers

/// 设置页（侧边栏独立页面，两栏排版，默认窗口一屏放下不滚动）。
///
/// 左栏：局域网访问；右栏：本地偏好 / 隐私保护 / 数据备份；
/// 底部通栏：在线设备管理。
struct SettingsView: View {

    @ObservedObject private var web = WebService.shared
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var favorites = FavoriteStore.shared

    @State private var hasPassword = false
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var portText = String(WebService.shared.port)
    @State private var qrIP: String?
    @State private var notice: String?
    @State private var isError = false

    // 隐私保护快捷键
    @State private var shortcutEnabled = UserDefaults.standard.bool(forKey: "privacyShortcutEnabled")
    @State private var shortcutText = SettingsView.shortcutDisplay()
    @State private var recordingShortcut = false
    @State private var shortcutMonitor: Any?

    // 阅读器默认单页模式
    @State private var defaultSinglePage = UserDefaults.standard.bool(forKey: "readerSinglePage") {
        didSet { UserDefaults.standard.set(defaultSinglePage, forKey: "readerSinglePage") }
    }

    // GitHub 同步
    @ObservedObject private var syncStore = SyncStore.shared
    @State private var syncRepoURL = SyncStore.shared.repoURL
    @State private var syncToken = ""
    @State private var syncPassword = ""

    // 内容过滤（不感兴趣的分组/标签）——点选预设选项
    private static let exclusionOptions = [
        "NTR", "觸手", "獸人", "偽娘", "百合", "純愛",
        "兄妹", "亂倫", "中出", "足控", "3D", "AI繪圖",
        "全彩", "血腥", "獵奇", "SM", "強暴", "睡奸",
    ]
    @State private var excluded: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "excludedTags") ?? [])
    private var initialExcluded: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "excludedTags") ?? [])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("设置").font(.title2.weight(.semibold))
                LazyVGrid(columns: [
                    GridItem(.flexible(minimum: 330), alignment: .top),
                    GridItem(.flexible(minimum: 330), alignment: .top),
                ], alignment: .leading, spacing: 16) {
                    card { lanSection }

                    VStack(alignment: .leading, spacing: 16) {
                        card { preferenceSection }
                        card { privacySection }
                        card { backupSection }
                        card { githubSyncSection }
                    }

                    card { deviceSection }
                        .gridCellColumns(2)
                }
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .task {
            hasPassword = await WebAuth.shared.hasPassword
            await web.refreshEntryToken()
        }
    }

    /// 统一卡片样式
    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { c() }
            .padding(14)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 局域网访问

    private var lanSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("局域网访问").font(.headline)
            Text("同一 WiFi 下扫码/输口令进入。")
                .font(.caption2).foregroundStyle(.secondary)

            if !hasPassword {
                Label("先设访问密码才能开启服务",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
            }

            HStack(spacing: 10) {
                Button(web.isRunning ? "停止服务" : "启动服务") {
                    if web.isRunning {
                        web.stop()
                    } else {
                        if let p = UInt16(portText), p >= 1024 { web.port = p }
                        web.start()
                    }
                }
                .disabled(!hasPassword)

                Text("端口")
                TextField("", text: $portText).frame(width: 62).disabled(web.isRunning)

                Circle().fill(web.isRunning ? .green : .secondary).frame(width: 8, height: 8)
                Text(web.isRunning ? "运行中" : "已停止").font(.caption2).foregroundStyle(.secondary)
            }

            Toggle("HTTPS 加密", isOn: $web.useHTTPS)
                .font(.caption).disabled(web.isRunning)
                .onChange(of: web.useHTTPS) { _, _ in
                    flash("加密开关在服务停止后生效", error: false)
                }

            Toggle("扫码自动登录（免密码）", isOn: $web.scanAutoLogin)
                .font(.caption)
            if web.scanAutoLogin {
                Label("拿到二维码者无需密码即可进入。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
            }

            Toggle("本机免登录（127.0.0.1 直接进）", isOn: $web.localAutoLogin)
                .font(.caption)
            if web.localAutoLogin {
                Label("注意：本机上的进程/恶意网页可能直接访问。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
                // 勾选后变为可点击：一键用默认浏览器打开本机入口
                HStack(spacing: 10) {
                    Button {
                        if let url = URL(string: "\(web.scheme)://127.0.0.1:\(web.port)") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("在浏览器中打开", systemImage: "safari")
                            .frame(minWidth: 110)
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    .disabled(!web.isRunning)
                    Text(web.isRunning ? "\(web.scheme)://127.0.0.1:\(web.port)" : "启动服务后可用")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }



            if let err = web.lastError {
                Text("启动失败：\(err)").font(.caption).foregroundStyle(.red)
            }

            if web.isRunning, !web.addresses.isEmpty {
                entryCard
            }

            Text(hasPassword ? "修改访问密码" : "设置访问密码").font(.subheadline.weight(.medium))
            SecureField("新密码（至少 6 位）", text: $newPassword)
            SecureField("再次输入", text: $confirmPassword)

            HStack {
                Button("保存密码") { savePassword() }
                    .disabled(newPassword.count < 6 || newPassword != confirmPassword)
                if hasPassword {
                    Button("清除密码", role: .destructive) {
                        Concurrency.detached {
                            await WebAuth.shared.clearPassword()
                            await MainActor.run {
                                hasPassword = false
                                web.stop()
                                flash("密码已清除，服务已停止", error: false)
                            }
                        }
                    }
                }
            }
            .font(.caption)

            if let notice {
                Text(notice).font(.caption).foregroundStyle(isError ? .red : .green)
            }
        }
    }

    /// 入口卡片：二维码 + 手输口令 + 换一个
    private var entryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if web.addresses.count > 1 {
                Picker("二维码地址", selection: $qrIP) {
                    ForEach(web.addresses, id: \.self) { ip in Text(ip) }
                }
                .font(.caption2)
            }

            if let url = web.entryURL(ip: qrIP ?? web.addresses.first),
               let qr = Self.qrImage(url) {
                HStack(alignment: .top, spacing: 10) {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .frame(width: 116, height: 116)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 5) {
                        Text("手机扫码进阅读").font(.caption.weight(.medium))
                        Text("口令一次性，每次使用自动更换。")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(web.scanAutoLogin ? "当前：扫码直接进入" : "当前：扫码后输密码")
                            .font(.caption2).foregroundStyle(web.scanAutoLogin ? .green : .secondary)

                        HStack(spacing: 5) {
                            Text(web.entryToken)
                                .font(.system(.caption2, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Color.primary.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(web.entryToken, forType: .string)
                                flash("口令已复制", error: false)
                            } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            Button("换一个") { web.rotateEntryToken() }
                                .buttonStyle(.borderless).font(.caption2)
                        }
                    }
                }
            }

            ForEach(web.addresses, id: \.self) { ip in
                let url = "\(web.scheme)://\(ip):\(web.port)"
                HStack {
                    Text(url).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                        flash("已复制", error: false)
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - 本地偏好

    private var preferenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("本地偏好").font(.headline)
            Toggle("无痕模式（不写历史/进度）", isOn: $library.privateMode)
                .font(.caption)
            Toggle("阅读器默认单页模式", isOn: $defaultSinglePage)
                .font(.caption)
            Text("单页=一屏一页翻书；连续=长条滚动。阅读器里也能临时切。")
                .font(.caption2).foregroundStyle(.secondary)

            Divider().padding(.vertical, 2)

            Text("内容过滤（不感兴趣）").font(.subheadline.weight(.medium))
            // 点选排除项（预设标签，可多选）
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 6)],
                      alignment: .leading, spacing: 6) {
                ForEach(Self.exclusionOptions, id: \.self) { t in
                    Button {
                        if excluded.contains(t) { excluded.remove(t) } else { excluded.insert(t) }
                    } label: {
                        Text(t).font(.caption)
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(excluded.contains(t)
                                        ? Color.accentColor.opacity(0.3)
                                        : Color.primary.opacity(0.08))
                            .foregroundStyle(.secondary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text(excluded.isEmpty ? "未设置过滤" : "已排除：\(excluded.sorted().joined(separator: ", "))")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("清空") { excluded.removeAll() }
                    .buttonStyle(.borderless).font(.caption)
                    .disabled(excluded.isEmpty)
            }
            Button("保存过滤") {
                UserDefaults.standard.set(Array(excluded), forKey: "excludedTags")
                flash("已保存：\(excluded.isEmpty ? "不过滤" : excluded.sorted().joined(separator: ", "))",
                      error: false)
            }
            .buttonStyle(.bordered).font(.caption)
            .disabled(excluded == initialExcluded)
            Text("热门/最新/分类/推荐都会剔除含这些标签的作品。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - 隐私保护

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("隐私保护").font(.headline)
            Text("侧边栏底部「保护」按钮一键最小化。")
                .font(.caption2).foregroundStyle(.secondary)

            Toggle("启用快捷键", isOn: $shortcutEnabled)
                .font(.caption)
                .onChange(of: shortcutEnabled) { _, on in
                    UserDefaults.standard.set(on, forKey: "privacyShortcutEnabled")
                    if !on { stopRecording() }
                }

            if shortcutEnabled {
                HStack(spacing: 8) {
                    Button(recordingShortcut ? "请按键…（Esc 取消）"
                                            : "快捷键：\(shortcutText)") {
                        toggleRecording()
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    if shortcutText != "未设置" {
                        Button("清除") {
                            UserDefaults.standard.removeObject(forKey: "privacyShortcutKeyCode")
                            UserDefaults.standard.removeObject(forKey: "privacyShortcutModifiers")
                            UserDefaults.standard.removeObject(forKey: "privacyShortcutChar")
                            shortcutText = "未设置"
                        }
                        .buttonStyle(.borderless).font(.caption)
                    }
                }
            }
        }
    }

    private func toggleRecording() {
        recordingShortcut.toggle()
        guard recordingShortcut else { stopRecording(); return }
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            if ev.keyCode == 53 {
                self.recordingShortcut = false
                self.stopRecording()
                return nil
            }
            let flags = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let char = ev.charactersIgnoringModifiers?.uppercased().first.map(String.init) ?? "?"
            UserDefaults.standard.set(Int(ev.keyCode), forKey: "privacyShortcutKeyCode")
            UserDefaults.standard.set(Int(flags.rawValue), forKey: "privacyShortcutModifiers")
            UserDefaults.standard.set(char, forKey: "privacyShortcutChar")
            self.shortcutText = SettingsView.modifierText(flags) + char
            self.recordingShortcut = false
            self.stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let m = shortcutMonitor {
            NSEvent.removeMonitor(m)
            shortcutMonitor = nil
        }
    }

    private static func shortcutDisplay() -> String {
        let kc = UserDefaults.standard.integer(forKey: "privacyShortcutKeyCode")
        guard kc != 0 else { return "未设置" }
        let mods = UInt(UserDefaults.standard.integer(forKey: "privacyShortcutModifiers"))
        let char = UserDefaults.standard.string(forKey: "privacyShortcutChar") ?? "?"
        return modifierText(NSEvent.ModifierFlags(rawValue: mods)) + char
    }

    private static func modifierText(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.command) { s += "⌘" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.shift) { s += "⇧" }
        return s
    }

    // MARK: - GitHub 同步

    private var githubSyncSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GitHub 同步").font(.headline)
            Text("收藏 + 历史 + 进度加密存私有仓库，换机/多机自动同步。")
                .font(.caption2).foregroundStyle(.secondary)

            TextField("仓库地址（https://github.com/你/仓库.git）", text: $syncRepoURL)
                .font(.caption)
            SecureField("GitHub Token（存本机钥匙串）", text: $syncToken)
                .font(.caption)
            SecureField("同步密码（加密密钥，存钥匙串）", text: $syncPassword)
                .font(.caption)

            HStack(spacing: 10) {
                Button("保存配置") { saveSyncConfig() }
                    .buttonStyle(.bordered).font(.caption)
                Button("从 gh 导入 Token") { importTokenFromGH() }
                    .buttonStyle(.bordered).font(.caption)
                Button(syncStore.syncing ? "同步中…" : "立即同步") {
                    Task { await syncStore.sync() }
                }
                .buttonStyle(.bordered).font(.caption)
                .disabled(syncStore.syncing)
                Spacer()
                if let last = syncStore.lastSync {
                    Text("上次同步：\(Self.relativeTime(last))").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let err = syncStore.lastError {
                Text(err).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func saveSyncConfig() {
        syncStore.setRepoURL(syncRepoURL)
        if !syncToken.isEmpty { syncStore.setToken(syncToken) }
        if !syncPassword.isEmpty { syncStore.setSyncPassword(syncPassword) }
        flash("已保存，点「立即同步」测试", error: false)
    }

    /// 新机一键：读本机 gh CLI 的登录 token 填入
    private func importTokenFromGH() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["gh", "auth", "token"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0,
                  let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty
            else {
                flash("读取失败：请先在本机执行 gh auth login", error: true)
                return
            }
            syncStore.setToken(token)
            flash("Token 已导入（存本机钥匙串）", error: false)
        } catch {
            flash("读取失败：\(error.localizedDescription)", error: true)
        }
    }

    // MARK: - 数据备份（收藏 + 历史/进度，各自独立导入导出）

    private var backupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("数据备份").font(.headline)
            Text("换机器/替换 App 前导出，之后导入（按 id 合并，不覆盖）。")
                .font(.caption2).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("导出收藏（\(favorites.entries.count)）") { exportFavorites() }
                Button("导入收藏") { importFavorites() }
            }
            .font(.caption)
            HStack(spacing: 8) {
                Button("导出历史进度（\(library.history.count)）") { exportState() }
                Button("导入历史进度") { importState() }
            }
            .font(.caption)
        }
    }

    private func exportFavorites() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "jmcomic-favorites.json"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = favorites.exportJSON() else { return }
        do {
            try data.write(to: url, options: .atomic)
            flash("已导出 \(favorites.entries.count) 条收藏", error: false)
        } catch {
            flash("导出失败：\(error.localizedDescription)", error: true)
        }
    }

    private func importFavorites() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        let n = favorites.importJSON(data)
        flash(n > 0 ? "导入 \(n) 条新收藏" : "无新增（都已存在）", error: n == 0)
    }

    private func exportState() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "jmcomic-history.json"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = library.exportState() else { return }
        do {
            try data.write(to: url, options: .atomic)
            flash("已导出历史 \(library.history.count) 条、进度 \(library.positions.count) 条", error: false)
        } catch {
            flash("导出失败：\(error.localizedDescription)", error: true)
        }
    }

    private func importState() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        let n = library.importState(data)
        flash(n > 0 ? "已合并 \(n) 条进度" : "无新增进度", error: n == 0)
    }

    // MARK: - 在线设备

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("在线设备").font(.headline)
                Spacer()
                Button("全部下线") { web.revokeAllDevices() }
                    .font(.caption).buttonStyle(.borderless)
                    .disabled(web.activeDevices.isEmpty)
            }
            if web.activeDevices.isEmpty {
                Text(web.isRunning ? "暂无设备在线" : "服务未启动")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 16) {
                    ForEach(web.activeDevices) { d in
                        HStack(spacing: 8) {
                            Image(systemName: "iphone").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.name).font(.caption.weight(.medium))
                                Text("\(d.ip) · \(Self.relativeTime(d.lastSeen)) · \(d.lastPath)")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Toggle("信任", isOn: Binding<Bool>(
                                get: { d.trusted },
                                set: { web.setTrusted(id: d.id, trusted: $0) }))
                                .toggleStyle(.checkbox)
                                .font(.caption)
                                .help("取消信任后该设备只能看不能改（进度/收藏只读）")
                            Button("踢出") { web.revokeDevice(id: d.id) }
                                .font(.caption).buttonStyle(.borderless).foregroundStyle(.red)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - 工具

    private static func relativeTime(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(s / 60) 分钟前" }
        if s < 86400 { return "\(s / 3600) 小时前" }
        return "\(s / 86400) 天前"
    }

    private static func qrImage(_ url: String) -> NSImage? {
        guard let data = url.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 116, height: 116))
    }

    private func savePassword() {
        let pw = newPassword
        Concurrency.detached {
            await WebAuth.shared.setPassword(pw)
            await MainActor.run {
                hasPassword = true
                newPassword = ""
                confirmPassword = ""
                flash("密码已保存，其他设备需重新扫码登录", error: false)
            }
        }
    }

    private func flash(_ msg: String, error: Bool) {
        notice = msg
        isError = error
    }
}
