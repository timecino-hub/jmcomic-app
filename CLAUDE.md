# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

Maven multi-module build, Java 17, no Maven wrapper (`mvn` must be on PATH).

```bash
# Build everything (skip GPG — signing is bound to the `verify` phase and will otherwise prompt/fail locally)
mvn -B -ntp -Dgpg.skip=true clean verify

# Fast compile without javadoc/sources/signing
mvn -Dgpg.skip=true -DskipTests compile

# Build one module plus its dependencies
mvn -pl jmcomic-core -am -Dgpg.skip=true -DskipTests package

# Run a single test (JUnit 5 via surefire) — no test sources exist yet
mvn -pl jmcomic-core test -Dtest=SomeTest#someMethod

# Desktop app (shaded fat jar; main class io.github.jukomu.jmcomic.desktop.JmDesktopApp)
mvn -pl jmcomic-desktop-support -am -Dgpg.skip=true -DskipTests package
./run-desktop.sh

# Docs (MkDocs Material, published to readthedocs)
pip install -r docs/requirements.txt && mkdocs serve -f docs/mkdocs.yml
```

CI (`.github/workflows/ci.yml`) runs `mvn -B -ntp -Dgpg.skip=true clean verify` on JDK 17.

## Module graph

```
jmcomic-api            zero third-party deps — interfaces, records, enums, exceptions, strategies
  └─ jmcomic-core      the implementation: clients, net, crypto, parsers, cache, download
       ├─ jmcomic-android-support   ImageProcessor SPI impl for Android (no AWT)
       ├─ jmcomic-desktop-support   Swing/FlatLaf demo app (macOS-flavored)
       └─ jmcomic-sample            usage examples — commented out of the parent <modules>
```

`jmcomic-api` must stay dependency-free — it's published for consumers who only want the contract. Anything needing OkHttp/Gson/Jsoup belongs in `jmcomic-core`.

The version (`1.1.7`) is duplicated across all poms plus `run-desktop.sh`, both READMEs, and several `docs/sources/*.md` files. A version bump has to touch all of them.

`jmcomic-swift/` sits outside the Maven build — a native macOS reader (SwiftPM, `swift run`) that reimplements the protocol rather than calling the Java code. It is not a port of `jmcomic-core`: only the ~8 API endpoints the reader needs are covered, and it deliberately shares no code, so **protocol changes must be applied in both places**. It exists because the Swing app used 3GB RSS and re-encoded every page through a JNI webp path; the Swift build uses ~160MB and decodes via system ImageIO. See its `README.md` for the equivalence proof and the parity checklist.

## Architecture

### Entry point and client hierarchy

`JmComic.newApiClient(config)` / `JmComic.newHtmlClient(config)` are the only supported construction paths — they build an `OkHttpClient` via `OkHttpBuilder` and wire it to a per-client `CookieManager` and `JmDomainManager` (state is isolated per client instance).

```
JmClient + JmDownloadClient (api module)
  └─ AbstractJmClient          shared: executor, cache, download manager, image download, close()
       ├─ JmApiClient          mobile-app API, signed requests, AES-encrypted responses  ← preferred
       └─ JmHtmlClient         scrapes the website with Jsoup
```

Both impls also implement `JmNovelClient` and `JmCreatorClient`. `JmHtmlClient` throws `UnsupportedOperationException` for ~54 methods it cannot serve — when adding a `JmClient` method, implement it in `JmApiClient` and add the explicit unsupported stub (or a real impl) in `JmHtmlClient`.

`AbstractJmClient` is `AutoCloseable`; callers use try-with-resources. Its constructor kicks off asynchronous initialization on the internal executor (fetch domains → probe them → start the periodic re-probe → subclass `initialize()`), so the first request may block on `JmDomainManager.blockUntilInitialized()`.

### Domain rotation — the placeholder-host trick

Requests are **not** built against a real host. `AbstractJmClient.newHttpUrlBuilder()` returns a builder pointed at `JmConstants.PLACEHOLDER_HOST` (`jm-placeholder.domain.com`). `RetryAndDomainRedirectInterceptor` recognizes that host and swaps in `domainManager.getBestDomain()` on every attempt, retrying across domains on IOException / 5xx / 403 and reporting success/failure back to the manager. `JmDomainManager` additionally runs a background probe (`DomainProbe`) to evict dead domains.

Consequences: never hardcode a host in a request builder, and any new request path should go through `newHttpUrlBuilder()` to inherit retry + rotation. After login, `loginHost` is pinned to the redirect host so session cookies stay valid.

