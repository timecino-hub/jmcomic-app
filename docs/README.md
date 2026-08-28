# JMComic 文档

本目录是 JMComic（macOS + iOS 漫画阅读器）的项目文档。

## 目录

| 文档 | 内容 |
| --- | --- |
| [上游接口仓库](upstream.md) | 上游 Java API 库 [JMComic-Api-Java](https://github.com/JUKOMU/JMComic-Api-Java) 的能力全景，以及本项目实现的对照 |
| [架构与设计](architecture.md) | 模块划分、并发模型、核心组件、关键设计决策 |
| [接口文档](api.md) | 本项目涉及的所有网络接口：外部 API、内建 Web 服务、图片代理、GitHub 同步、加解密机制 |

## 上游与本项目的关系

- **上游** [JMComic-Api-Java](https://github.com/JUKOMU/JMComic-Api-Java)：Java 实现的 jmcomic 数据获取与管理库，能力全面（漫画/下载/用户/评论/收藏/小说/创作者/签到/通知/发现）。
- **本项目** jmcomic-app：用 **Swift** 从零重新实现其中的「浏览 / 阅读 / 收藏 / 同步」核心能力，并叠加原生 SwiftUI 图形界面（macOS + iOS），零第三方依赖。

> 上游是接口能力的重要参考来源。本项目的接口加解密、图片解重组、域名轮换等机制与上游保持一致，详见 [upstream.md](upstream.md)。
