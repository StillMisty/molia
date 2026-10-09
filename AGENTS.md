# AGENTS.md

本文件面向在本仓库中工作的 AI 编码代理（以及新加入的开发者），说明环境、命令、架构约定与已知坑。

## 项目概览

**Molia（茉咏）** 是一个 Flutter 音乐播放器（纯播放器定位）：

- **音源**：LX Music 自定义源脚本（QuickJS 引擎 + 自愈监督）、内置平台搜索（酷我/酷狗/QQ/网易云/咪咕）、any-listen 接入（配置页 + 适配器骨架）；
- **发现**：资料页「搜索 / 热榜 / 歌单」三个可滑动 tab，热榜与歌单支持五平台切换（`lib/sources/builtin/*_discover.dart`，自 lx-music-mobile 移植）；个人内容（播放历史 / 我的列表 / .lxmc 导入）在收藏页；
- **播放**：本地音频（just_audio；桌面 Windows/Linux 走 media_kit/libmpv）、队列/播放模式、后台播放与系统媒体通知（audio_service，Android/iOS/macOS）；
- **省流模式**：默认关闭、手动开启；仅在移动数据下把取链音质压到用户设定的上限（默认 128K），并按开关把封面限制为「仅本地缓存」（列表/预加载/取色/通知/桌面小组件均不发起新请求）；网络检测用 connectivity_plus；
- **歌词**：QQ/网易/LRCLIB 获取与显示、歌词行选择、歌词海报导出（保存相册用 gal）；
- **UI**：Material 3 Expressive（`material_3_expressive` + `material_ui`，见「M3E 约定」）；
- **明确不含**：在线账号/流媒体后端、AI 功能、笔记/记录/漫游/评分等非播放器能力。

音源子系统细节见 `docs/lx_sources.md`；架构说明见 `docs/architecture.md`。

## 工具链（当前基线）

| 组件 | 版本 | 说明 |
|---|---|---|
| Flutter | 3.47.6 stable | 当前 stable 最新 |
| Dart | 随 Flutter（^3.13） | M3E 要求 |
| JDK | 25+（已在 27 上验证） | `flutter config --jdk-dir=<path>` 可指定 |
| Gradle | 9.8.1 | `android/gradle/wrapper/gradle-wrapper.properties` |
| AGP / Kotlin | 9.4.1 / 2.4.20 | `android/settings.gradle` |
| compileSdk/targetSdk/minSdk | 37 / 37 / 37 | Android 17（minSdk=37 → 只有 Android 17+ 可安装） |
| NDK | 30.0.16248370 | |
| Android SDK | platform 37.0 + build-tools 37.0.0 | |

> 不要随意降低以上版本：Gradle 9.8 是支持 JDK 27 class 文件所需的最低版本；
> AGP/Kotlin 与该 Gradle 组合已被 `flutter analyze`/构建验证通过。

## 常用命令

```bash
flutter pub get
flutter analyze                      # 必须保持 0 error / 0 warning
flutter test                         # 单元测试（含音源/播放/架构分层）
flutter test integration_test/lx_engine_integration_test.dart -d linux --no-pub
                                     # 端到端（真实引擎+播放+设置页）；测试内置看门狗会自动退出
flutter build apk --debug            # Android 调试包
flutter build apk --release --split-per-abi --split-debug-info=build/symbols --obfuscate
                                     # 发布体积实测；obfuscate 混淆 Dart 符号（栈需用 symbols 符号化），
                                     # symbols 留档（build/ 已 gitignore）；不要加 --no-pub，见已知坑 15
flutter build web --release          # Web（音源脚本在 Web 不可用，条件导入已处理）
```

音源子系统的离线校验（不依赖设备）：

```bash
node tool/build_lx_prelude.mjs            # 修改 prelude 源码后重新生成打包压缩版（terser）
node tool/lx_prelude_harness.mjs          # Node 沙箱验证打包产物 lx_prelude.js 协议全链路
node tool/gen_search_fixtures.mjs         # 重新抓取平台真实响应更新 test/fixtures/
```

### Linux 桌面运行要求

