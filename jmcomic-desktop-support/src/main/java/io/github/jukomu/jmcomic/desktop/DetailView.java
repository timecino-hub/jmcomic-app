package io.github.jukomu.jmcomic.desktop;

import io.github.jukomu.jmcomic.api.model.JmAlbum;
import io.github.jukomu.jmcomic.api.model.JmPhotoMeta;

import javax.swing.BorderFactory;
import javax.swing.Box;
import javax.swing.BoxLayout;
import javax.swing.DefaultListModel;
import javax.swing.JButton;
import javax.swing.JComponent;
import javax.swing.JLabel;
import javax.swing.JList;
import javax.swing.JPanel;
import javax.swing.JProgressBar;
import javax.swing.JScrollPane;
import javax.swing.JTextArea;
import javax.swing.ListCellRenderer;
import javax.swing.ListSelectionModel;
import javax.swing.SwingConstants;
import javax.swing.UIManager;
import java.awt.BorderLayout;
import java.awt.Color;
import java.awt.Component;
import java.awt.Dimension;
import java.awt.FlowLayout;
import java.awt.Graphics;
import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.event.MouseAdapter;
import java.awt.event.MouseEvent;
import java.awt.image.BufferedImage;
import java.util.function.BiConsumer;

/**
 * @author JUKOMU
 * @Description: 本子详情页。封面 + 元信息 + 操作区 + 章节列表 + 简介。
 * <p>
 * 章节行右侧有明确的「阅读」提示，单击即进入，不再依赖没有任何提示的双击。
 * @Project: jmcomic-api-java
 * @Date: 2026/8/9
 */
final class DetailView extends JPanel {

    private final ImageCache covers;
    private final BrowseView.CoverFetcher coverFetcher;

    private final JLabel coverLabel = new JLabel();
    private final JLabel titleLabel = Ui.label("", Ui.FONT_TITLE, true);
    private final JLabel authorLabel = Ui.secondaryLabel("", Ui.FONT_BODY);
    private final JLabel statsLabel = Ui.secondaryLabel("", Ui.FONT_CAPTION);
    private final JPanel tagPanel = new JPanel(new FlowLayout(FlowLayout.LEFT, Ui.S1, Ui.S1));
    private final JTextArea descArea = new JTextArea();

    private final DefaultListModel<JmPhotoMeta> chapterModel = new DefaultListModel<>();
    private final JList<JmPhotoMeta> chapterList = new JList<>(chapterModel);

    private final JButton readButton = new JButton("开始阅读");
    private final JButton downloadButton = new JButton("下载整本");
    private final JProgressBar progress = new JProgressBar();
    private final JLabel progressLabel = Ui.secondaryLabel(" ", Ui.FONT_CAPTION);

    private JmAlbum album;

