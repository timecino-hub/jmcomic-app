# iPadOS 11 英寸适配与安装

本分支把原先仅声明 iPhone 的目标改成 **iPhone + iPad 通用 App**，最低系统仍为 iOS / iPadOS 17。界面按可用宽度响应，而不是写死某一代设备的像素，因此覆盖 11 英寸 iPad 的横屏、竖屏、分屏和台前调度窗口。

## 已适配内容

- 11 英寸竖屏默认收起侧边栏，漫画区稳定显示四列；左上角系统按钮可随时展开侧栏。
- 横屏宽窗口使用 iPad 侧边栏；不足 900 pt 的窗口优先显示完整内容，紧凑窗口自动切回底部标签栏。
- 支持 iPad 四个方向和多窗口。
- 网格在 4:3 宽屏上自动增加列数，详情页限制阅读行宽。
- 连续阅读页最大宽度为 900 pt，横屏不再被无限拉宽；单页模式仍完整适配整个视口。
- 阅读器顶栏和跳页条在宽屏居中限宽。
- 支持触控板 / 鼠标的间接输入事件。

## 方式一：用 Xcode 直接装到 iPad

1. 在 Mac 上安装 Xcode，用数据线或无线调试连接 iPad，并在 iPad 开启“设置 → 隐私与安全性 → 开发者模式”。
2. 用 Xcode 打开 `jmcomic-ios.xcodeproj`。
3. 选中 `JMComic-iOS` Target，在 **Signing & Capabilities** 勾选自动签名并选择自己的 Team。
4. 若 Xcode 提示 Bundle Identifier 已占用，把 `local.jmcomic.ios` 改成自己唯一的反向域名，例如 `com.yourname.jmcomic`。
5. 运行目标选择已连接的 iPad，点击 ▶。
6. 首次启动若被拦截，在 iPad 的“设置 → 通用 → VPN 与设备管理”中信任对应开发者。

免费 Apple ID 的个人签名通常需要每 7 天重新安装；付费开发者证书有效期更长。

## 方式二：生成未签名 IPA

在 Mac 终端执行：

```bash
cd jmcomic-ios
chmod +x package-ipados.sh
./package-ipados.sh
```

产物位于 `dist/JMComic-iPadOS-unsigned.ipa`。它必须先由 Xcode、AltStore、Sideloadly 或其他你信任的签名方式使用自己的 Apple ID / 证书签名，不能直接在 iPad 上点开安装。

## 建议验收尺寸

在 Xcode 的 iPad 11 英寸模拟器上至少检查：

- 竖屏全屏：默认隐藏侧边栏 + 四列内容网格，并检查左上角按钮可以正常展开侧栏。
- 横屏全屏：侧边栏 + 五列左右内容网格。
- 半屏 / 窄窗口：自动切换为底部四标签，不挤压工具栏。
- 在线与本地阅读器：连续模式居中，单页模式整页显示，横竖屏切换后仍可翻页。
