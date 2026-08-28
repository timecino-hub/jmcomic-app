# 架构与设计

本项目为 **macOS + iOS 原生漫画阅读器**，使用 SwiftUI + SwiftPM，**零第三方依赖**——所有网络、加密、图片处理均用 Foundation/AppKit/UIKit 原生 API 实现。

包含两个独立端：

| 端 | 目录 | 工程 | Bundle ID |
| --- | --- | --- | --- |
| macOS | `jmcomic-swift/` | SwiftPM (`Package.swift`) | `local.jmcomic.reader` |
| iOS | `jmcomic-ios/` | Xcode (`jmcomic-ios.xcodeproj`) | `local.jmcomic.ios` |

## 模块划分（macOS 核心）

```
jmcomic-swift/Sources/JMComic/
├── App.swift              入口 + 路由
├── SelfCheck.swift        启动自检
├── Core/
│   ├── JmConstants.swift  密钥、域名、UA
│   ├── JmCrypto.swift     token 签名、AES-ECB 解密、切块数计算
│   ├── JmClient.swift     actor：域名轮换 + 签名请求 + 解密（失败自动换域名）
│   ├── JmParser.swift     JSON -> 模型
│   ├── Models.swift       Album / Chapter / ComicPage
│   ├── ImagePipeline.swift 解码 + 解重组（全程 CGImage，不重编码）
│   ├── ImageStore.swift   actor：内存 LRU + 磁盘缓存 + 请求合并 + 宽高比记录
│   ├── LibraryStore.swift 元数据缓存、阅读进度、历史
│   ├── CryptoStore.swift  AES 加密存储（密钥在钥匙串）
│   ├── DownloadStore.swift 下载管理
│   ├── FavoriteStore.swift 收藏管理
│   ├── SyncStore.swift    GitHub 私有仓库加密同步
│   └── Zip.swift          CBZ 打包
└── UI/
    ├── BrowseView.swift       封面网格、搜索、热门/最新/历史
    ├── AlbumDetailView.swift  详情、章节、相关作品
    ├── ReaderView.swift       连续滚动阅读器
    ├── FavoritesView.swift    收藏管理
    ├── CategoriesView.swift   分类筛选
    ├── RecentView.swift       最近浏览
    ├── PersonalizedView.swift 为你推荐
    ├── LocalLibraryView.swift 本地库
    ├── LocalReaderView.swift  本地阅读
    └── SettingsView.swift     设置
```

## 关键设计决策

- **actor 并发**：`JmClient`、`ImageStore`、`CryptoStore` 等核心组件使用 Swift actor 保证线程安全，无需手写锁。
- **零依赖**：网络用 `URLSession`，加密用 `CryptoKit`/`CommonCrypto`，图片用 `ImageIO` → `CGImage`，不引入任何第三方库。
- **图片解重组**：系统 ImageIO 解码 → CGImage 切块重排，**不重编码**（比传统 Java 实现更快更清晰）。
- **域名轮换**：请求不绑定固定域名（用 `PLACEHOLDER_HOST` 占位），HTTP 非 200 / 解密失败时自动切换下一个域名并计数；后台 `DomainProbe` 定期探活，剔除不可用域名。
- **加密存储**：AES-GCM 密钥存钥匙串，数据文件权限 `0600`。
- **命名约定**：SwiftUI 视图后缀 `View`，数据存储类后缀 `Store`，Core 层组件多为 `actor`。

## 构建命令

```bash
# macOS
cd jmcomic-swift
swift run -c release              # 直接运行
./build-app.sh --install          # 打包并安装到 /Applications
swift run -c release --selfcheck  # 自检

# iOS（编译验收，模拟器）
cd jmcomic-ios
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash build.sh
```

## 端到端同步链路

```
iOS App ──扫码配对──> macOS Web 服务（端口 8973）
                        │
                        ├── 浏览/阅读（经 Web API 代理到 JmClient）
                        ├── 收藏/进度回传（双向同步到 LibraryStore）
                        └── GitHub 私有仓库加密备份（SyncStore）
```

接口细节见 [api.md](api.md)，上游能力对照见 [upstream.md](upstream.md)。
