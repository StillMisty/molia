# 开发与编译流程

> 本文件是「从改一行代码到出包」的流程入口，只负责**顺序与门禁**；单条脚本的选项
> 以脚本自身的 `--help` / 文件头为准。环境依赖细节见 `docs/dev_environment.md`；
> 发布 secrets、产物清单与各平台限制见 `.agents/skills/molia-release/SKILL.md`；
> 工具链版本只在 `AGENTS.md`「工具链」维护。

## 1. 原则

1. **官方命令是事实，脚本只是封装。** 运行 / 测试 / 构建类脚本都能找到等价的
   `flutter ...` / `dart ...` 命令，脚本失效时按等价命令执行；只有数据夹具类
   （`tool/agent/seed.sh`）没有官方等价物，单独登记在第 8 节。
2. **快门禁在前，慢验证在后。** analyze → 单测 → 集成测试 → 构建，任一步失败就停，
   不带着红灯往后跑。
3. **debug 只证明「能跑」，不证明「够快」。** 启动、帧率、内存、体积的结论只允许
   来自 profile 或 release 产物。
4. **生成物入库但不手改。** 改源文件 → 重跑生成器 → 提交产物；直接改产物会在下次
   生成时丢失。
5. **默认显式。** 设备、显示、构建模式都不猜：无显示加 `--headless`，多设备用
   `-d <serial>`，模式写 `--release` / `--profile`。
6. **不为一次性问题新增脚本。** 先用官方命令 + 现有脚本；确实要固化再进
   `tool/agent/`，并在本文件第 8 节登记。

## 2. 首次准备

```bash
flutter doctor -v                 # SDK / 平台工具链自检
flutter pub get                   # 锁文件已入库；CI 用 --enforce-lockfile
tool/agent/hooks.sh               # 启用 .githooks（提交前格式化 + 文档检查）
tool/agent/setup.sh               # 可选：Android 模拟器 / SDK 组件（幂等）
```

- **依赖**：`pubspec.lock` 必须提交。CI 与发布用 `flutter pub get --enforce-lockfile`；
  升级依赖用 `flutter pub upgrade <pkg>` 定点升级，不要全量 `flutter pub upgrade`
  （会让锁文件整体漂移），升级后跑全量测试。
- **平台依赖**：Linux 的 libmpv / X11 开发包 / 中文字体，macOS 的 Xcode + Swift Package
  Manager（仓库没有 Podfile），Android 的 SDK / NDK —— 见 `docs/dev_environment.md`。
- **并行会话**：新 worktree 先跑 `tool/agent/worktree_prepare.sh <dir> [branch]`，
  避免 Gradle 与 native assets 缓存各拷一份、受限网络下卡在下载。

## 3. 日常开发循环

### 3.1 启动

```bash
flutter run -d linux                     # 桌面，前台，r / R / q 直接可用
tool/agent/emu.sh start                  # 没有模拟器时先起（默认 headless）
flutter run -d emulator-5554             # Android 模拟器
tool/agent/app.sh run -d linux           # 无 TTY / 后台：官方 --pid-file + SIGUSR1/2
tool/agent/app.sh run -d linux --headless  # 无图形显示：显式 Xvfb
```

`tool/agent/app.sh` 只做三件事：后台启动 `flutter run --pid-file`、按设备记录会话、
把 `r` / `R` 换成 `SIGUSR1` / `SIGUSR2`。**没有显示时不隐式切 Xvfb**：缺
`DISPLAY` / `WAYLAND_DISPLAY` 会直接报错并提示 `--headless`。

### 3.2 热重载边界

| 改动 | 操作 |
| --- | --- |
| widget 树 / `build` / 普通方法体 / 样式常量 | 热重载（`r`） |
| `main()` / `initState` / 全局单例 / 顶层 `final` 初始化 | 热重启（`R`） |
| ARB 文案、drift / prelude 生成物 | 先跑生成器，再热重启 |
| `pubspec.yaml`、原生代码、assets、`build.yaml` | `app.sh stop` 后重新 `run`（热重载不覆盖这些输入） |

