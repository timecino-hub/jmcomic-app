package io.github.jukomu.jmcomic.desktop;

import io.github.jukomu.jmcomic.api.model.JmAlbum;
import io.github.jukomu.jmcomic.api.model.JmPhoto;
import io.github.jukomu.jmcomic.api.model.JmPhotoMeta;
import io.github.jukomu.jmcomic.core.client.impl.JmApiClient;

import javax.swing.BorderFactory;
import javax.swing.JButton;
import javax.swing.JComponent;
import javax.swing.JDialog;
import javax.swing.JFrame;
import javax.swing.JLabel;
import javax.swing.JPanel;
import javax.swing.JScrollPane;
import javax.swing.SwingConstants;
import javax.swing.KeyStroke;
import javax.swing.ScrollPaneConstants;
import javax.swing.SwingUtilities;
import javax.swing.AbstractAction;
import java.awt.BorderLayout;
import java.awt.Color;
import java.awt.Dimension;
import java.awt.event.ActionEvent;
import java.awt.event.KeyEvent;
import java.util.List;

/**
 * @author JUKOMU
 * @Description: 连续滚动阅读器窗口。
 * <p>
 * 章节按需追加到同一条画布上，滚到章末自动接下一章，中间不打断。
 * 顶栏显示当前章节和页码，跟随滚动实时更新。
 * @Project: jmcomic-api-java
 * @Date: 2026/8/9
 */
final class ReaderWindow extends JDialog {

    private final JmApiClient client;
    private final JmAlbum album;
    private final List<JmPhotoMeta> chapters;

    private final ReaderCanvas canvas;
    private final JScrollPane scroll;
    private final JLabel locationLabel = Ui.secondaryLabel("加载中…", Ui.FONT_BODY);
    private final JLabel albumLabel;
    private final String fullTitle;

    /**
     * 下一个待加载的章节下标。
     */
    private int nextChapter;
    private volatile boolean loadingChapter;

    ReaderWindow(JFrame owner, JmApiClient client, ImageCache cache, JmAlbum album, JmPhotoMeta start) {
        super(owner, album.getTitle(), false);
        this.client = client;
        this.album = album;
        this.chapters = album.getPhotoMetas();

        int startIdx = 0;
        if (start != null) {
            int i = chapters.indexOf(start);
            if (i >= 0) {
                startIdx = i;
            }
        }
        this.nextChapter = startIdx;

        canvas = new ReaderCanvas(cache, img -> JmImages.loadPage(client, img),
                locationLabel::setText, this::loadNextChapter);
        canvas.setMaxContentWidth(1000);

        scroll = new JScrollPane(canvas);
        scroll.setBorder(null);
        scroll.setHorizontalScrollBarPolicy(ScrollPaneConstants.HORIZONTAL_SCROLLBAR_NEVER);
        scroll.getViewport().setBackground(new Color(0x1E1E1E));
        scroll.getVerticalScrollBar().setUnitIncrement(60);
        canvas.attach(scroll);

        fullTitle = album.getTitle() == null ? "" : album.getTitle();
        albumLabel = new JLabel(fullTitle) {
            @Override
            protected void paintComponent(java.awt.Graphics g) {
                // 按当前实际宽度截断，长标题不会溢出到右侧页码区
                setText(Ui.ellipsize(getFontMetrics(getFont()), fullTitle, getWidth()));
                super.paintComponent(g);
            }
        };
        albumLabel.setFont(Ui.font(Ui.FONT_BODY, true));
        albumLabel.setMinimumSize(new Dimension(0, 0));
        albumLabel.setToolTipText(album.getTitle());

        JButton closeButton = new JButton("‹ 关闭");
        closeButton.putClientProperty("JButton.buttonType", "borderless");
        closeButton.addActionListener(e -> dispose());

        locationLabel.setHorizontalAlignment(SwingConstants.RIGHT);

        JPanel bar = new JPanel(new BorderLayout(Ui.S3, 0));
        bar.setBorder(BorderFactory.createCompoundBorder(
                BorderFactory.createMatteBorder(0, 0, 1, 0, Ui.separator()),
                Ui.pad(Ui.S2, Ui.S3, Ui.S2, Ui.S3)));
        bar.add(closeButton, BorderLayout.WEST);
        bar.add(albumLabel, BorderLayout.CENTER);
        bar.add(locationLabel, BorderLayout.EAST);

        add(bar, BorderLayout.NORTH);
        add(scroll, BorderLayout.CENTER);

        installKeys();

        setSize(1080, 860);
        setMinimumSize(new Dimension(600, 400));
        setLocationRelativeTo(owner);

        loadNextChapter();
    }

