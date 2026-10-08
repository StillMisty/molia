# LX 音源（LX Music 自定义源）支持说明

本项目的「音源」能力与 [LX Music](https://github.com/lyswhut/lx-music-desktop) 自定义源脚本（API v2.0.0）兼容，
并预留了接入 [any-listen](https://github.com/any-listen/any-listen) 的抽象。

## 功能概览

- **音源管理**（设置 → 音源 → 音源管理）：
  - **导入**：文件 / 粘贴 / 链接（无 scheme 自动补 `https://`，下载中有进度与可读错误）；
  - **在线更新**：脚本 meta 支持 `@updateUrl`；运行时 `lx.updateAlert({log, updateUrl})`
    会把更新地址记入当前脚本；提供「立即更新」（下载 → 校验 → 原地替换 → 激活中自动重放），
    更新地址为网页时提示手动打开；
  - 启用 / 停用 / 删除 / 排序 / 默认音质（默认 320K，自动回退）。
- **搜索**：结果页顶部可选择音源——
  - 内置平台（与 LX 一致，Dart 移植）：酷我 `kw`、酷狗 `kg`、QQ 音乐 `tx`、网易云 `wy`、咪咕 `mg`；
  - 脚本扩展搜索：声明了 `search` / `musicSearch` 的第三方音源；
  - 搜索经 `CatalogService`（single-flight + LRU，5min TTL），分页由 `hasMore/total` 驱动。
- **发现**（资料页，底部「资料」）：
  - 顶部「搜索 / 热榜 / 歌单」三个可左右滑动的 tab；
  - 热榜与歌单页内可切换平台：网易云 `wy` / QQ `tx` / 酷狗 `kg` / 酷我 `kw` / 咪咕 `mg`，
    各自为 lx-music-mobile `*/leaderboard.js`、`*/songList.js`、`*/hotSearch.js` 的 Dart 移植
    （`lib/sources/builtin/*_discover.dart`，统一的 `DiscoverSource` 注册表）；
  - 歌曲搜索（搜索 tab）与内置平台搜索能力一致，热搜词跟随当前发现平台；
  - 个人内容（最近播放 / 播放历史 / 我的列表 / `.lxmc` 导入）在收藏页：合集 chips
    切换「我的收藏 / 列表 / 播放历史」，行内 ♥ 与搜索/排序语义与收藏一致。
- **播放**：点击结果后由 App 本地播放（`just_audio`，桌面端经 `media_kit` 后端），
  NowPlaying / 歌词 / 海报等界面自动复用；取链结果有 10min 缓存（key 含音源/payload hash/音质）。
- **歌词 / 封面**：脚本声明 `lyric` / `pic` 时优先使用脚本返回；歌词失败时回退 QQ / 网易 / LRCLIB 歌词源。

## 使用流程

1. 从社区（如 GitHub 搜索 `lx-music-source`）获取音源脚本 `.js` 文件或直链；
2. 设置 → 音源 → 音源管理 → 导入（文件 / 粘贴 / 链接）；
3. 脚本激活后，底部搜索框搜索，在结果页顶部选择该音源对应的平台；
4. 点击歌曲即可播放。默认音质可在音源管理页设置（默认 320K，自动回退）；
5. 脚本带 `@updateUrl` 或运行时更新提醒时，可在音源管理页一键更新。

> 音源脚本为第三方可执行代码，导入前请确认来源可信；脚本可发起网络请求，
> 其可用性与合法性由脚本提供者负责。

## 架构

```
lib/sources/
  source_track.dart          # 统一曲目模型（raw 原样回传脚本）
  source_manager.dart        # 音源注册与调度（搜索 / 取链 / 歌词 / 封面 / 排序 / 激活）
  builtin/                   # 内置平台搜索（kw/kg/tx/wy/mg）与加密工具
  lx/
    lx_script_info.dart      # 脚本元信息（@name/@version/@updateUrl...）与源声明解析
    lx_script_repository.dart# 脚本持久化（应用支持目录 lx_sources.json；replace 原地更新）
    lx_script_update.dart    # 在线检查/更新：下载（10s/1MB 上限）+ 校验 + HTML 识别
    lx_engine.dart           # 引擎入口（Web 平台为占位实现）
    lx_engine_native.dart    # isolate + flutter_js（QuickJS/JSC）实现
    lx_engine_supervisor.dart# 状态机 + 退避重启（0.5s/2s/8s，连续 3 次 → failed）
    lx_native_utils.dart     # 同步工具：md5 / AES / RSA NoPadding / randomBytes / zlib
  any_listen/                # any-listen 适配（配置 / API / 错误模型；HTTP 占位，官方为 WS IPC）
assets/lx/lx_prelude.js      # globalThis.lx（API v2.0.0，env=mobile）

lib/data/catalog/            # SourceManagerMusicSource / SourceRegistryImpl / CatalogService
lib/domain/ports/            # MusicSource / SourceRegistry / PlaybackFacade 等接口
lib/playback/
  local_playback_service.dart # 本地播放队列（just_audio），输出播放器形状兼容 map
  desktop_audio_init*.dart    # Windows/Linux media_kit 初始化
```

### 引擎要点

- 脚本在**独立 isolate** 中运行，出现死循环 / 超时可整体 kill 恢复；
- JS → Dart 使用 `sendMessage('lx', JSON)`，Dart → JS 使用 `__lxDeliver(...)`；
- `lx.utils.crypto / buffer / zlib` 通过 flutter_js 的 JSInvokable 机制**同步**绑定到 Dart
  （pointycastle + dart:io zlib），行为经 Node.js crypto 向量单测校验；
- 支持 `request`（method/headers/body/form/formData/timeout/follow_max、取消）与
  `inited / request / updateAlert` 事件；兼容社区扩展 action：`search` / `musicSearch`；
- **自愈监督**：`LxEngineSupervisor` 崩溃后自动退避重启并重放同一脚本，重启成功刷新
  `activeSources`（修复「引擎已死但源列表还在」）；连续失败进入 `failed` 停用；
- **请求缓存**：搜索 5min、取链 10min（失败不缓存，single-flight 并发去重）。

### any-listen 预留

`lib/domain/ports` 定义 `MusicSource` / `SourceRegistry` 接口，`lib/data/catalog` 提供
`SourceManager` 适配实现；any-listen 以新增一个 `MusicSource` 适配器（远程客户端或本地扩展）
接入即可，搜索页 / 播放器 / 歌词 / 通知栏无需改动。

## 开发与验证

- `flutter test`：加密向量、脚本元信息解析、引擎监督状态机、在线更新流程、
  内置平台搜索解析（真实响应夹具）、any-listen 配置、架构分层扫描。
- `node tool/lx_prelude_harness.mjs`：在 Node 沙箱中验证 prelude 协议全链路
  （inited → request → musicUrl → response、utils 桥接）。
- `node tool/gen_search_fixtures.mjs`：重新抓取各平台真实响应，更新 `test/fixtures/*.json`。
- 构建环境（WSL/Arch 参考）：
  - Linux 桌面：`sudo pacman -S --needed base-devel ninja cmake clang pkgconf gtk3 mesa-utils`
    - 本地播放依赖 libmpv：`sudo pacman -S --needed mpv`（media_kit 后端需要）
    - **中文字体**：`sudo pacman -S --needed wqy-microhei`（App 不内置 CJK 字体；否则中文显示方块）
  - Android（用户态安装）：`sdkmanager "platform-tools" "platforms;android-37.0" "build-tools;37.0.0" "ndk;30.0.16248370"`，
    然后 `flutter config --android-sdk "$HOME/Android/Sdk"`
  - 工程工具链：Gradle 9.8.0 + AGP 9.4.1 + Kotlin 2.4.20 + JDK 27（Flutter 3.47.6 stable），
    `compileSdk/targetSdk/minSdk = 37`、NDK r30
  - 注意：`minSdk = 37` 意味着只有 Android 17 及以上设备可安装此构建
  - flutter_js 在 Linux 的上游 CMake 存在 bundled library 变量名错误，
    `linux/CMakeLists.txt` 中已显式补装 `libquickjs_c_bridge_plugin.so`（引擎必需）

## 已知限制（后续计划）

- any-listen 真实协议（WS IPC）尚未接入，当前为 HTTP 占位端点；
- 脚本扩展搜索的返回格式为社区约定，字段兼容性尽力而为；
- 部分平台直链需要 Referer/UA 头，当前由脚本自行处理；
- Web 端不支持音源脚本（无本地 JS 引擎），界面已做降级；
- iOS/Android 后台播放与通知/耳机键需真机验证。
