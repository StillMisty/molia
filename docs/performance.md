# 启动耗时：基线、测量方法与已做的优化

> 本文只记**可复现的数字**与**为什么这样改**。改动前的每一步都用同一脚本在同一台机器
> 上采样（release / 冷启动 / 5 次取中位），「首帧」那行即用户可感总时长
> （`main.dart` 的 `molia.startup` 埋点，release 也输出）。
>
> 采样脚本：`tool/agent/startup.sh`（见 §3）。最近一次全表复测：2026-10-18（Linux）；
> Windows 基线：2026-10-21（§4.1）。

---

## 1. 结论（一行）

桌面 release 冷启动「首帧」中位数 **293ms → 207ms（−29%）**，全部改动对用户
可见行为无影响：装配期串行等待改并行、同步/更新两个可选子系统初始化后移到首帧之后。
Windows 干净启动应用内首帧 **318–338ms**、墙钟进程起→窗口可见
**1.36–1.45s**，其中约 1.0–1.1s 是引擎 / 进程 / DLL 固定成本；强杀或更新后
残留的陈旧单实例锁曾额外等待 **~2.1s**（首帧 2.66s → 0.32s），已改为 OS 级
pid 存活判定（§5.6）。

改完后剩下的 **~207ms 里有 ~190ms 是进程外的固定成本**：
GTK 建窗 ~46ms + libmpv `dlopen` ~39ms + 引擎与首帧渲染 ~100ms；我们自己 Dart 侧
的装配只剩 ~20ms。

## 2. 测量方法

- **只用 release 产物**：debug 的首帧含 JIT / 断言开销，历史 debug 数据在 1.5–2.4s，
  完全不能代表用户可感时长（release 是它的 1/7）。
- **冷启动、逐次新进程**：每轮 `TERM` 掉上一轮进程，跑 5 次取中位数（抖动 ±5ms）。
- **无头显示**：`xvfb-run -a` + `env -u WAYLAND_DISPLAY GDK_BACKEND=x11`（只改
  `DISPLAY` 不够：GDK 见到 `WAYLAND_DISPLAY` 会优先连真实合成器）。
- **测量机器**：本机 WSL2（Arch，20 vCPU / 23GB），Flutter 3.47.7 / Dart 3.13.5。
- **Windows 说明**：本机是 WSL2，没有 Windows 侧 Flutter SDK；Windows 数字用 CI
  `windows-dev` 的 release 产物，在 Windows 上从 `molia.exe` 重定向 stdout 抓
  `molia.startup`，并用 `MainWindowHandle` 轮询「进程起 → 窗口可见」的墙钟。
  引擎 / DLL 加载是 Windows 的固定成本，不能拿 Linux 的 207ms 代替。

## 3. 复测方法

```bash
tool/agent/startup.sh                 # Linux 桌面：构建 release 后采样 5 次，打印中位数
tool/agent/startup.sh android         # Android：默认取运行中的模拟器（先 tool/agent/emu.sh start）
tool/agent/startup.sh --runs 9        # 采样 9 次
tool/agent/startup.sh --no-build      # 复用已有产物（只重测）
tool/agent/startup.sh --window        # Linux：在真实显示上跑（WSLg 会弹窗）
```

- 结果落在 `/tmp/opencode/molia/startup-<平台>-<时间戳>/`：每轮原始日志 `run-N.log`
  + `summary.txt`（各阶段中位 / 最小 / 最大 / 原始样本）。
- Android 模式会构建 release APK 并按设备 ABI 安装（`am start -W -S` 冷启动 + logcat
  抓埋点）；汇总表里多一行 `Activity TotalTime`——那是 `am -W` 的系统口径（进程起到首帧
  绘制），与应用自己的「首帧」不是同一把尺。
- 脚本只删 `build/linux/x64/release/bundle`（install 产物），保留中间产物做增量构建。
  **不要** `rm -rf build/linux/x64/release`：那会连带删掉 media_kit_libs_linux
  下载的 `mimalloc-2.1.2.tar.gz`，而它的下载在受限网络下会失败（CMake 只报
  "Integrity check failed"，实际是 0 字节文件）。真遇到时手动放一份 MD5 为
  `5179c8f5cf1237d2300e2d8559a7bc55` 的 tarball 到该目录即可。

## 4. 结果（中位数，ms）