### 3.3 看数据、看界面

- 数据夹具：`tool/agent/seed.sh android|linux <cmd>`（收藏 / 历史 / 会话 / 语言 /
  mock 音源）。它绕过 UI 直接写 prefs 与 SQLite，**只用于构造固定夹具**；能通过界面
  或导入完成的操作不要用它。
- 截图：`tool/agent/shot.sh [name] [--annotate]`（Android）。
- 点按 / 输入 / 布局：`tool/agent/ui.sh layout|tap|swipe|text|key`。
- **视觉改动先在 360 与 640 宽各渲染一次**（共享工具栏 / 选择器 / 弹层尤其）。
  只靠 `didExceedMaxLines` 发现不了「chip 把输入区挤窄」这类比例问题。

## 4. 代码生成

| 改了什么 | 命令 | 产物 / 检查 |
| --- | --- | --- |
| `lib/l10n` 下的 ARB | `flutter gen-l10n` | `lib/l10n/app_localizations*.dart`（生成物，勿手改） |
| `lib/data/molia_database.dart` | `dart run build_runner build` | `lib/data/molia_database.g.dart` |
| 表结构（提 `schemaVersion`） | 上面 + `dart run drift_dev make-migrations` | `drift_schemas/` 快照；增量迁移见 ADR-0005 / ADR-0017 |
| `tool/lx_prelude/` | `node tool/build_lx_prelude.mjs` + `node tool/lx_prelude_harness.mjs` | `assets/lx/lx_prelude.js`（terser 产物）+ `PROTOCOL OK` |
| 内置平台响应 | `node tool/gen_search_fixtures.mjs` 等 `tool/gen_*_fixtures.mjs` | `test/` 下的 fixture |
| Windows 任务栏图标 | `python3 tool/gen_taskbar_icons.py` | `windows/runner/resources/thumbbar/` 下的 `.ico` |
| 品牌图标 | `swift tool/gen_macos_icons.swift` / `dart run icons_launcher:create` | macOS / iOS / Windows 图标 |

规则：生成物提交进仓库；**改源再生成**，不要反向改产物。改表结构时不能只跑
`dart run build_runner build`：还要用 `make-migrations` 生成快照，再用 `stepByStep`
写增量迁移并保留数据（ADR-0005）。

## 5. 质量门禁

### 5.1 本地（提交前）

```bash
dart format <改动的文件>          # pre-commit 也会自动格式化已暂存的 Dart
flutter analyze --no-pub          # 必须 0 error / 0 warning
flutter test --no-pub             # 默认集，本机 <30s
python3 tool/agent/check_docs.py  # 改文档 / 版本 / workflow 时
```

- `--no-pub` 是显式声明「依赖已就绪」；首次检出或改过 `pubspec.yaml` 后不要加。
- 测试按模块聚合：小用例并进同模块 `*_test.dart`；`*_cases.dart` 只是聚合套件的
  用例库，`flutter test` 不会单独发现它。每个测试文件都有独立的 engine/kernel 装载
  开销（约 1s，与文件大小无关），拆得越碎全量越慢。
- `test/architecture/` 是硬约束：分层 import、`Icons.*_rounded`、只走
  ColorScheme / `AppSemanticColors`、`context.typeScale` 排版。它们和普通单测一起
  跑，不需要单独命令。

### 5.2 设备 / 启动（改到引擎、启动、原生时）

```bash
tool/agent/test.sh linux              # 真实引擎 + 设置页 + 窗口/托盘；默认 Xvfb
tool/agent/test.sh android            # 同一套跑模拟器（先 emu.sh start）
tool/agent/smoke.sh linux             # 真实 main() + provider tree 的首帧烟测
```

- 集成测试只走官方 `flutter test integration_test/... -d <device>`；脚本负责
  Xvfb、设备等待、超时与日志。
- 集成测试**不进 CI**：需要真实设备 / 显示，引擎用例耗时也远超 CI 预算；CI 只跑
  analyze + 单测，设备回归在本地或发布前跑。
