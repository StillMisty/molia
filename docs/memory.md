# 桌面托盘内存：背景、改动与测量

> 本文只记**可复现的数字**与**为什么这样改**。采样脚本：`tool/agent/memory.sh`
> （Linux：RSS 曲线 + 应用自己的 `molia.memory` 转换日志）、
> `tool/agent/memory.ps1`（Windows：专用工作集 / 提交大小）；
> 最近一次复测：Linux 2026-10-18，Windows 2026-10-19。

## 1. 结论（一行）

关闭到托盘不再把「界面侧」内存挂到重新打开窗口为止：托盘隐藏时清空 Flutter
图片缓存并把上限临时压低、停掉后台期无展示面的封面预取与取色，界面整棵卸载
（等价一次保留播放的冷启动）；清理后按平台补一次 trim（Linux `malloc_trim`、
Windows `EmptyWorkingSet`），让释放体现在系统观测上。实测：Linux 关到托盘
瞬间 RSS 下降 63–73 MB（98.9 MB 图片缓存场景）；Windows 播放中专用工作集
201.7 → 14.6 MB（0.3s），随后稳定在 107–122 MB（旧构建约 214 MB），暂停态
161.5 → 4.8 MB。mpv 解复用缓存上限从 64 MiB 降到 32 MiB。

## 2. 背景：托盘态本来在占什么

- 「关闭时最小化到托盘」= `WindowChrome.hide()`：只是 `window_manager.hide()`，
  没有任何内存释放路径；
- 窗口隐藏后平台停止出帧（Linux：GTK withdrawn → `AppLifecycleState.hidden` →
  `framesEnabled=false`），任何「等回到前台再重建」的清理都拿不到托盘期收益；
- 三块本可回收的内存：
  1. **Flutter 图片缓存**（默认 100 MiB / 1000 张）全仓没有清理入口；托盘听歌
     时还在持续解码：`PlaybackObserver` 每次切歌预取「当前 + 下一首 + 队列 5 首」
     封面，`ArtworkThemeSync` 每次切歌解一张全尺寸封面取色，直到缓存打满；
  2. **常驻页面**：播放 / 收藏 / 资料库三页在 `Offstage` 下仍挂载，页面
     RenderObject、图层与 live 图片引用全留着；
  3. **mpv 解复用缓存**：`just_audio_media_kit` 把 `bufferSize` 同时设给
     `demuxer-max-bytes` 与 `demuxer-max-back-bytes`，缺省 32 MiB → 上限 ~64 MiB。

## 3. 改了什么

| 位置 | 行为 |
| --- | --- |
| `lib/services/app_presence.dart` | 窗口三态（可见 / 最小化 / 托盘隐藏）；置位只在窗口层，消费者按状态各自应对 |
| `lib/managers/app_memory_manager.dart` | 托盘隐藏：等休眠帧落定后 `imageCache.clear()` + `clearLiveImages()` + 上限临时 16 MiB + 平台 trim（Linux `malloc_trim(0)` / Windows `EmptyWorkingSet`）；恢复还原；每次翻转打 `molia.memory`（RSS + 缓存占用） |
| `lib/managers/image_preload_manager.dart` | 后台期不排预取、清空待办；预取途中进入后台的条目立即 `evict` |
| `lib/services/playback_observer.dart` | 后台期跳过封面预取；恢复后等重建帧落定补一次 |
| `lib/services/artwork_palette_service.dart` | `ArtworkThemeSync` 后台期只记 URL 不取色；恢复后补一次且同 URL 不重复应用 |
| `lib/app/tray_dormant_gate.dart` | 托盘隐藏卸载整棵 `MaterialApp`（导航 / 常驻页面 / 弹层），恢复重建 |
| `lib/playback/desktop_audio_init_io.dart` | `JustAudioMediaKit.bufferSize = 16 MiB`（上限 64 → 32 MiB） |

**为什么还要平台 trim**：清空图片缓存只是把像素 `free` 回 allocator，空闲页
留在 arena / 工作集里不会自动归还内核，系统观测（RSS / 任务管理器）看不到
下降——Linux 实测「清 40 MB 缓存、RSS 反而 +10 MB」。所以守卫在清理后按平台
补一次 trim：Linux/glibc 用 `malloc_trim(0)`，Windows 用 `EmptyWorkingSet`
（`psapi.dll`，符号缺失 / 调用失败时静默跳过）。**trim 只改「内存」（工作集）
列，不改「提交大小」**：真正释放的仍是 `imageCache.clear()`；mpv 自带
allocator 与 Dart 堆不受它影响。

