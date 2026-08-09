package io.github.jukomu.jmcomic.desktop;

import com.formdev.flatlaf.themes.FlatMacDarkLaf;
import com.formdev.flatlaf.themes.FlatMacLightLaf;
import io.github.jukomu.jmcomic.api.download.DownloadProgress;
import io.github.jukomu.jmcomic.api.download.DownloadResult;
import io.github.jukomu.jmcomic.api.enums.ClientType;
import io.github.jukomu.jmcomic.api.enums.OrderBy;
import io.github.jukomu.jmcomic.api.enums.TimeOption;
import io.github.jukomu.jmcomic.api.model.JmAlbum;
import io.github.jukomu.jmcomic.api.model.JmAlbumMeta;
import io.github.jukomu.jmcomic.api.model.JmPhotoMeta;
import io.github.jukomu.jmcomic.api.model.JmPromoteCategory;
import io.github.jukomu.jmcomic.api.model.JmSearchPage;
import io.github.jukomu.jmcomic.api.model.SearchQuery;
import io.github.jukomu.jmcomic.core.JmComic;
import io.github.jukomu.jmcomic.core.client.impl.JmApiClient;
import io.github.jukomu.jmcomic.core.config.JmConfiguration;

import javax.swing.BorderFactory;
import javax.swing.Box;
import javax.swing.ButtonGroup;
import javax.swing.JButton;
import javax.swing.JCheckBox;
import javax.swing.JFileChooser;
import javax.swing.JFrame;
import javax.swing.JLabel;
import javax.swing.JOptionPane;
import javax.swing.JPanel;
import javax.swing.JTextField;
import javax.swing.JToggleButton;
import javax.swing.SwingUtilities;
import javax.swing.WindowConstants;
import java.awt.BorderLayout;
import java.awt.CardLayout;
import java.awt.Dimension;
import java.awt.FlowLayout;
import java.awt.event.WindowAdapter;
import java.awt.event.WindowEvent;
import java.nio.file.Path;
import java.util.List;
import java.util.prefs.BackingStoreException;
import java.util.prefs.Preferences;

/**
 * @author JUKOMU
 * @Description: macOS 桌面版 JMComic 阅读/下载工具。
 * <p>
 * 主界面为封面网格墙，点封面进详情页，详情页点章节进连续滚动阅读器。
 * 界面用 FlatLaf FlatMac 主题，跟随系统深浅色。
 * <p>
 * 构建：mvn -pl jmcomic-desktop-support -am package -DskipTests
 * 运行：java -jar jmcomic-desktop-support/target/jmcomic-desktop-support-1.1.7.jar
 * @Project: jmcomic-api-java
 * @Date: 2025/12/20
 */
public class JmDesktopApp {

    private static final String CARD_BROWSE = "browse";
    private static final String CARD_DETAIL = "detail";

    private final Preferences prefs = Preferences.userNodeForPackage(JmDesktopApp.class);

    private JmApiClient client;
    /*
     * 缓存的是解码后的 BufferedImage：一页 1280x1807 约 9MB，
     * 512MB 会让常驻内存非常难看。144MB 够存约 16 页（视口 + 前后预读）绰绰有余。
     */
    private final ImageCache images = new ImageCache(144L * 1024 * 1024, 6);

    private JFrame frame;
    private final CardLayout cards = new CardLayout();
    private final JPanel content = new JPanel(cards);
    private BrowseView browseView;
    private DetailView detailView;

    private final JTextField searchField = new JTextField();
    private final JLabel statusLabel = Ui.secondaryLabel("就绪", Ui.FONT_CAPTION);
    private final JButton backButton = new JButton("‹ 返回");
    private final JToggleButton hotTab = new JToggleButton("热门");
    private final JToggleButton promoteTab = new JToggleButton("推荐");
    private final JToggleButton latestTab = new JToggleButton("最新");

    private Path downloadRoot;
    private JmAlbum currentAlbum;

    /**
     * 详情请求代次。快速连点不同封面时，只有最后一次的结果会被采纳。
     */
    private int detailGeneration;

    public static void main(String[] args) {
        System.setProperty("apple.awt.application.name", "JMComic");
        // 使用系统标题栏融合外观（macOS）
        System.setProperty("apple.awt.application.appearance", "system");
        setupTheme();
        SwingUtilities.invokeLater(JmDesktopApp::new);
    }