Domain lists come from the network at runtime: `JmApiClient` decrypts them from `API_URL_DOMAIN_SERVER_LIST`; `JmHtmlClient` scrapes JmPub with a GitHub Pages fallback.

### Request signing and response decryption (API client)

`JmApiClient.executeGetRequest/executePostRequest` stamp a second-resolution timestamp, derive `token = md5(timestamp + secret)` and `tokenparam = "timestamp,appVersion"` via `JmCryptoTool.generateToken`, then attach them as headers. The response `data` field is Base64 + AES-ECB, keyed by `md5(timestamp + APP_DATA_SECRET)` — so **the same timestamp used for signing must be carried into `JmApiResponse`** to decrypt. That's why the timestamp is a constructor arg.

Three different secrets are in play (`APP_TOKEN_SECRET`, `APP_TOKEN_SECRET_2` for the scramble-id endpoint, `API_DOMAIN_SERVER_SECRET` for the domain server). Picking the wrong one yields a decryption failure, not an HTTP error.

`executeGetRequest` also detects the "請先登入會員" response and transparently re-logs-in using the AES-encrypted-in-memory password before retrying once.

### Parsing

`ApiParser` (JSON/Gson) and `HtmlParser` (Jsoup + `ParseHelper` selectors) are static-only classes that turn raw payloads into `jmcomic-api` records. Server responses are loosely typed — the existing code leans on null-tolerant helpers (`getJsonFieldAsString`, `safeParseInt`, `StringUtils.defaultIfBlank`). Match that defensiveness; the upstream site changes shape without notice.

### Image descrambling and the SPI

Downloaded images are sliced into horizontal segments that must be reordered. `JmImageTool.calculateNumSegments` derives the segment count from `scrambleId`/`photoId`/filename MD5 with hardcoded version thresholds (`SCRAMBLE_220980` / `268850` / `421926`). The actual pixel work goes through the `ImageProcessor` SPI: `ServiceLoader` first, then a reflective fallback to `AwtImageProcessor`. Android consumers get `AndroidImageProcessor` registered in `META-INF/services/` — this is why `jmcomic-core` must never reference `java.awt` outside `AwtImageProcessor`.

### Download subsystem

Two parallel APIs over the same machinery:

- **Fire-and-forget**: `downloadAlbum` / `downloadPhoto` overloads, plus the chained `client.download(album).withPath(...).withProgress(...).withExecutor(...).execute()` returning a `DownloadResult` (successes + per-image failures).
- **Managed tasks**: `createDownloadTask(...)` returns a `BaseDownloadTask` (ALBUM → PHOTO → IMAGE tree) that you submit to `client.downloadManager()`. `AlbumDownloadTask` is itself a `TaskObserver` of its children, aggregating progress and state upward through the 10-state `TaskState` machine.

Path layout is caller-controlled via `IAlbumPathGenerator` / `IPhotoPathGenerator` / `IDownloadPathGenerator`. Images write to a temp file and are atomically moved into place.

Thread pools: a user-supplied `ExecutorService` (`config.executor()`) is never shut down by `close()`; internally created pools are. Note `AbstractJmClient` creates *two* pools when none is supplied — one internal, one for `DownloadManager`.

`CachePool` is an LFU byte-budgeted cache keyed by `CacheKey.of(Class, id)`, used for `JmAlbum`, `JmPhoto`, and favorite pages.

## Conventions

- Code comments, Javadoc, logs, and commit messages are in **Chinese**. Commits follow `type(scope): 中文描述`, e.g. `feat(client): 实现JmHtmlClient#logout 方法`.
- Class-level Javadoc uses the project's custom tags, registered in the parent pom's javadoc plugin config:
  ```java
  /**
   * @author JUKOMU
   * @Description: ...
   * @Project: jmcomic-api-java
   * @Date: 2025/10/28
   */
  ```
- Public data models in `jmcomic-api` are Java `record`s (immutable); builders (`JmConfiguration.Builder`, `SearchQuery.Builder`, `FavoriteQuery.Builder`, `ForumQuery`) are used for inputs.
- Exceptions all descend from `JmComicException`: `NetworkException`, `ResponseException`, `ParseResponseException`, `ResourceNotFoundException` (and `AlbumNotFoundException` / `PhotoNotFoundException`).
- `slf4j-api` only in main code; no logging implementation is imposed on consumers.
- Work happens on `dev` and merges to `master` via PR.