| 阶段 | 基线 | 依赖升级后 | 并行化 + 后移后 | 撤掉预热实验后（现状） |
| --- | ---: | ---: | ---: | ---: |
| 窗口就绪 | 54 | 54 | 49 | **46** |
| 本地数据/资料库栈 | 124 | 123 | 100 | **98** |
| 播放栈（含媒体会话） | 134 | 132 | 109 | **107** |
| 主题/歌词显示 | 136 | 135 | 111 | **109** |
| 同步栈 | 174 | 173 | 111 | **109** |
| 更新栈（装配完成） | 189 | 187 | 111 | **109** |
| **首帧** | **293** | **288** | **211** | **207** |

- 「基线」= 依赖升级前（`chore(deps)` 提交之前）。
- 「依赖升级后」= `flutter pub upgrade`（17 包）+ Flutter 3.47.7：与基线之差在噪声内，
  **依赖升级没有带来启动回归**。
- 最后两列之差是 §5.4 的否证实验（撤掉后回到 207ms）。

### 4.1 Windows（2026-10-21）

| 场景 | 构建 | 应用内首帧 | 墙钟（进程起 → 窗口可见） |
| --- | --- | ---: | ---: |
| 干净启动（无陈旧锁） | beta.14（改前） | 327ms（窗口就绪 163ms） | 1392ms |
| 强杀后启动（陈旧锁） | beta.14（改前） | 2662ms（窗口就绪 2445ms） | — |
| 干净启动（无陈旧锁） | dev54（改后） | 338ms（窗口就绪 170ms） | 1445ms |
| 强杀后启动（陈旧锁） | dev54（改后） | **318ms**（窗口就绪 161ms） | **1363ms** |

- dev54 分段：窗口就绪 161–170ms → 本地数据/资料库 171–188ms → 播放栈
  185–205ms → 主题/歌词显示 300–321ms → 首帧 318–338ms；`sub.hotkeys.attach`
  2ms、`sub.desktop.build` 0ms、`sub.lyricsDisplay.build` 114–116ms；
- 应用内首帧与墙钟的差 ≈ **1.0–1.1s**，是进程启动、Flutter 引擎 / Impeller、
  插件 DLL（含 ~30MB libmpv）加载的固定成本；干净启动的 327→338ms 在噪声内；
- 强杀 / 更新器终止应用会在 `single_instance.lock` 留下已退出进程的 pid，旧逻辑
  仍去连它的 loopback 端口，等满 2s 超时 + 300ms 重抢才继续，额外 **~2.1s**；
  §5.6 的 OS 存活判定修掉这段（dev54 日志「锁进程 … 已退出，立即重抢」）。

## 5. 逐项：改了什么、实测多少

### 5.1 装配期等待改并行（≈ −28ms）

- 窗口前缀三项互不依赖 → `(WindowSettings.load, SystemFontsService.loadPlatformDefaultFamily,
  SingleInstance.acquire).wait`：实测这三项自身合计 ≈0ms（Windows 上字体读注册表，
  仍是毫秒级），并行后完全被后面的建窗遮住。（2026-10 字体口径再修正：Windows
  默认字体恢复为读取 `MessageFont` 的系统 UI 字体，第三项恢复；并行结论不受影响。）
- 本地数据栈与资料库栈互不依赖 → 并行装配。内部细分（实测）：`dataSaver.init`
  8–9ms、`downloadSettings.init` 0ms、`syncState.init` 0ms、统计 init / 换源 init /
  DB `maxVersion()`（含 drift 库打开）11–12ms、`downloadService.init` 12–13ms；
  串行是相加，并行取最大值。

### 5.2 同步栈初始化后移（≈ −38ms）

`buildSyncStack` 里 `await syncProvider.init()` + `await scheduler.start()` 移到
首帧之后（新的 `startSync`，由 `post_frame_init.dart` 调用）。这两步要开安全存储
（Android Keystore 冷读更贵）**和跑电量/网络探针**（`SyncScheduler.refreshEnvironment`），
都不参与首帧内容；同步设置页在首帧后才可能被打开，状态面看不到差别。
失败仍不阻断启动（口径不变，见 `docs/pitfalls.md` #31）。

### 5.3 更新栈后移（≈ −14ms）

`buildUpdateStack` 变成纯构造（无 IO），`PackageInfo.fromPlatform()` + 偏好 +
平台信息的读取收进 `UpdateProvider.start()`，首帧后与自动检查（本来就排在首帧后）
串起来。读不到包信息仍按 0.0.0 处理（可检查、无比较基准），与拆分前一致。

### 5.4 libmpv 预热：试过，**无效**（否证，勿重试）

