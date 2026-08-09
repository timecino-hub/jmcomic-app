package io.github.jukomu.jmcomic.desktop;

import io.github.jukomu.jmcomic.api.model.JmImage;
import io.github.jukomu.jmcomic.api.model.JmPhoto;

import javax.swing.JComponent;
import javax.swing.JScrollPane;
import javax.swing.Scrollable;
import javax.swing.SwingUtilities;
import java.awt.Color;
import java.awt.Dimension;
import java.awt.Graphics;
import java.awt.Graphics2D;
import java.awt.Rectangle;
import java.awt.RenderingHints;
import java.awt.image.BufferedImage;
import java.util.ArrayList;
import java.util.List;
import java.util.function.Consumer;

/**
 * @author JUKOMU
 * @Description: 连续竖向滚动的漫画画布。
 * <p>
 * 所有页首尾相接排成一列，只有进入视口附近的图才会被请求。
 * 未加载的图按占位高度参与布局，保证滚动条长度稳定、不会边滚边跳。
 * 滚到最后一页附近自动续上下一章。
 * @Project: jmcomic-api-java
 * @Date: 2026/8/9
 */
final class ReaderCanvas extends JComponent implements Scrollable {

    /**
     * 单页。图片未加载前用估算高度占位。
     */
    private static final class PageEntry {
        final JmImage image;
        final int chapterIndex;
        final int pageIndex;
        final int pageCount;
        int y;
        int height;
        boolean measured;
        boolean failed;

        PageEntry(JmImage image, int chapterIndex, int pageIndex, int pageCount) {
            this.image = image;
            this.chapterIndex = chapterIndex;
            this.pageIndex = pageIndex;
            this.pageCount = pageCount;
        }
    }

    /**
     * 漫画页通常比宽度高一些，未知高度时按 1.4 倍宽度占位，
     * 实际加载后会重新测量。
     */
    private static final double PLACEHOLDER_RATIO = 1.4;
    private static final int GAP = 2;

    /**
     * 视口外多远开始预加载。约一屏，够覆盖快速滚动。
     */
    private static final int PRELOAD_MARGIN = 900;

    private final ImageCache cache;
    private final PageFetcher fetcher;
    private final Consumer<String> onLocation;
    private final Runnable onNeedNextChapter;

    private final List<PageEntry> pages = new ArrayList<>();
    private final List<String> chapterTitles = new ArrayList<>();

    private int contentWidth = 800;
    private int maxContentWidth = 1000;
    private JScrollPane scrollPane;
    private boolean nextChapterRequested;

    @FunctionalInterface
    interface PageFetcher {
        BufferedImage fetch(JmImage image) throws Exception;
    }

    ReaderCanvas(ImageCache cache, PageFetcher fetcher,
                 Consumer<String> onLocation, Runnable onNeedNextChapter) {
        this.cache = cache;
        this.fetcher = fetcher;
        this.onLocation = onLocation;
        this.onNeedNextChapter = onNeedNextChapter;
        setBackground(new Color(0x1E1E1E));
        setOpaque(true);
        setDoubleBuffered(true);
    }

    void attach(JScrollPane pane) {
        this.scrollPane = pane;
        pane.getVerticalScrollBar().addAdjustmentListener(e -> {
            requestVisible();
            reportLocation();
        });
    }

    /**
     * 阅读区最大宽度。超宽窗口下限制正文宽度，两侧留黑边，
     * 否则图片被拉得过大反而难看。
     */
    void setMaxContentWidth(int w) {
        this.maxContentWidth = w;
        relayout();
    }

    void clear() {
        pages.clear();
        chapterTitles.clear();
        nextChapterRequested = false;
        relayout();
    }

    /**
     * 追加一章。已有内容保留，滚动位置不变，实现无缝续章。
     */
    void appendChapter(JmPhoto photo, String title) {
        int chapterIndex = chapterTitles.size();
        chapterTitles.add(title);
        List<JmImage> images = photo.getImages();
        for (int i = 0; i < images.size(); i++) {
            pages.add(new PageEntry(images.get(i), chapterIndex, i, images.size()));
        }
        nextChapterRequested = false;
        relayout();
        SwingUtilities.invokeLater(() -> {
            requestVisible();
            reportLocation();
        });
    }

    boolean isEmpty() {
        return pages.isEmpty();
    }

    private void relayout() {
        int viewW = scrollPane != null ? scrollPane.getViewport().getWidth() : getWidth();
        contentWidth = Math.max(320, Math.min(viewW > 0 ? viewW : maxContentWidth, maxContentWidth));

        int y = 0;
        for (PageEntry p : pages) {
            p.y = y;
            if (!p.measured) {
                p.height = (int) (contentWidth * PLACEHOLDER_RATIO);
            }
            y += p.height + GAP;
        }
        setPreferredSize(new Dimension(contentWidth, Math.max(y, 1)));
        revalidate();
        repaint();
    }

    @Override
    public void setBounds(int x, int y, int width, int height) {
        boolean widthChanged = width != getWidth();
        super.setBounds(x, y, width, height);
        if (widthChanged) {
            // 宽度变了，所有已测高度都作废，需要按新宽度重算
            for (PageEntry p : pages) {
                p.measured = false;
            }
            relayout();
        }
    }

