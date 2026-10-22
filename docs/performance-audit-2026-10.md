# 全链路性能体检（2026-10-22）

> 目标：在同一个可复现口径下拿到启动、帧、交互、内存与体积的基线，按数据排序
> 再修，不重复已否证的方向（见 `docs/performance.md`、`docs/memory.md`）。
>
> 采样环境：WSL2 Linux（Arch，20 vCPU）+ 本机 Windows 11（i5-13600K /
> RTX 4060 Ti / 2560×1440，150% 缩放）+ Android 模拟器 `molia_api37`
> （x86_64，headless，软件渲染）。Windows 是桌面运行时主口径；Android 只做
> 相对比较。

## 1. 结论（先看这里）

- 启动没有回归：Linux release 首帧中位 **191ms**（`docs/performance.md`
  基线 207ms），Windows 应用内首帧中位 **298ms**、进程起→窗口可见
  **1386ms**，与 2026-10-21 的 318–338ms / 1.36–1.45s 同一量级。
- Windows 真实窗口滚动（收藏 1000+ 首，多轮）：帧总时长 p50 **2.6–2.9ms**、
  p95 **4.1–4.7ms**、p99 **20.5–24.6ms**；稳定轮次没有 >33ms 的帧，
  最差 **25–28ms**。不是大面积卡顿，但 p99 的 20ms+ 单帧尖刺仍值得归因。
- 图片缓存是滚动里最明显的资源项：不同轮次从 **9MB 到 78MB**，取决于
  播放页预取与滚动经过的封面量；队列 5 首已改为 44dp 缩略预取，但缓存
  仍到 71–78MB，说明大头在当前 / 邻位大封面、取色或其它显示面。
- 内存仍是 `docs/memory.md` 的形状：Windows 托盘暂停态专用工作集
  **8.2MB**，托盘播放态约 **99MB**；提交大小 **352–456MB**。
- Android 模拟器首帧 **1009ms**（中位），其中 `sub.mediaSession.activate`
  **589ms**——落在文档已说明的「首个平台通道约 400ms + 模拟器抖动」上，
  不作为真机回归结论；需要真机复测。帧侧 build p95 最高 **5.47ms**
  （收藏滚动），没有 total >33ms 的帧，但 raster 在 `flutter drive` 下不可用。

## 2. 测量方法

### 2.1 启动

```bash
tool/agent/startup.sh --runs 5                 # Linux release 冷启动
tool/agent/perf.sh startup android             # Android 模拟器 release
tool/agent/perf.sh startup windows             # Windows release（本机）
```

Windows 由 `tool/agent/startup_windows.ps1` 完成：结束旧进程 →
`Start-Process -RedirectStandardOutput` → 轮询 `MainWindowHandle` 得到
「进程起 → 窗口可见」→ 从 `molia.startup: 首帧：Nms` 取应用内首帧。
每轮独立进程；中位数对 Defender / 文件系统热缓存不敏感。

### 2.2 帧

新增 opt-in 埋点 `lib/app/perf/frame_stats.dart`：

- 构建期 `--dart-define=MOLIA_PERF_TRACE=true` 才注册
  `SchedulerBinding.addTimingsCallback`；正常包零开销；
- 每 5s 输出一行 `molia.frame`（p50/p95/p99 build / raster / total、
  >16.7ms / >33.3ms 帧数、最差帧、图片缓存 MB）；
- `MOLIA_PERF_OUT` 可追加 JSONL，供 Windows 这种控制台不易抓取的场景。

两种跑法：

```bash
tool/agent/perf.sh frames linux                 # profile integration_test，build 可信
tool/agent/perf.sh frames android               # 同上，模拟器
tool/agent/perf.sh frames windows               # profile integration_test，raster 为 0
tool/agent/perf.sh frames windows --real        # release 真实窗口 + 滚轮，raster 可信
```

**重要口径**：`flutter drive` 的 integration_test 在桌面上拿不到
`rasterDuration`（恒 0），只能看 build；真实窗口的 release 包才有 raster
与用户可感总时长。Windows 结论一律取 `--real`。

滚动场景是「默认首页 = 收藏」+ 鼠标滚轮 40 步；截图
`frames-pre-scroll.png` / `frames-post-scroll.png` 用于确认滚的是收藏列表。
脚本启动前会把 `favorites_scroll_offsets` 清零（否则第二轮从上次底部开始，
帧数据不可比）；跑之前先备份 `shared_preferences.json`。

