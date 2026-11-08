---
name: Molia 性能与体积工具
description: 优化或验证 Molia 的包体积、内存、APK 内容、Linux release bundle，或在并行 worktree 中构建 / seed / 采样时使用。触发词：包体积、内存、perf、size、APK、bundle、worktree、seed、imageCache、release 体积、native 库。
---

# Molia 性能与体积工具

## 先用对入口

| 目标 | 命令 |
|---|---|
| 新 worktree 构建前置 | `tool/agent/worktree_prepare.sh <dir> [branch]` |
| Linux bundle 体积 | `tool/agent/perf.sh size linux` |
| Android APK 体积 | `tool/agent/perf.sh size android` |
| APK 明细 / native 库约束 | `python3 tool/agent/apk_size.py --check <apk>` |
| Android 内存采样 | `tool/agent/perf.sh memory android`（需 `adb root`） |
| Linux / Windows 内存 | `tool/agent/perf.sh memory linux\|windows` |
| Linux release 卫生 | `tool/agent/check_linux_bundle.sh [bundle]` |

权威数字与基线：`docs/performance.md`、`docs/memory.md`、`docs/performance-audit-*.md`。
**先有原始产物 / 日志，再写数字；没有 A/B 就明确写「未测」，不要归因。**

## 新 worktree

`worktree_create` 可能给 detached HEAD；不要直接提交。统一跑：

```bash
tool/agent/worktree_prepare.sh /path/to/worktree perf/my-change
```

它补：分支、`android/key.properties` + `*.jks`、`android/gradle` wrapper、
`.dart_tool/hooks_runner/shared`（sqlite3 / cnativeapi 预编译缓存），并做首次
`pub get`。缺签名时 release APK 会失败；缺 hooks 缓存时 Android build 会去
GitHub 下载 sqlite3（受限网络会等 3 分钟以上）。细节见 `docs/pitfalls.md` #26。

## seed.sh

```bash
tool/agent/seed.sh android favorites 1000   # 1000 首收藏
tool/agent/seed.sh android history 500      # 最近播放
tool/agent/seed.sh android covers 30        # 30 张本地 file:// 封面，填 ImageCache
tool/agent/seed.sh android mock-source      # mock LX 音源 + WAV
```

- DB 读取会拉主库 + `-wal` / `-shm`，本地 checkpoint 后修改；release 包的 schema
  常只在 WAL 里，只 `cat` 主库会得到 0 表空库（`no such table`）。
- 大数据量走临时 JSON 文件，不把 tracks 塞进 argv（1000 首会 `Argument list too long`）。
- 首次注入前的有效单文件库备份在 `/tmp/opencode/molia/seed-backup/latest/`；
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
python3 tool/agent/apk_size.py --check build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

- 发布参数以 `.github/workflows/release.yml` 的 `flags` 为准（`--split-per-abi
  --split-debug-info --obfuscate`）；不同参数的数字不能直接 A/B。
- `apk_size.py` 会按 `lib/<abi>` / dex / `flutter_assets` / res 分组，并检查
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
- 图片缓存预算：前台 64MiB / 托盘与移动端后台 16MiB；后台 30s 清理
  `imageCache.clear()`，**不清 live images**（恢复后当前封面不能空白）。
- `LibraryProvider` 列表曲目缓存 LRU 上限 5；搜索 / 目录缓存只在
  `didHaveMemoryPressure` 释放，普通退后台不清列表。
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
- APK 内容用 `apk_size.py` 或 `python3 -m zipfile -l`，不依赖 `unzip`。
- `adb` 未在 PATH 时用 `~/Android/Sdk/platform-tools/adb`，或先
  `export PATH="$HOME/Android/Sdk/platform-tools:$PATH"`。