    /**
     * 跟随系统深浅色。macOS 下 AppleInterfaceStyle=Dark 表示深色。
     */
    private static void setupTheme() {
        boolean dark = false;
        try {
            Process p = new ProcessBuilder("defaults", "read", "-g", "AppleInterfaceStyle")
                    .redirectErrorStream(true).start();
            String out = new String(p.getInputStream().readAllBytes()).trim();
            p.waitFor();
            dark = out.equalsIgnoreCase("Dark");
        } catch (Exception ignored) {
            // 非 macOS 或读取失败，用浅色
        }
        if (dark) {
            FlatMacDarkLaf.setup();
        } else {
            FlatMacLightLaf.setup();
        }
    }

    public JmDesktopApp() {
        downloadRoot = Path.of(prefs.get("downloadRoot",
                Path.of(System.getProperty("user.home"), "Downloads", "JMComic").toString()));
        this.client = buildClient(prefs.get("proxyHost", ""), prefs.getInt("proxyPort", 0));
        buildUi();
        showHot();
    }

    private JmApiClient buildClient(String proxyHost, int proxyPort) {
        JmConfiguration.Builder b = new JmConfiguration.Builder().clientType(ClientType.API);
        if (proxyHost != null && !proxyHost.isBlank()) {
            b.proxy(proxyHost, proxyPort);
        }
        return JmComic.newApiClient(b.build());
    }

    private void buildUi() {
        frame = new JFrame("JMComic");
        frame.setDefaultCloseOperation(WindowConstants.DO_NOTHING_ON_CLOSE);
        frame.addWindowListener(new WindowAdapter() {
            @Override
            public void windowClosing(WindowEvent e) {
                shutdown();
            }
        });

        browseView = new BrowseView(images, this::fetchCover, this::openDetail, this::setStatus);
        detailView = new DetailView(images, this::fetchCover, this::openReader, this::download);

        content.add(browseView, CARD_BROWSE);
        content.add(detailView, CARD_DETAIL);

        frame.add(buildToolbar(), BorderLayout.NORTH);
        frame.add(content, BorderLayout.CENTER);
        frame.add(buildStatusBar(), BorderLayout.SOUTH);

        frame.setSize(1180, 820);
        frame.setMinimumSize(new Dimension(760, 560));
        frame.setLocationRelativeTo(null);
        frame.setVisible(true);
    }

    private JPanel buildToolbar() {
        backButton.putClientProperty("JButton.buttonType", "borderless");
        backButton.addActionListener(e -> showBrowse());
        backButton.setVisible(false);

        searchField.putClientProperty("JTextField.placeholderText", "搜索本子、作者、标签…");
        searchField.putClientProperty("JTextField.showClearButton", true);
        searchField.setPreferredSize(new Dimension(320, 30));
        searchField.addActionListener(e -> doSearch());

        hotTab.addActionListener(e -> showHot());
        promoteTab.addActionListener(e -> showPromote());
        latestTab.addActionListener(e -> showLatest());
        hotTab.setSelected(true);
        ButtonGroup group = new ButtonGroup();
        group.add(hotTab);
        group.add(promoteTab);
        group.add(latestTab);
        for (JToggleButton t : List.of(hotTab, promoteTab, latestTab)) {
            t.putClientProperty("JButton.buttonType", "roundRect");
        }

        JButton settingsButton = new JButton("设置");
        settingsButton.putClientProperty("JButton.buttonType", "roundRect");
        settingsButton.addActionListener(e -> openSettings());

        JPanel left = new JPanel(new FlowLayout(FlowLayout.LEFT, Ui.S2, 0));
        left.setOpaque(false);
        left.add(backButton);
        left.add(searchField);

        JPanel right = new JPanel(new FlowLayout(FlowLayout.RIGHT, Ui.S2, 0));
        right.setOpaque(false);
        right.add(hotTab);
        right.add(promoteTab);
        right.add(latestTab);
        right.add(Box.createHorizontalStrut(Ui.S2));
        right.add(settingsButton);

        JPanel bar = new JPanel(new BorderLayout());
        bar.setBorder(BorderFactory.createCompoundBorder(
                BorderFactory.createMatteBorder(0, 0, 1, 0, Ui.separator()),
                Ui.pad(Ui.S2, Ui.S3, Ui.S2, Ui.S3)));
        bar.add(left, BorderLayout.WEST);
        bar.add(right, BorderLayout.EAST);
        return bar;
    }

    private JPanel buildStatusBar() {
        JPanel bar = new JPanel(new BorderLayout());
        bar.setBorder(BorderFactory.createCompoundBorder(
                BorderFactory.createMatteBorder(1, 0, 0, 0, Ui.separator()),
                Ui.pad(Ui.S1, Ui.S3, Ui.S1, Ui.S3)));
        // 状态文字独占一行左侧，长度变化不会挤压其他控件
        bar.add(statusLabel, BorderLayout.WEST);
        return bar;
    }

