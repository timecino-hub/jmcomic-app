import SwiftUI
import AVFoundation
import UIKit
import Vision

// MARK: - 二维码配对扫描页
//
// AVCaptureSession + AVCaptureVideoDataOutput + Vision(VNDetectBarcodesRequest, .qr)
// 识别 Mac 端「iPhone 同步」面板的配置串（jmsync|v1|<ip>|<port>|<pairCode>），
// 识别成功回调 onFound。
// 注：iOS 17.4+ 上 AVCaptureMetadataOutput 回调不再触发（Apple 已知回归），
// 故改用 Vision 在视频帧上做条码识别。
// 相机不可用（模拟器 / 权限被拒）时降级为引导文案 + 手动输入表单。

struct PairingScannerView: View {

    /// 识别出原始配置串后回调（解析与配对由父级处理）
    let onFound: (String) -> Void

    @StateObject private var scanner = ScannerModel()
    @State private var showManual = false

    var body: some View {
        VStack(spacing: 0) {
            switch scanner.state {
            case .running:
                CameraPreview(session: scanner.session)
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .center) {
                        reticle
                    }
                    .overlay(alignment: .bottom) {
                        Text("对准 Mac 端「iPhone 同步」面板的二维码")
                            .font(.footnote)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 24)
                    }
            case .denied:
                permissionDenied
            case .unavailable:
                unavailable
            }

            manualSection
        }
        .navigationTitle("扫码配对")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            scanner.start(onFound: onFound)
        }
        .onDisappear {
            scanner.stop()
        }
    }

    // 取景框
    private var reticle: some View {
        RoundedRectangle(cornerRadius: 14)
            .stroke(Color.white.opacity(0.9), lineWidth: 3)
            .frame(width: 240, height: 240)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.clear))
            .shadow(radius: 2)
    }

    // 相机权限被拒：引导去系统设置
    private var permissionDenied: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("相机权限被拒绝")
                .font(.headline)
            Text("请在 系统设置 → JMComic → 相机 中允许访问后重试；\n也可以直接在下方手动输入 Mac 显示的配对信息。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("打开系统设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // 无相机（模拟器）
    private var unavailable: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.on.rectangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("当前设备没有可用相机（如模拟器）")
                .font(.headline)
            Text("请在下方手动输入 Mac 端显示的 IP、端口与配对码，\n或直接粘贴完整配置串。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // 底部手动输入回退（始终可见，收起为一行入口）
    private var manualSection: some View {
        VStack(spacing: 8) {
            Button {
                showManual.toggle()
            } label: {
                Label(showManual ? "收起手动输入" : "无法扫码？手动输入",
                      systemImage: "keyboard")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if showManual {
                // 手动提交后转回标准配置串，与扫码结果走同一条配对链路
                ManualPairForm { cfg in
                    onFound("jmsync|v1|\(cfg.host)|\(cfg.port)|\(cfg.pairCode)")
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .background(.bar)
    }
}

// MARK: - 相机预览层包装

private struct CameraPreview: UIViewRepresentable {

    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

// MARK: - 扫描会话模型

@MainActor
final class ScannerModel: NSObject, ObservableObject {

    enum State { case running, denied, unavailable }

    @Published private(set) var state: State = .running

    let session = AVCaptureSession()
    private var configured = false
    private var onFound: ((String) -> Void)?
    private let videoQueue = DispatchQueue(label: "local.jmcomic-ios.scanner.video")
    private var sampleBridge: SampleBufferBridge?

    nonisolated func start(onFound: @escaping (String) -> Void) {
        Task { @MainActor in
            self.onFound = onFound
            await self.begin()
        }
    }

    nonisolated func stop() {
        Task { @MainActor in
            self.session.stopRunning()
        }
    }

    private func begin() async {
        guard !configured else {
            session.startRunning()
            return
        }

        // 权限：被拒时降级手动输入，不反复弹窗
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else { state = .denied; return }
        default:
            state = .denied
            return
        }

        // 模拟器等无相机环境
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else {
            state = .unavailable
            return
        }

        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            state = .unavailable
            return
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            state = .unavailable
            return
        }
        let bridge = SampleBufferBridge(model: self)
        sampleBridge = bridge
        output.setSampleBufferDelegate(bridge, queue: videoQueue)
        session.addOutput(output)
        session.commitConfiguration()

        configured = true
        // startRunning 是阻塞调用，放后台队列避免卡主线程
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.startRunning()
                cont.resume()
            }
        }
        if session.isRunning { state = .running }
    }

    /// 识别回调桥：同一个串只回调一次，防止连拍重复触发
    fileprivate func handleCode(_ text: String) {
        guard session.isRunning else { return }
        session.stopRunning()
        onFound?(text)
    }

    private final class SampleBufferBridge: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        // weak 持 model 避免循环强引用；model 由 ScannerModel 持有
        private weak var model: ScannerModel?
        // 串行节流标志：仅在 videoQueue（串行）上访问，无需加锁
        private var inFlight = false

        init(model: ScannerModel) { self.model = model }

        func captureOutput(_ output: AVCaptureOutput,
                           didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            // 上一帧 Vision 仍在处理则丢帧，避免逐帧排队造成卡顿
            guard !inFlight else { return }
            inFlight = true
            defer { inFlight = false }

            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            // 后置摄像头在 iPhone 竖屏下的传感器朝向为 .right
            let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .right)
            do {
                try handler.perform([request])
            } catch {
                return
            }
            guard let obs = request.results?.first,
                  let payload = obs.payloadStringValue, !payload.isEmpty
            else { return }
            // 结果回主线程交给 ScannerModel，复用单次防重逻辑
            Task { @MainActor [weak self] in
                self?.model?.handleCode(payload)
            }
        }
    }
}

