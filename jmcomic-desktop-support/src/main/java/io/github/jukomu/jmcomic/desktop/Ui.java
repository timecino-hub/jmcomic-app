package io.github.jukomu.jmcomic.desktop;

import javax.swing.BorderFactory;
import javax.swing.JLabel;
import javax.swing.UIManager;
import javax.swing.border.Border;
import java.awt.Color;
import java.awt.Font;
import java.awt.FontMetrics;

/**
 * @author JUKOMU
 * @Description: 界面设计令牌。间距、字号、圆角、颜色集中在这里，
 * 避免各处随手写 EmptyBorder 导致的视觉不一致。
 * @Project: jmcomic-api-java
 * @Date: 2026/8/9
 */
final class Ui {

    private Ui() {
    }

    // == 8pt 间距刻度 ==
    static final int S1 = 4;
    static final int S2 = 8;
    static final int S3 = 12;
    static final int S4 = 16;
    static final int S5 = 24;

    // == 封面卡片尺寸（封面按禁漫的 3:4 比例，下方留标题两行 + 作者一行）==
    static final int COVER_W = 150;
    static final int COVER_H = 200;
    static final int CARD_W = COVER_W + S3;
    static final int CARD_H = COVER_H + 56;

    static final int RADIUS = 10;

    // == 字号层级 ==
    static final float FONT_TITLE = 20f;
    static final float FONT_SUBTITLE = 15f;
    static final float FONT_BODY = 13f;
    static final float FONT_CAPTION = 11f;

    static Font font(float size, boolean bold) {
        Font base = UIManager.getFont("Label.font");
        return base.deriveFont(bold ? Font.BOLD : Font.PLAIN, size);
    }

    /**
     * 次要文字颜色。跟随当前主题，不写死灰度。
     */
    static Color secondaryFg() {
        Color c = UIManager.getColor("Label.disabledForeground");
        return c != null ? c : UIManager.getColor("Label.foreground");
    }

    static Color separator() {
        Color c = UIManager.getColor("Component.borderColor");
        return c != null ? c : Color.GRAY;
    }

    /**
     * 占位/骨架块的底色，比背景稍深一档。
     */
    static Color skeleton() {
        Color bg = UIManager.getColor("Panel.background");
        if (bg == null) {
            return Color.LIGHT_GRAY;
        }
        boolean dark = (bg.getRed() + bg.getGreen() + bg.getBlue()) / 3 < 128;
        return dark ? bg.brighter() : bg.darker();
    }

    static Border pad(int top, int left, int bottom, int right) {
        return BorderFactory.createEmptyBorder(top, left, bottom, right);
    }

    static Border pad(int all) {
        return BorderFactory.createEmptyBorder(all, all, all, all);
    }

    static JLabel label(String text, float size, boolean bold) {
        JLabel l = new JLabel(text);
        l.setFont(font(size, bold));
        return l;
    }

    static JLabel secondaryLabel(String text, float size) {
        JLabel l = label(text, size, false);
        l.setForeground(secondaryFg());
        return l;
    }

    /**
     * 把文本截断到指定像素宽度，超出部分用省略号代替。
     *
     * @param fm       目标组件的字体度量
     * @param text     原始文本
     * @param maxWidth 可用宽度（像素）
     * @return 适配宽度后的文本
     */
    static String ellipsize(FontMetrics fm, String text, int maxWidth) {
        if (text == null || text.isEmpty() || fm.stringWidth(text) <= maxWidth) {
            return text == null ? "" : text;
        }
        int ellipsisWidth = fm.stringWidth("…");
        int end = 0;
        int width = 0;
        while (end < text.length()) {
            int cw = fm.charWidth(text.charAt(end));
            if (width + cw + ellipsisWidth > maxWidth) {
                break;
            }
            width += cw;
            end++;
        }
        return text.substring(0, end) + "…";
    }
}