`initDesktopAudioIfNeeded()` 会在主 isolate 上同步 `dlopen` libmpv，实测 39–48ms
（Windows 打包的是 ~30MB 的 `libmpv-2.dll`，只会更贵），看起来很适合藏进建窗的
I/O 空档。试法：在后台 isolate 里先 `DynamicLibrary.open` 一次（动态库是进程级的，
理论上后续 open 命中缓存）。

实测结果：后台 isolate 的 dlopen 在 38ms 内完成（时间戳证明它在建窗结束前就跑完了），
但「窗口就绪」同时从 46ms 涨到 89ms —— **两次 dlopen 争用进程级动态加载器锁，
与 GTK 建窗互相串行，总时长一分不省**。已回退，代码里留了注释。

### 5.5 首帧内的界面树：**不用优化**（否证）

用 `--dart-define` 临时把 `runApp` 的整棵树换成 `SizedBox.shrink()` 实测：
首帧仍是 **211ms**，与真实界面树（211ms）完全一致。结论：runApp → 首帧的 ~100ms
是引擎/框架/窗口表面的固定成本（Impeller 初始化、首帧光栅化），**与我们构建了
几个页面无关**，因此不需要动「三个常驻页面同帧构建」这类设计（也就不用牺牲
播放页共享元素飞行的首帧行为）。

### 5.6 Windows 陈旧单实例锁 + 装配并行（2026-10-21）

- **陈旧锁**：`SingleInstance.acquire()` 抢锁失败后读锁里的 pid / port，旧逻辑直接
  `Socket.connect`；pid 已退出时 Windows 仍可能等满 `_connectTimeout=2s`，随后
  `_retryDelay=300ms` 才清锁重抢。新增 `process_liveness.dart`：Windows 用
  `OpenProcess(SYNCHRONIZE) + WaitForSingleObject(0)`，Linux 用 `kill(pid, 0)` +
  errno；pid 已退出立即清锁，不为死端口等超时。只动单实例 IO 判定，不改锁协议 /
  退出路径。
- **装配并行**：热键注册、桌面壳（tray settings prefs）、歌词显示 / 主题预解析
  原本串行；三者互不依赖，现并行发起、`runApp` 前统一 await。新增子阶段
  `sub.hotkeys.attach` / `sub.desktop.build` / `sub.lyricsDisplay.build` 供回归。
- 改后 dev54 实测：陈旧锁日志「锁进程 23080 已退出，立即重抢」，窗口就绪
  161ms、首帧 318ms（改前 2445 / 2662ms）；干净启动 338ms / 墙钟 1.45s。
  `sub.hotkeys.attach` 2ms、`sub.desktop.build` 0ms、`sub.lyricsDisplay.build`
  114ms——剩余 Dart 最大段是首帧封面色预解析；并行把 hotkeys / desktop 的串行
  等待移出关键路径，本次它们都在毫秒级，干净启动收益在噪声内。真正的收益是
  强杀 / 更新后的 2.1s 不再出现。

## 6. 剩下的固定成本（不建议再碰）

| 项 | 实测 | 为什么留着 |
| --- | ---: | --- |
| GTK 建窗 + 隐藏 + 几何恢复（`WindowChrome.ensureInitialized`） | ~46ms | 窗口必须存在才能 `runApp`；窗口先隐藏、首帧回调再亮（避免盯空白窗）是既定交互 |
| libmpv `dlopen`（`initDesktopAudioIfNeeded`） | ~39ms | 播放后端注册必须早于播放栈（恢复会话要用），推迟到首帧后会让恢复态/通知状态可见地迟一拍 |
| 引擎 + 框架 + 首帧渲染 | ~100ms | 见 §5.5，与界面树无关 |
| Dart 侧装配（`molia.startup` 各阶段合计） | ~20ms | 省流探测、下载存储、drift 库打开；都是首帧内容或播放链路的前置 |

## 7. Android 参考（模拟器，非真机）

2026-10-18 本机模拟器（`molia_api37`，x86_64）实测，release APK，
`tool/agent/startup.sh android --no-build --runs 5`：

| 口径 | 中位 | 最小 | 最大 |
| --- | ---: | ---: | ---: |
| `Activity TotalTime`（系统：进程起到首帧绘制） | 1353 | 1324 | 1387 |
| 应用内「首帧」埋点 | 451 | 406 | 498 |
| ├ 窗口就绪 | 16 | 4 | 412 |
| ├ 本地数据/资料库栈 | 385 | 347 | 426 |
| ├ 播放栈（含媒体会话） | 418 | 379 | 460 |
| └ 同步栈 / 更新栈（已后移，与主题同刻） | 421 | 383 | 463 |

