# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

macOS 原生漫画阅读器。SwiftUI + SwiftPM，零第三方依赖。

## Commands

```bash
cd jmcomic-swift

# 运行（Debug）
swift run

# 运行（Release）
swift run -c release

# 运行自检
swift run -c release --selfcheck

# 打包并安装到 /Applications
./build-app.sh --install
```

## Architecture

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

## Key Design Decisions

- **actor-based concurrency**: `JmClient`, `ImageStore`, `CryptoStore` 等核心组件使用 Swift actor 保证线程安全
- **零依赖**: 所有网络、加密、图片处理均用 Foundation/AppKit 原生 API
- **图片解重组**: 系统 ImageIO 解码 → CGImage 切块重排，不重编码（比 Java 版更快更清晰）
- **域名轮换**: 请求不绑定固定域名，失败自动切换（与 Java 版同策略）
- **加密存储**: AES-GCM 密钥存钥匙串，数据文件权限 0600

## Conventions

- 代码注释使用中文
- SwiftUI 视图命名后缀 `View`
- 数据存储类命名后缀 `Store`
- Core 层组件多为 `actor`，保证并发安全
