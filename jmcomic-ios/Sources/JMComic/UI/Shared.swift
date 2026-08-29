import SwiftUI
import UIKit
import CoreGraphics

/// 根视图按当前窗口形态给 iPad 指定稳定列数；iPhone / 紧凑窗口保留自适应列数。
private struct JMAlbumGridColumnCountKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

private struct JMLargePadLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var jmAlbumGridColumnCount: Int? {
        get { self[JMAlbumGridColumnCountKey.self] }
        set { self[JMAlbumGridColumnCountKey.self] = newValue }
    }

    var jmUsesLargePadLayout: Bool {
        get { self[JMLargePadLayoutKey.self] }
        set { self[JMLargePadLayoutKey.self] = newValue }
    }
}

/// iPhone / 11 英寸 / 13 英寸 iPad 共用的响应式尺寸策略。
///
/// 11 与 13 英寸保持相同信息密度：默认竖屏 4 列 / 横屏 5 列，13 英寸用额外空间
/// 放大封面而不是增加列数。阅读器按窗口短边选择宽度档位，同时覆盖分屏和台前调度窗口。
enum JMLayout {
    static let contentMaxWidth: CGFloat = 1120
    static let detailMaxWidth: CGFloat = 980
    static let readerToolbarMaxWidth: CGFloat = 980
    static let readerJumpBarMaxWidth: CGFloat = 760

    static let albumGridMinimumWidth: CGFloat = 160
    static let albumGridSpacing: CGFloat = 14
    static func albumGridColumns(count: Int?) -> [GridItem] {
        if let count {
            return Array(repeating: GridItem(.flexible(), spacing: albumGridSpacing), count: count)
        }
        return [GridItem(.adaptive(minimum: albumGridMinimumWidth), spacing: albumGridSpacing)]
    }

    /// 13 英寸 iPad 的全屏短边约为 1024 pt；安全区变化后仍明显大于 11 英寸的约 820–834 pt。
    /// 窗口短边达到 960 pt 时启用 1024 pt 上限，否则维持 11 英寸验证过的 900 pt 上限。
    static func readerContinuousWidth(for viewport: CGSize) -> CGFloat {
        let shortSide = min(viewport.width, viewport.height)
        let widthCap: CGFloat = shortSide >= 960 ? 1024 : 900
        return min(viewport.width, widthCap)
    }
}

extension View {
    /// 在宽屏中居中并限制内容行长；窄屏下等同于原来的全宽布局。
    func jmCentered(maxWidth: CGFloat = JMLayout.contentMaxWidth,
                    alignment: Alignment = .center) -> some View {
        frame(maxWidth: maxWidth, alignment: alignment)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// 路由：各 tab 的 NavigationStack 共用的推入目标。
/// album 是详情页；后三个是浏览 tab 的二级页（Mac 版侧栏项 → 推入式导航）。
enum Route: Hashable {
    case album(AlbumMeta)
    case categories      // 分类筛选
    case personalized    // 为你推荐
    case recent          // 最近浏览
}

/// 全局偏好读取（断点续读开关等真实设置项，见 SettingsView）。
enum AppPrefs {
    /// 断点续读开关：关闭后阅读器不恢复上次页码。默认开启。
    static var resumeReadingEnabled: Bool {
        UserDefaults.standard.object(forKey: "resumeReadingEnabled") as? Bool ?? true
    }
    /// 读完自动接下一话：停在本话最后一页片刻后自动切章。默认关闭。
    static var autoNextChapterEnabled: Bool {
        UserDefaults.standard.object(forKey: "readerAutoNext") as? Bool ?? false
    }
}

extension Color {
    /// 灰度便捷初始化（iOS 下无 Color(white:) 的稳定版本保证，用 UIColor 兜底）
    init(intensity v: Double) {
        self = Color(UIColor(white: CGFloat(v), alpha: 1))
    }
}

/// 封面（固定宽高比 3:4）。加载失败时显示占位图标而不是永远转圈。
struct CoverImage: View {
    let albumId: String
    var width: CGFloat = 132

    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1.0).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Color(intensity: 0.16))
                    .overlay {
                        if failed {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
            }
        }
        .frame(width: width, height: width * 4 / 3)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: albumId) {
            let img = await ImageStore.shared.cover(albumId: albumId)
            await MainActor.run {
                self.image = img
                self.failed = (img == nil)
            }
        }
    }
}

/// 网格里的专辑卡片：封面宽度自适应列宽（iPhone 两列），不再是 Mac 版固定 150pt。
struct AlbumCard: View {
    let meta: AlbumMeta
    /// 底部附加信息行（本地库显示「N 话 · N 页」用）
    var footer: String? = nil

    @Environment(\.jmUsesLargePadLayout) private var usesLargePadLayout
    @State private var image: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: usesLargePadLayout ? 8 : 6) {
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1.0)
                        .resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Color(intensity: 0.16))
                        .overlay { ProgressView().controlSize(.small) }
                }
            }
            // 宽度撑满列、比例固定 3:4：两列网格随屏宽自适应
            .aspectRatio(3 / 4, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: usesLargePadLayout ? 10 : 8))

            Text(meta.title)
                .font(usesLargePadLayout ? .callout : .footnote)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let footer {
                Text(footer)
                    .font(usesLargePadLayout ? .footnote : .caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(meta.authorText)
                    .font(usesLargePadLayout ? .footnote : .caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: meta.id) {
            image = await ImageStore.shared.cover(albumId: meta.id)
        }
    }
}

/// 标签自动换行（胶囊样式）。可传点击回调（分类页点标签用）。
struct FlowTags: View {
    let tags: [String]
    var onTap: ((String) -> Void)? = nil

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 6, alignment: .leading)],
                  alignment: .leading, spacing: 6) {
            ForEach(tags, id: \.self) { t in
                if let onTap {
                    Button { onTap(t) } label: { tagView(t) }
                        .buttonStyle(.plain)
                } else {
                    tagView(t)
                }
            }
        }
    }

    private func tagView(_ t: String) -> some View {
        Text(t).font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Color.primary.opacity(0.08))
            .foregroundStyle(.secondary)
            .clipShape(Capsule())
    }
}
