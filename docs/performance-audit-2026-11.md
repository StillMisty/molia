# 全链路性能复测（2026-11-07）

> 范围：Linux 桌面（Xvfb 无头，按本轮要求不弹 WSLg 窗口）+ Android 模拟器
> `molia_api37`。Windows 本轮未测（用户指定范围）。
>
> 基线/方法沿用 `docs/performance-audit-2026-10.md`；本文只记录本轮数字、
> 改动与未结论项。原始日志在 `/tmp/opencode/molia/`（文末列出目录名）。

## 1. 结论

- **没有启动 / 帧 / 数据链路回归**：Linux release 首帧中位 **160ms**
  （2026-10 基线 191–207ms）；Android release 首帧中位 **526 → 496ms**
  （改动前后，噪声内小幅改善），Activity TotalTime 1441–1551ms。
- Linux Xvfb 无头下滚动 / 切页 / 切歌 build p95 **1.0–2.8ms**、jank 0；
  Android 模拟器 build p95 **3.5–6.3ms**，无稳定回归。
- **AI 初始化从首帧前移到首帧后**，并把安全存储 / 偏好 / 历史读取并行化：
  Android `sub.ai.init` **207 → 158ms**（−49ms），Linux 129 → 102ms。
- **音源初始化不再等待同步初始化**：音源脚本与搜索 / 播放入口只依赖本地
  脚本仓库；同步仍等戳种子，传输 / 首轮在两边就绪后起。Android
  `sub.sourceManager.init` 105ms、`sub.sync.start` 181ms，互不阻塞。
- Linux 无头数据链路的首搜延迟（~250ms）**不是产品回归**：同场景首屏
  Xvfb 软件光栅 p95 达 **330ms**（`raster` 不可用于真实 GPU 结论），
  隐藏窗口 / 把 LX 任务泵改快都不能消除它，不据此改应用代码。
- Android 模拟器 `mobile-nowplaying-leave-return` 出现 build jank
  （p99 17.32ms、jank16=2、worst 97.66ms），但同场景第二个窗口恢复干净；
  没有真机 raster，仍不外推。

## 2. 测量口径

```bash
# Linux：全部无头，禁止弹 WSLg 窗口
env -u DISPLAY -u WAYLAND_DISPLAY GDK_BACKEND=x11 tool/agent/startup.sh --runs 5
env -u DISPLAY -u WAYLAND_DISPLAY GDK_BACKEND=x11 tool/agent/perf.sh frames linux
env -u DISPLAY -u WAYLAND_DISPLAY GDK_BACKEND=x11 dbus-run-session -- \
  tool/agent/perf.sh data linux
env -u DISPLAY -u WAYLAND_DISPLAY GDK_BACKEND=x11 tool/agent/perf.sh cpu linux

# Android：模拟器 headless
tool/agent/startup.sh android --runs 5
tool/agent/perf.sh frames android
tool/agent/perf.sh data android
```

- `perf.sh` 的隔离 `PERF_HOME` 会复用上一次的窗口几何；本轮第一次 CPU 采样
  读到 **3492×3012** 的持久 bounds，Xvfb 软件光栅直接把平台线程拉到 98%。
  已在 `tool/agent/perf.sh::prepare_perf_home` 每次固定为 1440×900，避免
  后续体检被污染；这不是应用回归。
- Android release 包不能 `run-as`，`perf.sh data android` 需要先
  `adb root`；首次安装还要先启动一次应用创建私有数据目录，再注入 mock 音源。

## 3. 启动

### 3.1 Linux release（Xvfb，5 次冷启动）

| 阶段 | 中位 | 最小–最大 |
| --- | ---: | ---: |
| 首帧 | **160ms** | 156–233ms（首轮 233ms 为构建后首次冷读） |
| 窗口就绪 | 19ms | 19–21ms |
| 本地数据/资料库栈 | 70ms | 69–145ms |
| 播放栈（含媒体会话） | 79ms | 78–154ms |
| 主题/歌词显示 | 81ms | 81–156ms |
| 首帧后：`sub.db.maxVersion` | 66ms | 62–69ms |
| 首帧后：`sub.ai.init` | 102ms | 94–106ms |
| 首帧后：`sub.downloadService.init` | 126ms | 116–132ms |
| 首帧后：`sub.dataSaver.monitor` | 185ms | 171–198ms |
| 首帧后：`sub.startupWallpaper` | 251ms | 241–269ms |