    private void setStatus(String text) {
        SwingUtilities.invokeLater(() -> statusLabel.setText(text));
    }

    // == 数据源 ==

    /**
     * 热门排行。按周观看量排序，有 100+ 页，是质量最高的浏览入口，作为默认首页。
     */
    private void showHot() {
        hotTab.setSelected(true);
        showBrowse();
        browseView.setSource(new BrowseView.Source() {
            @Override
            public String title() {
                return "本周热门";
            }

            @Override
            public BrowseView.Page load(int page) {
                JmSearchPage p = client.search(new SearchQuery.Builder()
                        .text("")
                        .orderBy(OrderBy.MOST_VIEWED)
                        .time(TimeOption.WEEK)
                        .page(page)
                        .build());
                return new BrowseView.Page(p.getContent(), page < p.getTotalPages());
            }
        });
    }

    /**
     * 官方推荐位。每一「页」对应首页的一个推荐分区（连载更新、漢化組、韓漫…），
     * 比 getRandomRecommend 好用：后者只返回 9 条且多次调用高度重复。
     */
    private void showPromote() {
        promoteTab.setSelected(true);
        showBrowse();
        browseView.setSource(new BrowseView.Source() {
            private List<JmPromoteCategory> categories;

            @Override
            public String title() {
                return "官方推荐";
            }

            @Override
            public BrowseView.Page load(int page) {
                if (categories == null) {
                    categories = client.getPromote();
                }
                if (page > categories.size()) {
                    return new BrowseView.Page(List.of(), false);
                }
                JmPromoteCategory category = categories.get(page - 1);
                JmSearchPage p = client.getPromoteList(category, 1);
                return new BrowseView.Page(p.getContent(), page < categories.size());
            }
        });
    }

    private void showLatest() {
        latestTab.setSelected(true);
        showBrowse();
        browseView.setSource(new BrowseView.Source() {
            @Override
            public String title() {
                return "最新上架";
            }

            @Override
            public BrowseView.Page load(int page) {
                JmSearchPage p = client.getLatest(page);
                return new BrowseView.Page(p.getContent(), page < p.getTotalPages());
            }
        });
    }

    private void doSearch() {
        String text = searchField.getText().trim();
        if (text.isEmpty()) {
            showHot();
            return;
        }
        hotTab.setSelected(false);
        promoteTab.setSelected(false);
        latestTab.setSelected(false);
        showBrowse();
        browseView.setSource(new BrowseView.Source() {
            @Override
            public String title() {
                return "搜索「" + text + "」";
            }

            @Override
            public BrowseView.Page load(int page) {
                JmSearchPage p = client.search(
                        new SearchQuery.Builder().text(text).page(page).build());
                return new BrowseView.Page(p.getContent(), page < p.getTotalPages());
            }
        });
    }

    /**
     * 封面图。URL 需要域名管理器就绪，所以只能在后台线程构造。
     */
    private java.awt.image.BufferedImage fetchCover(String albumId) throws Exception {
        return JmImages.loadCover(client, albumId);
    }

    // == 页面切换 ==

    private void showBrowse() {
        backButton.setVisible(false);
        cards.show(content, CARD_BROWSE);
    }

    private void openDetail(JmAlbumMeta meta) {
        backButton.setVisible(true);
        cards.show(content, CARD_DETAIL);
        detailView.showPlaceholder(meta.getTitle(),
                meta.getAuthors() == null || meta.getAuthors().isEmpty()
                        ? "" : String.join(", ", meta.getAuthors()));
        setStatus("加载详情…");

        final int gen = ++detailGeneration;
        new Thread(() -> {
            try {
                JmAlbum album = client.getAlbum(meta.getId());
                SwingUtilities.invokeLater(() -> {
                    if (gen != detailGeneration) {
                        return;
                    }
                    currentAlbum = album;
                    detailView.show(album);
                    setStatus(album.getTitle());
                });
            } catch (Exception ex) {
                SwingUtilities.invokeLater(() -> {
                    if (gen != detailGeneration) {
                        return;
                    }
                    setStatus("获取详情失败：" + ex.getMessage());
                });
            }
        }, "jm-detail").start();
    }

    private void openReader(JmAlbum album, JmPhotoMeta start) {
        if (album == null) {
            return;
        }
        new ReaderWindow(frame, client, images, album, start).setVisible(true);
    }

    // == 下载 ==

