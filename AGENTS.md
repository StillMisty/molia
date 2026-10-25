# AGENTS.md

**Molia** 是 Flutter 音乐播放器：LX 音源脚本 + 六平台内置搜索/发现（五个音乐平台 +
哔哩哔哩）、本地与网络播放
（桌面 media_kit/libmpv）、歌词（含桌面歌词与海报）、省流模式、AI 推歌（可选）、跨设备同步
（WebDAV / 局域网，可选）。目前处于内部快速迭代状态，明确不兼容任何历史数据与协议。
完整术语与能力地图见 `GLOSSARY.md`。

## 工具链

Flutter / Dart 3.47.7 / 3.13.5；JDK 26+；Gradle 9.8.2 / AGP 9.4.1 / Kotlin 2.4.21；
compileSdk/targetSdk 37，minSdk 35；NDK 30.0.16248370。这里是版本来源，改 CI / 发布工作流前先改本行。
最低支持：iOS 18 / macOS 12（Xcode + CocoaPods；macOS 走 just_audio 原生 AVPlayer，不需要 libmpv）。

## 常用命令

```bash
flutter analyze --no-pub   # 必须 0 error / 0 warning
flutter test --no-pub      # 单文件：flutter test test/lx_core_test.dart --no-pub
tool/agent/test.sh linux   # 端到端（真实引擎 + 设置页 + 窗口/托盘，不含播放）；Xvfb 无窗口，桌面看门狗勿删
tool/agent/test.sh android # 同一套跑模拟器（先 emu.sh start）；--window / --timeout 见脚本
tool/agent/seed.sh android|linux <cmd>   # 数据注入：favorites/history/session/mock-source/status/clear/restore
tool/agent/startup.sh                    # 启动耗时采样（release 冷启动 N 次取中位；基线与结论见 docs/performance.md）
tool/agent/perf.sh                       # 全链路体检：frames / startup / data / cpu / memory / size（见 docs/performance-audit-2026-10.md）
tool/agent/cpu.sh                        # 按线程 CPU 采样（平台 / Dart UI / raster / IO / 音频；被 perf.sh cpu 调用）
tool/agent/memory.sh                     # 托盘内存采样（RSS 曲线 + molia.memory 转换日志；见 docs/memory.md）
tool/agent/memory.ps1                    # Windows 托盘内存采样（专用工作集 / 提交大小；见 docs/memory.md）
```

生成物（改对应源码后必跑，产物提交进仓库）：

- 改 `tool/lx_prelude/` → `node tool/build_lx_prelude.mjs`（`assets/lx/lx_prelude.js` 是 terser 产物，勿手改）
  + `node tool/lx_prelude_harness.mjs`（应输出 PROTOCOL OK）；重抓平台响应 → `node tool/gen_{search,artist,lyric_search}_fixtures.mjs`；
- 改 `lib/data/molia_database.dart` → `dart run build_runner build`；当前基线是
  `molia_database_v2.sqlite` / `schemaVersion = 1`，旧库不迁移、不读取；以后改表结构
  提 `schemaVersion`，用 `dart run drift_dev make-migrations` 从新 v1 生成快照 +
  `stepByStep` 写增量迁移并保留数据（ADR-0005）；
- 改 `tool/gen_taskbar_icons.py`（Windows 任务栏按钮字形 / 档位）→ `python3 tool/gen_taskbar_icons.py`
  （产物 `windows/runner/resources/thumbbar/*.ico` 提交进仓库；需 `rsvg-convert`）；
- 改品牌图标 → `swift tool/gen_macos_icons.swift`（产物 `macos/Runner/Assets.xcassets/AppIcon.appiconset/*.png`
  提交进仓库；iOS / Windows 图标走 `dart run icons_launcher:create`）。

发布：`git tag -s v1.2.3 -m "Molia 1.2.3" && git push origin v1.2.3`（tag 即版本；
流程、secrets 与产物清单见 `.agents/skills/molia-release/`）。