恢复语义：页面滚动位置 / 合集选择本就有持久化（`CollectionScrollBookkeeping` /
`LibraryCollections`），恢复后自然回位；页内瞬时状态（搜索词、展开的弹层、
设置页）不保留——整体等价一次「保留播放与托盘的冷启动」。**最小化不休眠、不清
缓存**（通常短暂且要跟手恢复），只停后台解码类工作。

mpv 缓冲的取舍：只影响**当前流播曲目**的内存缓冲（弱网抗抖动 / 回看重取），
16 MiB ≈ 320kbps 6.7 分钟、无损 ~2 分钟；下载与下一首预取是独立 HTTP 直写
磁盘，不受影响。缓存过的曲目按 `file://` 本地文件播放，缓存上限本来就被文件
大小封顶。

## 4. 测量

### 4.1 方法

Linux：

```bash
tool/agent/app.sh run -d linux          # 或 --window 在真实显示上跑（WSLg 弹窗）
tool/agent/memory.sh --interval 5       # 另一个终端采样 RSS
```

Windows：

```powershell
flutter run -d windows                  # 或启动 release 包；debug 控制台可见 molia.memory
powershell -ExecutionPolicy Bypass -File tool/agent/memory.ps1 -Interval 5
```

托盘隐藏 / 恢复时应用会打 `molia.memory`（RSS + 图片缓存占用），脚本会连同
RSS 曲线一起打印；结束给出 min / 中位 / max。Windows 上 release 包没有控制台，
以 `memory.ps1` 为准：`内存` = 专用工作集（`WorkingSetPrivate`），`提交` =
`PrivateBytes`。

### 4.2 基线（2026-10-18，改动前）

- 环境：WSL2 + Xvfb + 软件渲染（llvmpipe），mock 音源；软件渲染会明显放大
  RSS（gallium / LLVM / 大块匿名页都算进进程），绝对值只用于同环境前后对比，
  真机 GPU 会更低。
- 启动恢复会话后空闲：**~361 MB**；播放中（40 张 800×800 本地封面入缓存）：
  **~423 MB**。
- 关到托盘后不会有任何下降（`hide()` 路径无释放逻辑）。

### 4.3 改后（真实引擎往返，2026-10-18）

**空会话往返**（debug + Xvfb，VM service 驱动 `WindowChrome.hide()`/`show()`）：

```
托盘隐藏（等休眠帧）：RSS=680.2MB，imageCache=2.5MB/100MB
托盘隐藏完成：RSS=673.3MB，imageCache=0.0MB/16MB
窗口可见：RSS=674.1MB，imageCache=0.0MB/100MB
```

**压测往返**（同一进程，先把 40 张 800×800 本地封面显式灌进图片缓存，模拟
「浏览过大量封面后关到托盘」）：

```
托盘隐藏（等休眠帧）：RSS=825.8MB，imageCache=98.9MB/100MB
托盘隐藏完成：RSS=762.7MB，imageCache=0.0MB/16MB   # −63.1MB
（3 秒后进程 RSS 753.1MB，−72.7MB）
```

对照：加 `malloc_trim` 之前，同样清掉 40.3MB 缓存的实测是
`719.9MB → 729.9MB`（RSS 反升，空闲页留在 arena）——trim 是让释放体现在
系统观测上的关键一步。

同刻 VM service 断言：隐藏后 `AppPresence.value == trayHidden`、
`imageCache.currentSizeBytes == 0`、`maximumSizeBytes == 16 MiB`、
`framesEnabled == false`（休眠帧已在隐藏前抢到）；恢复后逐项还原，封面预取
补跑（缓存重新出现条目）。

- 数字是 debug + 软件渲染，绝对值不代表发布包；**差额**（本次 63–73MB）才是
  改动效果的量级——缓存越大差额越大（上限 100MB），恢复后按需重解。
- 托盘挂机 30 分钟的完整 RSS 曲线需在真实显示 + 托盘宿主下用 `memory.sh`
  采样（无头 Xvfb 既没有托盘宿主、也没有窗口管理器，触发不了原生关闭）。