### 2.3 内存

```bash
tool/agent/memory.sh --interval 2 --timeout 120          # Linux
tool/agent/perf.sh memory windows                        # 本机场景
```

Windows 场景：启动 → 空闲 → 滚轮浏览 → 媒体键播放 / 暂停 → 关闭到托盘 →
单实例唤起；采样 `WorkingSetPrivate`（任务管理器「内存」）与
`PrivateMemorySize64`（「提交大小」）。

Windows 构建前提：Flutter 3.47.7 Windows zip + VS BuildTools 2022（Windows
10/11 SDK、ATL）、系统 Developer Mode；构建目录在 C: 上（不要用
`\\wsl$` UNC 路径），脚本默认 `C:\Users\Still\molia-perf`，可用
`MOLIA_WIN_PROJECT` / `MOLIA_WIN_FLUTTER` 覆盖。首次构建由
`media_kit_libs_windows_audio` 下载 mpv 压缩包；受限网络下手动放入
`build\windows\x64\mpv-dev-x86_64-20230924-git-652a1dd.7z` 并核对
MD5 `cd738e16e2a19626d7cfa48801524f8c`。

### 2.4 体积

```bash
tool/agent/perf.sh size android
tool/agent/perf.sh size linux
```

Windows 直接量 `build\windows\x64\runner\Release` 目录。

## 3. 基线

### 3.1 启动

| 口径 | 中位 | 最小–最大 |
| --- | ---: | ---: |
| Linux release 首帧 | 191ms | 188–353ms |
| Windows 应用内首帧 | 298ms | 287–305ms |
| Windows 进程起→窗口可见 | 1386ms | 1381–1424ms |
| Android 模拟器应用首帧 | 1009ms | 611–1115ms |
| Android 模拟器 `Activity TotalTime` | 2914ms | 1658–4061ms |

Android 这轮与 Windows 构建 / Gradle 同时跑，宿主负载偏高；
`sub.mediaSession.activate` 占 589ms，是首个平台通道而非 Dart 侧逻辑。

### 3.2 Windows 真实窗口帧（release）

收藏列表 1000+ 首，滚轮 40 步 × 6s：

| 窗口 | frames | build p95 | raster p95 | total p95 | total p99 | >33ms | 最差 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 启动 + 空闲 | 167 | 0.74 | 3.70 | 12.10 | 32.47 | 1 | 38.2ms |
| 滚动（主体） | 621 | 1.17 | 1.62 | 4.18 | 20.46 | 0 | 26.4ms |
| 滚动（收尾） | 482 | 1.18 | 1.55 | 4.16 | 21.69 | 0 | 27.8ms |

多轮滚动主体 p95 稳定在 4.1–4.7ms、p99 20.5–24.6ms；热身不足的冷缓存
首轮曾出现 >33ms 帧，稳定轮次不再复现。滚动时图片缓存从 **2.5MB 涨到
71–78MB**（这一轮从列表顶部开始、封面加载完整；从底部开始的短轮次只有
9MB 左右），基本落在默认 100MB 上限内。`frames-post-scroll.png` 里仍可见
少量灰色占位，说明新进入视口的封面还在异步取图。p99 的 20ms+ 单帧需要用
DevTools timeline 抓一次，确认是解码、布局还是 GC。

### 3.2.1 integration_test（build 可信，raster 不可用）

| 平台 / 场景 | frames | build p50 | build p95 | build p99 | total p95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Linux 收藏滚动 | 88 | 1.37 | 2.14 | 2.31 | 4.36 |
| Linux 切资料库 | 48 | 0.63 | 2.07 | 5.70 | 3.27 |
| Linux 连续切歌 | 137 | 0.50 | 0.98 | 5.78 | 2.01 |
| Android 收藏滚动 | 84 | 1.52 | 5.47 | 9.94 | 6.35 |
| Android 切资料库 | 42 | 0.84 | 3.46 | 4.06 | 4.44 |
| Android 连续切歌 | 133 | 0.71 | 3.14 | 7.83 | 5.14 |

两端的 `raster` 在 `flutter drive` 下都恒为 0，不能用这组数据判断光栅
耗时；Android 是模拟器软件渲染，绝对值仍只做相对比较。

