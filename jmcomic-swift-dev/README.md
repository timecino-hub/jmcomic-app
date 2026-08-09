# JMComic for macOS (Swift)

原生 macOS 阅读器。SwiftUI + SwiftPM，**零第三方依赖**。

```bash
cd jmcomic-swift
swift run -c release
```

## 为什么另起一套

Swing 版的问题不是"写得不好"，是几个结构性的坑：

| | Swing 版 | 这个 Swift 版 |
|---|---|---|
| 常驻内存 | ~3000 MB | **159 MB** |
| 单页图片处理 | 1228 ms | **275 ms**（解码仅 9 ms） |
| 产物体积 | 9.3 MB jar + JRE | **1.1 MB** |
| webp 解码 | `webp-imageio` JNI，**只带 x86_64 dylib，Apple Silicon 直接崩** | 系统 ImageIO 原生 |
| 滚动手感 | 手写滚轮翻页，无惯性/橡皮筋 | `ScrollView`（底层 NSScrollView） |

Swing 那条图片链路是 `解码 → 重组 → 重新编码成 webp → byte[]`，调用方还得再解码一次。
那次 webp 重编码单页约 700 ms，**而且有损**。

## 正确性依据

解重组算法是照着 `jmcomic-core` 的 `AwtImageProcessor` 移植的，做过逐像素比对：

```
Swift 解重组 vs Java 解重组(去掉重编码) : mean abs diff = 0.0000   ← 完全一致
Java 无重编码 vs Java 有重编码          : mean abs diff = 2.2743   ← 重编码的画质损失
```

即 Swift 版不仅更快，画面还**比 Java 版更清晰**（少了一次有损重编码）。

坐标系是这里唯一的陷阱：`CGImage.cropping(to:)` 用**左上**原点（与 Java 一致），
而 `CGContext.draw(_:in:)` 用**左下**原点，所以目标 y 必须翻转成 `height - currentY - sliceHeight`。
四种组合都实测过，只有这一种能对上 Java（其余为 96.38 / 9.79）。改这段前先看 `ImagePipeline.swift` 的注释。

## 结构

```
Core/
  JmConstants.swift   密钥、域名、UA
  JmCrypto.swift      token 签名、AES-ECB 解密、切块数计算
  JmClient.swift      actor：域名轮换 + 签名请求 + 解密（失败自动换域名）
  JmParser.swift      JSON -> 模型，字段与 ApiParser 对齐
  Models.swift        Album / Chapter / ComicPage
  ImagePipeline.swift 解码 + 解重组（全程 CGImage，不重编码）
  ImageStore.swift    actor：内存 LRU + 磁盘缓存 + 请求合并 + 宽高比记录
  LibraryStore.swift  元数据缓存、阅读进度、历史
UI/
  BrowseView.swift    封面网格、搜索、热门/最新/历史
  AlbumDetailView.swift 详情、章节、相关作品（续作）
  ReaderView.swift    连续滚动阅读器
```

## 几个实现要点

**图片不会"只显示一半"。** 每页外框高度由已记录的宽高比算出，图片到达前后高度不变，
所以不会像 Swing 版那样"先按占位高度画、图到了再重排"。宽高比持久化在 `ratios.json`，
第二次打开同一话版面从第一帧就是准的。

**续作不需要算法。** 服务端 `related_list` 直接给，`Album.related` 就是。
`series_id != "0"` 表示属于某个系列。

**磁盘缓存才是"加载慢"的解药。** 存的是解重组后的 PNG，第二次看同一话不走网络、
连解重组都省了。元数据 JSON 只有几 KB，它让详情页秒开，但救不了图片速度——那是 MB 级的。

## 与 Java 版的关系

**不共享代码**，协议逻辑是独立实现的。`jmcomic-core` 若变更以下任一项，这里要同步改：

- `JmConstants`：`tokenSecret` / `dataSecret` / `domainServerSecret` / 域名服务器地址
- `JmCrypto.segmentCount`：切块阈值 `268850` / `421926`
- `JmParser`：API 字段名（`series` / `related_list` / `scramble_id` / `content` / `total`）

## 现状

已做：热门/最新/搜索/历史、详情、相关作品、连续滚动阅读器、断点续读、磁盘缓存。

未做：下载、登录/收藏/签到（这些仍在 Swing 版里）。HTML 客户端未移植，仅走移动端 API。

未验证：UI 的视觉细节没有截图确认过（本机截屏权限受限），逻辑与网络层是实测通过的。
