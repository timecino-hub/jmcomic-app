package io.github.jukomu.jmcomic.desktop;

import io.github.jukomu.jmcomic.api.model.JmAlbumMeta;

import javax.swing.DefaultListModel;
import javax.swing.JComponent;
import javax.swing.JLabel;
import javax.swing.JList;
import javax.swing.JPanel;
import javax.swing.JScrollPane;
import javax.swing.ListCellRenderer;
import javax.swing.ListSelectionModel;
import javax.swing.ScrollPaneConstants;
import javax.swing.SwingUtilities;
import javax.swing.UIManager;
import java.awt.BorderLayout;
import java.awt.Color;
import java.awt.Dimension;
import java.awt.Graphics;
import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.event.KeyAdapter;
import java.awt.event.KeyEvent;
import java.awt.event.MouseAdapter;
import java.awt.event.MouseEvent;
import java.awt.image.BufferedImage;
import java.util.List;
import java.util.function.Consumer;

/**
 * @author JUKOMU
 * @Description: 封面网格墙。用 JList 的 HORIZONTAL_WRAP 实现自动换行网格，
 * 只渲染可见单元格，封面按需懒加载，滚动到底自动加载下一页。
 * <p>
 * 关键交互约定：选中不触发任何网络请求，只有点击/回车才打开详情，
 * 这样键盘浏览列表不会打出一串请求。
 * @Project: jmcomic-api-java
 * @Date: 2026/8/9
 */
final class BrowseView extends JPanel {

    /**
     * 一页数据源。分页信息由实现方自己算好。
     */
    interface Source {
        String title();

        Page load(int page) throws Exception;
    }

    record Page(List<JmAlbumMeta> items, boolean hasMore) {
    }

    private final ImageCache covers;
    private final CoverFetcher coverFetcher;
    private final Consumer<JmAlbumMeta> onOpen;
    private final Consumer<String> onStatus;

    private final DefaultListModel<JmAlbumMeta> model = new DefaultListModel<>();
    private final JList<JmAlbumMeta> grid = new JList<>(model);
    private final JScrollPane scroll;
    private final JLabel emptyHint = Ui.secondaryLabel("", Ui.FONT_BODY);

    private Source source;
    private int loadedPage;
    private boolean hasMore;
    private boolean loading;

    /**
     * 已展示的本子 id，用于跨页去重。
     */
    private final java.util.Set<String> seenIds = new java.util.HashSet<>();

    /**
     * 请求代次。切换数据源或重新搜索时自增，
     * 迟到的旧响应会被丢弃，避免结果串台。
     */
    private int generation;

    @FunctionalInterface
    interface CoverFetcher {
        java.awt.image.BufferedImage fetch(String albumId) throws Exception;
    }

    BrowseView(ImageCache covers, CoverFetcher coverFetcher,
               Consumer<JmAlbumMeta> onOpen, Consumer<String> onStatus) {
        super(new BorderLayout());
        this.covers = covers;
        this.coverFetcher = coverFetcher;
        this.onOpen = onOpen;
        this.onStatus = onStatus;

        grid.setLayoutOrientation(JList.HORIZONTAL_WRAP);
        // -1 表示按容器宽度自动决定每行个数，窗口缩放时自动重排
        grid.setVisibleRowCount(-1);
        grid.setFixedCellWidth(Ui.CARD_W);
        grid.setFixedCellHeight(Ui.CARD_H);
        grid.setSelectionMode(ListSelectionModel.SINGLE_SELECTION);
        grid.setCellRenderer(new CardRenderer());
        grid.setBorder(Ui.pad(Ui.S3));
        grid.setOpaque(false);

        grid.addMouseListener(new MouseAdapter() {
            @Override
            public void mouseClicked(MouseEvent e) {
                int idx = grid.locationToIndex(e.getPoint());
                if (idx < 0) {
                    return;
                }
                // locationToIndex 会返回最近的格子，即使点在空白区，需要命中校验
                if (!grid.getCellBounds(idx, idx).contains(e.getPoint())) {
                    return;
                }
                grid.setSelectedIndex(idx);
                onOpen.accept(model.get(idx));
            }
        });
        grid.addKeyListener(new KeyAdapter() {
            @Override
            public void keyPressed(KeyEvent e) {
                if (e.getKeyCode() == KeyEvent.VK_ENTER) {
                    JmAlbumMeta sel = grid.getSelectedValue();
                    if (sel != null) {
                        onOpen.accept(sel);
                    }
                }
            }
        });

        scroll = new JScrollPane(grid);
        scroll.setBorder(null);
        scroll.setHorizontalScrollBarPolicy(ScrollPaneConstants.HORIZONTAL_SCROLLBAR_NEVER);
        scroll.getVerticalScrollBar().setUnitIncrement(24);
        scroll.getVerticalScrollBar().addAdjustmentListener(e -> maybeLoadMore());

        JPanel emptyWrap = new JPanel(new BorderLayout());
        emptyWrap.setBorder(Ui.pad(Ui.S5));
        emptyWrap.add(emptyHint, BorderLayout.NORTH);

        add(scroll, BorderLayout.CENTER);
        add(emptyWrap, BorderLayout.NORTH);
        emptyWrap.setVisible(false);
    }