### 3.3 已落地的低风险修复：图片解码尺寸

`AppNetworkImage` 的两条路径之前没有统一的缩略解码口径：

- `file://` 本地封面（下载封面）直接 `Image(FileImage)`，完全绕过
  `memCacheWidth`，44px 行也会按原图解码；
- 远端封面只有调用方显式传 `memCacheWidth` 才缩放；96px 专辑 / 歌手头图、
  评论区头像等没有传，按原图解码。

现改为：本地封面包 `ResizeImage.resizeIfNeeded`；远端封面在调用方没给
尺寸时按 `width/height × devicePixelRatio` 兜底。单测
`test/widgets/app_network_image_test.dart` 覆盖两条路径。

这不会改变显示内容，收益主要在解码 CPU 与图片内存；Windows 同口径复测
（多轮）没有帧回退：p95 4.1–4.7ms、p99 20.5–24.6ms、稳定轮次无 >33ms 帧。
它不是本轮 p99 单帧尖刺的主因；队列预取也改成 44dp 缩略后，图片缓存仍在
71–78MB，说明大头在当前 / 邻位大封面、取色或其它显示面，见问题清单 #2。

### 3.4 内存（Windows，本机实测）

| 状态 | 专用工作集 | 提交 |
| --- | ---: | ---: |
| 启动空闲 | 192MB | 380MB |
| 浏览收藏（滚轮后） | 162MB | 356MB |
| 媒体键后（播放态待复核） | 202MB | 392MB |
| 关闭到托盘（播放中） | **99MB** | 352MB |
| 单实例唤起 | 175MB | 456MB |

另一次暂停态托盘往返：**8.2MB** / 400MB（`molia.memory` 记录
`RSS=0.3MB, imageCache=0.0MB/16MB`），与 `docs/memory.md` 的 4.8–6.6MB
量级一致。提交大小不随托盘 trim 下降，仍是引擎 / Dart 堆 / libmpv。

### 3.5 体积

| 产物 | 大小 |
| --- | ---: |
| Android `app-arm64-v8a-release.apk` | 15.4MB |
| Android `app-armeabi-v7a-release.apk` | 15.1MB |
| Android `app-x86_64-release.apk` | 15.7MB |
| Windows `Release` 目录 | 58MB（其中 `data/` 18MB） |
| Linux release bundle | 40MB |

## 4. 问题清单（按证据排序）

1. **Windows 滚动 p99 单帧尖刺**：p95 4.1–4.7ms，但 p99 20.5–24.6ms、
   最差 25–28ms；冷缓存首轮曾出现 >33ms 帧，热身后消失。滚动后新行有
   灰色封面占位，优先怀疑封面取图 / 解码 / 缩略图尺寸；下一步用 DevTools
   timeline 抓最差帧。`AppNetworkImage` 的本地 `file://` 分支与 96px 头图
   尺寸已在本轮修复并有单测，但还缺真实下载封面的 A/B。
2. **封面预取尺寸**：`ImagePreloadManager` 的队列 5 首已改为 44dp 缩略
   预取（本轮修复），但实测滚动时图片缓存仍到 **71–78MB**，说明大头不在
   队列预取，而在当前 / 邻位大封面、取色或其它显示面；继续压需要逐个
   确认缓存键与展示面，避免把播放页大图降质。
3. **Android 模拟器首帧高**：首个平台通道 + 宿主负载；不是 Dart 侧回归。
   真机复测前不修。
4. **提交大小高于工作集**：托盘 trim 只降工作集，符合 `docs/memory.md`
   的已知结论；要不要做 Phase 3 取决于后续内存预算，不在本轮先动。

## 5. 未覆盖 / 下一步

- Windows 最差帧的 DevTools timeline 归因（p99 20.5–24.6ms 的单帧）；
- 本地下载封面的真实数据 A/B（`ResizeImage` 路径已有单测）；
- 数据路径（搜索 / 取链 / 取词 / DB 写入）本轮只复用了启动与同步既有埋点，
  没有做独立的端到端时延矩阵；
- 修完 Top 1–2 后，用同一组 `perf.sh` 命令复测并回填本表；
- 真机 Android / iOS 仍需设备侧采样（模拟器的首个平台通道等待会掩盖
  Dart 侧收益）。
