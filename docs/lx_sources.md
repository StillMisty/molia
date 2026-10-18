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
  - 搜索经 `CatalogService`（single-flight + LRU，5min TTL），分页由 `hasMore/total` 驱动；
  - **结果类型分段**（内置平台按能力位显示）：**单曲 / 歌手 / 歌词**
    （歌手条目进歌手页；歌词为按歌词搜歌，行副标题显示命中片段）；
    脚本源只有单曲（无稳定的平台歌手 id 与歌词检索约定）。
- **歌手页**（歌曲信息页「歌手」行 / 搜索结果行内歌手名 / 歌手条目进入）：
  头像 / 简介 + 歌手歌曲分页（曲目行与搜索结果行同款：操作菜单收藏 / 加入列表，
  触摸端行尾 ⋮ / 桌面行表面右键）
  + 播放全部 / 加入列表，取数走 `ArtistService`（10min 缓存）；
  - 歌手 id 来自曲目 payload 的 `_artists`（内置平台解析时注入），与平台歌手接口同体系；
    没有 id 的旧数据（历史收藏 / 导入列表）按歌手名回退检索（精确匹配，`ArtistService.resolveByName`）；
  - 平台降级：kg 歌手搜索单页、tx 歌手歌曲单页约 60 首、mg 无歌手简介。
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
- **歌词 / 封面**：脚本声明 `lyric` / `pic` 时优先使用脚本返回；否则走内置平台
  原生实现（wy/tx/kg/kw/mg 的精确 ID 取词取图，含逐字 / 翻译 / 罗马音），
  全部失败时回退 QQ / 网易 / 酷狗 / 酷我 / 咪咕 / LRCLIB 名字搜索歌词源；
  曲目起播无封面时自动补取并回写队列（省流模式不发请求）。

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
  builtin/                   # 内置平台搜索 / 歌手 / 歌词检索（kw/kg/tx/wy/mg）、原生取词/取图与加密工具
    kg_lyric.dart kg_pic.dart    # 酷狗 KRC 取词 / get_res_privilege 取图
    kw_lyric.dart kw_pic.dart    # 酷我 LRCX 取词（H5 兜底）/ pic.web 取图
    mg_lyric.dart                # 咪咕 MRC（TEA）取词 / 资源封面
    tx_lyric.dart tx_qrc.dart    # QQ PlayLyricInfo + QRC（定制 3DES）解码
    wy_lyric.dart wy_music_detail.dart  # 网易云 eapi + yrc / 歌曲详情
  lx/
    lx_script_info.dart      # 脚本元信息（@name/@version/@updateUrl...）与源声明解析
    lx_script_repository.dart# 脚本持久化（应用支持目录 lx_sources.json；replace 原地更新）
    lx_script_update.dart    # 在线检查/更新：下载（10s/1MB 上限）+ 校验 + HTML 识别
    lx_engine.dart           # 引擎入口（原生 isolates + FFI，自愈监督）
    lx_engine_native.dart    # isolate + quickjs_engine（QuickJS-NG）实现
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

- 脚本在**独立 isolate** 中运行；调用超时不再整体 kill——先探活（ping/pong）判定：
  有在途 HTTP 时按脚本声明的超时延长预算、空闲即抛 `LxEngineTimeoutException`（只失败
  该请求）；只有事件循环被卡死（无应答）才 kill 重启。supervisor 对连续超时熔断
  （默认 3 次 → `failed` + `failureReason`，再次 `start` 可恢复）；
- JS → Dart 使用 `sendMessage('lx', JSON)`，Dart → JS 通过 `__lxDeliver` / `__lxSetup` 的
  **JSInvokable 值直投**（不再把消息拼成 JS 源码 evaluate）；HTTP 响应只下发原文
  `raw`，`body` 由 prelude 在 JS 侧 `JSON.parse` 还原（失败 / 空串退化为原文）；
- `lx.utils.crypto / buffer / zlib` 通过 quickjs_engine 的 JSInvokable 机制**同步**绑定到 Dart
  （pointycastle + dart:io zlib），行为经 Node.js crypto 向量单测校验；