    /**
     * 换数据源并从第一页开始加载。
     */
    void setSource(Source newSource) {
        this.source = newSource;
        this.generation++;
        this.loadedPage = 0;
        this.hasMore = true;
        this.loading = false;
        model.clear();
        seenIds.clear();
        scroll.getVerticalScrollBar().setValue(0);
        loadNextPage();
    }

    private void maybeLoadMore() {
        var bar = scroll.getVerticalScrollBar();
        boolean nearBottom = bar.getValue() + bar.getVisibleAmount() >= bar.getMaximum() - Ui.CARD_H;
        if (nearBottom) {
            loadNextPage();
        }
    }

    private void loadNextPage() {
        if (loading || !hasMore || source == null) {
            return;
        }
        loading = true;
        final int gen = generation;
        final int page = loadedPage + 1;
        onStatus.accept(page == 1 ? "正在加载 " + source.title() + "…" : "加载第 " + page + " 页…");

        new Thread(() -> {
            try {
                Page result = source.load(page);
                SwingUtilities.invokeLater(() -> {
                    if (gen != generation) {
                        return;
                    }
                    // 推荐分区之间会有重复本子，按 id 去重，避免同一本出现多次
                    for (JmAlbumMeta item : result.items()) {
                        if (seenIds.add(item.getId())) {
                            model.addElement(item);
                        }
                    }
                    loadedPage = page;
                    hasMore = result.hasMore();
                    loading = false;
                    onStatus.accept(source.title() + " · 已加载 " + model.size() + " 项");
                    updateEmptyHint(null);
                    // 首页内容没铺满视口时继续补下一页，否则用户没得可滚，永远触发不了加载
                    if (hasMore && grid.getPreferredSize().height <= scroll.getViewport().getHeight()) {
                        loadNextPage();
                    }
                });
            } catch (Exception ex) {
                SwingUtilities.invokeLater(() -> {
                    if (gen != generation) {
                        return;
                    }
                    loading = false;
                    hasMore = false;
                    onStatus.accept("加载失败：" + ex.getMessage());
                    updateEmptyHint(ex.getMessage());
                });
            }
        }, "jm-browse-load").start();
    }

    private void updateEmptyHint(String error) {
        boolean empty = model.isEmpty();
        emptyHint.getParent().setVisible(empty);
        if (empty) {
            emptyHint.setText(error != null
                    ? "加载失败：" + error + "　（可在设置里配置代理后重试）"
                    : "没有结果");
        }
    }

    /**
     * 封面卡片渲染器。复用同一个组件实例，直接在 paintComponent 里画，
     * 避免每次绘制都 new 一堆 JLabel。
     */
    private final class CardRenderer extends JComponent implements ListCellRenderer<JmAlbumMeta> {

        private JmAlbumMeta value;
        private boolean selected;

        @Override
        public JComponent getListCellRendererComponent(JList<? extends JmAlbumMeta> list, JmAlbumMeta v,
                                                       int index, boolean isSelected, boolean cellHasFocus) {
            this.value = v;
            this.selected = isSelected;
            setPreferredSize(new Dimension(Ui.CARD_W, Ui.CARD_H));
            return this;
        }