    /**
     * @param onRead     打开阅读器，参数为本子和起始章节（章节可为 null 表示第一章）
     * @param onDownload 下载整本
     */
    DetailView(ImageCache covers, BrowseView.CoverFetcher coverFetcher,
               BiConsumer<JmAlbum, JmPhotoMeta> onRead, Runnable onDownload) {
        super(new BorderLayout());
        this.covers = covers;
        this.coverFetcher = coverFetcher;

        // == 头部：封面 + 标题 + 元信息 + 操作 ==
        coverLabel.setPreferredSize(new Dimension(180, 240));
        coverLabel.setHorizontalAlignment(SwingConstants.CENTER);
        coverLabel.setOpaque(true);
        coverLabel.setBackground(Ui.skeleton());
        coverLabel.setBorder(BorderFactory.createLineBorder(Ui.separator()));

        readButton.addActionListener(e -> onRead.accept(album, chapterList.getSelectedValue()));
        downloadButton.addActionListener(e -> onDownload.run());
        readButton.putClientProperty("JButton.buttonType", "roundRect");
        downloadButton.putClientProperty("JButton.buttonType", "roundRect");

        JPanel actions = new JPanel(new FlowLayout(FlowLayout.LEFT, Ui.S2, 0));
        actions.setOpaque(false);
        actions.add(readButton);
        actions.add(downloadButton);

        progress.setStringPainted(true);
        progress.setVisible(false);
        progress.setPreferredSize(new Dimension(320, 18));

        tagPanel.setOpaque(false);

        JPanel info = new JPanel();
        info.setOpaque(false);
        info.setLayout(new BoxLayout(info, BoxLayout.Y_AXIS));
        info.add(leftAligned(titleLabel));
        info.add(Box.createVerticalStrut(Ui.S2));
        info.add(leftAligned(authorLabel));
        info.add(Box.createVerticalStrut(Ui.S1));
        info.add(leftAligned(statsLabel));
        info.add(Box.createVerticalStrut(Ui.S3));
        info.add(leftAligned(tagPanel));
        info.add(Box.createVerticalGlue());
        info.add(leftAligned(actions));
        info.add(Box.createVerticalStrut(Ui.S2));
        info.add(leftAligned(progress));
        info.add(leftAligned(progressLabel));

        JPanel header = new JPanel(new BorderLayout(Ui.S5, 0));
        header.setOpaque(false);
        header.setBorder(Ui.pad(Ui.S5, Ui.S5, Ui.S4, Ui.S5));
        header.add(coverLabel, BorderLayout.WEST);
        header.add(info, BorderLayout.CENTER);

        // == 章节列表 ==
        chapterList.setSelectionMode(ListSelectionModel.SINGLE_SELECTION);
        chapterList.setCellRenderer(new ChapterRenderer());
        chapterList.setFixedCellHeight(40);
        chapterList.addMouseListener(new MouseAdapter() {
            @Override
            public void mouseClicked(MouseEvent e) {
                int idx = chapterList.locationToIndex(e.getPoint());
                if (idx < 0 || !chapterList.getCellBounds(idx, idx).contains(e.getPoint())) {
                    return;
                }
                chapterList.setSelectedIndex(idx);
                onRead.accept(album, chapterModel.get(idx));
            }
        });

        JLabel chapterTitle = Ui.label("章节", Ui.FONT_SUBTITLE, true);
        chapterTitle.setBorder(Ui.pad(0, 0, Ui.S2, 0));

        JPanel chapters = new JPanel(new BorderLayout());
        chapters.setOpaque(false);
        chapters.setBorder(Ui.pad(0, Ui.S5, Ui.S4, Ui.S5));
        chapters.add(chapterTitle, BorderLayout.NORTH);
        JScrollPane chapterScroll = new JScrollPane(chapterList);
        chapterScroll.setBorder(BorderFactory.createLineBorder(Ui.separator()));
        chapterScroll.getVerticalScrollBar().setUnitIncrement(20);
        chapters.add(chapterScroll, BorderLayout.CENTER);

        // == 简介 ==
        descArea.setEditable(false);
        descArea.setLineWrap(true);
        descArea.setWrapStyleWord(true);
        descArea.setOpaque(false);
        descArea.setFont(Ui.font(Ui.FONT_BODY, false));
        descArea.setBorder(Ui.pad(Ui.S2, 0, 0, 0));

        JPanel desc = new JPanel(new BorderLayout());
        desc.setOpaque(false);
        desc.setBorder(Ui.pad(0, Ui.S5, Ui.S5, Ui.S5));
        desc.add(Ui.label("简介", Ui.FONT_SUBTITLE, true), BorderLayout.NORTH);
        JScrollPane descScroll = new JScrollPane(descArea);
        descScroll.setBorder(null);
        descScroll.setOpaque(false);
        descScroll.getViewport().setOpaque(false);
        descScroll.setPreferredSize(new Dimension(100, 96));
        desc.add(descScroll, BorderLayout.CENTER);

        JPanel body = new JPanel(new BorderLayout());
        body.setOpaque(false);
        body.add(chapters, BorderLayout.CENTER);
        body.add(desc, BorderLayout.SOUTH);

        add(header, BorderLayout.NORTH);
        add(body, BorderLayout.CENTER);
    }

    private static JComponent leftAligned(JComponent c) {
        c.setAlignmentX(Component.LEFT_ALIGNMENT);
        JPanel wrap = new JPanel(new BorderLayout());
        wrap.setOpaque(false);
        wrap.add(c, BorderLayout.WEST);
        wrap.setAlignmentX(Component.LEFT_ALIGNMENT);
        wrap.setMaximumSize(new Dimension(Integer.MAX_VALUE, c.getPreferredSize().height));
        return wrap;
    }

    /**
     * 先用列表里已有的摘要把界面铺出来，避免详情请求期间整页空白。
     */
    void showPlaceholder(String title, String author) {
        titleLabel.setText(title);
        authorLabel.setText(author);
        statsLabel.setText("加载详情…");
        tagPanel.removeAll();
        chapterModel.clear();
        descArea.setText("");
        readButton.setEnabled(false);
        downloadButton.setEnabled(false);
        progress.setVisible(false);
        progressLabel.setText(" ");
        revalidate();
        repaint();
    }

    void show(JmAlbum a) {
        this.album = a;
        titleLabel.setText(a.getTitle());
        authorLabel.setText(a.getAuthors() == null || a.getAuthors().isEmpty()
                ? "未知作者" : String.join(", ", a.getAuthors()));
        statsLabel.setText(String.format("%d 页 · %s 喜欢 · %s 观看 · %d 评论 · %s",
                a.getPageCount(), nz(a.getLikes()), nz(a.getViews()), a.getCommentCount(), nz(a.getAddTime())));

        tagPanel.removeAll();
        if (a.getTags() != null) {
            a.getTags().stream().filter(t -> t != null && !t.isBlank()).limit(12)
                    .forEach(t -> tagPanel.add(new TagChip(t)));
        }

        chapterModel.clear();
        a.getPhotoMetas().forEach(chapterModel::addElement);
        if (!chapterModel.isEmpty()) {
            chapterList.setSelectedIndex(0);
        }

        descArea.setText(a.getDescription() == null ? "" : a.getDescription());
        descArea.setCaretPosition(0);
        readButton.setEnabled(true);
        downloadButton.setEnabled(true);

        loadCover(a);
        revalidate();
        repaint();
    }

