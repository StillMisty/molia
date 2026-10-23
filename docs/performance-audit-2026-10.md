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
- Windows 真实窗口滚动（收藏 1000+ 首，多轮）：按 `work = build + raster`
  统计，p95 **2.5–2.6ms**、p99 **3.0–3.7ms**，**jank16/33 均为 0**；
  `totalSpan` 的 p99 **20.9–23.4ms** 是 vsync / 流水线延迟（约 1% 帧），
  不是掉帧。滚动本身没有需要继续压的 UI 工作量。
- 图片缓存是滚动里最明显的资源项：不同轮次从 **9MB 到 78MB**，取决于
  播放页预取与滚动经过的封面量。2026-10-23 的 §3.3.1 已把播放链路改为
  有界解码 + 取色 100px，同 fixture 连切 12 首从 91.6MB 降到 16.7MB。
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

**掉帧判定看 `work = build + raster`**：`totalSpan` 还包含 vsync 等待和
流水线延迟，60Hz 下正常帧也可能到 20ms；本报告把 `total > 16.7ms` 单列为
`latency16`，不叫 jank。需要归因时用：

```bash
# Windows 侧
flutter run --profile -d windows --trace-to-file=C:\Users\Still\molia-perf\perf-scroll.binpb
# 另一个终端跑滚轮（脚本只驱动，不启动/退出应用）
powershell -File tool/agent/scroll_windows.ps1 -Steps 80
```

结束后停掉应用，Perfetto trace 里按 `work` 找长切片；本轮实测见 §3.2.1。

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

收藏列表 1000+ 首，滚轮 40 步 × 6s。`work = build + raster` 才是掉帧口径；
`totalSpan` 包含 vsync 等待与流水线延迟：

| 窗口 | frames | work p95 | work p99 | total p95 | total p99 | jank16/33 | latency16 | 最差 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 启动 + 空闲 | 171 | 2.96 | 12.28 | 7.86 | 18.16 | 1 / 0 | 2 | 20.4ms |
| 滚动（主体） | 585 | 2.59 | 3.66 | 4.12 | 23.42 | 0 / 0 | 8 | 26.6ms |
| 滚动（收尾） | 486 | 2.50 | 3.04 | 4.11 | 20.90 | 0 / 0 | 5 | 29.6ms |

多轮滚动主体 work p95 稳定在 2.5–2.6ms、p99 3.0–3.7ms，**没有一帧
work >16.7ms**；`totalSpan` 的 20ms+ 是帧请求到呈现的延迟（约 1% 帧），
不影响动画连续性。滚动时图片缓存从 **2.5MB 涨到 9–78MB**（取决于启动后
播放页预取是否已经灌满缓存、以及滚动经过多少新封面），基本落在默认
100MB 上限内；`frames-post-scroll.png` 里仍可见少量灰色占位。

### 3.2.1 帧时间线归因（Windows profile trace）

用 `flutter run --profile -d windows --trace-to-file=...` 抓同一场景，
解析 Perfetto trace 后：

- **启动阶段（0.04–1.3s）** 的大头是 `impeller::LinkProgram`
  **52–68ms**（着色器编译，一次性）和 `ImageCache.putIfAbsent`
  **72–99ms**；对应首帧 / 首屏封面，不是滚动问题。
- **滚动阶段（5s 之后）** 没有 >5ms 的 Dart / Embedder 应用切片；
  最大的是 GC `ConcurrentMark` **9–14ms** 和 `Frame Request Pending`
  **6–9ms**，`GPURasterizer::Draw` 只有 **1.3–1.6ms**。
- 因此 `totalSpan` 的 p99 是**等待 vsync / 流水线**的延迟，不是
  build/raster 卡顿；继续压缩 UI 构建不会改善这个 p99。

### 3.2.2 integration_test（build 可信，raster 不可用）

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
（多轮）没有帧回退：work p95 2.5–2.6ms、p99 3.0–3.7ms、jank 0。

### 3.3.1 播放封面有界解码（2026-10-23）

§3.3 只统一了列表缩略图路径；播放链路本身仍按封面源尺寸解码：顶栏 /
迷你条 / 播放页三封面 / 飞行副本 / 当前+邻位预取为了共享元素飞行同步出帧，
共用同一个无缩放 `CachedNetworkImageProvider` 键，这个键之前没有
`memCacheWidth`。一张 2000×2000 封面因此按原图占 15MB，三张邻位封面就
超过 45MB。

确定性探针（2000×2000 本地 JPEG，`ImageCache.currentSizeBytes` 增量）：

| 解码边长 | 单张缓存 |
| --- | ---: |
| 原图 2000px | 15.26MB |
| 900px | 3.09MB |
| 100px | 0.04MB |

修复：

- 新增 `lib/utils/playback_cover_decode.dart::playbackCoverDecodeEdge`：取
  屏幕短边与 600 逻辑像素的较小值 × DPR。顶栏、迷你条、播放页三封面、
  飞行副本、当前/邻位预取全部使用同一个值，继续共享同一个 ImageCache 键，
  共享元素飞行不会因缓存键不同重新解码；
- 600 是播放器大屏列宽上限，布局代码与解码共用同一个常量。三封面堆叠里
  中心封面只占可用宽的 1/1.5（两侧留给邻位），桌面 1440 宽窗口实际封面
  约 368 逻辑像素，解码 600 仍是约 1.5 倍采样；高 DPI 再乘 DPR，因此不会
  低于显示分辨率，观感与按原图绘制一致；
