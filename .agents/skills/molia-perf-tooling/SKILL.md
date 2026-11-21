---
name: Molia 性能与体积工具
description: 优化或验证 Molia 的帧 / 120Hz（jank8）、启动、包体积、内存、APK 内容、Linux release bundle，或在并行 worktree 中构建 / seed / 采样时使用。触发词：帧、120Hz、jank8、frames、perf、启动、包体积、内存、size、APK、bundle、worktree、seed、imageCache、release 体积、native 库。
---

# Molia 性能与体积工具

## 先用对入口

| 目标 | 命令 |
|---|---|
| 新 worktree 构建前置 | `tool/agent/worktree_prepare.sh <dir> [branch]` |
| 帧 / 120Hz | `tool/agent/perf.sh frames linux`（`--only a,b` 只跑场景；`--timeline [stats]` 归因） |
| 语义 / 读屏成本 | 帧命令加 `--with-at`（默认关闭 GTK 无障碍桥） |
| Linux bundle 体积 | `tool/agent/perf.sh size linux` |
| Android APK 体积 | `tool/agent/perf.sh size android` |
| APK 明细 / native 库约束 | `dart run tool/agent/cli.dart size apk --check <apk>` |
| Android 内存采样 | `tool/agent/perf.sh memory android`（需 `adb root`） |
| Linux / Windows 内存 | `tool/agent/perf.sh memory linux\|windows` |
| Linux release 卫生 | `tool/agent/check_linux_bundle.sh [bundle]` |

权威数字与基线：`docs/performance.md`、`docs/memory.md`、`docs/performance-audit.md`。
**先有原始产物 / 日志，再写数字；没有 A/B 就明确写「未测」，不要归因。**

## 帧 / 120Hz

- 判定口径：`work = build + raster`，120Hz 看 **`jank8`**（>8.33ms），60Hz 看
  `jank16` / `jank33`；`totalSpan` 只用于 `latency16`，不是卡顿依据。
- 场景都在 `integration_test/perf_flows_test.dart`：桌面滚动 / 切页 / 切歌、
  移动壳进出播放页、播放器展开/收起，以及三个 120Hz 专用场景
  `desktop-favorites-toggle`（10k 真实内存库）、`desktop-statistics-open`
  （400 天统计）与 `desktop-window-resize`（1440×900 ↔ 1100×720 逐帧往返）。
  Android 跳过这三个桌面专用场景。
- **只跑改动的场景**：`tool/agent/perf.sh frames linux --only desktop-statistics-open`
  （逗号分隔；会校验场景名并确认确实产出了 `molia.frame`）。全量一轮含 10k seed，
  分钟级，迭代不要每轮全跑。
- 归因：`--timeline`（收藏滚动）或 `--timeline stats`（统计页开页）；
  产物为 `timeline.json` + `summary.md`。
- headless 默认注入 `NO_AT_BRIDGE=1 GTK_A11Y=none`（best-effort）：没有真实 AT 时
  语义树不该计入帧预算；但实测 Xvfb + integration_test 下引擎仍会报告
  accessibility enabled，SEMANTICS 属环境成本。`--with-at` 只控制测试是否主动建
  语义 handle，跨轮比较保持同机同环境。
- 新增场景：改 `test/support/perf_app_harness.dart` +
  `test/support/perf_scenarios.dart` + `integration_test/perf_flows_test.dart`，
  并把场景名登记到 `tool/agent/perf.sh` 的 `KNOWN_FRAME_SCENES`。
- 基线与历史 A/B 见 `docs/performance.md` §9 与 `docs/performance-audit.md`。

## 新 worktree

`worktree_create` 可能给 detached HEAD；不要直接提交。统一跑：

```bash
tool/agent/worktree_prepare.sh /path/to/worktree perf/my-change
```

它补：分支、签名（优先用户级 `~/.config/molia/android.properties`，没有时才复制
`android/key.properties` + `*.jks`）、`.dart_tool/hooks_runner/shared`
（sqlite3 / cnativeapi 预编译缓存），并做首次 `pub get`。Gradle wrapper 已入库，
不再复制。缺签名时 release APK 会失败；缺 hooks 缓存时 Android build 会去
GitHub 下载 sqlite3（受限网络会等 3 分钟以上）。细节见 `docs/pitfalls.md` #26。

## seed.sh

完整命令、数据位置与恢复语义见 `docs/dev_environment.md`「数据注入」。性能采样
常用的两个大样本：