## 架构地图

```
lib/
  domain/                     # 纯 Dart：models + ports
  data/ sources/ playback/    # 端口实现：db/catalog/cache/update、音源（builtin/lx/any_listen）、播放后端
  providers/ services/ app/   # UI 状态、领域服务、应用壳（可挂载）+ bootstrap/ 组合根 stack builders
  pages/ widgets/ + main.dart # UI 与唯一 composition root（薄壳，禁止被其它 lib 文件 import）
```

分层硬约束由 `test/architecture/layering_test.dart` 扫描 import 强制：domain 纯 Dart；
data/sources/playback 不碰 UI；providers 不 import `main.dart`；UI（pages/widgets）不直接 import
sources/playback。

关键不变量（改相关代码前确认）：

- `SourceTrack.raw` / `Track.payload` 原样回传脚本（`songmid`/`hash`/`copyrightId` 等被脚本依赖），payload UI 禁读；
- `PlayableStream.headers` 必须一路透传给播放器（`AudioSource.uri` / `LockCachingAudioSource`）、
  下一首预取、桌面缓存写入与下载：B 站直链缺 `Referer` / 浏览器 UA 会直接 403；
- 进度只走 `PlaybackProvider.position`（`ValueListenable`，≤4Hz），不进 `notifyListeners`；快照值变才通知；
- UI 只消费类型化 `PlaybackSnapshot`，不感知播放后端实现；
- 错误在边界统一为 `SourceFailure`（kind/l10nKey/retryable），UI 不直接展示 `$e`；
- 取色（ADR-0001）：`theme/scheme_builder.dart::buildColorScheme` 是唯一方案工厂，
  `services/artwork_palette_service.dart` 是唯一封面取色入口；消费面（桌面歌词/海报）经
  `resolveSurfaceScheme` 解析，禁止二次提取封面像素。

## 开发约定

- 订阅优先 `Selector`/`ValueListenableBuilder`；`select` 不返回 `Map`/`List` 引用（用不可变对象/record）；
- 文案走 `AppLocalizations`（en/zh + `flutter gen-l10n`）；用户可见文案只说「能不能用 + 怎么办」，
  黑话对照与长度约定见 `docs/copy_style.md`（zh/en 与测试断言同步改）；注释中文、写「为什么」；
- UI 硬约定（`test/architecture/` 强制，细节见 `docs/architecture.md` §6）：`Icons.*_rounded`；
  颜色只走 ColorScheme/`AppSemanticColors`（透明度用 `withValues(alpha:)`）；优先 `M3E*` 组件；
  禁止 import `package:flutter/material.dart`；
  排版走 `context.typeScale` / `emphasizedTypeScale`（`lib/theme/m3e_context.dart`），
  `textTheme` 与 `w600/w800/w900` 由 `test/architecture/m3e_typography_test.dart` 拦截；
  顶栏 / 弹层 / 排序的 M3E 口径见 `docs/architecture.md` §6；
- 每次改动至少 `flutter analyze --no-pub` + `flutter test --no-pub`（迭代可只跑改动范围，提交前跑全量）；
- 测试按模块聚合：小用例并入同模块 `*_test.dart`，`*_cases.dart` 只作为聚合套件的用例库
  （不被 `flutter test` 单独发现）。每个测试文件都有独立的 engine/kernel 装载开销（~1s，
  与文件大小无关），拆得越碎全量越慢；
- Git：功能分支（主分支 `main`），提交 `type(scope): 描述`；密钥不进仓库。

## 领域文档与技能

- Issues 与规格走 GitHub issues（`gh` CLI，`docs/agents/issue-tracker.md`）；标签见
  `docs/agents/triage-labels.md`；术语与决策见 `GLOSSARY.md` + `docs/adr/`（`docs/agents/domain.md`）；
- `.agents/skills/` 为第三方内容勿手改；更新走 `npx skills update` + `dart run skills@ get --all`。
