# ADR-0036：桌面媒体集成（输出丢失 / 进程身份 / 播放菜单 / 桌面入口）

- 状态：已采纳
- 日期：2026-11-18
- 相关：ADR-0010、ADR-0020、ADR-0035、issue #63、
  `lib/playback/platform_audio_port.dart`、`lib/playback/desktop_audio_output_port_io.dart`、
  `lib/playback/pactl_sink_events.dart`、`lib/playback/pactl_output_watcher.dart`、
  `lib/services/window/playback_menu_io.dart`、`windows/runner/audio_output_watcher.*`、
  `macos/Runner/AppDelegate.swift`、`linux/packaging/share/applications/top.stillmisty.molia.desktop`、
  `docs/pitfalls.md` #115–#118

## 背景

1. **输出设备消失后继续外放**：Windows 拔耳机 / 蓝牙断开 / USB DAC 掉电，系统把
   音频改到内置扬声器，Molia 继续满音量播放。macOS 的播放层订阅了
   `audio_session` 的设备变化流，但 macOS 插件只实现配置，路由变化事件只在 iOS
   存在，订阅永远不触发；Linux 没有对应事件。Android / iOS 已有焦点与设备移除
   处理，桌面没有等价能力。
2. **Windows 音量合成器不认识应用**：`just_audio_media_kit` 用静态
   `JustAudioMediaKit.title`（默认 `JustAudioMediaKit`）标记音频会话，应用从未
   设置，用户无法判断哪条流属于 Molia。
3. **Linux 启动器信息太少**：`.desktop` 只有名字 / 注释 / 图标 / 分类 / WM class；
   GNOME / KDE 无法用「音乐 / 播放器」搜索，通知不归属应用，没有启动反馈，也
   没有声明单主窗口。
4. **macOS 没有播放菜单**：媒体键和 Now Playing 可用，但菜单栏用户、鼠标用户与
   VoiceOver 用户找不到播放 / 上一首 / 下一首。

## 决策

### 一个端口，不新增第二个 seam

- 沿用 ADR-0035 的 `PlatformAudioPort`。桌面实现
  （`desktop_audio_output_port_io.dart`）只扩展 **`outputLost`** 事件：
  `supported` 仍为 false（不提供 `audio_session` 的配置 / 激活 / 释放），
  新增能力位 **`emitsOutputLost`** 为 true。
- `LocalPlaybackService` 构造时仍只经 `AudioSessionLifecycle` 拥有端口；生命周期
  的会话路径继续按 `supported` 短路，播放服务的事件接线按「`supported` 或
  `emitsOutputLost`」判断。**没有**第二个构造流、没有第二套暂停策略。
- `outputLost` 到达后复用现有的 `pause(urgent: true)`：立即暂停、不走淡变、
  不新增设置、不自动恢复。暂停幂等，所以重复事件（Windows 的 removal + default
  change）无害。
- 失败静默：通道未注册、`pactl` 缺失、沙箱拒绝、声音服务器重启都只记一行日志，
  不阻塞启动 / 播放，不向 UI 报错。
- 端口由生命周期唯一释放；`dispose()` 与 `shutdownAudioForQuit()` 都走同一个
  幂等入口，桌面 watcher 的通道处理函数 / 子进程随端口销毁。

**输出丢失的语义**：「之前的默认输出已经不可用」，不是「有设备变化」。设备新增、
用户在两个仍然存活的输出之间主动切换、无关端点（录音 / 通信设备）变化都不暂停。

### Windows 检测

- 在 runner 实现 `IMMNotificationClient`（`audio_output_watcher.*`），注册到
  `IMMDeviceEnumerator`，只跟踪 `eRender` + `eConsole`。
- 缓存当前默认 render 端点。默认变化时仅当**旧端点不再 ACTIVE** 才上报；跟踪的
  端点被删除 / 变为非 ACTIVE 上报；新默认为空上报。旧端点仍存活时继续播放。
- COM 回调在任意 worker 线程：回调只登记待处理事件并 `PostMessage`，平台线程
  （窗口过程）再做设备枚举、存活判断与 `top.stillmisty.molia/audio_output` 的
  `outputLost` 调用。注册在窗口与通道创建之后，`OnDestroy` 先
  `UnregisterEndpointNotificationCallback` 再销毁引擎 / 反初始化 COM。
- 只用系统 COM / WASAPI；runner 的 CMake 增加源码，不引入第三方库。

### macOS 检测

- 在 `kAudioObjectSystemObject` 上注册
  `kAudioHardwarePropertyDefaultOutputDevice` 的 `AudioObjectAddPropertyListenerBlock`，
  回调固定投递到 main queue（CoreAudio block listener 可能来自 HAL 线程）。
- 缓存上一台默认设备；新默认为未知或旧设备 `DeviceIsAlive` 为 false 才上报；
  两台都存活时主动切换不暂停。退出时移除 listener。
- CoreAudio / AudioToolbox 是系统框架；不新增 entitlement、不申请麦克风权限，
  现有 sandbox 与网络权限不变。

### Linux 检测

- 使用 `pactl subscribe`（PulseAudio 与 PipeWire-pulse 共用），启动时 / server
  变化时用 `pactl list short sinks` 建立 id→name 表，用 `pactl get-default-sink`
  （旧版本回退 `pactl info` 的 `Default Sink:`）跟踪默认 sink。