- `ArtworkPaletteService` 稳态取色改走 100px 缩略解码（启动预解析原本就是），
  不再把原图留在共享图片缓存里；
- `ImagePreloadManager` 的 LRU / 去重键改成 `(url, memCacheWidth)`：44dp
  队列缩略图与播放页大图是两条 ImageCache 条目，只按 URL 去重会让后到的
  一方拿不到预取。

A/B（Xvfb 1440×900 / DPR 1 → 解码 600px；10 张 2000×2000 本地封面，
恢复会话后连续切 12 首，`molia.frame` 的 `image_cache_mb`）：

| 版本 | 首段 | 中段 | 收尾 |
| --- | ---: | ---: | ---: |
| 改前 | 33.1MB | 78.9MB | **91.6MB**（接近 100MB 上限） |
| 改后 | 5.3MB | 11.0MB | **16.7MB** |

Xvfb 软件光栅的帧耗时不用于结论，只对比图片缓存。Windows 150% 缩放下
解码边长为 900px（单张 3.09MB），量级相同；未改变任何展示尺寸或图片内容。

### 3.3.2 数据路径第一批（2026-10-23）

§5 指出搜索 / 取链 / 取词 / DB 写入还没有独立时延矩阵。本轮先收敛其中
**可确定复现的高频重载**，不宣称绝对时延收益：

- **下载进度**：`DownloadService` 的 UI 通知从「每累计 32KB」改为「每任务
  100ms 一次」；首个进度与 100% / 完成 / 失败 / 取消仍无条件送达，系统
  通知仍逐分块上报。`TrackInfoView` 对下载通知加 300ms 防抖 + 单飞，缓存
  目录扫描从「每 32KB 一次」降为「每次落定一次」。
- **播放快照**：`LocalPlaybackBackend` 每次快照只求一次 `queueProjection`，
  队列 `Track` 映射按 `queueRevision` 复用；位置 tick 不再重建整队列。
- **失败恢复**：播放失败只失效当前曲目的取链缓存，不再清空同音源全部
  URL，避免一次过期让后续曲目全部重新取链。
- **资料库**：`LibraryChange.history/favorites` 增加单条增量载荷，provider
  对播放历史 / 收藏切换做内存 patch；测试钉住单条历史写入不再调用
  `listHistory()`，单曲收藏不再调用 `favoriteKeys()` /
  `listPlaylistTracks()` / `listPlaylists()`。批量、同步、导入等无载荷变化
  仍走整表校准。
- **统计页**：仓库变更 1s 防抖 + 单飞；同一轮收尾连续广播的多条变更合并成
  一次 6 条聚合查询，不再逐条重跑。
- 新增 opt-in 的 `molia.perf` 数据路径埋点（复用
  `--dart-define=MOLIA_PERF_TRACE=true`）；关闭时没有 Stopwatch / 日志开销。

验证：`flutter analyze --no-pub` 无问题；`flutter test --no-pub` 全量通过。
查询次数由测试断言钉住；绝对耗时待同口径 release 采样后补充。

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

1. **滚动没有掉帧，只有呈现延迟**：work p95 2.5–2.6ms、p99 3.0–3.7ms、
   jank 0；`totalSpan` p99 20.9–23.4ms 来自 vsync / 流水线等待，
   时间线里没有 >5ms 的应用切片。除非要压「触摸到呈现」的延迟，
   否则不需要继续优化列表构建。
2. **启动阶段的一次性着色器 / 封面解码**：`impeller::LinkProgram`
   52–68ms、`ImageCache.putIfAbsent` 72–99ms，集中在前 1.3s；这是首帧
   之后的正常成本，若要再压需要缓存 shader / 缩略预取，收益只影响首屏。
3. **图片缓存波动（已修，§3.3.1）**：滚动后图片缓存 **9–78MB**，受播放页
   预取 / 取色 / 当前与邻位大封面影响；播放链路统一有界解码后，同 fixture
   连切 12 首从 **91.6MB 降到 16.7MB**。剩余增长是 ImageCache 在 100MB
   上限内保留的历史曲目封面，不再按展示面逐个排查。
4. **Android 模拟器首帧高**：首个平台通道 + 宿主负载；不是 Dart 侧回归。
   真机复测前不修。
5. **提交大小高于工作集**：托盘 trim 只降工作集，符合 `docs/memory.md`
   的已知结论；要不要做 Phase 3 取决于后续内存预算，不在本轮先动。

## 5. 未覆盖 / 下一步

- 图片缓存波动已由 §3.3.1 收口：播放链路统一 600 逻辑像素上限 × DPR 解码，
  取色只留 100px 采样图；同 fixture 从 91.6MB 降到 16.7MB；
- 本地下载封面的真实数据 A/B（`ResizeImage` 路径已有单测）；
- 数据路径的高频重载已由 §3.3.2 收口（下载进度 / 本地数据扫描 / 播放快照 /
  失败取链 / 历史与收藏 / 统计页）；搜索、取链、取词、DB 写入的端到端时延
  矩阵仍未做，下一步用 `molia.perf` 埋点补同口径 release 数据；
- 歌词缓存仍在 SharedPreferences（写入会整文件重写、占用统计要重新
  `utf8.encode`），缓存管理页的目录扫描也仍在 UI isolate；
- `.lxmc` 导入的 gzip / JSON 解码、AI DJ 的串行取源仍会阻塞或拉长等待；
- 若目标是降低「触摸到呈现」的延迟，再评估 shader 缓存 / 帧调度；
- 真机 Android / iOS 仍需设备侧采样（模拟器的首个平台通道等待会掩盖
  Dart 侧收益）。