- 宿主↔脚本：`globalThis.lx.on('request'|'inited'|'updateAlert')`、`lx.send(...)`、
  `lx.request(url, options, cb)`；支持 `request`（method/headers/body/form/formData/timeout/
  follow_max、取消）；`follow_max` 为显式数值时**逐请求**生效——`0` = 不跟随重定向
  （3xx 原样交给脚本，响应体照常可读）、`>0` = 最多跟随 N 跳（再遇 3xx 报请求错误）；
  未声明时保持宿主默认（最多 5 跳）——LX 两端本身不一致（桌面版底层 needle 默认
  `follow_max: 0` 不跟随、移动版底层 fetch 默认跟随，且都未把脚本声明的 `follow_max`
  透传到请求层），没有可对齐的统一定义，故不声明时不改变存量脚本的取链结果；
- 官方 action：`musicUrl` / `lyric` / `pic`（后两者通常仅 `local` 源）；社区扩展 action：
  `search` / `musicSearch`（非官方约定，本项目兼容）；
- 安全边界：脚本是不可信代码，不暴露文件系统/平台通道，网络只走 `lx.request` 桥；
  `currentScriptInfo` 必须原样透传（部分脚本有防篡改校验，失败会死循环）；
- 内联前导脚本**源码**在 `tool/lx_prelude/lx_prelude.js`（唯一修改入口），打包产物
  `assets/lx/lx_prelude.js` 由 `node tool/build_lx_prelude.mjs`（terser，版本固定）生成；
  改源码后必须重新生成（`--check` 校验产物同步），不要手改产物；ELECTRON 兼容 shim
  （`atob/btoa/TextEncoder/setTimeout/window/navigator` 等）也加在这里；
- **自愈监督**：`LxEngineSupervisor` 崩溃后自动退避重启并重放同一脚本，重启成功刷新
  `activeSources`（修复「引擎已死但源列表还在」）；连续失败进入 `failed` 停用；
- **请求缓存**：搜索 5min、取链 10min（失败不缓存，single-flight 并发去重）；
- **引擎选型**：JS 运行时为 quickjs_engine（QuickJS-NG 0.14.0）。依据：API 与 flutter_js
  同源（`evaluate(sourceUrl:)` / `JsEvalResult` / `JSInvokable` / `executePendingJob`），
  JSInvokable 是**同步** FFI 调用，满足脚本侧 `lx.utils.crypto` 的同步语义（fjs 仅异步
  bridge、lemon_js API 不同，均不兼容）；QuickJS-NG 支持 `Symbol.iterator` / `Proxy` /
  `BigInt` 等 ES2020+ 语法，早期 QuickJS 构建缺这些特性会让音源脚本直接解析失败；
  Linux / Android 原生库由包自身 CMake 从源码编译，arm64 实测 16 KB 页对齐。
  不调 `getJavascriptRuntime()`（它会装内置 fetch 与 handlePromises 辅助 JS，
  见 pitfalls #2），直接建 `QuickJsRuntime2(stackSize: 1 MiB, memoryLimit: 64 MiB)`
  为不可信脚本兜底；Linux 侧需一处仓库补丁，见 pitfalls #1。

### any-listen 预留

`lib/domain/ports` 定义 `MusicSource` / `SourceRegistry` 接口，`lib/data/catalog` 提供
`SourceManager` 适配实现；any-listen 以新增一个 `MusicSource` 适配器（远程客户端或本地扩展）
接入即可，搜索页 / 播放器 / 歌词 / 通知栏无需改动。

## 开发与验证

- `flutter test`：加密向量、脚本元信息解析、引擎监督状态机、在线更新流程、
  内置平台搜索解析（真实响应夹具）、专辑解析（`test/builtin_album_parse_test.dart`，
  真实响应夹具）、any-listen 配置、架构分层扫描。
- `node tool/lx_prelude_harness.mjs`：在 Node 沙箱中验证 prelude 协议全链路
  （inited → request → musicUrl → response、utils 桥接）。