- 只有在被移除的 sink 是当前跟踪的默认 sink 时才上报；`remove` 发生在
  source / sink-input 不是输出丢失；`new` / `change` 只刷新快照。server 事件刷新
  后若旧默认名已不在 sink 列表里，也按丢失处理（部分服务器先发 change 再发
  remove）。
- 解析器 `pactl_sink_events.dart` 是纯函数：损坏行、CRLF、空行、超大 id 都返回
  null / 类型化事件，不抛异常，CI 不需要声音服务器。
- `pactl` 缺失、Flatpak 沙箱拒绝、服务器重启 → 静默停用（不重试、不弹窗）；
  dispose 时 kill + await exitCode、关闭管道，`_disposed` 之后晚到的行不再触发
  事件。

### 平台通道

- 原生 → Dart：`top.stillmisty.molia/audio_output`，唯一方法 `outputLost`，无参数。
  通道名在 Dart、Windows runner、macOS runner 三处必须一致；未知方法忽略。
- Dart 在端口 `start()` 时安装处理函数（Windows / macOS），`dispose()` 摘除；
  Linux 不装通道，只管理 `pactl` 子进程。

### Windows 媒体身份

- `desktop_audio_init_io.dart` 在 `JustAudioMediaKit.ensureInitialized()` 与任何
  播放器创建之前设置 `JustAudioMediaKit.title = 'Molia'`，让音量合成器显示品牌名。
- 这是**进程品牌身份**，与 AUMID、可执行文件元数据、Linux `.desktop` 的 `Name`
  同一层；不是应用内可自定义的显示标题。`media_kit` 只在创建播放器时读取该值，
  已有播放器不会热更新；如未来要让混音器跟随自定义标题，是另一次改动。
- 不改其他 media_kit 配置。

### macOS 播放菜单

- 在 `AppDelegate.applicationDidFinishLaunching` 程序化插入顶层「播放」菜单
  （View 之后、Window 之前），不改 nib。三个菜单项：播放 / 暂停、上一首、下一首。
- **不设 key equivalent**：媒体键与应用内可自定义快捷键是唯一键位来源，避免
  第二套不可配置的绑定。菜单项在 Dart 发出第一份状态且存在曲目时启用；无曲目 /
  首帧前禁用。
- 通道 `top.stillmisty.molia/playback_menu`：原生 → Dart
  `togglePlayPause` / `previousTrack` / `nextTrack`；Dart → 原生 `update`
  （`menuTitle`、`playPauseLabel`、`previousLabel`、`nextLabel`、`hasTrack`、
  `isPlaying`）。原生只应用变化过的值。
- Dart 适配器（`lib/services/window/playback_menu_io.dart`）由组合根在
  `syncTray` 同一处同步，命令回落到托盘 / 任务栏共用的闭包，恢复态路由、会话
  落盘与失败处理仍只在 provider 命令面。菜单标题 / 文案随语言与播放态更新；
  相同载荷不重复发送。
- `applicationShouldHandleReopen`、单实例激活与托盘行为不动。

### Linux 桌面入口

- 保留 `Type` / `Name` / `Comment` / `Exec` / `Icon` / `Terminal` / `Categories` /
  `StartupWMClass`；`Name` 不本地化。
- 新增本地化 `GenericName`（Music Player / 音乐播放器）、`Keywords` 与
  `Keywords[zh_CN]`（分号结尾）、`X-GNOME-UsesNotifications=true`、
  `SingleMainWindow=true`、`StartupNotify=true`。
- **不新增** `MimeType` / `Actions` / 文件关联 / `DBusActivatable`：应用不解析
  argv 文件参数，声明音频类型会让文件管理器提供无法使用的「打开方式」。
- 契约测试钉住字段和「没有 MimeType」；`desktop-file-validate` 仍是最后门禁。

## 后果

- 三端输出消失都会立即暂停并保留进度；主动切换两台存活设备不打断播放。
- Windows 音量合成器显示 Molia；Linux 启动器可按通用词搜索、通知归属应用、
  声明单主窗口与启动反馈。
- 无新增运行时依赖、无新增权限 / entitlement、无新增用户设置。
- 桌面 `supported` 仍为 false：ADR-0035 的会话配置 / 激活 / 释放行为不变，
  Android / iOS 路径完全未改。
- Linux 服务器重启后本会话可能失去输出检测（设计上的静默降级）；`pactl` 是
  可选工具，Flatpak 内不可用属已知限制。

## 验证

- 纯 `pactl` 解析（remove sink / source / sink-input、new / change、损坏行、
  CRLF、空行、大 id）。
- 假端口 → 服务：一次 `outputLost` 只产生一次 urgent pause、不走淡变；已暂停 /
  无曲目无副作用；dispose 与退出收尾只释放端口一次。
- 假 MethodChannel：`outputLost` 到达流、未知方法忽略、dispose 后无事件；
  macOS 菜单命令路由、首份载荷、相同状态不重发、初始化前命令忽略。
- Linux 桌面入口契约 + `desktop-file-validate`。
- **原生 / 真机仍需人工验证**：Windows 拔有线耳机、蓝牙关机、USB DAC 掉电、
  两台存活输出切换、禁用唯一输出、退出时端点正在消失、音量合成器名称；
  macOS AirPods 断开、USB 声卡掉电、Sound 设置切换、VoiceOver 菜单；
  Linux PipeWire / PulseAudio、移除默认 / 非默认 sink、无 `pactl`、Flatpak、
  退出后无残留 `pactl` 子进程。原生代码在 Linux 上无法编译，见 issue #63 的
  manual matrix。
