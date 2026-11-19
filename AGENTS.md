# AGENTS.md

**Molia** 是 Flutter 音乐播放器：LX 音源脚本 + 七渠道内置搜索/发现（六个音乐平台 +
哔哩哔哩）、本地与网络播放
（桌面 media_kit/libmpv）、歌词（含桌面歌词与海报）、省流模式、听歌同步（可选）、
AI 推歌（可选）、跨设备同步（WebDAV / 局域网，可选）。目前处于内部快速迭代状态，
明确不兼容任何历史数据与协议。
完整术语与能力地图见 `GLOSSARY.md`。

## 工具链

Flutter / Dart 3.50.0 / 3.14.0；JDK 27+；Gradle 9.9.1 / AGP 9.5.1 / Kotlin 2.4.21；
compileSdk 37.2 / targetSdk 37，minSdk 35；build-tools 37.0.0；NDK 30.0.16248370；
Android CLI 1.1.16919734。
这里是版本来源；其它文档与技能只引用本节、不复列版本号，改 CI / 发布工作流前先改本行。
最低支持：iOS 18 / macOS 12（Xcode；macOS 走 just_audio 原生 AVPlayer，不需要 libmpv）。

版本策略：本仓刻意跟最新 stable（工具链与依赖都是），不因“更稳妥”降级。
升级门槛是 `flutter analyze` + `flutter test` + 发布矩阵 dry-run 全绿；确实要压制的
告警必须在本节下面的「已知例外」登记，不接受隐式全局开关。

已知例外（每项都要有移除条件，不能只留注释）：

- `kotlin.jvm.target.validation.mode=warning`：app target 26 与常用插件 target 17/11
  并存；插件跟上 26 或本仓把 target 降到 17 时删除。
- `android/app/build.gradle` 剔除 `libcnativeapi.so`：nativeapi 的 Android C++ 核
  运行期不用；上游按平台裁剪后删除。
- `analysis_options.yaml` 排除 `lib/l10n/app_localizations*.dart`：Flutter 模板仍用
  已弃用的 `Global*Localizations`；SDK 更新后删除。
- `android.newDsl=false`：Flutter 3.50 尚未支持 AGP9 新 DSL；Flutter 支持后删除。

## 常用命令

完整流程（准备 → 开发 → 门禁 → 编译 → 发布）见 `docs/dev_workflow.md`；下面是高频命令。

```bash
flutter analyze --no-pub   # 必须 0 error / 0 warning
flutter test --no-pub      # 全量（默认集，本机 <30s）；单文件：flutter test test/lx_core_test.dart --no-pub
dart run tool/agent/cli.dart -h                # 跨端工具入口：info/deps/analyze/test/smoke/app/emu/win/size/perf…（ADR-0031）
dart run tool/agent/cli.dart test linux        # 端到端（真实引擎 + 设置页 + 窗口/托盘，不含播放）；默认后台（打印日志/状态路径），--wait 等结果；Xvfb 无窗口，桌面看门狗勿删
dart run tool/agent/cli.dart test android      # 同一套跑模拟器（先 emu start）；同样默认后台；--window / --timeout 见命令用法
dart run tool/agent/cli.dart smoke linux       # 启动首帧烟测（真实 main + provider tree；Xvfb，抓 runApp 前崩溃）
dart run tool/agent/cli.dart deps              # 依赖/工具链体检：pub outdated + analyze suggestions + Gradle 实际版本
dart run tool/agent/cli.dart size apk --check <apk>   # APK 分组体积与 native 库约束（无需 unzip）
dart run tool/agent/cli.dart size desktop --check <bundle>  # 桌面 release 包：禁止 dartjni，校验 AOT / 引擎 / exe 结构
dart run tool/agent/cli.dart docs check        # 文档引用 / 工具链一致性（CI 与 pre-commit 自动跑）
tool/agent/seed.sh android|linux <cmd>         # 数据注入：favorites/covers/history/session/lang/mock-source/status/clear/restore
tool/agent/startup.sh                          # 启动耗时采样（release 冷启动 N 次取中位；基线与结论见 docs/performance.md）
tool/agent/perf.sh                             # 全链路体检：frames / startup / data / cpu / memory / size（见 docs/performance.md）
tool/agent/cpu.sh                              # 按线程 CPU 采样（平台 / Dart UI / raster / IO / 音频；被 perf.sh cpu 调用）
tool/agent/memory.sh                           # 托盘内存采样（RSS 曲线 + molia.memory 转换日志；见 docs/memory.md）
tool/agent/io.sh                               # 磁盘写入采样（prefs mtime 计数 + DB/WAL 大小 + /proc IO 差分）
tool/agent/memory.ps1                          # Windows 托盘内存采样（专用工作集 / 提交大小；见 docs/memory.md）
tool/agent/hooks.sh                            # 启用 .githooks/pre-commit：格式化暂存 Dart + 文档/工具链检查
tool/agent/worktree_prepare.sh <dir> [branch]  # 新 worktree：分支 / 签名 / hooks 缓存
```