// MARK: - 手动输入配对表单（扫码页与桌面同步页共用）
//
// 三栏输入（IP / 端口 / 配对码）或直接粘贴完整配置串；提交前做与服务端一致的严格校验。

struct ManualPairForm: View {

    /// 提交校验通过的配置串
    let onSubmit: (SyncConfig) -> Void

    @State private var host = ""
    @State private var port = ""
    @State private var pairCode = ""
    @State private var pasteError: String?

    private var config: SyncConfig? {
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty,
              let p = UInt16(port.trimmingCharacters(in: .whitespaces)), p > 0
        else { return nil }
        let code = pairCode.trimmingCharacters(in: .whitespaces).uppercased()
        guard code.count == 8,
              code.allSatisfy({ LanSyncClient.pairAlphabet.contains($0) })
        else { return nil }
        let parsed = LanSyncClient.parseConfig("jmsync|v1|\(host.trimmingCharacters(in: .whitespaces))|\(p)|\(code)")
        guard case .success(let cfg) = parsed else { return nil }
        return cfg
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("手动输入 Mac 端「iPhone 同步」面板显示的信息")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("IP 地址，如 192.168.1.8", text: $host)
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("端口", text: $port)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
            TextField("配对码（8 位大写字母数字）", text: $pairCode)
                .keyboardType(.asciiCapable)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)

            HStack {
                Button("粘贴配置串") {
                    pasteFromBoard()
                }
                .font(.caption)

                Spacer()

                Button {
                    if let cfg = config { onSubmit(cfg) }
                } label: {
                    Text("配对")
                        .frame(minWidth: 64)
                }
                .buttonStyle(.borderedProminent)
                .disabled(config == nil)
            }

            if let pasteError {
                Text(pasteError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// 从剪贴板读整串配置，识别成功直接填三栏（等价于粘贴后回车）
    private func pasteFromBoard() {
        let raw = UIPasteboard.general.string ?? ""
        switch LanSyncClient.parseConfig(raw) {
        case .success(let cfg):
            host = cfg.host
            port = String(cfg.port)
            pairCode = cfg.pairCode
            pasteError = nil
        case .failure(let err):
            pasteError = err.localizedDescription
        }
    }
}