- 本地播放需要 `libmpv`：`sudo pacman -S --needed mpv`（Debian/Ubuntu: `libmpv2`）。
- **中文字体需要系统安装**（App 不内置 CJK 字体，保持包体精简）：
  `sudo pacman -S --needed wqy-microhei`（最小 1.7MB）或 `noto-fonts-cjk`（质量最好但 189MB）；
  否则中文界面显示为方块。
- 本地数据库（最近播放）依赖 sqflite FFI：`lib/data/database_factory_init*.dart` 已在
  Linux/Windows 自动 `sqfliteFfiInit`（Linux 用系统 libsqlite3）；缺 `xdg-user-dirs` 时
  `database_helper` 会回退到应用支持目录。

### WSL 安卓调试（模拟器 / 热重载 / 截图）

Android 侧调试全部在 WSL 内完成（KVM 原生模拟器，不依赖 Windows / Android Studio）：

```bash
tool/agent/setup.sh        # 一次性：装 emulator + API 37 镜像 + 建 AVD（幂等）
tool/agent/emu.sh start    # 启动模拟器（默认 headless，阻塞到 boot 完成；--window 经 WSLg 显示）
tool/agent/app.sh run      # 后台 flutter run（首次需 Gradle 构建）
tool/agent/app.sh reload   # 热重载；restart = 热重启（无 TTY 走 --pid-file + SIGUSR1/2）
tool/agent/shot.sh [name]  # 截图 → /tmp/opencode/molia/shots/*.png（供 agent 直接读图）
tool/agent/ui.sh layout|tap|swipe|text|key|launch|force-stop
tool/agent/emu.sh stop     # 停止模拟器（app.sh stop 只停 flutter run）
```

## 架构地图（as-built）

```
lib/
  domain/                      # 纯 Dart，禁止 Flutter/provider/HTTP
    models/                    # Track/TrackId/Artwork/AudioQuality、PlaybackSnapshot/
                               #   BackendSnapshot/PlaybackRequest、SearchQuery/SearchResult、
                               #   SourceFailure/FailureKind、SourceDescriptor/Capabilities
    ports/                     # MusicSource / SourceRegistry / PlaybackBackend /
                               #   PlaybackFacade / UiMessenger / StateListenable
  data/
    catalog/                   # SourceManagerMusicSource / SourceRegistryImpl / CatalogService
    playback/                  # LocalPlaybackBackend（包装 LocalPlaybackService）/
                               #   DefaultPlaybackFacade（快照去重 + position 独立通道）
    cache/request_cache.dart   # single-flight + LRU + TTL（搜索 5min / resolve 10min）
    mapping/track_mapper.dart  # SourceTrack <-> Track（payload 原样往返）
    database_factory_init*.dart# 桌面 sqflite FFI 初始化（条件导入）
  providers/
    playback_provider.dart     # UI 播放状态唯一入口（facade 代理；不 import main.dart）
    search_provider.dart       # 经 CatalogService 搜索（兼容 map 结果 + _sourceTracks）
    local_database_provider.dart # 仅 play_contexts（最近播放）
    theme_provider.dart        # 系统亮度 + 专辑封面取色（驱动 M3EThemeData）
  sources/
    source_manager.dart        # 音源注册/调度：search / resolveUrl / fetchLyric / fetchPic
    builtin/                   # 内置平台搜索（kw/kg/tx/wy/mg）+ 加密工具 +
                               #   多平台发现（*_discover.dart：热榜/歌单/热搜，DiscoverSource 注册表）
    lx/                        # LX 引擎（isolate + flutter_js）
      lx_engine_native.dart    # 引擎主/从两侧、协议、超时
      lx_engine_supervisor.dart# 状态机 + 退避重启（0.5s/2s/8s，连续 3 次 → failed）
      lx_script_repository.dart# 脚本持久化（含 replace 原地更新）
      lx_script_update.dart    # 在线检查/更新（下载/校验/HTML 识别）
    any_listen/                # any-listen 适配（配置/API/错误模型）
  playback/
    local_playback_service.dart# just_audio 队列播放（唯一播放后端本体）
    local_audio_handler.dart   # audio_service 系统媒体会话映射
  pages/ widgets/              # UI（M3E 组件 + material_ui 基础件）
```

**分层硬约束**（由 `test/architecture/layering_test.dart` 扫描 import 强制执行）：