生成物（改对应源码后必跑，产物提交进仓库）：

- 改 `tool/lx_prelude/` → `node tool/build_lx_prelude.mjs`（`assets/lx/lx_prelude.js` 是 terser 产物，勿手改）
  + `node tool/lx_prelude_harness.mjs`（应输出 PROTOCOL OK）；重抓平台响应 →
  `node tool/gen_{search,album,artist,lyric_search,qs}_fixtures.mjs`；
- 改 `lib/data/molia_database.dart` → `dart run build_runner build`；当前基线是
  `molia_database_v2.sqlite` / `schemaVersion = 4`（v2 新增播放会话两表，v3 是
  本地曲库 / 列表增强的身份重写，v4 新增设备本地缓存索引
  `local_cache_index`）；以后改表结构提 `schemaVersion`，用
  `dart run drift_dev make-migrations` 生成 schema 快照 + `stepByStep` 写增量
  迁移并保留数据（ADR-0005、ADR-0017、ADR-0021）；
- 改 `tool/gen_taskbar_icons.py`（Windows 任务栏按钮字形 / 档位）→ `python3 tool/gen_taskbar_icons.py`
  （产物 `windows/runner/resources/thumbbar/*.ico` 提交进仓库；需 `rsvg-convert`）；
- 改品牌图标 → `swift tool/gen_macos_icons.swift`（产物 `macos/Runner/Assets.xcassets/AppIcon.appiconset/*.png`
  提交进仓库；iOS / Windows 图标走 `dart run icons_launcher:create`）；
- 改原生互操作输入（ADR-0038）→ `JAVA_HOME=/usr/lib/jvm/java-21-openjdk dart run
  tool/jnigen.dart`（Android JNI，先编译 Kotlin 再生成，产物
  `lib/platform/android/*.g.dart`；生成 JDK 21、构建仍 JDK 27）、
  `dart run tool/ffigen_system.dart`（桌面 C 系统绑定，
  产物 `lib/platform/desktop/*.g.dart`）；Pigeon 契约在 `tool/pigeon/`，阶段 3（Apple）/
  4（其余域）起按域运行 `dart run pigeon --input tool/pigeon/<域>.dart`，生成 Dart +
  Swift host；widget 的 native interop 试点（issue #78）走 `tool/pigeon/generate.sh`
  （JDK 21，先编译 Kotlin 再跑 Pigeon/JNIgen，产物含 `widget*.g.dart` +
  `android/.../pigeon/WidgetApi.g.kt`）。生成物一律提交进仓库，勿手改。

发布：`git tag -s v1.2.3 -m "Molia 1.2.3" && git push origin v1.2.3`（tag 即版本；
流程、secrets 与产物清单见 `.agents/skills/molia-release/`）。

## 架构地图