    /**
     * 键盘：空格/PageDown 翻一屏，方向键小步滚，Home/End 跳首尾，Esc 关闭。
     * 连续滚动模式下没有「页」的概念，所以全部按屏/像素滚动。
     */
    private void installKeys() {
        var im = getRootPane().getInputMap(JComponent.WHEN_IN_FOCUSED_WINDOW);
        var am = getRootPane().getActionMap();

        im.put(KeyStroke.getKeyStroke(KeyEvent.VK_SPACE, 0), "screenDown");
        im.put(KeyStroke.getKeyStroke(KeyEvent.VK_PAGE_DOWN, 0), "screenDown");
        im.put(KeyStroke.getKeyStroke(KeyEvent.VK_SPACE, KeyEvent.SHIFT_DOWN_MASK), "screenUp");
        im.put(KeyStroke.getKeyStroke(KeyEvent.VK_PAGE_UP, 0), "screenUp");
        im.put(KeyStroke.getKeyStroke(KeyEvent.VK_DOWN, 0), "lineDown");
        im.put(KeyStroke.getKeyStroke(KeyEvent.VK_UP, 0), "lineUp");
        im.put(KeyStroke.getKeyStroke(KeyEvent.VK_HOME, 0), "top");
        im.put(KeyStroke.getKeyStroke(KeyEvent.VK_END, 0), "bottom");
        im.put(KeyStroke.getKeyStroke(KeyEvent.VK_ESCAPE, 0), "close");

        am.put("screenDown", action(e -> scrollBy(scroll.getViewport().getHeight() - 60)));
        am.put("screenUp", action(e -> scrollBy(-(scroll.getViewport().getHeight() - 60))));
        am.put("lineDown", action(e -> scrollBy(120)));
        am.put("lineUp", action(e -> scrollBy(-120)));
        am.put("top", action(e -> scroll.getVerticalScrollBar().setValue(0)));
        am.put("bottom", action(e -> {
            var bar = scroll.getVerticalScrollBar();
            bar.setValue(bar.getMaximum());
        }));
        am.put("close", action(e -> dispose()));
    }

    private static AbstractAction action(java.util.function.Consumer<ActionEvent> body) {
        return new AbstractAction() {
            @Override
            public void actionPerformed(ActionEvent e) {
                body.accept(e);
            }
        };
    }

    private void scrollBy(int delta) {
        var bar = scroll.getVerticalScrollBar();
        bar.setValue(bar.getValue() + delta);
    }

    /**
     * 加载下一章并追加到画布。由画布在滚动接近末尾时回调，
     * 或首次打开时主动调用一次。
     */
    private void loadNextChapter() {
        if (loadingChapter || nextChapter >= chapters.size()) {
            return;
        }
        loadingChapter = true;
        final JmPhotoMeta meta = chapters.get(nextChapter);
        final boolean first = canvas.isEmpty();
        if (first) {
            locationLabel.setText("加载章节…");
        }

        new Thread(() -> {
            try {
                JmPhoto photo = client.getPhoto(meta.getId());
                SwingUtilities.invokeLater(() -> {
                    String title = meta.getTitle() == null || meta.getTitle().isBlank()
                            ? "第 " + meta.getSortOrder() + " 话" : meta.getTitle();
                    canvas.appendChapter(photo, title);
                    nextChapter++;
                    loadingChapter = false;
                });
            } catch (Exception ex) {
                SwingUtilities.invokeLater(() -> {
                    loadingChapter = false;
                    if (first) {
                        locationLabel.setText("章节加载失败：" + ex.getMessage());
                    }
                });
            }
        }, "jm-reader-chapter").start();
    }
}
