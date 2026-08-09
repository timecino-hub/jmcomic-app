# JMComic-Api-Java

漫画数据 API（Java）+ macOS 原生阅读器（Swift）多模块项目。

## 模块结构

```
jmcomic-api               零第三方依赖：接口 / 模型 / 枚举 / 异常
  └─ jmcomic-core         实现：客户端 / 网络 / 加密 / 解析 / 缓存 / 下载
       ├─ jmcomic-android-support   Android 图片处理 SPI
       ├─ jmcomic-desktop-support   Swing 桌面 Demo
       ├─ jmcomic-sample            用法示例（默认不编译）
       └─ jmcomic-swift             macOS 阅读器（SwiftUI + SwiftPM）
            ├─ jmcomic-swift/       Swift 版正式源码
            └─ jmcomic-swift-dev/   开发副本（测试用）
```

## Java API 库

`mvn -Dgpg.skip=true -DskipTests compile` 构建；提供专辑/章节/搜索/收藏等数据访问接口。

## macOS 阅读器（jmcomic-swift）

原生 SwiftUI 阅读器，**零第三方依赖**，含局域网 Web 服务与 GitHub 同步。

### 构建

```bash
cd jmcomic-swift
./build-app.sh --install      # 自检 → 打包 → 安装到 /Applications
swift run -c release --selfcheck   # 运行自检
```

### 功能

- **阅读**：连续滚动 / 单页翻书、键盘翻页、双击放大、沉浸顶栏、跳页条、断点续读
- **浏览**：热门/最新/历史/最近浏览/收藏/分类（多选精准筛选）/为你推荐（本地画像）
- **本地**：收藏分组、整本下载（CBZ/散图）、目录扫描导入、内容过滤（不感兴趣标签）
- **局域网**：手机扫码阅读、在线设备管理、设备信任开关（不信任设备只读）
- **安全**：AES 加密存储（密钥在钥匙串）、一次性入场 token、密码限流、可选 HTTPS
- **同步**：GitHub 私有仓库加密备份（收藏+历史+进度），换机一条命令恢复

### 隐私与安全设计

- 历史/收藏/进度全部 AES 加密落盘，密钥在 macOS 钥匙串，文件权限 0600
- Web 访问三门槛：一次性 token → 短时凭证 → 密码会话（绑定 IP + 限流）
- 数据同步到自己的 GitHub 私有仓库，仓库里只有密文

## 免责声明

本项目仅用于个人技术学习与合法用途。不包含任何内容站点的接口密钥、签名或逆向细节；请勿用于违反法律法规或平台规则的行为，使用者自行承担一切责任。