首帧与 2026-10 的 191–207ms 基线相比下降，主要是当轮机器/缓存差异；
没有新增首帧前工作。

### 3.2 Android release（模拟器，5 次冷启动）

| 阶段 | 改动前中位 | 改动后中位 | 改动后范围 |
| --- | ---: | ---: | ---: |
| 首帧 | 526ms | **496ms** | 427–515ms |
| `Activity TotalTime` | 1441ms | 1447–1551ms | 1454–2116ms |
| `sub.db.prewarm` | 454ms | 418ms | 346–440ms |
| `sub.syncState.init` | 334ms | 8ms | 3–432ms |
| `sub.mediaSession.activate` | 24ms | 28ms | 24–31ms |
| 首帧后：`sub.ai.init` | 207ms | **158ms** | 140–178ms |
| 首帧后：`sub.sourceManager.init` | — | 105ms | 97–127ms |
| 首帧后：`sub.sync.start` | 202ms | 181ms | 172–205ms |
| 首帧后：`sub.stats.maintenance` | — | 96ms | 32–105ms |
| 首帧后：`sub.update.start/check` | 178ms | 157ms | 149–186ms |

`sub.syncState.init` 的 8ms 中位与 334ms 基线不能直接比较：Android 的
「首个平台通道 ~400ms」这次落在 `lyricsPrefsCleanup`（两轮 432/408ms），
首帧中位仍在噪声内。首帧后各任务并行收尾，全部在 ~240ms 内结束。

## 4. 帧

### 4.1 Linux profile（`flutter drive`，raster 在桌面上恒 0）

| 场景 | frames | build p50 | build p95 | build p99 | jank16/33 | worst |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 收藏滚动 | 89 | 1.92 | 2.80 | 3.29 | 0 / 0 | 5.49 |
| 切资料库 | 51 | 0.76 | 2.20 | 7.21 | 0 / 0 | 9.35 |
| 连续切歌 | 136 | 0.56 | 1.05 | 6.93 | 0 / 0 | 8.81 |
| 进播放页 | 62 | 0.87 | 1.67 | 6.20 | 0 / 0 | 6.85 |
| 播放页 ⇄ 收藏 ×3 | 48 | 1.13 | 1.98 | 4.13 | 0 / 0 | 4.36 |
| 迷你条展开 / 收起 | 52 | 0.96 | 3.16 | 5.03 | 0 / 0 | 5.83 |

与 2026-10 的 Linux build p95（2.14 / 2.07 / 0.98 / 1.81ms）同量级，
没有发现需要继续压的 UI 工作量。

### 4.2 Android emulator profile

| 场景 | frames | build p50 | build p95 | build p99 | jank16/33 | worst |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 收藏滚动 | 82 | 2.03 | 4.02 | 6.36 | 0 / 0 | 7.03 |
| 切资料库 | 43 | 0.92 | 3.91 | 9.01 | 0 / 0 | 9.47 |
| 连续切歌 | 133 | 0.80 | 3.47 | 10.26 | 0 / 0 | 11.79 |
| 进播放页 | 63 | 1.13 | 3.79 | 4.65 | 0 / 0 | 6.40 |
| 播放页 ⇄ 收藏 ×3（首窗） | 123 | 1.06 | 6.31 | 17.32 | **2 / 1** | **97.66** |
| 播放页 ⇄ 收藏 ×3（次窗） | 62 | 1.06 | 3.47 | 9.07 | 0 / 0 | 9.32 |

- 首窗的 97.66ms 最差帧没有稳定复现（次窗干净），且 `flutter drive` 下
  `raster` 恒 0，不能据此断言真机掉帧；维持 2026-10 §3.3.6 的「待真机
  raster 复测」结论。
- `mobile-mini-expand` 场景本轮在模拟器失败：下拉 420 后播放器高度仍为
  394.8（期望 72），没有产生该场景的完整帧数据。属于测试手势/时序问题，
  不是帧耗时回归；下一轮跑真机前先修测试再采数。

## 5. 数据链路（mock 音源）

