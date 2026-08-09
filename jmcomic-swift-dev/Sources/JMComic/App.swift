import SwiftUI
import AppKit

@main
struct JMComicApp: App {
    init() {
        if CommandLine.arguments.contains("--selfcheck") { SelfCheck.run() }        // 无界面启动 web 服务，供本机验证与「当后台服务跑」两种用法
        // 用法：JMComicDev --webserve <密码> [--port <n>] [--https]
        if let i = CommandLine.arguments.firstIndex(of: "--webserve"),
           i + 1 < CommandLine.arguments.count {
            let pw = CommandLine.arguments[i + 1]
            if let pi = CommandLine.arguments.firstIndex(of: "--port"),
               pi + 1 < CommandLine.arguments.count,
               let p = UInt16(CommandLine.arguments[pi + 1]) {
                WebService.shared.port = p
            }
            if CommandLine.arguments.contains("--https") {
                WebService.shared.useHTTPS = true
            }
            Concurrency.detached {
                await WebAuth.shared.setPassword(pw)
                await MainActor.run {
                    WebService.shared.start()
                    let addrs = WebService.shared.addresses.joined(separator: ", ")
                    FileHandle.standardError.write(Data(
                        "web 服务已启动 scheme=\(WebService.shared.scheme) port=\(WebService.shared.port) 地址=[\(addrs)]\n".utf8))
                }
                // 打印当前入场 token，方便命令行验证完整流程
                let t = await WebAuth.shared.currentBootToken
                FileHandle.standardError.write(Data(
                    "入场 token=\(t)（一次性，每次使用后自动更换）\n".utf8))
                await JmClient.shared.bootstrap()
            }
        }
        // 隐私保护快捷键：设置页录制，这里全局监听，命中即最小化窗口
        installPrivacyShortcut()
        // GitHub 同步：配置过仓库才执行（后台，不阻塞启动）
        Concurrency.detached {
            await SyncStore.shared.sync()
        }
        NSApplication.shared.setActivationPolicy(.regular)
    }

    /// 全局 keyDown 监听。命中设置的组合键时最小化主窗口并吞掉事件。
    private func installPrivacyShortcut() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            let d = UserDefaults.standard
            guard d.bool(forKey: "privacyShortcutEnabled") else { return ev }
            let kc = d.integer(forKey: "privacyShortcutKeyCode")
            guard ev.keyCode == kc else { return ev }
            let mods = UInt(d.integer(forKey: "privacyShortcutModifiers"))
            guard ev.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue == mods
            else { return ev }
            NSApp.keyWindow?.miniaturize(nil)
            return nil
        }
    }

    var body: some Scene {
        WindowGroup("JMComic") {
            BrowseView()
                .frame(minWidth: 900, minHeight: 620)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                    Task { await JmClient.shared.bootstrap() }
                }
        }
        .defaultSize(width: 1200, height: 820)
        .windowToolbarStyle(.unified)
    }
}
