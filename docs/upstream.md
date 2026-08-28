# 上游接口仓库

本项目的能力参考自上游 Java API 库：

> **[JMComic-Api-Java](https://github.com/JUKOMU/JMComic-Api-Java)** — 一个用于获取 JMComic（禁漫天堂）数据的 Java API 库（MIT License，© JUKOMU）。

上游采用模块化设计，将公共接口（`jmcomic-api`）与核心实现（`jmcomic-core`）分离，并提供 Android 支持（`jmcomic-android-support`）。本目录的接口加解密、图片解重组、域名轮换等机制均与上游保持一致，本项目用 Swift 从零重新实现并叠加了原生 GUI。

## 上游能力全景

上游覆盖以下能力域（摘自上游 README）：

- **漫画**：本子详情、章节阅读、多维度搜索、分类排行、分类列表
- **下载**：并发下载、链式 API、进度回调、任务系统（暂停/恢复/取消）、自定义路径、自定义线程池
- **用户**：登录/登出、个人资料
- **评论**：评论列表、发表/回复（漫画/博客/小说）
- **收藏**：收藏夹、收藏管理、标签管理
- **小说**：列表、详情、章节阅读、搜索、评论/收藏
- **创作者**：作者列表、作品浏览、作品详情
- **签到**：签到状态、执行签到、签到历史
- **通知与追踪**：通知列表、已读/未读、连载追踪
- **发现**：热门标签、最新上架、随机推荐、每周必看、首页推广
- **其他**：浏览历史、任务系统

## 本项目实现对照

本项目（jmcomic-app，Swift + SwiftUI）聚焦「浏览 / 阅读 / 收藏 / 同步」核心场景，以下为与上游能力的对照：

| 能力域 | 上游 | 本项目 | 说明 |
| --- | :-: | :-: | --- |
| 本子详情 | ✅ | ✅ | `JmClient.album(id:)` → `JmParser.parseAlbum` |
| 章节阅读 | ✅ | ✅ | `JmClient.chapter(id:)`，含图片解重组 |
| 关键词搜索 | ✅ | ✅ | `JmClient.search(text:page:)` |
| 分类筛选 | ✅ | ✅ | `JmClient.categoryFilter(...)` |
| 热门标签 | ✅ | ✅ | `JmClient.hotTags()` |
| 并发下载 | ✅ | ✅ | `DownloadStore`，CBZ/散图打包 |
| 收藏管理 | ✅ | ✅ | `FavoriteStore`，本地分组 |
| 浏览历史 | ✅ | ✅ | `LibraryStore.history` |
| 个性化推荐 | — | ✅ | 本地标签画像算法（`LibraryStore.recommendations`） |
| 局域网阅读 | — | ✅ | 内建 Web 服务 + 手机扫码 |
| 加密备份同步 | — | ✅ | GitHub 私有仓库 AES-GCM 同步 |
| 用户登录/资料 | ✅ | ❌ | 暂未实现 |
| 评论互动 | ✅ | ❌ | 暂未实现 |
| 小说子系统 | ✅ | ❌ | 暂未实现 |
| 创作者子系统 | ✅ | ❌ | 暂未实现 |
| 签到 | ✅ | ❌ | 暂未实现 |
| 通知/追踪 | ✅ | ❌ | 暂未实现 |
| 每周必看/随机推荐 | ✅ | ❌ | 暂未实现 |

## 一致的核心机制

以下机制与上游保持一致，是接口互通的基础（实现细节见 [api.md](api.md) 第 6、7 节）：

- **请求签名**：`token = md5(timestamp + "18comicAPP")`，附加 `tokenparam = "{timestamp},231024"`
- **响应解密**：Base64 → AES-256-ECB 解密，密钥 `md5(timestamp + "185Hcomic3PAPP7R")`
- **域名服务器**：启动时拉取加密域名列表，密钥 `"diosfjckwpqpdfjkvnqQjsik"`
- **域名轮换**：不绑定固定域名，失败自动切换 + 后台探活
- **图片解重组**：按 `scramble_id` 对分块图片还原（本项目用 ImageIO → CGImage 切块重排，不重编码）

## 致谢

感谢上游项目 [JMComic-Api-Java](https://github.com/JUKOMU/JMComic-Api-Java) 及其作者 [JUKOMU](https://github.com/JUKOMU) 提供的接口能力参考。