    /**
     * 请求视口内及附近的图片。已缓存的直接测量，未缓存的发起加载。
     */
    private void requestVisible() {
        if (scrollPane == null || pages.isEmpty()) {
            return;
        }
        Rectangle view = scrollPane.getViewport().getViewRect();
        int from = view.y - PRELOAD_MARGIN;
        int to = view.y + view.height + PRELOAD_MARGIN;

        for (PageEntry p : pages) {
            if (p.y > to) {
                break;
            }
            if (p.y + p.height < from || p.failed) {
                continue;
            }
            String key = p.image.getDownloadUrl();
            BufferedImage img = cache.peek(key);
            if (img != null) {
                measure(p, img);
                continue;
            }
            cache.load(key, () -> fetcher.fetch(p.image), loaded -> {
                if (loaded == null) {
                    p.failed = true;
                    repaint();
                    return;
                }
                measure(p, loaded);
                repaint();
            });
        }

        // 接近末尾时预约下一章
        PageEntry last = pages.get(pages.size() - 1);
        if (!nextChapterRequested && view.y + view.height >= last.y - view.height) {
            nextChapterRequested = true;
            onNeedNextChapter.run();
        }
    }

    /**
     * 按实际图片比例更新该页高度。高度变了要重排后续页，
     * 并把视口锚定在当前页，避免上方页面变高把内容顶走。
     */
    private void measure(PageEntry p, BufferedImage img) {
        int newHeight = (int) Math.round((double) contentWidth * img.getHeight() / img.getWidth());
        if (p.measured && p.height == newHeight) {
            return;
        }
        int delta = newHeight - p.height;
        p.height = newHeight;
        p.measured = true;
        if (delta == 0) {
            return;
        }

        int idx = pages.indexOf(p);
        int y = p.y + p.height + GAP;
        for (int i = idx + 1; i < pages.size(); i++) {
            pages.get(i).y = y;
            y += pages.get(i).height + GAP;
        }
        setPreferredSize(new Dimension(contentWidth, Math.max(y, 1)));
        revalidate();

        // 变高的页在视口之上时，同步平移滚动位置，视觉上保持不动
        if (scrollPane != null) {
            Rectangle view = scrollPane.getViewport().getViewRect();
            if (p.y + p.height <= view.y) {
                var bar = scrollPane.getVerticalScrollBar();
                bar.setValue(bar.getValue() + delta);
            }
        }
    }

    private void reportLocation() {
        if (scrollPane == null || pages.isEmpty()) {
            return;
        }
        Rectangle view = scrollPane.getViewport().getViewRect();
        int center = view.y + view.height / 2;
        for (PageEntry p : pages) {
            if (center >= p.y && center < p.y + p.height + GAP) {
                String title = p.chapterIndex < chapterTitles.size()
                        ? chapterTitles.get(p.chapterIndex) : "";
                onLocation.accept(String.format("%s　%d / %d", title, p.pageIndex + 1, p.pageCount));
                return;
            }
        }
    }

    @Override
    protected void paintComponent(Graphics g) {
        Graphics2D g2 = (Graphics2D) g.create();
        g2.setColor(getBackground());
        g2.fillRect(0, 0, getWidth(), getHeight());
        g2.setRenderingHint(RenderingHints.KEY_INTERPOLATION, RenderingHints.VALUE_INTERPOLATION_BILINEAR);
        g2.setRenderingHint(RenderingHints.KEY_RENDERING, RenderingHints.VALUE_RENDER_QUALITY);

        Rectangle clip = g2.getClipBounds();
        int xOffset = (getWidth() - contentWidth) / 2;

        for (PageEntry p : pages) {
            if (p.y + p.height < clip.y) {
                continue;
            }
            if (p.y > clip.y + clip.height) {
                break;
            }
            BufferedImage img = p.failed ? null : cache.peek(p.image.getDownloadUrl());
            if (img != null) {
                g2.drawImage(img, xOffset, p.y, contentWidth, p.height, null);
            } else {
                g2.setColor(new Color(0x2A2A2A));
                g2.fillRect(xOffset, p.y, contentWidth, p.height);
                g2.setColor(new Color(0x808080));
                g2.setFont(Ui.font(Ui.FONT_BODY, false));
                String text = p.failed
                        ? "第 " + (p.pageIndex + 1) + " 页加载失败"
                        : "第 " + (p.pageIndex + 1) + " 页…";
                var fm = g2.getFontMetrics();
                g2.drawString(text,
                        xOffset + (contentWidth - fm.stringWidth(text)) / 2,
                        p.y + p.height / 2);
            }
        }
        g2.dispose();
    }

    // == Scrollable：让滚轮和滚动条按合理步长移动 ==

    @Override
    public Dimension getPreferredScrollableViewportSize() {
        return getPreferredSize();
    }

    @Override
    public int getScrollableUnitIncrement(Rectangle visibleRect, int orientation, int direction) {
        return 60;
    }

    @Override
    public int getScrollableBlockIncrement(Rectangle visibleRect, int orientation, int direction) {
        return visibleRect.height - 60;
    }

    @Override
    public boolean getScrollableTracksViewportWidth() {
        return true;
    }

    @Override
    public boolean getScrollableTracksViewportHeight() {
        return false;
    }
}