- 模拟器比真机慢得多（x86_64 转译 + 宿主负载），抖动也大，只用于**相对比较**与冒烟：
  release 包能正常启动、没有插件异常（这一步抓到过 `shared_preferences_android 2.5.0`
  的 R8 冲突，见 `docs/pitfalls.md` #56）。
- 绝对值不代表真机：真机的总时长应远低于这里的 1.3s；系统口径与应用埋点之差
  （约 900ms）是进程 fork + 引擎初始化 + 首帧绘制，在模拟器上被放大得最厉害。
- 本轮改动（§5.1–5.3）都是平台无关的 Dart 侧装配，Android 同样受益；上面的数字是
  **同一次改动后**的参照值，没有做改动前的 Android A/B（模拟器方差不足以分辨几十毫秒）。

### 7.1 2026-10-20：本地数据 / DB 后移（Android A/B）

同一模拟器、release APK、冷启动、每轮 `am start -W -S`；改前 9 次、改后 15 次，
构建完成后先停 Gradle / Kotlin daemon 再采样（避免编译进程和模拟器抢 CPU）：

| 口径 | 改前中位 | 改后中位 | 改后最小–最大 |
| --- | ---: | ---: | ---: |
| `Activity TotalTime` | 1324 | 1256 | 1190–3366 |
| 应用内「首帧」 | 477 | 473 | 429–504 |
| ├ 本地数据/资料库栈 | 425 | 18 | 8–419 |
| ├ 播放栈（含媒体会话） | 450 | 440 | 385–469 |
| └ 首帧回调 | 477 | 473 | 429–504 |

改后首帧之后（不再占关键路径）的实测：`maxVersion` 24ms、下载记录加载 27ms、
省流网络探测 32ms。

**关键发现（比数字本身更重要）**：模拟器上**第一个平台通道调用**本身就要等
约 **400ms**（临时用 `updater.supportedAbi` 做首调探针测得 396ms 中位）。
`Activity TotalTime` 的最大值 3366 是宿主负载抖动，中位与最小值更可比。
这 400ms 会落在「第一个 await 平台通道」的阶段上——改前落在 prefs / DB，
改后落在省流 prefs 或媒体会话，所以**应用内首帧仍约 470ms**，Dart 侧后移
并不能消掉它。这不是某个模块的成本；不要因为某个阶段偶尔 400ms 就去优化它。

- 本轮实际改了什么：`DownloadService.init`（含 `.part` 清扫）、
  `LibraryRepository.maxVersion`（含 drift 打开/迁移）、统计收尾/裁剪、
  音频缓存命名清理、省流网络探测全部移到首帧后；下载取链经 `ready` 等记录，
  资料库写入经 `stampSeedReady` 等最大戳种子（保留 ADR-0003 基线约束）。
- 原生侧同时移除了无效的 `MoliaApplication` / `DynamicColors` 和
  `EmojiCompatInitializer`（Flutter 自绘文本用不到；原生只有 RemoteViews）。
- 真机结论仍需真机复测：模拟器的 400ms 固定等待会掩盖 Dart 侧收益；
  真机上应重点看「首帧之后」的 DB/下载/探测是否消失、以及系统 TotalTime。
- **不采用引擎 / 系统库替换类 hack**：试过排除 `androidx.window`、影子类、
  反射清空 `WindowInfoTracker` 的 extension backend——要么直接崩
  （`WindowMetricsCalculator` 是 Flutter `ViewUtils` 必需），要么能压掉这
  400ms 但会随 Flutter / AndroidX 升级失效，属于以后每次升级都要还债的
  适配风险。按 Flutter 官方建议，只做「首帧后初始化非关键子系统」和平台
  条件分支；剩余部分等 Flutter 引擎 / 真机数据。

## 8. 未覆盖

- **iOS**：本机没有对应设备侧采样；做法同 Android（release 构建 + 平台日志）。
- **Windows / 真机**：Windows 已用 CI `windows-dev` + 重定向 stdout 采样（§4.1）；
  仍需覆盖不同机器 / Defender 冷扫描等环境。Android 只有模拟器，真机数据待补。

## 9. 运行时体检（2026-10）

启动之外的帧、交互、数据链路、CPU、内存与体积基线见
`docs/performance-audit-2026-10.md`；复测入口为 `tool/agent/perf.sh`
（`frames` / `memory` / `size` / `startup` / `data` / `cpu`），Windows
真实窗口帧用 `tool/agent/perf.sh frames windows --real`。
