# 接口文档

本文档记录 JMComic 阅读器涉及的所有网络接口，包括外部 API、内建 Web 服务器、图片代理和同步接口。

> 本项目的接口加解密、域名轮换、图片解重组等机制参考自上游 [JMComic-Api-Java](https://github.com/JUKOMU/JMComic-Api-Java)，详见 [upstream.md](upstream.md)。架构与模块见 [architecture.md](architecture.md)。

---

## 目录

1. [外部 API（签名请求 + AES 加密响应）](#1-外部-api签名请求--aes-加密响应)
2. [静态资源 URL（无签名）](#2-静态资源-url无签名)
3. [域名服务器（启动引导）](#3-域名服务器启动引导)
4. [内建 LAN Web 服务器](#4-内建-lan-web-服务器)
5. [GitHub 同步](#5-github-同步)
6. [加密与签名机制](#6-加密与签名机制)
7. [域名配置](#7-域名配置)

---

## 1. 外部 API（签名请求 + AES 加密响应）

所有请求通过 `JmClient.getJSON()` 发出，均为 `GET` 方法。

**通用请求头：**
| Header | 值 | 说明 |
|---|---|---|
| `token` | `md5(timestamp + "18comicAPP")` | 签名 token |
| `tokenparam` | `"{timestamp},231024"` | 时间戳 + appVersion |
| `user-agent` | Android Chrome UA | 伪装移动端 |

**通用响应处理：** JSON 信封 → `data` 字段 Base64 解码 → AES-ECB 解密（密钥 = `md5(timestamp + "185Hcomic3PAPP7R")`）

### 1.1 热门/推荐列表

| 项目 | 值 |
|---|---|
| 路径 | `/search` |
| 方法 | `GET` |
| 参数 | `main_tag=0`, `search_query=""`, `o=mv`, `t=w`, `page={page}` |
| 用途 | 获取热门/推荐漫画列表（按浏览量排序，周榜） |
| 响应 | `PagedAlbums`（分页专辑列表） |
| 代码 | `JmClient.swift:155-163` |

### 1.2 最新更新

| 项目 | 值 |
|---|---|
| 路径 | `/latest` |
| 方法 | `GET` |
| 参数 | `page={page}` |
| 用途 | 获取最新更新的漫画 |
| 响应 | `PagedAlbums` |
| 代码 | `JmClient.swift:166-170` |

### 1.3 关键词搜索

| 项目 | 值 |
|---|---|
| 路径 | `/search` |
| 方法 | `GET` |
| 参数 | `main_tag=0`, `search_query={text}`, `page={page}` |
| 用途 | 按关键词搜索漫画 |
| 响应 | `PagedAlbums` |
| 代码 | `JmClient.swift:173-179` |

### 1.4 精确作者/标签搜索

| 项目 | 值 |
|---|---|
| 路径 | `/search` |
| 方法 | `GET` |
| 参数 | 作者：`main_tag=2`, `search_query={author}`；标签：`main_tag=3`, `search_query={tag}`；另含 `o={order}`, `t={time}`, `page={page}` |
| 用途 | 只匹配漫画作者或标签字段，支持排序、时间范围和分页 |
| 响应 | `PagedAlbums` |

`main_tag=0` 是全站关键词搜索；作者入口使用 `main_tag=2`，标签入口使用 `main_tag=3`，避免标题或其他字段中的同名词进入结果。

### 1.5 热门标签

| 项目 | 值 |
|---|---|
| 路径 | `/hot_tags` |
| 方法 | `GET` |
| 参数 | 无 |
| 用途 | 获取热门/趋势标签列表 |
| 响应 | JSON `{ "list": ["标签1", "标签2", ...] }` |
| 代码 | `JmClient.swift:183-187` |

### 1.6 分类筛选

| 项目 | 值 |
|---|---|
| 路径 | `/categories/filter` |
| 方法 | `GET` |
| 参数 | `page={page}`, `order=""`, `c={category}`, `o={order}` |
| `category` 可选值 | `doujin`, `single`, `short`, `hanman`, `meiman`, `cosplay`, `3D` 等 |
| `order` 可选值 | `mv`（最多浏览）等 |
| 用途 | 按分类筛选漫画 |
| 响应 | `PagedAlbums` |
| 代码 | `JmClient.swift:191-199` |

### 1.7 专辑详情

| 项目 | 值 |
|---|---|
| 路径 | `/album` |
| 方法 | `GET` |
| 参数 | `comicName=""`, `id={id}` |
| 用途 | 获取漫画完整详情（章节、标签、相关作品、简介等） |
| 响应 | `Album`（通过 `JmParser.parseAlbum` 解析） |
| 代码 | `JmClient.swift:201-207` |

### 1.8 章节详情

| 项目 | 值 |
|---|---|
| 路径 | `/chapter` |
| 方法 | `GET` |
| 参数 | `id={id}` |
| 用途 | 获取章节内页列表（图片文件名、scramble_id） |
| 响应 | `Chapter`（含 `ComicPage` 数组，每页有 CDN URL 和解密参数） |
| 缓存 | 按 chapter ID 内存缓存 |
| 代码 | `JmClient.swift:211-219` |

---

## 2. 静态资源 URL（无签名）

### 2.1 封面图片

| 项目 | 值 |
|---|---|
| URL | `https://{host}/media/albums/{albumId}_3x4.jpg` |
| 方法 | `GET` |
| 用途 | 获取专辑封面（3:4 比例 JPEG） |
| 域名 | API 域名池 |
| 代码 | `JmClient.swift:147-151` |

### 2.2 漫画内页图片

| 项目 | 值 |
|---|---|
| URL | `https://{host}/media/photos/{photoId}/{filename}` |
| 方法 | `GET` |
| 用途 | 获取单张漫画页面图片 |
| 域名 | CDN 域名池（6 个域名轮询） |
| 代码 | `JmParser.swift:124` |

---

## 3. 域名服务器（启动引导）

### 3.1 域名列表拉取

| 项目 | 值 |
|---|---|
| 主 URL | `https://rup4a04-c01.tos-ap-southeast-1.bytepluses.com/newsvr-2025.txt` |
| 备用 URL | `https://rup4a04-c02.tos-cn-hongkong.bytepluses.com/newsvr-2025.txt` |
| 方法 | `GET` |
| 用途 | 获取 AES 加密的 API 域名列表 |
| 响应 | Base64 编码 → AES 解密（密钥 = `"diosfjckwpqpdfjkvnqQjsik"`），JSON 含 `Server` 和 `Setting` 数组 |
| 触发时机 | 首次 API 调用时 `JmClient.bootstrap()` 执行 |
| 代码 | `JmConstants.swift:20-23`, `JmClient.swift:52-77` |

### 3.2 备用域名（域名服务器不可达时）

```
www.cdnhjk.net
www.cdngwc.cc
www.cdngwc.net
www.cdngwc.club
```

代码：`JmConstants.swift:26-28`

### 3.3 图片 CDN 域名（专用池）

```
cdn-msp.jmapiproxy1.cc
cdn-msp.jmapiproxy2.cc
cdn-msp2.jmapiproxy2.cc
cdn-msp3.jmapiproxy2.cc
cdn-msp.jmapinodeudzn.net
cdn-msp3.jmapinodeudzn.net
```

代码：`JmConstants.swift:30-34`

---

## 4. 内建 LAN Web 服务器

默认端口 **8973**，支持 HTTP 和 HTTPS（自签名证书）。完整路由在 `WebService.swift` 中实现。

### 认证体系

三层认证机制（`WebAuth.swift`）：

| 层级 | 凭证 | 有效期 | 绑定 |
|---|---|---|---|
| Entry Token | URL 参数 `?t=` | 一次性 | — |
| Preauth Cookie | `jm_preauth` | 5 分钟 | IP |
| Session Cookie | `jm_token` | 7 天 | IP |

- 密码存储：PBKDF2-HMAC-SHA256，210,000 轮，16 字节随机 salt
- Token 生成：32 字节 `SecRandomCopyBytes`（密码学安全）
- 比较：常量时间字节比较
- 限流：同一 IP 5 次失败 = 300 秒锁定
- 设备信任：Session 有 `trusted` 标志，非受信设备只读

### 4.1 认证端点

#### 入场 Token 消费

| 项目 | 值 |
|---|---|
| 路径 | `/?t={token}` 或 `/entry?t={token}` |
| 方法 | `GET` |
| 认证 | 无（消耗 token） |
| 行为 | 消耗一次性入场 token。若 `scanAutoLogin` 启用则直接创建会话（302 → `/`），否则授予 preauth（5 分钟 cookie）并重定向到 `/login` |
| 代码 | `WebService.swift:189-212` |

#### 登录页面

| 项目 | 值 |
|---|---|
| 路径 | `/login` |
| 方法 | `GET` |
| 认证 | 需要 `jm_preauth` cookie |
| 响应 | HTML 登录表单 |
| 代码 | `WebService.swift:226-229` |

#### 密码认证

| 项目 | 值 |
|---|---|
| 路径 | `/login` |
| 方法 | `POST` |
| Content-Type | `application/x-www-form-urlencoded` |
| Body 参数 | `password` |
| 认证 | 需要 `jm_preauth` cookie |
| 响应 | 302 → `/`，`Set-Cookie: jm_token={token}; Max-Age=604800; HttpOnly; SameSite=Strict` |
| 安全 | PBKDF2 密码验证、限流、常量时间比较 |
| 代码 | `WebService.swift:231-233`, handler: `264-288` |

#### 登出

| 项目 | 值 |
|---|---|
| 路径 | `/logout` |
| 方法 | `POST` |
| 认证 | 需要 `jm_token` session cookie |
| 响应 | 302 → `/`，`Set-Cookie: jm_token=; Max-Age=0`（过期 cookie） |
| 代码 | `WebService.swift:235-243` |

### 4.2 数据 API 端点

#### 浏览 Feed（热门/最新/搜索）

| 项目 | 值 |
|---|---|
| 路径 | `/api/feed` |
| 方法 | `GET` |
| 认证 | 需要 `jm_token` |
| 参数 | `kind`（hot/latest/search）、`page`（默认 1）、`q`（搜索时必填） |
| 响应 | `{"items": [{"id","title","author"}], "hasMore": bool}` |
| 代理到 | `JmClient.shared.hot()` / `latest()` / `search()` |
| 代码 | `WebService.swift:295-315` |

#### 最近浏览

| 项目 | 值 |
|---|---|
| 路径 | `/api/recent` |
| 方法 | `GET` |
| 认证 | 需要 `jm_token` |
| 响应 | `{"items": [{"id","title","author"}], "hasMore": false}` |
| 数据源 | `LibraryStore.shared.recentlyViewed`（本地缓存，最多 30 条） |
| 代码 | `WebService.swift:317-324` |

#### 个性化推荐

| 项目 | 值 |
|---|---|
| 路径 | `/api/personalized` |
| 方法 | `GET` |
| 认证 | 需要 `jm_token` |
| 响应 | `{"items": [{"id","title","author"}], "tags": [...], "hasMore": false}` |
| 数据源 | `LibraryStore.shared.recommendations()`（本地标签画像算法） |
| 代码 | `WebService.swift:326-333` |

#### 收藏切换

| 项目 | 值 |
|---|---|
| 路径 | `/api/favorites/toggle` |
| 方法 | `POST`（非 POST 返回 405） |
| Content-Type | `application/x-www-form-urlencoded` |
| Body 参数 | `id`（必填）、`title`（可选） |
| 认证 | 需要 `jm_token` + 受信设备（非受信返回 403） |
| 响应 | `{"favorited": true/false}` |
| 行为 | 在 `FavoriteStore` 中切换收藏状态 |
| 代码 | `WebService.swift:335-353` |

#### 上报阅读进度

| 项目 | 值 |
|---|---|
| 路径 | `/api/progress` |
| 方法 | `POST`（非 POST 返回 405） |
| Content-Type | `application/x-www-form-urlencoded` |
| Body 参数 | `albumId`（必填）、`chapterId`（必填）、`sort`（int, 必填）、`page`（int ≥ 0, 必填）、`title`（可选） |
| 认证 | 需要 `jm_token` + 受信设备（非受信返回 403） |
| 响应 | `{"ok": true}` |
| 行为 | 将 Web 阅读进度同步到 `LibraryStore`（与 Mac 端双向同步） |
| 代码 | `WebService.swift:355-371` |

#### 阅读历史

| 项目 | 值 |
|---|---|
| 路径 | `/api/history` |
| 方法 | `GET` |
| 认证 | 需要 `jm_token` |
| 响应 | `{"items": [{"id","title","author"}], "hasMore": false}` |
| 数据源 | `LibraryStore.shared.history`（本地，最多 60 条） |
| 代码 | `WebService.swift:373-379` |

#### 专辑详情

| 项目 | 值 |
|---|---|
| 路径 | `/api/album` |
| 方法 | `GET` |
| 认证 | 需要 `jm_token` |
| 参数 | `id`（必填） |
| 响应 | `{"id", "title", "author", "description", "tags", "views", "likes", "favorited", "position": {...} | null, "chapters": [...], "related": [...]}` |
| 代理到 | `JmClient.shared.album(id:)`，附加本地进度和收藏状态 |
| 代码 | `WebService.swift:381-402` |

#### 章节内页列表

| 项目 | 值 |
|---|---|
| 路径 | `/api/chapter` |
| 方法 | `GET` |
| 认证 | 需要 `jm_token` |
| 参数 | `id`（必填）、`sort`（默认 1） |
| 响应 | `{"id", "title", "pages": [{"index": 0, "src": "/img/page?chapter={id}&i=0"}, ...]}` |
| 注意 | 真实 CDN URL 不暴露给浏览器，页面通过 `/img/page` 代理 |
| 代码 | `WebService.swift:404-419` |

### 4.3 图片代理端点

#### 封面图片代理

| 项目 | 值 |
|---|---|
| 路径 | `/img/cover` |
| 方法 | `GET` |
| 认证 | 需要 `jm_token` |
| 参数 | `id`（专辑 ID） |
| 响应 | `image/jpeg`，`Cache-Control: private, max-age=604800` |
| 行为 | 通过 `ImageStore.shared.cover()` 获取封面，返回解码后的 JPEG |
| 代码 | `WebService.swift:421-427` |

#### 漫画页面图片代理

| 项目 | 值 |
|---|---|
| 路径 | `/img/page` |
| 方法 | `GET` |
| 认证 | 需要 `jm_token` |
| 参数 | `chapter`（章节 ID, 必填）、`i`（页码索引, 必填） |
| 响应 | `image/jpeg`，`Cache-Control: private, max-age=604800` |
| 行为 | 通过 `ImageStore.shared.page()` 获取页面（含解重组），返回解码后的 JPEG。CDN URL 不暴露给客户端 |
| 代码 | `WebService.swift:429-447` |

### 4.4 Web 应用 Shell

#### 主页面

| 项目 | 值 |
|---|---|
| 路径 | `/` |
| 方法 | `GET` |
| 认证 | 需要 `jm_token` |
| 响应 | 完整 SPA HTML（`WebUI.appShell`），内联 CSS + JS（约 20KB） |
| 代码 | `WebService.swift:292-293` |

---

## 5. GitHub 同步

通过系统 `git` CLI 与 GitHub 私有仓库同步加密数据。

| 项目 | 值 |
|---|---|
| 传输方式 | `/usr/bin/git` CLI 子进程 |
| 认证 | GitHub Personal Access Token，存于 macOS 钥匙串。HTTP Basic Auth：`Authorization: Basic base64("x-access-token:{token}")` |
| 数据格式 | 单文件 `backup.bin`（salt + AES-GCM 加密 JSON）。PBKDF2-HMAC-SHA256（210,000 轮）从用户密码派生加密密钥 |
| 载荷结构 | `{"favorites": base64(...), "state": base64(...)}` — 收藏和阅读进度/状态 |
| 操作 | `git clone` → `git pull` → `git add backup.bin` → `git commit` → `git push` |
| 冲突解决 | 拉取远程 → 本地合并（收藏按 ID、进度按 `updatedAt` 最新者胜出）→ 重新打包 → 推送。推送失败则重试一次 |
| 存储路径 | `~/Library/Application Support/JMComicDev/backup.bin` |
| 代码 | `SyncStore.swift:196-269` |

---

## 6. 加密与签名机制

### 6.1 请求签名

| 项目 | 值 |
|---|---|
| 文件 | `JmCrypto.swift:22-24` |
| 算法 | `token = md5(timestamp + "18comicAPP")` |
| 附加头 | `tokenparam = "{timestamp},231024"` |

### 6.2 响应解密

| 项目 | 值 |
|---|---|
| 文件 | `JmCrypto.swift:27-46` |
| 算法 | Base64 解码 → AES-256-ECB 解密（PKCS7 填充） |
| 密钥 | `md5(timestamp + "185Hcomic3PAPP7R")` 作为 UTF8 字节（32 字节 = AES-256） |

### 6.3 域名服务器响应解密

| 项目 | 值 |
|---|---|
| 密钥 | `"diosfjckwpqpdfjkvnqQjsik"` |
| 算法 | AES 解密 Base64 响应 |

### 6.4 密钥常量

| 常量 | 值 | 用途 |
|---|---|---|
| `tokenSecret` | `"18comicAPP"` | 请求签名 |
| `dataSecret` | `"185Hcomic3PAPP7R"` | 响应解密 |
| `domainServerSecret` | `"diosfjckwpqpdfjkvnqQjsik"` | 域名服务器响应解密 |
| `appVersion` | `"231024"` | 请求头中的版本号 |

代码：`JmConstants.swift:4-6`

---

## 7. 域名配置

### API 域名池（动态获取 + 备用）

主备域名服务器拉取，失败时使用备用域名。域名通过 `JmDomainManager` 管理，支持自动探活和轮换。

### 图片 CDN 域名池（硬编码）

6 个 CDN 域名轮询（取模分配），用于漫画内页图片下载：

```
cdn-msp.jmapiproxy1.cc
cdn-msp.jmapiproxy2.cc
cdn-msp2.jmapiproxy2.cc
cdn-msp3.jmapiproxy2.cc
cdn-msp.jmapinodeudzn.net
cdn-msp3.jmapinodeudzn.net
```

### 域名轮换机制

- 请求不绑定固定域名，使用 `PLACEHOLDER_HOST` 占位
- `RetryAndDomainRedirectInterceptor` 在实际发送时替换为最佳域名
- HTTP 非 200 / 解密失败时自动切换下一个域名并计数
- 后台 `DomainProbe` 定期探活，剔除不可用域名

代码：`JmClient.swift:86-136`