```bash
tool/agent/seed.sh android favorites 1000   # 1000 首收藏
tool/agent/seed.sh android covers 30        # 30 张本地 file:// 封面，填 ImageCache
```

- DB 读取会拉主库 + `-wal` / `-shm`，本地 checkpoint 后修改；release 包的 schema
  常只在 WAL 里，只 `cat` 主库会得到 0 表空库（`no such table`）。
- 大数据量走临时 JSON 文件，不把 tracks 塞进 argv（1000 首会 `Argument list too long`）。
- 首次注入前的有效单文件库备份在 `${TMPDIR:-/tmp}/molia-agent/seed-backup/latest/`；
  0 表空备份会被替换。`restore` 会清设备旁挂文件。
- `covers` 依赖本地 1000×1000 PNG；采样时用 `perf.sh memory android`，不要手写
  adb 循环。

## 体积口径

### Linux

```bash
tool/agent/perf.sh size linux
```

它会清 `build/flutter_assets`、`linux/flutter/ephemeral`、bundle（保留 mimalloc
tarball），用 `--split-debug-info=build/symbols/linux` 构建，调用
`tool/strip_linux_bundle.sh`，并用 `check_linux_bundle.sh` 检查：
- `data/flutter_assets/kernel_blob.bin` 不允许存在（debug 残留可把 bundle 从
  40MB 推到 186MB）；
- `libflutter_linux_gtk.so` >20MB 视为非 release 引擎（常见于跑过
  `--analyze-size`，会留下约 42MB 的 `linux/flutter/ephemeral`）。

普通 `flutter build linux --release` 后也跑一次 `check_linux_bundle.sh`；不要
在跑过 `--analyze-size` 的同一 build 目录直接量发布体积。

### Android

```bash
tool/agent/perf.sh size android
dart run tool/agent/cli.dart size apk --check build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

- 发布参数以 `.github/workflows/release.yml` 的 `flags` 为准（`--split-per-abi
  --split-debug-info --obfuscate`）；不同参数的数字不能直接 A/B。
- `size apk` 会按 `lib/<abi>` / dex / `flutter_assets` / res 分组，并检查
  禁止库：`libmpv.so`、`libmediakitandroidhelper.so`、`libcnativeapi.so`；
  必需库：`libsqlite3.so`（坑 #28）、`libquickjs_c_bridge_plugin.so`。
- 估算 `lib/` 占比时看压缩后；native 库通常占 APK 的 80% 以上。AOT 侧要看
  `--analyze-size`，但注意它会污染 Linux ephemeral。

## 内存

```bash
tool/agent/perf.sh memory android          # 构建/安装 → 30 封面 → 空闲/后台 35s/回前台
tool/agent/perf.sh memory linux            # 托盘 RSS + molia.memory
```

- Android 采样要求 `adb root`（release 包不可 `run-as`）；首次安装先启动一次
  创建私有目录，脚本已处理。
- 图片缓存预算、列表曲目 LRU、后台清理与释放口径见 `docs/memory.md` §8；
  这里只记采样入口与 A/B 条件。
- 受控 A/B 必须同 fixture（封面数、列表数、前后台时长）；空 fixture 的
  `imageCache=0.0MB` 只能证明预算切换，不能宣称省内存。

## 并行删除功能后的 review

子代理并行删功能时，文档可能引用已删除的类型。合并后由集成者做一次：

```bash
rg "RemovedType|removed_key|旧术语" lib test integration_test docs GLOSSARY.md
```

文档只在合并后由集成者成稿，避免两个 workstream 同时写 `docs/` 造成
「已删功能的缓存 / 派生图」残留。代码 / 测试的残留扫描是硬门槛；文档
措辞由 reviewer 确认。

## 搜索与工具经济

- 代码检索优先用 `rg`（跳过 `.gitignore`）；不要 `grep -r .` 扫到
  `.dart_tool/flutter_build`，也不要 `find /` 找系统 libmpv（Linux 用系统
  `libmpv.so`，见 `docs/media_kit_native_libs.md`）。
- APK 内容用 `size apk` 或 `python3 -m zipfile -l`，不依赖 `unzip`。
- `adb` 未在 PATH 时用 `~/Android/Sdk/platform-tools/adb`，或先
  `export PATH="$HOME/Android/Sdk/platform-tools:$PATH"`。