1. `lib/domain/**` 禁止 import Flutter/provider/HTTP/其它 lib 层；
2. `lib/data/**`、`lib/sources/**`、`lib/playback/**` 禁止 import providers/pages/widgets/main；
3. `lib/providers/**` 禁止 import `lib/main.dart`（错误提示走注入的 `UiMessenger`）；
4. `lib/main.dart` 是唯一 composition root，不允许被其它 lib 文件 import；
5. UI 禁止 import `lib/sources/**`（Wave 7 后白名单已清空，新增违规必须修复）。

关键不变量：

- **现有 UI 不感知播放后端**：`PlaybackProvider` 输出兼容 map（`item/artists/album.images/
  progress_ms/is_playing/context`），本地播放与未来 any-listen 后端无差别；
- **`SourceTrack.raw` 必须原样回传**给脚本的 `musicUrl/lyric/pic`（脚本依赖平台字段
  如 `songmid`/`hash`/`copyrightId`）；领域层 `Track.payload` 同理，UI 禁读；
- **进度是独立通道**：`PlaybackProvider.position`（`ValueListenable`，≤4Hz）不进
  `notifyListeners`；快照通知值变才发（`==` 可靠对象）；
- 引擎默认 `env=mobile`；`flutter_js` 必须以 `xhr: false` 初始化；引擎运行在独立 isolate，
  超时/崩溃由 `LxEngineSupervisor` 自动退避重启；
- 错误在边界统一为 `SourceFailure`（kind/l10nKey/retryable），UI 不直接展示 `$e`。

## LX 引擎协议要点

- 宿主↔脚本：`globalThis.lx.on('request'|'inited'|'updateAlert')`、`lx.send(...)`、`lx.request(url, options, cb)`；
- 官方 action：`musicUrl` / `lyric` / `pic`（后两者通常仅 `local` 源）；社区扩展 action：`search` / `musicSearch`（非官方约定，本项目兼容）；
- `lx.utils.crypto/buffer/zlib` 由 Dart 同步函数绑定实现（pointycastle + dart:io zlib），行为有 Node crypto 向量单测；
- 内联前端前导脚本**源码**在 `tool/lx_prelude/lx_prelude.js`；打包产物
  `assets/lx/lx_prelude.js` 由 `node tool/build_lx_prelude.mjs`（terser 压缩，
  版本固定）生成——改源码后必须重新生成，`node tool/lx_prelude_harness.mjs`
  验证的是打包产物；不要手改产物（`--check` 可校验产物与源码是否同步）；
- 在线导入/更新：脚本 meta 支持 `@updateUrl`；运行时 `lx.updateAlert({log, updateUrl})` 会把
  updateUrl 记入当前脚本；音源管理页支持「立即更新」（下载→校验→原地替换→激活中自动重放）。

## M3E 约定（Material 3 Expressive）

- App 壳：`M3EMaterialApp(data: M3EThemeData.fromMaterial(themedData), theme: themedData, ...)`；
  主题令牌用 `M3ETheme.of(context)`；`ThemeProvider`（系统亮度 + 封面取色）是唯一主题源，
  `autoTheming/dynamicColoring` 显式关闭。
- **UI 一律优先使用 `M3E*` 组件**（AppBar/按钮/卡片/列表/输入/开关/单选/分段/弹层/
  菜单/Snackbar/进度/加载等）；`Scaffold/Text/Icon/Image/Theme/Material` 等基础件来自
  `material_ui`（M3E 的必需依赖，**不要试图移除**；M3EIcons 与 Icons 共用 MaterialIcons 字体）。
- **图标统一用圆角风格 `Icons.*_rounded`**（与 M3E 圆润外形一致）：不使用 `Icons.adaptive.*`
  （会按平台切成 Cupertino/横向图标），也不混用 `_outlined`/基础实心；新代码照此添加。
  例外：选中/未选中成对图标按 M3 惯例「未选中空心、选中实心」——空心优先圆角字形
  （`favorite_border_rounded`），音符/资料库无圆角空心字形时用 `_outlined` 与实心成对；
  由 `test/architecture/icon_usage_test.dart` 扫描强制。
