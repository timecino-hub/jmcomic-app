package io.github.jukomu.jmcomic.desktop;

import io.github.jukomu.jmcomic.api.model.JmImage;
import io.github.jukomu.jmcomic.core.client.impl.JmApiClient;
import io.github.jukomu.jmcomic.core.crypto.JmImageTool;

import javax.imageio.ImageIO;
import java.awt.Graphics2D;
import java.awt.image.BufferedImage;
import java.io.ByteArrayInputStream;

/**
 * @author JUKOMU
 * @Description: 图片获取与重组。
 * <p>
 * 刻意不走 client.fetchImageBytes()：那条路是 解码 → 重组 → 重新编码成 webp → byte[]，
 * 调用方为了显示还得再解码一次。Apple Silicon 上实测单页约 1230ms，其中 webp 重编码占大头。
 * 这里直接取原始字节、只解码一次、在内存里重组成 BufferedImage，实测约 275ms。
 * <p>
 * 下载走的仍然是 core 的 fetchImageBytes，因为那里确实需要可写入磁盘的编码字节。
 * @Project: jmcomic-api-java
 * @Date: 2026/8/9
 */
final class JmImages {

    private JmImages() {
    }

    /**
     * 拉取并重组一张漫画页。
     *
     * @param client 已就绪的 API 客户端
     * @param image  页面元数据
     * @return 可直接绘制的图片
     */
    static BufferedImage loadPage(JmApiClient client, JmImage image) throws Exception {
        byte[] raw = client.executeRequest(new okhttp3.Request.Builder()
                .url(image.getDownloadUrl()).get().build()).getContent();
        BufferedImage src = ImageIO.read(new ByteArrayInputStream(raw));
        if (src == null) {
            throw new IllegalStateException("无法解码图片: " + image.getTag());
        }
        // GIF 未经禁漫加密，无需重组
        if (image.isGif()) {
            return src;
        }
        return descramble(src, image);
    }

    /**
     * 拉取一张封面。封面不经过加密，解码即可。
     */
    static BufferedImage loadCover(JmApiClient client, String albumId) throws Exception {
        String url = client.getAlbumCoverUrl(albumId, "_3x4");
        byte[] raw = client.executeRequest(new okhttp3.Request.Builder()
                .url(url).get().build()).getContent();
        return ImageIO.read(new ByteArrayInputStream(raw));
    }

    /**
     * 按禁漫的切块算法把乱序的横条重新拼回原图。
     * 算法与 core 的 AwtImageProcessor 一致，区别只是全程在内存里操作 BufferedImage。
     */
    private static BufferedImage descramble(BufferedImage src, JmImage image) {
        int numSegments = JmImageTool.calculateNumSegments(
                Long.parseLong(image.scrambleId()),
                Long.parseLong(image.photoId()),
                image.getFilenameWithoutSuffix());
        int width = src.getWidth();
        int height = src.getHeight();
        if (numSegments == 0 || height < numSegments) {
            return src;
        }

        int type = src.getType() == BufferedImage.TYPE_CUSTOM
                ? BufferedImage.TYPE_INT_RGB : src.getType();
        BufferedImage out = new BufferedImage(width, height, type);
        Graphics2D g = out.createGraphics();

        int segmentHeight = height / numSegments;
        int remainder = height % numSegments;
        int currentY = 0;
        for (int i = 0; i < numSegments; i++) {
            int hSrc = segmentHeight;
            int ySrc;
            if (i == 0) {
                hSrc += remainder;
                ySrc = height - hSrc;
            } else {
                ySrc = height - (segmentHeight * (i + 1)) - remainder;
            }
            // 直接按源/目标矩形拷贝，避免 getSubimage 产生额外的共享栅格对象
            g.drawImage(src,
                    0, currentY, width, currentY + hSrc,
                    0, ySrc, width, ySrc + hSrc, null);
            currentY += hSrc;
        }
        g.dispose();
        return out;
    }
}