### 4.4 Windows（实机，2026-10-19）

环境：Windows 11，2560×1440，release 构建（CI `windows-dev` 的 dev52，含本
改动）；数据为真实库副本（schema v5，收藏约 1019 首）。方法：对主窗口发
`WM_CLOSE` 走真实关闭策略，采样 `WorkingSetPrivate`（任务管理器「内存」）
与 `PrivateMemorySize64`（「提交大小」）。

**旧构建对照（beta.13，已含托盘卸载 / 清缓存，无 Windows trim）**

- 暂停态：显示时约 235–270 MB → 关闭到托盘后 **214 MB**，基本不降；
- 手动对同一进程调 `EmptyWorkingSet`：288.9 → **80.0 MB**（0.3s），10s 后
  154.4 MB，空闲稳定约 157 MB——trim 本身有效，缺的是自动调用。

**新构建（dev52，关闭到托盘瞬间）**

| 场景 | 关闭前 | +0.3s | 后续稳定值 |
| --- | --- | --- | --- |
| 暂停态（未播放过） | 161.5 MB | **4.8 MB** | 6.6 MB（39s） |
| 播放中（SMTC=Playing） | 201.7 MB | **14.6 MB** | 107–122 MB（4–60s） |

恢复窗口后专用工作集回到 ~175–189 MB，再次关闭仍会 trim（17.0 MB）；播放中
SMTC 始终为 `Playing`，音频未中断。一首播完后未再触发 trim，托盘暂停态约
104–105 MB。

- **提交大小不随 trim 降**：冷启动暂停约 370 MB；播放中 818–848 MB（关闭前
  837 MB）；播放过后暂停 763–792 MB。它是 Dart 堆 / 引擎 / libmpv 的已提交
  页，物理驻留看工作集；想压提交需要 Phase 3（释放 provider 浏览缓存）。
- 播放中关闭瞬间的 5–15 MB 会在几秒内回弹，是音频线程 / 解码器把需要的页
  触回来；107–122 MB 是本次播放场景的功能性工作集下限。
- 若要把「播完后暂停」的 ~105 MB 也压到个位数，可在「托盘 + 播放暂停」时
  再补一次 trim；当前未做，避免暂停 / 恢复瞬间的额外缺页。

复现：启动 release 包 → 播放（或暂停）→ 关闭到托盘 → 用 `memory.ps1`
采样。关闭瞬间的下降来自工作集 trim，与会话里缓存了多少封面无关；缓存量只
影响「提交大小」的降幅。

## 5. 验证

- `flutter analyze --no-pub`：0 error / 0 warning；
- `flutter test --no-pub`：全绿（新增 `test/services/audio_services_test.dart`、
  `test/managers/app_memory_manager_test.dart`、`test/app/app_wiring_test.dart`，
  以及 observer / ArtworkThemeSync 的后台门控用例）；
- `tool/agent/test.sh linux`：集成用例全绿（含窗口 chrome hide → show 往返）；
- 真实应用托盘往返：见 §4.3 的三行 `molia.memory` 与同刻断言；
- Windows 实机（2026-10-19）：CI `windows-dev` dev52（run `39273980119`）
  关闭到托盘往返，数据见 §4.4。

## 6. 未验证 / 已知代价

- **Windows** 已实机验证（§4.4）；`window_manager` 的隐藏事件与
  `AppLifecycleState.hidden` 语义在本次往返中正常。
- `EmptyWorkingSet` 只降工作集（物理驻留），「提交大小」不会跟着大降；播放中
  剩余的大头是引擎 / Dart 堆 / libmpv。若以提交为准继续优化，需要 Phase 3
  （托盘期释放 provider 浏览缓存，恢复时重拉）。
- 真实托盘宿主（KDE / GNOME + AppIndicator 扩展）下的隐藏 / 唤起观感：关闭
  到托盘前会多渲染一帧休眠占位（窗口随即隐藏，肉眼基本不可见）；恢复时窗口
  映射与界面重建同帧完成。
- 恢复后列表首次滚到未缓存区可能短暂出现占位（图片从磁盘缓存重解）；当前
  曲目封面由恢复后的补发预取提前解好。
- `tool/agent/memory.sh` 只支持桌面 Linux（Android 不在范围）；Windows 用
  `tool/agent/memory.ps1`。
