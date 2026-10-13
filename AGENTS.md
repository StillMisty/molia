# AGENTS.md

**Molia（茉咏）** 是 Flutter 音乐播放器：

- **音源**：LX Music 自定义源脚本（QuickJS 引擎 + 自愈监督）、内置平台搜索与发现
  （酷我/酷狗/QQ/网易云/咪咕）、any-listen 接入（骨架）
- **播放**：本地音频（just_audio；桌面 Windows/Linux 走 media_kit/libmpv）、队列/播放模式、后台播放与系统媒体通知（audio_service）
- **歌词**：QQ/网易/LRCLIB 获取与显示、歌词行选择、歌词海报导出
- **省流模式**（移动数据下压低取链音质、封面仅本地缓存）、**M3E（Material 3 Expressive）UI**
- **AI 推歌（可选，默认关闭）**：用户自备 API Key 的 OpenAI-compatible LLM
  「今日推荐」列表（持久可浏览）+ 可选推歌电台（播放全部即接管队列并自动续推）
- **跨设备同步（可选，默认关闭）**：歌单/音源/设置/统计/凭证经局域网直连或自备 WebDAV 同步

## 工具链

| 组件 | 版本 |
|---|---|
| Flutter / Dart | 3.47.6 stable / 3.13.5 |
| JDK | 26+ |
| Gradle / AGP / Kotlin | 9.8.1 / 9.4.1 / 2.4.21 |
| compileSdk/targetSdk/minSdk | 37 / 37 / 37 |
| NDK | 30.0.16248370 |

## 常用命令

```bash
flutter pub get
flutter analyze --no-pub               # 必须保持 0 error / 0 warning
flutter test --no-pub                  # 单文件：flutter test test/lx_core_test.dart --no-pub
tool/agent/test.sh linux               # 端到端（真实引擎+播放+设置页）；桌面看门狗自动退出，勿删
                                       # 等价 flutter test integration_test/... -d linux；无 DISPLAY 自动 xvfb-run
tool/agent/test.sh android             # 同一套集成测试跑 Android 模拟器（需先 emu.sh start；跳过播放）
                                       # 首次 Gradle 构建较久，必要时 --timeout 放宽
tool/agent/seed.sh android|linux <cmd> # 数据注入：favorites / history / session / mock-source / status / clear / restore
flutter build apk --debug              # 手动装包验证用；自动化验证走上面的集成测试
flutter build web --release            # 涉及 UI 组件时加跑；音源脚本在 Web 不可用
flutter build apk --release --split-per-abi --split-debug-info=build/symbols --obfuscate --extra-gen-snapshot-options=--strip   # 构建发布
```

音源 prelude 离线校验（改 `tool/lx_prelude/` 后必跑）：

```bash
node tool/build_lx_prelude.mjs            # 源码 → assets/lx/lx_prelude.js（terser，勿手改产物）
node tool/build_lx_prelude.mjs --check    # 校验产物与源码同步
node tool/lx_prelude_harness.mjs          # Node 沙箱全链路，输出 PROTOCOL OK
node tool/gen_search_fixtures.mjs         # 重抓平台真实响应到 test/fixtures/
```

Android 调试（模拟器 / 热重载 / 截图）走 `tool/agent/*.sh`，用法见 `docs/dev_environment.md`。

本地数据库代码生成（drift，改 `lib/data/molia_database.dart` 后必跑）：

```bash
dart run build_runner build               # 重新生成 lib/data/molia_database.g.dart（提交生成物）
dart run drift_dev make-migrations        # 改表结构 + 提 schemaVersion 后：schema 快照 + test/drift 迁移测试
```

## 架构地图

```
lib/
  domain/          # 纯 Dart：models（Track/PlaybackSnapshot/SearchResult/SourceFailure…）+ ports
  data/            # 端口实现：db（MoliaDatabase，drift）/ catalog（CatalogService）/ playback（facade）/ cache / mapping
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
- 错误在边界统一为 `SourceFailure`（kind/l10nKey/retryable），UI 不直接展示 `$e`；
- 取色模型见 ADR-0001：基础配色（壁纸/自定义）+ 封面覆盖 + 纯黑（正交）；
  `theme/scheme_builder.dart::buildColorScheme` 是唯一方案工厂，
  `services/artwork_palette_service.dart` 是唯一封面取色入口（组合根挂播放监听触发）；
  消费面（桌面歌词/海报）按各自来源经 `resolveSurfaceScheme` 解析，禁止二次提取封面像素。

## 开发约定

- 状态管理：订阅优先 `Selector`/`ValueListenableBuilder`；`select` 禁止返回 `Map`/`List`
  引用（用不可变对象/record）；
- 文案必须走 `AppLocalizations`（en/zh + `flutter gen-l10n`）；注释中文为主，关键设计写明「为什么」，
  噪音注释的界定与清理标准见 `docs/comment_style.md`；
- UI 硬约定（由 `test/architecture/` 扫描强制，细节见 `docs/architecture.md` §6）：
  图标一律 `Icons.*_rounded`；颜色只走 ColorScheme/`AppSemanticColors`，透明度用
  `withValues(alpha:)`；优先 `M3E*` 组件，禁止 import `package:flutter/material.dart`；
- Git：功能分支开发（主分支 `main`），提交信息 `feat/fix/chore/refactor(scope): 描述`；
- 每次改动后至少 `flutter analyze --no-pub` + `flutter test --no-pub`；引擎/音源改动按
  `docs/lx_sources.md` 的验证清单，UI 组件改动加跑 `flutter build web --release`；
- 不要把密钥（API Key 等）提交进仓库。

## AI 工具链（OpenCode）

- **热重载**：改 `lib/` 下 `.dart` 后，UI 组件 / 简单方法 → hot reload；
  `initState`、全局/静态状态、`main()` → hot restart；`test/**`、`integration_test/**`、
  注释或空白不触发；
- **技能维护**：`.agents/skills/` 为第三方内容，勿手改；更新走 `npx skills update` +
  `dart run skills@ get --all`。

## Agent skills

- Issues and specs live as GitHub issues, read/written with the `gh` CLI. See `docs/agents/issue-tracker.md`.
- Five canonical labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.
- Single-context: root `GLOSSARY.md` plus `docs/adr/`. See `docs/agents/domain.md`.