- 集成测试不含真实播放：无头环境 libmpv 装载不可靠（已知坑 #33），播放由单测与
  真机手动验证覆盖。
- `tool/agent/smoke.sh` 是唯一覆盖 `main()` 的检查：`flutter test` 与集成测试都不
  执行 `main()`，`runApp` 前的 Provider 装配崩溃只有它能兜住。窗口黑屏先跑它，
  不要先怀疑 GPU。

### 5.3 CI

`.github/workflows/ci.yml` 是本地门禁的压缩版，顺序固定：
`check_docs.py` → 系统依赖（native assets 的 GTK / X11）→
`flutter pub get --enforce-lockfile` → `flutter analyze --no-pub` →
`flutter test --no-pub`。

CI 红了的处理顺序：先本地复现同一条命令，不要先改 CI；本地绿而 CI 红，再查环境
差异（系统包、SDK 版本、未提交的生成物）。

## 6. 多平台编译

### 6.1 三种模式

| 模式 | 用途 | 命令 |
| --- | --- | --- |
| debug | 日常开发、断言、`flutter run` | `flutter run` / `flutter build apk --debug` |
| profile | 性能采样（AOT + timeline，保留符号） | `flutter run --profile` / `flutter build <target> --profile` |
| release | 交付产物（AOT，按需混淆） | `flutter build <target> --release` |

不要在 debug 包上得出启动 / 帧率 / 内存结论：JIT、断言与调试服务会让数字失去意义。

### 6.2 通用参数

- `--build-name <version>` / `--build-number <n>`：本地复现发布包时与 tag、CI 构建号
  对齐。
- `--dart-define=KEY=VALUE`：构建期配置（例如 Last.fm key）。密钥只从环境变量 /
  CI secrets 注入，不写进仓库。
- `--split-debug-info=<dir>`：把符号拆到单独目录；线上崩溃需要它还原堆栈。
- `--obfuscate`：必须与 `--split-debug-info` 配对；目前只有 Android 发布包启用。
- `--target-platform` + `--split-per-abi`：Android 按 ABI 拆包。APK 与 AAB 必须共用
  同一组 AOT 参数，否则第二次构建会重编全部 ABI。

### 6.3 各平台

| 平台 | 命令 | 前置 / 校验 |
| --- | --- | --- |
| Android | `flutter build apk --release --split-per-abi` / `flutter build appbundle --release` | JDK + SDK + NDK；签名读 `android/key.properties`（不入库）；`python3 tool/agent/apk_size.py --check <apk>` 校验 native 库与分组体积 |
| Windows | `flutter build windows --release` | 必须在 Windows 侧 Flutter 构建（WSL 的 Flutter 不能出 Windows 包）；安装器用 `windows/installer/molia.iss` |
| Linux | `flutter build linux --release` | 系统安装 `libmpv`；`tool/agent/check_linux_bundle.sh` 拒绝 debug 残留 / 非 release 引擎；`tool/strip_linux_bundle.sh` 只 strip 第三方插件库；桌面入口在 `linux/packaging/` |
| iOS | `flutter build ios --release --no-codesign` | 必须在 macOS 构建；Swift Package Manager（无 Podfile）；产物仅供侧载与验证 |
| macOS | `flutter build macos --release` | 必须在 macOS 构建；ad-hoc 签名；打包用 `ditto` 保留 framework 符号链接 |

产物位置：

- Android：`build/app/outputs/flutter-apk`、`build/app/outputs/bundle/release`
- Linux：`build/linux/x64/release/bundle`
- Windows：`build/windows/x64/runner/Release`
- macOS：`build/macos/Build/Products/Release`
- iOS：`build/ios/iphoneos`

### 6.4 本地复现发布包

```bash
v=<与 tag 一致的版本>; n=<构建号>
flutter build linux --release --build-name "$v" --build-number "$n" \
  --split-debug-info=build/symbols/linux \
  --dart-define=MOLIA_LASTFM_API_KEY="$MOLIA_LASTFM_API_KEY"
tool/agent/check_linux_bundle.sh
```

