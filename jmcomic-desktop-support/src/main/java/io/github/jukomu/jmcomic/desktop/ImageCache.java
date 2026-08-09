package io.github.jukomu.jmcomic.desktop;

import javax.swing.SwingUtilities;
import java.awt.image.BufferedImage;
import java.util.HashSet;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.function.Consumer;

/**
 * @author JUKOMU
 * @Description: 异步图片加载器 + 按字节预算淘汰的 LRU 缓存。
 * <p>
 * 封面和漫画页共用一份缓存。同一 key 的并发请求会合并，只发一次网络请求。
 * 解码后的回调统一在 EDT 上触发，调用方不需要自己切线程。
 * @Project: jmcomic-api-java
 * @Date: 2026/8/9
 */
final class ImageCache {

    /**
     * 缓存的是解码后的 BufferedImage，一张漫画页解码后可达 10MB 以上，
     * 所以按估算字节数而不是条目数来限制。
     */
    private final long budgetBytes;
    private long usedBytes;

    private final Map<String, BufferedImage> cache = new LinkedHashMap<>(64, 0.75f, true);
    private final Set<String> inFlight = new HashSet<>();
    private final ExecutorService pool;

    ImageCache(long budgetBytes, int threads) {
        this.budgetBytes = budgetBytes;
        this.pool = Executors.newFixedThreadPool(threads, r -> {
            Thread t = new Thread(r, "jm-image-loader");
            // 守护线程，窗口关掉后不阻止 JVM 退出
            t.setDaemon(true);
            return t;
        });
    }

    /**
     * 同步取缓存，不触发加载。渲染器每次绘制都会调，必须够快。
     *
     * @param key 缓存键（一般是图片 URL）
     * @return 命中的图片，未命中返回 null
     */
    synchronized BufferedImage peek(String key) {
        return cache.get(key);
    }

    /**
     * 异步加载图片。已缓存则立即回调；已在加载中则丢弃这次请求，
     * 等第一次的回调统一刷新（渲染器会重绘，拿得到结果）。
     *
     * @param key      缓存键
     * @param loader   实际产出图片的动作，在后台线程执行
     * @param onLoaded 加载完成回调，在 EDT 执行；失败时传 null
     */
    void load(String key, Loader loader, Consumer<BufferedImage> onLoaded) {
        BufferedImage hit;
        synchronized (this) {
            hit = cache.get(key);
            if (hit == null) {
                if (inFlight.contains(key)) {
                    return;
                }
                inFlight.add(key);
            }
        }
        if (hit != null) {
            SwingUtilities.invokeLater(() -> onLoaded.accept(hit));
            return;
        }

        pool.submit(() -> {
            BufferedImage img = null;
            try {
                img = loader.load();
            } catch (Exception ignored) {
                // 单张图失败不影响其他图，交给调用方展示占位
            }
            final BufferedImage result = img;
            synchronized (this) {
                inFlight.remove(key);
                if (result != null) {
                    put(key, result);
                }
            }
            SwingUtilities.invokeLater(() -> onLoaded.accept(result));
        });
    }

    private void put(String key, BufferedImage img) {
        long size = estimate(img);
        // 单张就超预算的图不进缓存，否则会把缓存清空还装不下
        if (size > budgetBytes) {
            return;
        }
        BufferedImage old = cache.put(key, img);
        if (old != null) {
            usedBytes -= estimate(old);
        }
        usedBytes += size;

        Iterator<Map.Entry<String, BufferedImage>> it = cache.entrySet().iterator();
        while (usedBytes > budgetBytes && it.hasNext()) {
            Map.Entry<String, BufferedImage> eldest = it.next();
            if (eldest.getKey().equals(key)) {
                continue;
            }
            usedBytes -= estimate(eldest.getValue());
            it.remove();
        }
    }

    private static long estimate(BufferedImage img) {
        return (long) img.getWidth() * img.getHeight() * 4;
    }

    synchronized void clear() {
        cache.clear();
        usedBytes = 0;
    }

    void shutdown() {
        pool.shutdownNow();
    }

    /**
     * 产出一张解码后图片的动作，允许抛异常。
     * <p>
     * 刻意返回 BufferedImage 而不是 byte[]：漫画页的 webp 重编码在 Apple Silicon 上
     * 约需 700ms，只为显示而编码再解码纯属浪费，直接传解码后的图省掉这一趟。
     */
    @FunctionalInterface
    interface Loader {
        BufferedImage load() throws Exception;
    }
}