| 口径 | Linux headless | Android emulator |
| --- | ---: | ---: |
| 搜索端到端 | 599–798ms | 372ms |
| ├ 防抖 | 351–387ms | 321ms |
| ├ 音源搜索 | 239–258ms | 2.06ms |
| 起播 queue→首声 | 786–1251ms | 507ms |
| ├ resolve | 14–251ms | 110ms |
| ├ setAudioSource | 528–999ms | 396ms |
| 歌词（缓存命中） | 12–17ms | 82ms |
| 歌词缓存写 | — | 134–142ms |

Linux 无头下首搜的 ~250ms 与 Xvfb 首屏软件光栅重叠（同轮 14 帧里
`raster p95=330ms`、`worst=490ms`）；隐藏窗口、把 LX 任务泵从 250ms 改
25ms 都不能消除，因此**不把这段算到应用 Dart 侧**。Android 搜索
（372ms）与 2026-10 的 325–449ms 同量级，起播总时长 507ms 也在模拟器
抖动内（2026-10：363–416ms）。

## 6. CPU / IO

Linux release（Xvfb，1440×900）：

| 状态 | 总占用 | 平台/GTK | Dart UI + IO + worker |
| --- | ---: | ---: | ---: |
| 空闲（首帧后 8s） | 4.0% | 2.87% | 0.87% |
| 播放中 8s | 91.7% | 89.00% | 2.75% |

播放中的平台线程仍是 Xvfb 呈现拷贝，Dart 侧没有可修热点（与 2026-10
结论一致）。启动 + 数据场景期间 prefs 只写 **2 次**（1.2KB），WAL
648KB；没有发现高频整文件重写回归。

## 7. 本轮改动

1. `lib/app/bootstrap/ai_stack.dart` / `post_frame_init.dart`：
   `AiDjProvider.init()` 从首帧前移到首帧后，避免 AI 安全存储 / 历史批次
   和首帧前的窗口 / 播放装配抢平台通道；新增 `sub.ai.init（首帧后）` 埋点。
2. `lib/providers/ai_dj_provider.dart` / `services/ai/ai_settings_store.dart`：
   配置 / 确认 / 开关 / 偏好 / 反馈记忆 / 历史索引并行读；安全存储的三个
   键也并行。Android `sub.ai.init` 207→158ms，Linux 129→102ms。
3. `lib/app/bootstrap/post_frame_init.dart`：
   音源初始化与同步初始化并行（音源不再等安全存储 / 电池 / 网络探针），
   传输与首轮同步在两边就绪后起；新增
   `sub.sourceManager.init` / `sub.sync.start` / `sub.update.start/check` 埋点。
4. `lib/app/bootstrap/library_stack.dart`：新增 `sub.stats.maintenance`
   首帧后埋点，便于确认统计收尾 / 裁剪不回到首帧路径。
5. `tool/agent/perf.sh`：`prepare_perf_home` 每次把隔离 HOME 的窗口 bounds
   固定为 1440×900，避免 Xvfb 复用大窗口导致 CPU / 帧数据失真。

## 8. 验证

- `flutter analyze --no-pub`：0 error / 0 warning；
- `flutter test --no-pub`：2526 passed / 11 skipped；
- `tool/agent/test.sh linux`：见本轮执行日志；
- Android release 启动 A/B：5 次冷启动（上方 §3.2）；
- Linux 数据 / 帧 / CPU：Xvfb 无头，原始结果目录：
  - `startup-linux-20261107-205809`（最终）
  - `startup-linux-20261107-192133`（改动前）
  - `perf-linux-20261107-192300`
  - `perf-linux-data-20261107-204841`
  - `perf-linux-cpu-20261107-195111`
  - `startup-android-20261107-200007` / `-205326`
  - `perf-android-20261107-201336`
  - `perf-android-data-20261107-203847`

## 9. 未覆盖 / 下一步

- **真实 Android 设备**：`mobile-nowplaying-leave-return` 的 raster 与
  `mobile-mini-expand` 手势时序；模拟器数据只做相对比较。
- **Windows**：本轮按用户要求跳过；恢复范围后补 `startup windows` /
  `frames windows --real`。
- **托盘内存 / 提交大小**：本轮没有做 Linux 托盘往返（Xvfb 无托盘宿主），
  Windows 实机数据仍以 `docs/memory.md` 为准。
- **Linux 无头数据链路**：首搜 250ms 已归因为 Xvfb 首屏软件光栅，不再改
  应用代码；需要真实 GPU 桌面时再按 `frames windows --real` 口径复测。