```
lib/
  domain/                     # 纯 Dart：models + ports
  data/ sources/ playback/    # 端口实现：db/catalog/cache/update、音源（builtin/lx/any_listen）、播放后端
  providers/ services/ app/   # UI 状态、领域服务、应用壳（可挂载）+ bootstrap/ 组合根 stack builders
  platform/                   # 原生互操作层：JNIgen / FFIgen / Pigeon 生成物 + 薄适配器（ADR-0038）
  pages/ widgets/ + main.dart # UI 与唯一 composition root（薄壳，禁止被其它 lib 文件 import）
```

分层硬约束由 `test/architecture/layering_test.dart` 扫描 import 强制：domain 纯 Dart；
data/sources/playback 不碰 UI；providers 不 import `main.dart`；UI（pages/widgets）不直接 import
sources/playback。模块布局与体积由 `test/architecture/module_layout_test.dart` 强制
（模型只在 `domain/models/`、服务在 `services/`、`utils` 纯度、800 行棘轮，ADR-0034）；
原生互操作边界由 `test/architecture/native_interop_test.dart` 强制（只有 `lib/platform/`
可直连 JNI / FFI / Win32 / POSIX 绑定；Apple 走 Swift + Pigeon，`objective_c` 仅允许作为
上游插件的传递依赖，ADR-0038）。

关键不变量（改相关代码前确认）：

- `SourceTrack.raw` / `Track.payload` 原样回传脚本（`songmid`/`hash`/`copyrightId` 等被脚本依赖），payload UI 禁读；
- `PlayableStream.headers` 必须一路透传给播放器（`AudioSource.uri` / `LockCachingAudioSource`）、
  下一首预取、桌面缓存写入与下载：B 站直链缺 `Referer` / 浏览器 UA 会直接 403；
- 进度只走 `PlaybackProvider.position`（`ValueListenable`，≤4Hz），不进 `notifyListeners`；快照值变才通知；
- UI 只消费类型化 `PlaybackSnapshot`，不感知播放后端实现；
- 错误在边界统一为 `SourceFailure`（kind/l10nKey/retryable），UI 不直接展示 `$e`；
- B 站账号 Cookie 只随字幕 / 账号资料请求发送（`BiliAuth.account*`）；播放、搜索、
  评论、字幕 CDN 必须保持匿名；登录信息是凭证类别，默认随同步；完整备份默认
  包含全部凭证（ADR-0016）；
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
- UI 视觉改动（共享工具栏 / 选择器 / 弹层）先在 360 与 640 宽渲染截图或 preview 再提交；
  单测的 `didExceedMaxLines` 发现不了「chip 把输入区挤窄」这类比例问题；
- 每次改动至少 `flutter analyze --no-pub` + `flutter test --no-pub`（迭代可只跑改动范围，提交前跑全量）；
- 测试按模块聚合：小用例并入同模块 `*_test.dart`，`*_cases.dart` 只作为聚合套件的用例库
  （不被 `flutter test` 单独发现）。每个测试文件都有独立的 engine/kernel 装载开销（~1s，
  与文件大小无关），拆得越碎全量越慢；
- Git：功能分支（主分支 `main`），提交 `type(scope): 描述`；密钥不进仓库。
  并行会话用独立 worktree（`tool/agent/worktree_prepare.sh`）；主工作树可能同时有其它会话的
  改动，提交前按自己的路径核对 `git diff --stat`。

## 领域文档与技能

- 文档地图与单一来源约定见 `docs/README.md`；改 / 删文档前先查指向；
- Issues 与规格走 GitHub issues（`gh` CLI，`docs/agents/issue-tracker.md`）；标签见
  `docs/agents/triage-labels.md`；术语与决策见 `GLOSSARY.md` + `docs/adr/`（`docs/agents/domain.md`）；
- 包体积 / 内存 / worktree / seed / APK 明细的完整口径与踩坑见
  `.agents/skills/molia-perf-tooling/SKILL.md`；
- `skills-lock.json` 管理的 `dart-*` / `flutter-*` 等第三方技能勿手改；`molia-*` 为本仓技能，
  随 `AGENTS.md` 与 docs 一起维护。