- **禁止 import `package:flutter/material.dart`**（使用 `package:material_ui/material_ui.dart`）；
  组件 import 用 `package:material_3_expressive/material_3_expressive.dart`。
- 已知无法等价替换处（保持 material）：带 `bottom:` 槽的 `AppBar`（2 处）、
  `responsive.dart::_showCenterDialog`（M3EDialog.title 必填且无关闭钮）、
  `ScaffoldMessenger` 兼容代码（NotificationService/main）。
- 弹层观感差异（M3E 统一 inverseSurface Snackbar、无红底错误色、Dialog/BottomSheet 圆角
 与 spring 入场）属预期，改动相关区域时留意。

### 色彩契约（唯一主题出口）

- 主题构建唯一入口是 `lib/theme/app_theme.dart::buildAppThemeData`（禁止在别处 `ThemeData(`）；
  `ThemeProvider` 只产出 `ColorScheme`，`main.dart` 用 `AnimatedSchemeBuilder`
  （450ms 插值）过渡方案色，material_ui 与 M3E 两套主题由同一插值结果重建。
- **角色用法**：`primary` 只用于交互/选中/强调图形（按钮、进度、选中项、标记条）；
  正文/标题用 `onSurface`、次要文本用 `onSurfaceVariant`；容器背景必须配
  `on*Container` 前景；空态/禁用态一律 `onSurfaceVariant`（禁用透明度交给组件默认值）。
- **状态色**：成功/警告用 `AppSemanticColors.of(context)`（success/warning 四件套，
  固定色调、随亮度派生、不随封面取色）；错误用 `colorScheme.error`；禁止硬编码
  `Colors.green` 等字面量。
- **禁止**：`withAlpha/withOpacity`（统一 `withValues(alpha:)`）、`Colors.*` 字面量
  （`Colors.transparent` 除外）、`Color(0x...)`、`scaffoldBackgroundColor`/`dividerColor`
  双源属性；由 `test/architecture/color_usage_test.dart` 扫描强制。
- 海报导出的四种配色（`lyrics_poster_preview_page.dart`）是刻意的艺术预设，
  不受上述角色契约约束，但同样不得使用 `withAlpha`。

## 已知坑（改代码前务必阅读）

1. **flutter_js 在 Linux 的 QuickJS 桥接库不会自动打包**（上游 CMake 变量名错误）。
   已在 `linux/CMakeLists.txt` 显式 `install(FILES ... libquickjs_c_bridge_plugin.so)`，不要删除。
2. **`getJavascriptRuntime()` 必须传 `xhr: false`**。默认开启的 fetch 会在后台 isolate 调用
   `rootBundle`（依赖平台通道），产生未处理异常并**终止 isolate**，表现为引擎初始化成功但所有请求超时。
3. **`material_color_utilities` 被 Flutter SDK 固定为 0.13.0**，不要升级为 0.13.1（版本求解会失败）。
4. **`encrypt` 已移除**：pointycastle 4.x 与其冲突；AES/RSA 统一走 `lx_native_utils.dart`。
5. **maven.google.com 在部分网络不可达**：`android/app/build.gradle` 仓库显式使用
   `https://dl.google.com/dl/android/maven2`，不要改回 `maven.google.com`。
6. **share_plus 13**：使用 `SharePlus.instance.share(ShareParams(files: ..., text: ...))`，
   `Share.shareXFiles` 已不存在。
7. **Web 不支持音源**：`kIsWeb` 时 `SourceManager` 不激活引擎；不要移除条件导入
   （`lx_engine.dart` / `desktop_audio_init.dart` / `database_factory_init.dart` 的 stub 分支）。
8. **音源脚本是不可信代码**：不要在引擎里暴露文件系统/平台通道；网络只走 `lx.request` 桥。
   `currentScriptInfo` 必须原样透传（部分脚本有防篡改校验，校验失败会死循环）。
9. **ELECTRON 脚本兼容性**：脚本可能使用 `atob/btoa/TextEncoder/setTimeout/window/navigator`
   等 shim；扩展能力请加在 `lx_prelude.js` 而不是假设宿主提供。