    private static String nz(String s) {
        return s == null || s.isBlank() ? "-" : s;
    }

    private void loadCover(JmAlbum a) {
        String key = "cover:" + a.getId();
        BufferedImage hit = covers.peek(key);
        if (hit != null) {
            applyCover(hit);
            return;
        }
        coverLabel.setIcon(null);
        coverLabel.setText("封面加载中…");
        covers.load(key, () -> coverFetcher.fetch(a.getId()), img -> {
            if (album == a) {
                applyCover(img);
            }
        });
    }

    private void applyCover(BufferedImage img) {
        if (img == null) {
            coverLabel.setIcon(null);
            coverLabel.setText("无封面");
            return;
        }
        int w = coverLabel.getPreferredSize().width;
        int h = coverLabel.getPreferredSize().height;
        double scale = Math.min((double) w / img.getWidth(), (double) h / img.getHeight());
        coverLabel.setIcon(new javax.swing.ImageIcon(img.getScaledInstance(
                Math.max(1, (int) (img.getWidth() * scale)),
                Math.max(1, (int) (img.getHeight() * scale)),
                java.awt.Image.SCALE_SMOOTH)));
        coverLabel.setText("");
    }

    // == 下载进度反馈 ==

    void onDownloadStart() {
        downloadButton.setEnabled(false);
        progress.setVisible(true);
        progress.setValue(0);
        progress.setString("准备中…");
        progressLabel.setText(" ");
    }

    void onDownloadProgress(int done, int total, String chapter) {
        if (total > 0) {
            progress.setMaximum(total);
            progress.setValue(done);
            progress.setString(done + " / " + total + " 张");
        }
        progressLabel.setText(chapter == null ? " " : chapter);
    }

    void onDownloadDone(String message) {
        downloadButton.setEnabled(true);
        progress.setValue(progress.getMaximum());
        progress.setString("完成");
        progressLabel.setText(message);
    }

    void onDownloadFailed(String message) {
        downloadButton.setEnabled(true);
        progress.setVisible(false);
        progressLabel.setText(message);
    }

    /**
     * 标签胶囊。
     */
    private static final class TagChip extends JLabel {
        TagChip(String text) {
            super(text);
            setFont(Ui.font(Ui.FONT_CAPTION, false));
            setForeground(Ui.secondaryFg());
            setBorder(Ui.pad(3, Ui.S2, 3, Ui.S2));
        }

        @Override
        protected void paintComponent(Graphics g) {
            Graphics2D g2 = (Graphics2D) g.create();
            g2.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
            g2.setColor(Ui.skeleton());
            g2.fillRoundRect(0, 0, getWidth(), getHeight(), getHeight(), getHeight());
            g2.dispose();
            super.paintComponent(g);
        }
    }

    /**
     * 章节行：序号 + 标题，右侧「阅读 ›」明示单击可进入。
     */
    private static final class ChapterRenderer extends JComponent implements ListCellRenderer<JmPhotoMeta> {

        private JmPhotoMeta value;
        private boolean selected;

        @Override
        public Component getListCellRendererComponent(JList<? extends JmPhotoMeta> list, JmPhotoMeta v,
                                                      int index, boolean isSelected, boolean cellHasFocus) {
            this.value = v;
            this.selected = isSelected;
            return this;
        }

        @Override
        protected void paintComponent(Graphics g) {
            if (value == null) {
                return;
            }
            Graphics2D g2 = (Graphics2D) g.create();
            g2.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
            int w = getWidth();
            int h = getHeight();

            if (selected) {
                g2.setColor(UIManager.getColor("List.selectionBackground"));
                g2.fillRect(0, 0, w, h);
            }
            Color fg = selected
                    ? UIManager.getColor("List.selectionForeground")
                    : UIManager.getColor("List.foreground");

            g2.setColor(fg);
            g2.setFont(Ui.font(Ui.FONT_BODY, false));
            var fm = g2.getFontMetrics();
            String title = value.getTitle() == null || value.getTitle().isBlank()
                    ? "第 " + value.getSortOrder() + " 话" : value.getTitle();

            String hint = "阅读 ›";
            g2.setFont(Ui.font(Ui.FONT_CAPTION, false));
            int hintW = g2.getFontMetrics().stringWidth(hint);
            g2.setFont(Ui.font(Ui.FONT_BODY, false));

            int textW = w - Ui.S4 * 2 - hintW - Ui.S3;
            g2.drawString(Ui.ellipsize(fm, title, textW), Ui.S4, (h + fm.getAscent() - fm.getDescent()) / 2);

            g2.setColor(selected ? fg : Ui.secondaryFg());
            g2.setFont(Ui.font(Ui.FONT_CAPTION, false));
            var fm2 = g2.getFontMetrics();
            g2.drawString(hint, w - Ui.S4 - hintW, (h + fm2.getAscent() - fm2.getDescent()) / 2);

            g2.setColor(Ui.separator());
            g2.drawLine(Ui.S4, h - 1, w - Ui.S4, h - 1);
            g2.dispose();
        }
    }
}