        @Override
        protected void paintComponent(Graphics g) {
            if (value == null) {
                return;
            }
            Graphics2D g2 = (Graphics2D) g.create();
            g2.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
            g2.setRenderingHint(RenderingHints.KEY_INTERPOLATION, RenderingHints.VALUE_INTERPOLATION_BILINEAR);

            int w = getWidth();
            int h = getHeight();

            if (selected) {
                g2.setColor(UIManager.getColor("List.selectionBackground"));
                g2.fillRoundRect(0, 0, w, h, Ui.RADIUS + 4, Ui.RADIUS + 4);
            }

            int coverX = (w - Ui.COVER_W) / 2;
            int coverY = Ui.S2;
            BufferedImage img = coverOf(value);
            if (img != null) {
                java.awt.Shape clip = g2.getClip();
                g2.setClip(new java.awt.geom.RoundRectangle2D.Float(
                        coverX, coverY, Ui.COVER_W, Ui.COVER_H, Ui.RADIUS, Ui.RADIUS));
                drawCoverFit(g2, img, coverX, coverY, Ui.COVER_W, Ui.COVER_H);
                g2.setClip(clip);
            } else {
                g2.setColor(Ui.skeleton());
                g2.fillRoundRect(coverX, coverY, Ui.COVER_W, Ui.COVER_H, Ui.RADIUS, Ui.RADIUS);
            }

            int textX = coverX;
            int textW = Ui.COVER_W;
            int y = coverY + Ui.COVER_H + Ui.S3;

            g2.setColor(selected
                    ? UIManager.getColor("List.selectionForeground")
                    : UIManager.getColor("List.foreground"));
            g2.setFont(Ui.font(Ui.FONT_CAPTION + 1, false));
            var fm = g2.getFontMetrics();
            // 标题最多两行
            String title = value.getTitle() == null ? "" : value.getTitle();
            String line1 = title;
            String line2 = "";
            if (fm.stringWidth(title) > textW) {
                int split = splitAt(fm, title, textW);
                line1 = title.substring(0, split);
                line2 = Ui.ellipsize(fm, title.substring(split), textW);
            }
            g2.drawString(line1, textX, y + fm.getAscent());
            if (!line2.isEmpty()) {
                g2.drawString(line2, textX, y + fm.getAscent() + fm.getHeight());
            }

            String author = value.getAuthors() == null || value.getAuthors().isEmpty()
                    ? "" : String.join(", ", value.getAuthors());
            if (!author.isEmpty()) {
                g2.setColor(selected
                        ? UIManager.getColor("List.selectionForeground")
                        : Ui.secondaryFg());
                g2.setFont(Ui.font(Ui.FONT_CAPTION, false));
                var fm2 = g2.getFontMetrics();
                int ay = y + fm.getHeight() * 2 + Ui.S1;
                g2.drawString(Ui.ellipsize(fm2, author, textW), textX, ay + fm2.getAscent());
            }
            g2.dispose();
        }

        private int splitAt(java.awt.FontMetrics fm, String text, int maxWidth) {
            int width = 0;
            for (int i = 0; i < text.length(); i++) {
                width += fm.charWidth(text.charAt(i));
                if (width > maxWidth) {
                    return Math.max(1, i);
                }
            }
            return text.length();
        }

        /**
         * 等比缩放并居中裁切，填满封面框（类似 CSS 的 object-fit: cover）。
         */
        private void drawCoverFit(Graphics2D g2, BufferedImage img, int x, int y, int w, int h) {
            double scale = Math.max((double) w / img.getWidth(), (double) h / img.getHeight());
            int dw = (int) Math.ceil(img.getWidth() * scale);
            int dh = (int) Math.ceil(img.getHeight() * scale);
            g2.drawImage(img, x + (w - dw) / 2, y + (h - dh) / 2, dw, dh, null);
        }

        @Override
        public Color getBackground() {
            return null;
        }
    }

    /**
     * 取封面缓存，未命中就发起一次加载，加载完重绘。
     * URL 构造放在后台线程里做，因为它可能等待域名探活完成。
     */
    private BufferedImage coverOf(JmAlbumMeta meta) {
        String key = "cover:" + meta.getId();
        BufferedImage hit = covers.peek(key);
        if (hit != null) {
            return hit;
        }
        covers.load(key, () -> coverFetcher.fetch(meta.getId()), img -> {
            if (img != null) {
                grid.repaint();
            }
        });
        return null;
    }
}