- `node tool/gen_search_fixtures.mjs`：重新抓取各平台真实响应，更新 `test/fixtures/*.json`。
- `node tool/gen_album_fixtures.mjs`：重新抓取各平台真实专辑响应，更新
  `test/fixtures/albums/*.json`（曲目列表截断到 3 条控制体积）。
- `node tool/gen_artist_fixtures.mjs`：重新抓取五平台歌手搜索 / 详情 / 歌曲响应，
  更新 `test/fixtures/artists/*`（kw 的 wbd 响应存密文，测试里跑解密）。
- `node tool/gen_lyric_search_fixtures.mjs`：重新抓取五平台歌词搜索响应，更新
  `test/fixtures/lyric_search/*`（列表截断到 3 条；wy 另抓歌曲详情用于补规范 raw）。
- 构建环境（WSL/Arch 参考）：
  - Linux 桌面：`sudo pacman -S --needed base-devel ninja cmake clang pkgconf gtk3 mesa-utils`
    - 本地播放依赖 libmpv：`sudo pacman -S --needed mpv`（media_kit 后端需要）
    - **中文字体**：`sudo pacman -S --needed wqy-microhei`（App 不内置 CJK 字体；否则中文显示方块）
  - Android（用户态安装）：`sdkmanager "platform-tools" "platforms;android-37.0" "build-tools;37.0.0" "ndk;30.0.16248370"`，
    然后 `flutter config --android-sdk "$HOME/Android/Sdk"`
  - 工程工具链：Gradle 9.8.1 + AGP 9.4.1 + Kotlin 2.4.21 + JDK 27（Flutter 3.47.6 stable），
    `compileSdk/targetSdk/minSdk = 37`、NDK r30、Java/Kotlin 字节码 target 26（Kotlin 2.4.x JvmTarget 上限）
  - 注意：`minSdk = 37` 意味着只有 Android 17 及以上设备可安装此构建
  - JS 运行时为 quickjs_engine（QuickJS-NG），Linux / Android 原生库由包自身 CMake 从源码
    编译（Linux bundle 实测含 `libquickjs_c_bridge_plugin.so`，需 `linux/CMakeLists.txt`
    末端一处导出宏补丁，见 pitfalls #1）

改动引擎/音源的完整验证清单：

1. `flutter analyze --no-pub` 0 error / 0 warning；
2. `flutter test --no-pub`（含 `test/lx_core_test.dart`、`test/lx_supervisor_test.dart`、
   `test/lx_script_update_test.dart`、`test/builtin_search_parse_test.dart`、
   `test/builtin_lyric_decode_test.dart`（KRC/LRCX/QRC/MRC 合成数据闭环）、
   `test/source_manager_builtin_lyric_test.dart`、`test/architecture/layering_test.dart`）；
3. `node tool/lx_prelude_harness.mjs` 输出 `PROTOCOL OK`；
4. `tool/agent/test.sh linux`（等价 `flutter test integration_test/lx_engine_integration_test.dart
   -d linux`）：真实导入→搜索→取链→歌词；不含真实播放（无头环境 libmpv 装载不可靠，
   见 `docs/pitfalls.md` #33），默认跑在 Xvfb 上（无窗口，`--window` 才上真实显示）；
5. `tool/agent/test.sh android`（模拟器，官方 flutter test 路径）：同一份引擎/UI 用例；
   跑完自动卸载，不污染设备状态；
6. 真机/模拟器验证：设置 → 音源管理 → 导入社区脚本（或在线更新）→ 搜索 → 播放。

## 已知限制（后续计划）

- any-listen 真实协议（WS IPC）尚未接入，当前为 HTTP 占位端点；
- 脚本扩展搜索的返回格式为社区约定，字段兼容性尽力而为；
- 部分平台直链需要 Referer/UA 头，当前由脚本自行处理；
- 歌手 / 歌词检索为内置平台的非官方接口：tx 歌手歌曲无分页（约 60 首）、
  kg 歌手搜索无总数、mg 歌手无简介、kw 歌词搜索为模糊匹配、mg 歌词排序偏翻唱
  （按平台排序原样展示）；
- iOS/Android 后台播放与通知/耳机键需真机验证。
