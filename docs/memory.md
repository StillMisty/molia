# 桌面托盘内存：背景、改动与测量

> 本文只记**可复现的数字**与**为什么这样改**。采样脚本：`tool/agent/memory.sh`
> （RSS 曲线 + 应用自己的 `molia.memory` 转换日志）；最近一次复测：2026-10-18。

## 1. 结论（一行）

关闭到托盘不再把「界面侧」内存挂到重新打开窗口为止：托盘隐藏时清空 Flutter
图片缓存并把上限临时压低、停掉后台期无展示面的封面预取与取色，界面整棵卸载
（等价一次保留播放的冷启动）；mpv 解复用缓存上限从 64 MiB 降到 32 MiB。

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
| `lib/managers/app_memory_manager.dart` | 托盘隐藏：等休眠帧落定后 `imageCache.clear()` + `clearLiveImages()` + 上限临时 16 MiB；恢复还原；每次翻转打 `molia.memory`（RSS + 缓存占用） |
| `lib/managers/image_preload_manager.dart` | 后台期不排预取、清空待办；预取途中进入后台的条目立即 `evict` |
| `lib/services/playback_observer.dart` | 后台期跳过封面预取；恢复后等重建帧落定补一次 |
| `lib/services/artwork_palette_service.dart` | `ArtworkThemeSync` 后台期只记 URL 不取色；恢复后补一次且同 URL 不重复应用 |
| `lib/app/tray_dormant_gate.dart` | 托盘隐藏卸载整棵 `MaterialApp`（导航 / 常驻页面 / 弹层），恢复重建 |
| `lib/playback/desktop_audio_init_io.dart` | `JustAudioMediaKit.bufferSize = 16 MiB`（上限 64 → 32 MiB） |

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

```bash
tool/agent/app.sh run -d linux          # 或 --window 在真实显示上跑（WSLg 弹窗）
tool/agent/memory.sh --interval 5       # 另一个终端采样 RSS
```

托盘隐藏 / 恢复时应用会打 `molia.memory`（RSS + 图片缓存占用），脚本会连同
RSS 曲线一起打印；结束给出 min / 中位 / max。

### 4.2 基线（2026-10-18，改动前）

- 环境：WSL2 + Xvfb + 软件渲染（llvmpipe），mock 音源；软件渲染会明显放大
  RSS（gallium / LLVM / 大块匿名页都算进进程），绝对值只用于同环境前后对比，
  真机 GPU 会更低。
- 启动恢复会话后空闲：**~361 MB**；播放中（40 张 800×800 本地封面入缓存）：
  **~423 MB**。
- 关到托盘后不会有任何下降（`hide()` 路径无释放逻辑）。

### 4.3 改后（真实引擎往返，2026-10-18）

debug 应用 + Xvfb，经 VM service 直接调用 `WindowChrome.hide()` / `show()` 驱动
托盘往返（无 WM 的 Xvfb 里点原生关闭走的是窗口销毁，触发不到托盘路径），
`molia.memory` 三行：

```
托盘隐藏（等休眠帧）：RSS=680.2MB，imageCache=2.5MB/100MB
托盘隐藏完成：RSS=673.3MB，imageCache=0.0MB/16MB
窗口可见：RSS=674.1MB，imageCache=0.0MB/100MB
```

同刻在 VM service 断言：隐藏后 `AppPresence.value == trayHidden`、
`imageCache.currentSizeBytes == 0`、`maximumSizeBytes == 16 MiB`、
`framesEnabled == false`（休眠帧已在隐藏前抢到）；恢复后逐项还原，封面预取
补跑（缓存重新出现条目）。

- 数字是 debug + 软件渲染，绝对值不代表发布包（只用于「释放发生了」的证据）；
  2.5 MB 的缓存差是本次会话没有浏览封面——正常浏览后会大得多（托盘听歌时
  每首歌的预取都曾进这块缓存）。
- 托盘挂机 30 分钟的完整 RSS 曲线需在真实显示 + 托盘宿主下用 `memory.sh`
  采样（无头 Xvfb 既没有托盘宿主、也没有窗口管理器，触发不了原生关闭）。

## 5. 验证

- `flutter analyze --no-pub`：0 error / 0 warning；
- `flutter test --no-pub`：全绿（新增 `test/services/app_presence_test.dart`、
  `test/managers/app_memory_manager_test.dart`、`test/app/tray_dormant_gate_test.dart`，
  以及 observer / ArtworkThemeSync 的后台门控用例）；
- `tool/agent/test.sh linux`：集成用例全绿（含窗口 chrome hide → show 往返）；
- 真实应用托盘往返：见 §4.3 的三行 `molia.memory` 与同刻断言。

## 6. 未验证 / 已知代价

- **Windows** 未实机验证（本机只有 Linux 产物）；`window_manager` 的最小化 /
  隐藏事件与 `AppLifecycleState.hidden` 语义相同，但需要真机复核。
- 真实托盘宿主（KDE / GNOME + AppIndicator 扩展）下的隐藏 / 唤起观感：关闭
  到托盘前会多渲染一帧休眠占位（窗口随即隐藏，肉眼基本不可见）；恢复时窗口
  映射与界面重建同帧完成。
- 恢复后列表首次滚到未缓存区可能短暂出现占位（图片从磁盘缓存重解）；当前
  曲目封面由恢复后的补发预取提前解好。
- `tool/agent/memory.sh` 只支持桌面 Linux（Android 不在范围）。