10. **插件 JVM target 校验**：`flutter_js` 等插件 Java target(11) 与 Kotlin target(1.8) 不一致，
    AGP 9 默认按错误处理；已在 `android/gradle.properties` 设置
    `kotlin.jvm.target.validation.mode=warning`，不要删除。
11. **集成测试挂起保护**：桌面端 media_kit 的原生事件循环会阻止测试进程退出；
    `integration_test/lx_engine_integration_test.dart` 的 `tearDownAll` 有 2s 上报窗口后
    `exit(0)` 的看门狗，不要删除（否则 `flutter test -d linux` 会永久挂起）。
12. **不内置字体资产**：界面与海报统一使用设备字体，用户可在设置中切换「应用字体」
    （枚举实现见 `lib/services/system_fonts_service*.dart`：Android 解析系统
    `fonts.xml`、iOS 走 `UIFont.familyNames` 通道、Linux 调 `fc-list`），海报页可
    独立覆盖（`PosterFontStore`）。不要再向 `pubspec.yaml` 的 `fonts:` 或
    `assets/fonts/` 添加字体，保持包体精简。
13. **发布体积**：新增资产前先评估体积；不要内置 CJK 字体（系统字体 + 用户安装）。
    Android 启动图标自 2026-10 起为手绘矢量（`drawable/ic_launcher_foreground.xml`，
    维护方式见 `flutter_launcher_icons.yaml` 头注释），该工具现在只生成 iOS 图标；
    `minSdk=37` 下传统 mipmap 密度图无意义，已全部移除，不要用工具再生成。
14. **省流模式的网络检测**：Android 8+ 后台不广播网络变化，`_MyThemedAppState` 在
    `resumed` 时调 `DataSaverService.refreshConnectivity()`，不要删除；Web 的
    connectivity_plus 拿不到「蜂窝」类型（只会返回 wifi/none），省流在 Web 不会自动生效；
    检测失败时保守按「未生效」处理（`detectionAvailable=false`）。
15. **`--no-pub` 会跳过插件注册文件再生成**：`flutter build ... --no-pub` 不重写
    `android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java`。
    若该文件缺失，构建**不会报错**但产物没有插件注册（R8 会把插件类全部裁掉，
    表现为通知/播放/数据库全失效）；若文件来自 debug/集成测试还会残留
    `integration_test` 引用，导致 release 编译失败。发布构建不要加 `--no-pub`，
    它只适合本地快速迭代。

## 开发约定

- 状态管理：新 UI 订阅优先用 `Selector`/`ValueListenableBuilder`；禁止 `select` 返回
  `Map`/`List` 引用（用不可变对象/record）；
- 文案：UI 文案必须走 `AppLocalizations`（en/zh 双语 + `flutter gen-l10n`）；
- 注释：中文为主，关键设计写明「为什么」；
- Git：功能分支开发（主分支 `main`），提交信息用 `feat/fix/chore/refactor(scope): 描述`；
- 每次改动后至少执行：`flutter analyze --no-pub` + `flutter test --no-pub`；涉及引擎/播放的改动
  加跑集成测试；涉及 UI 组件的改动加跑 `flutter build web --release`；
- 不要把密钥（API Key 等）提交进仓库。

## 音源完整验证清单（改动引擎/音源时）

1. `flutter analyze --no-pub` 0 error/0 warning；
2. `flutter test --no-pub`（含 `test/lx_core_test.dart`、`test/lx_supervisor_test.dart`、
   `test/lx_script_update_test.dart`、`test/builtin_search_parse_test.dart`、`test/architecture/layering_test.dart`）；
3. `node tool/lx_prelude_harness.mjs` 输出 `PROTOCOL OK`；
4. `flutter test integration_test/lx_engine_integration_test.dart -d linux --no-pub`
   （真实导入→搜索→取链→歌词；播放测试需要 libmpv）；
5. 真机/模拟器验证：设置 → 音源管理 → 导入社区脚本（或在线更新）→ 搜索 → 播放。

## 当前未完成 / 后续计划

- any-listen 真实协议接入（当前为 HTTP 占位端点，官方为 WS IPC；抽象已就绪）；
- 真机验证：Android 17 通知/耳机键、iOS 15+ 后台播放（需设备）；
- M3E 组件目视复核（弹层观感/间距），发布前 release 体积与签名检查。