    private void download() {
        JmAlbum album = currentAlbum;
        if (album == null) {
            return;
        }
        detailView.onDownloadStart();
        setStatus("开始下载：" + album.getTitle());

        new Thread(() -> {
            try {
                DownloadResult result = client.download(album)
                        .withPath(downloadRoot)
                        .withProgress(this::onDownloadProgress)
                        .execute();
                SwingUtilities.invokeLater(() -> {
                    String msg = result.isAllSuccess()
                            ? String.format("下载完成：%d 张 → %s",
                            result.getSuccessfulFiles().size(), downloadRoot)
                            : String.format("成功 %d 张，失败 %d 张",
                            result.getSuccessfulFiles().size(), result.getFailedTasks().size());
                    detailView.onDownloadDone(msg);
                    setStatus(msg);
                });
            } catch (Exception ex) {
                SwingUtilities.invokeLater(() -> {
                    detailView.onDownloadFailed("下载失败：" + ex.getMessage());
                    setStatus("下载失败：" + ex.getMessage());
                });
            }
        }, "jm-download").start();
    }

    private void onDownloadProgress(DownloadProgress p) {
        SwingUtilities.invokeLater(() ->
                detailView.onDownloadProgress(p.completedImages(), p.totalImages(), p.photoTitle()));
    }

    // == 设置 ==

    private void openSettings() {
        JTextField hostField = new JTextField(prefs.get("proxyHost", ""), 14);
        JTextField portField = new JTextField(
                prefs.getInt("proxyPort", 0) > 0 ? String.valueOf(prefs.getInt("proxyPort", 0)) : "", 6);
        JTextField pathField = new JTextField(downloadRoot.toString(), 22);
        JButton pick = new JButton("选择…");
        pick.addActionListener(e -> {
            JFileChooser fc = new JFileChooser(pathField.getText());
            fc.setFileSelectionMode(JFileChooser.DIRECTORIES_ONLY);
            if (fc.showOpenDialog(frame) == JFileChooser.APPROVE_OPTION) {
                pathField.setText(fc.getSelectedFile().getAbsolutePath());
            }
        });
        JPanel pathRow = new JPanel(new BorderLayout(Ui.S2, 0));
        pathRow.add(pathField, BorderLayout.CENTER);
        pathRow.add(pick, BorderLayout.EAST);

        JCheckBox clearCache = new JCheckBox("清空图片缓存");

        int rc = JOptionPane.showConfirmDialog(frame, new Object[]{
                "代理主机（留空 = 直连）：", hostField,
                "代理端口：", portField,
                " ",
                "下载目录：", pathRow,
                " ",
                clearCache
        }, "设置", JOptionPane.OK_CANCEL_OPTION, JOptionPane.PLAIN_MESSAGE);
        if (rc != JOptionPane.OK_OPTION) {
            return;
        }

        String host = hostField.getText().trim();
        int port = 0;
        if (!host.isEmpty()) {
            try {
                port = Integer.parseInt(portField.getText().trim());
            } catch (NumberFormatException ex) {
                JOptionPane.showMessageDialog(frame, "端口必须是数字", "设置", JOptionPane.ERROR_MESSAGE);
                return;
            }
        }

        String newPath = pathField.getText().trim();
        if (!newPath.isEmpty()) {
            downloadRoot = Path.of(newPath);
            prefs.put("downloadRoot", newPath);
        }
        if (clearCache.isSelected()) {
            images.clear();
        }

        boolean proxyChanged = !host.equals(prefs.get("proxyHost", "")) || port != prefs.getInt("proxyPort", 0);
        prefs.put("proxyHost", host);
        prefs.putInt("proxyPort", port);
        /*
         * Preferences 默认由后台线程延迟落盘，而退出走的是 System.exit，
         * 不显式 flush 的话设置会丢，表现为「改了没保存」。
         */
        try {
            prefs.flush();
        } catch (BackingStoreException ex) {
            setStatus("设置保存失败：" + ex.getMessage());
        }
        if (proxyChanged) {
            reconnect(host, port);
        }
    }

    private void reconnect(String host, int port) {
        setStatus("正在重新连接…");
        new Thread(() -> {
            try {
                JmApiClient old = client;
                client = buildClient(host, port);
                old.close();
                images.clear();
                SwingUtilities.invokeLater(this::showLatest);
            } catch (Exception ex) {
                setStatus("重连失败：" + ex.getMessage());
            }
        }, "jm-reconnect").start();
    }

    private void shutdown() {
        frame.setVisible(false);
        setStatus("正在关闭…");
        new Thread(() -> {
            // System.exit 会跳过 Preferences 的延迟落盘，退出前必须显式 flush
            try {
                prefs.flush();
            } catch (BackingStoreException ignored) {
                // 落盘失败不阻塞退出
            }
            images.shutdown();
            try {
                client.close();
            } catch (Exception ignored) {
                // 关闭失败不影响退出
            }
            System.exit(0);
        }, "jm-shutdown").start();
    }
}
