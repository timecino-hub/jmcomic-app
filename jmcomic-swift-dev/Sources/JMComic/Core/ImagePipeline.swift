import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 图片下载 + 解重组。
///
/// 相比 Java 版少了整整一趟：Java 的 fetchImageBytes 是
/// 解码 → 重组 → **重新编码成 webp** → byte[]，调用方还要再解码一次；
/// webp 重编码在 Apple Silicon 上单页约 700ms，纯属浪费。
/// 这里全程在 CGImage 上操作，实测解码 9ms。
enum ImagePipeline {

    /// 系统 ImageIO 原生支持 webp，无需任何第三方库
    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 按禁漫的切块规则把乱序横条拼回原图。
    ///
    /// 与 Java 版 AwtImageProcessor 的切分一致：
    /// 第 0 块吃掉余数并取自原图底部，之后逐块向上。
    /// 注意 CoreGraphics 原点在左下角，所以目标 y 要翻转。
    static func descramble(_ image: CGImage, segments: Int) -> CGImage {
        guard segments > 0 else { return image }
        let width = image.width
        let height = image.height
        guard height >= segments else { return image }

        guard let ctx = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }

        let segmentHeight = height / segments
        let remainder = height % segments
        var currentY = 0

        for i in 0..<segments {
            var sliceHeight = segmentHeight
            let sourceY: Int
            if i == 0 {
                sliceHeight += remainder
                sourceY = height - sliceHeight
            } else {
                sourceY = height - (segmentHeight * (i + 1)) - remainder
            }
            guard let slice = image.cropping(to: CGRect(x: 0, y: sourceY,
                                                        width: width, height: sliceHeight))
            else { continue }
            // 翻转到 CoreGraphics 的左下原点坐标系
            ctx.draw(slice, in: CGRect(x: 0, y: height - currentY - sliceHeight,
                                       width: width, height: sliceHeight))
            currentY += sliceHeight
        }
        return ctx.makeImage() ?? image
    }

    /// 完整流程：字节 → 可显示的图
    static func process(_ data: Data, page: ComicPage) -> CGImage? {
        guard let decoded = decode(data) else { return nil }
        return descramble(decoded, segments: page.segmentCount)
    }
}