其它平台的参数组合与 `.github/workflows/release.yml` 完全一致。本地只验证「能不能
出包 + 体积 / 资源是否达标」，签名与上传交给 CI，不在本地伪造发布环境。

## 7. 发布

发布由 tag 驱动：

```bash
git tag -s v<version> -m "Molia <version>" && git push origin v<version>
```

- 打 tag 前先把 `pubspec.yaml` 的 `version` 改成同一个版本号；CI 会逐字比对，不一致
  直接失败。
- 构建号由 CI 的 run number 生成，与 Android `versionCode` 同源，保证覆盖安装与
  「有新版本」判定可靠。
- 带 `-beta.N` 后缀的 tag 发布为 prerelease，`latest.json` 走 beta 渠道。
- secrets、产物命名、各平台打包限制、`latest.json` 字段见
  `.agents/skills/molia-release/SKILL.md`；更新清单由 `tool/ci/gen_update_manifest.py`
  生成，`SHA256SUMS.txt` 随产物一起发布。

## 8. 偏离标准的做法（登记表）

> 这里只登记**有意保留**的偏离。新增一条前先问：官方命令 + 现有脚本能不能做？
> 能做的写进主流程，不做成脚本；确实要偏离，写清原因和退出条件。

| 位置 | 做法 | 为什么 | 退出条件 |
| --- | --- | --- | --- |
| `tool/agent/app.sh` | 后台跑 `flutter run` + pid-file 信号 | 无 TTY 的 agent / 子代理会话里也要热重载；`--pid-file` 与 `SIGUSR1` / `SIGUSR2` 是 Flutter 官方通道 | 会话始终有 TTY，或官方提供等价的非交互控制接口 |
| `tool/agent/test.sh`、`tool/agent/smoke.sh` | Xvfb + `GDK_BACKEND=x11`，并去掉 `WAYLAND_DISPLAY` | WSL / 容器没有显示，又要把窗口应用真正跑起来；只改 `DISPLAY` 时 GTK 仍会走 Wayland | 有稳定的无头 Flutter 桌面测试方案 |
| `tool/agent/_common.sh` | 本地 release / 体积测量前删 `build/flutter_assets` 与 `linux/flutter/ephemeral` | 上一次 debug / `--analyze-size` 的 kernel_blob 与引擎会混进 release bundle | Flutter 增量构建按模式隔离产物 |
| `tool/strip_linux_bundle.sh` | 额外 strip 第三方插件 `.so` | 发布包体积；只 strip 白名单，`libapp.so` 与引擎保持原样 | 上游打包流程默认 strip |
| `tool/agent/seed.sh` | 直接写 prefs / SQLite / 音源 JSON | 没有公开的「造固定数据」API；UI 点按造数慢且不稳 | 应用提供 debug-only 导入 / seed 入口后删除 |
| `tool/agent/smoke.sh` | 用日志里的 `molia.startup: 首帧` 判定启动 | `flutter test` 不执行 `main()`；这是唯一能覆盖 `runApp` 前装配的检查 | 官方提供启动烟测，或集成测试统一执行 `main()` |
| `assets/lx/lx_prelude.js`、图标 | 生成物入库 | 构建期不跑 Node / 图像工具，受限网络下也能复现 | CI 与本地都能在构建前稳定生成 |

## 9. 提交前清单

- [ ] 改过的生成物已重跑并提交（ARB / drift / prelude / 图标 / fixture）
- [ ] `flutter analyze --no-pub` 0 error / 0 warning
- [ ] `flutter test --no-pub` 全绿（迭代可只跑改动范围，提交前跑全量）
- [ ] 改到引擎 / 启动 / 原生：`tool/agent/test.sh linux` + `tool/agent/smoke.sh linux`
- [ ] 改到文档 / 版本 / workflow：`python3 tool/agent/check_docs.py`
- [ ] 视觉改动附 360 与 640 宽截图
- [ ] `git diff --stat` 只包含本次路径（主工作树可能同时有其它会话的改动）
- [ ] 提交信息 `type(scope): 描述`
