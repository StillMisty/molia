# AGENTS.md

**Molia（茉咏）** 是 Flutter 音乐播放器（纯播放器定位）：

- **音源**：LX Music 自定义源脚本（QuickJS 引擎 + 自愈监督）、内置平台搜索与发现
  （酷我/酷狗/QQ/网易云/咪咕）、any-listen 接入（骨架）；
- **播放**：本地音频（just_audio；桌面 Windows/Linux 走 media_kit/libmpv）、队列/播放模式、
  后台播放与系统媒体通知（audio_service）；
- **歌词**：QQ/网易/LRCLIB 获取与显示、歌词行选择、歌词海报导出（保存相册用 gal）；
- **省流模式**（移动数据下压低取链音质、封面仅本地缓存）、**M3E（Material 3 Expressive）UI**；
- **明确不含**：在线账号/流媒体后端、AI 功能、笔记/记录/漫游/评分等非播放器能力。

文档入口：

| 文档 | 内容 |
|---|---|
| `docs/pitfalls.md` | 已知坑清单（编号被源码注释引用） |
| `docs/architecture.md` | 分层 / 状态策略 / M3E / 验证（as-built） |
| `docs/lx_sources.md` | 音源子系统（引擎要点、验证清单、构建环境） |
| `docs/lyrics_display.md` | 歌词显示（桌面/通知/蓝牙）设计 |
| `docs/dev_environment.md` | Linux 桌面依赖、WSL 安卓模拟器调试 |
| `GLOSSARY.md`、`docs/adr/` | 领域词汇与架构决策记录（ADR 按需创建） |

## 工具链

| 组件 | 版本 | 说明 |
|---|---|---|
| Flutter / Dart | 3.47.6 stable / 3.13.5 | |
| JDK | 25+（已在 27 上验证） | `flutter config --jdk-dir=<path>` 可指定 |
| Gradle / AGP / Kotlin | 9.8.1 / 9.4.1 / 2.4.20 | Gradle 9.8 是支持 JDK 27 class 文件的最低版本 |
| compileSdk/targetSdk/minSdk | 37 / 37 / 37 | minSdk=37 → 只有 Android 17+ 可安装 |
| NDK | 30.0.16248370 | |

该组合已被 `flutter analyze` / 构建验证通过；降级前先想清楚（Gradle/AGP/Kotlin 相互约束）。

## 常用命令

```bash
flutter pub get
flutter analyze --no-pub               # 必须保持 0 error / 0 warning
flutter test --no-pub                  # 单文件：flutter test test/lx_core_test.dart --no-pub
flutter test integration_test/lx_engine_integration_test.dart -d linux --no-pub
                                       # 端到端（真实引擎+播放+设置页）；看门狗自动退出，勿删
flutter build apk --debug
flutter build apk --release --split-per-abi --split-debug-info=build/symbols --obfuscate
                                       # 发布构建不要加 --no-pub（pitfalls #15）
flutter build web --release            # 涉及 UI 组件时加跑；音源脚本在 Web 不可用
```

音源 prelude 离线校验（改 `tool/lx_prelude/` 后必跑）：

```bash
node tool/build_lx_prelude.mjs            # 源码 → assets/lx/lx_prelude.js（terser，勿手改产物）
node tool/build_lx_prelude.mjs --check    # 校验产物与源码同步
node tool/lx_prelude_harness.mjs          # Node 沙箱全链路，输出 PROTOCOL OK
node tool/gen_search_fixtures.mjs         # 重抓平台真实响应到 test/fixtures/
```

Android 调试（模拟器 / 热重载 / 截图）走 `tool/agent/*.sh`，用法见 `docs/dev_environment.md`。

## 架构地图

```
lib/
  domain/          # 纯 Dart：models（Track/PlaybackSnapshot/SearchResult/SourceFailure…）+ ports
  data/            # 端口实现：catalog（CatalogService）/ playback（facade）/ cache / mapping
  sources/         # source_manager + builtin（五平台搜索/发现）/ lx（引擎）/ any_listen
  playback/        # LocalPlaybackService（just_audio 后端）+ local_audio_handler（audio_service）
  providers/       # UI 状态：PlaybackProvider / SearchProvider / LibraryProvider / ThemeProvider…
  services/        # 歌词、歌词显示、省流、缓存、字体、设置…
  app/             # app_shell.dart：应用壳（测试可直接挂载）
  pages/ widgets/  # UI（M3E 组件 + material_ui 基础件）
  main.dart        # 唯一 composition root
```

分层硬约束（`test/architecture/layering_test.dart` 扫描 import 强制，白名单已清空）：

1. `lib/domain/**` 禁止 Flutter/provider/HTTP 与 data/sources/playback/main/UI；
2. `lib/data/**`、`lib/sources/**`、`lib/playback/**` 禁止 providers/pages/widgets/main；
3. `lib/providers/**` 禁止 import `lib/main.dart`（错误提示走注入的 `UiMessenger`）；
4. `lib/main.dart` 不允许被其它 lib 文件 import；
5. `lib/pages/**`、`lib/widgets/**` 禁止 import `lib/sources/**` 与 `lib/playback/**`。

关键不变量（改动相关代码前确认）：

- `SourceTrack.raw` / `Track.payload` 必须原样回传给脚本（`songmid`/`hash`/`copyrightId`
  等字段被脚本依赖）；payload UI 禁读；
- 进度只走 `PlaybackProvider.position`（`ValueListenable`，≤4Hz），不得进 `notifyListeners`；
  快照通知值变才发（对象 `==` 可靠）；
- UI 消费类型化 `PlaybackSnapshot`（旧 Map 兼容层已删除），不感知播放后端实现；
- 错误在边界统一为 `SourceFailure`（kind/l10nKey/retryable），UI 不直接展示 `$e`。

## 开发约定

- 状态管理：订阅优先 `Selector`/`ValueListenableBuilder`；`select` 禁止返回 `Map`/`List`
  引用（用不可变对象/record）；
- 文案必须走 `AppLocalizations`（en/zh + `flutter gen-l10n`）；注释中文为主，关键设计写明「为什么」；
- UI 硬约定（由 `test/architecture/` 扫描强制，细节见 `docs/architecture.md` §6）：
  图标一律 `Icons.*_rounded`；颜色只走 ColorScheme/`AppSemanticColors`，透明度用
  `withValues(alpha:)`；优先 `M3E*` 组件，禁止 import `package:flutter/material.dart`；
- Git：功能分支开发（主分支 `main`），提交信息 `feat/fix/chore/refactor(scope): 描述`；
- 每次改动后至少 `flutter analyze --no-pub` + `flutter test --no-pub`；引擎/音源改动按
  `docs/lx_sources.md` 的验证清单，UI 组件改动加跑 `flutter build web --release`；
- 不要把密钥（API Key 等）提交进仓库。
