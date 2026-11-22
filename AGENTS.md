# AGENTS.md

**Molia** 是 Flutter 音乐播放器：七渠道内置搜索/发现（六个音乐平台 + 哔哩哔哩）、
本地与网络播放（桌面 media_kit/libmpv）、歌词与海报、省流模式，以及可选的 AI 推歌、
听歌同步与跨设备同步（WebDAV / 局域网）；同时支持 LX 音源脚本。
术语与能力地图见 `GLOSSARY.md`。

## 工具链

Flutter / Dart 3.50.1 / 3.14.0；JDK 27+；Gradle 9.9.2 / AGP 9.5.1 / Kotlin 2.4.21；
compileSdk 37.2 / targetSdk 37，minSdk 35；build-tools 37.0.0；NDK 30.0.16248370；
Android CLI 1.1.16919734。

## 常用命令

完整流程（准备 → 开发 → 门禁 → 编译 → 发布）见 `docs/dev_workflow.md`；脚本选项以 `-h` 为准。

```bash
flutter analyze --no-pub                        # 必须 0 error / 0 warning
flutter test --no-pub                           # 全量；单文件在末尾加路径
dart run tool/agent/cli.dart -h                 # 跨端工具入口（ADR-0031）
dart run tool/agent/cli.dart test linux|android # 端到端测试，默认后台
dart run tool/agent/cli.dart docs check         # 文档与工具链一致性
dart run tool/agent/cli.dart size apk|desktop --check <产物>
tool/agent/ui_preview.sh                        # 无设备 UI 预览（360 / 640）
tool/agent/seed.sh android|linux <cmd>          # 数据注入
tool/agent/worktree_prepare.sh <dir> [branch]   # 并行会话工作树
```

性能采样（startup / perf / cpu / memory / io）与体积口径见
`.agents/skills/molia-perf-tooling/SKILL.md`；设备调试见
`.agents/skills/molia-device-debug/SKILL.md`。

## 生成物

改源文件后重跑对应生成器；产物提交进仓库，不手改。

- `tool/lx_prelude/` → `node tool/build_lx_prelude.mjs` 与 `node tool/lx_prelude_harness.mjs`
  （应输出 `PROTOCOL OK`）；平台夹具用 `tool/gen_*_fixtures.mjs` 重抓；
- `lib/data/molia_database.dart` → `dart run build_runner build`；表结构变更再跑
  `dart run drift_dev make-migrations` 并写增量迁移（ADR-0005 / 0017 / 0021）；
- 图标：Windows 任务栏 `python3 tool/gen_taskbar_icons.py`；macOS
  `swift tool/gen_macos_icons.swift`；iOS / Windows 品牌图标 `dart run icons_launcher:create`；
- 原生互操作（ADR-0038）：Android `dart run tool/jnigen.dart`，桌面
  `dart run tool/ffigen_system.dart`，Pigeon 见 `tool/pigeon/README.md`。

## 架构地图

```
lib/
  domain/                     # 纯 Dart：models + ports
  data/ sources/ playback/    # 端口实现：db / 缓存 / 更新、音源、播放后端
  providers/ services/ app/   # UI 状态、领域服务、应用壳与 bootstrap 组合根
  platform/                   # JNIgen / FFIgen / Pigeon 生成物与薄适配器
  pages/ widgets/ + main.dart # UI 与唯一 composition root
```

分层与模块边界由 `test/architecture/` 强制（ADR-0034 / 0038）：domain 纯 Dart；
data/sources/playback 不碰 UI；providers 不 import `main.dart`；UI 不直接依赖
sources/playback；只有 `lib/platform/` 可直连原生绑定。模型只在 `domain/models/`、
服务在 `services/`，文件体积按 800 行棘轮收紧。细节见 `docs/architecture.md`。

关键不变量（改相关代码前确认）：

- `SourceTrack.raw` / `Track.payload` 原样回传脚本，payload 禁止被 UI 读取；
- `PlayableStream.headers` 必须透传给播放器、下一首预取、缓存写入与下载
  （B 站直链缺 `Referer` / 浏览器 UA 会 403）；
- 播放进度只走 `PlaybackProvider.position`（≤4Hz），不进 `notifyListeners`；
- UI 只消费类型化 `PlaybackSnapshot`，不感知播放后端实现；
- 错误在边界统一为 `SourceFailure`（kind / l10nKey / retryable），UI 不展示 `$e`；
- B 站 Cookie 只随字幕与账号资料请求发送，播放、搜索、评论、字幕 CDN 保持匿名；
  登录信息属凭证，默认随同步，完整备份也包含全部凭证（ADR-0016）；
- 取色唯一入口为 `buildColorScheme` 与 `artwork_palette_service.dart`，禁止二次提取封面像素（ADR-0001）。

## 开发约定

- 订阅优先 `Selector` / `ValueListenableBuilder`；`select` 返回不可变对象或 record；
- 文案统一走 `AppLocalizations`；用户可见文案与注释规则见 `docs/copy_style.md`、
  `docs/comment_style.md`；
- UI 改动前先读 `docs/README.md` 中的界面版式 ADR；M3E 组件、圆角图标、颜色与排版令牌
  由 `test/architecture/` 强制，口径见 `docs/architecture.md` §6；
- 共享工具栏、选择器与弹层的视觉改动先跑 `tool/agent/ui_preview.sh`，查看 360 / 640
  截图比例后再提交；
- 每次改动至少跑 `flutter analyze --no-pub` 与 `flutter test --no-pub`；测试按模块聚合，
  小用例并入同模块 `*_test.dart`，`*_cases.dart` 只作为聚合套件的用例库；
- Git：功能分支（主分支 `main`），提交 `type(scope): 描述`，密钥不进仓库；并行会话使用
  独立 worktree，提交前按自己的路径核对 `git diff --stat`。

## 领域文档与技能

- 文档地图与单一来源约定见 `docs/README.md`；改删文档前先查引用；
- 规格与议题走 GitHub issues（`gh` CLI，`docs/agents/`）；
- 性能、发布、设备调试的完整口径见 `.agents/skills/molia-*`。
