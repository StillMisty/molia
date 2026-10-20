# ADR-0010：跨端系统媒体会话（flutter_media_session + MPRIS）

- 状态：已采纳
- 日期：2026-10-17
- 相关：`lib/playback/local_audio_handler.dart`、`lib/playback/media_session_backend.dart`、
  `lib/playback/flutter_media_session_backend.dart`、
  `lib/playback/mpris_media_session_backend*.dart`、`lib/managers/artwork_cache.dart`、
  `android/app/src/main/kotlin/top/stillmisty/molia/MainActivity.kt`、
  `android/app/src/main/AndroidManifest.xml`、`windows/runner/main.cpp`、
  `windows/installer/molia.iss`、issue #34、`docs/pitfalls.md` #18 / #34

## 背景

此前系统媒体会话由 `audio_service` 提供，平台覆盖只有 Android / iOS / macOS / Web：

- Windows 上 `audio_service` 不注册任何媒体会话，蓝牙耳机的 AVRCP 媒体键
  （播放/暂停/上一首/下一首）没有接收方；
- Linux 上同样没有 MPRIS 会话；
- Windows 社区实现 `audio_service_win` 有已确认的退出时原生崩溃（上游 issue #5），
  不可直接用；`smtc_windows` 需要 Rust 工具链，与当前构建链不匹配。

同时 `audio_service` 的 Android 集成要求 Activity 继承
`AudioServiceActivity`，并在 manifest 里声明它自己的 service / MediaButtonReceiver，
与本项目「自持平台通道 + 最小依赖面」的取向不符。

## 决策

1. **Android / iOS / macOS / Windows / Web 统一用 `flutter_media_session ^3.0.9`**：
   - Windows 原生实现走 `ISystemMediaTransportControlsInterop`，析构时释放 SMTC，
     支持硬件媒体键、媒体浮层、元数据/封面/进度/seek；
   - Android 原生实现是 Media3 `MediaSessionService`（通知、锁屏、耳机键、
     自定义动作），manifest 由插件合并，应用不再声明自己的 service / receiver；
   - iOS / macOS 走 Now Playing / 远程控制命令；Web 走 `navigator.mediaSession`
     （本应用 Web 不启用本地播放，不激活）。
2. **Linux 用 `audio_service_mpris ^0.2.1` 的 Dart 平台接口**
   （`AudioServicePlatform.instance` + `audio_service_platform_interface ^0.1.3` 的
   `ConfigureRequest` / `SetMediaItemRequest` / `SetStateRequest` /
   `AudioHandlerCallbacks`），**不引入 `audio_service` 本体**：只借用平台接口的
   消息类型，控制回调自己映射回统一动作流。
3. **完全移除 `audio_service`**：依赖、Android service/receiver、`AudioServiceActivity`
   基类、注释与测试 mock 全部清掉。
4. **应用层入口不变**：保留 `LocalAudioHandler` 类名与公开方法
   （`play/pause/stop/skipToNext/skipToPrevious/seek/skipToQueueItem/customAction/
   attachSessionPersister/setLyricMetadataOverride`）以及 `mediaSessionFactory`
   签名，内部改为「控制器 + 可注入 `MediaSessionBackend`」，
   组合根 / 歌词栈 / UI 的改动面最小。

## 架构

```
LocalPlaybackService ──监听──▶ LocalAudioHandler ──▶ MediaSessionBackend
                                   ▲                      ├─ FlutterMediaSessionBackend（Android/iOS/macOS/Windows）
                                   └── Stream<MediaAction> ┘   └─ MprisMediaSessionBackend（Linux）
```

- `lib/playback/media_session_backend.dart`：后端接口，统一使用
  `flutter_media_session` 的 `MediaMetadata` / `PlaybackState` / `MediaAction`
  模型；`activate/deactivate/updateMetadata/updatePlaybackState/
  updateAvailableActions/actions`。另含 `NoopMediaSessionBackend`（Web 兜底）。
- `lib/playback/flutter_media_session_backend.dart`：包装
  `FlutterMediaSessionPlatform.instance`（构造可注入，便于单测）。
  **不走 `FlutterMediaSession().activate()`**：后者在 Android 会自动请求通知权限，
  而本应用的权限时机由 `services/notification_permission.dart` 在「首次真正播放 /
  首次开启歌词输出」时决定。
- `lib/playback/mpris_media_session_backend.dart`（条件导出 stub/io）：
  `ConfigureRequest` 用 channel id `top.stillmisty.molia.media`、name `Molia`
  （MPRIS 用 id 生成 `org.mpris.MediaPlayer2.<id>.instance<pid>` 总线名）；
  `MediaMetadata` → `MediaItemMessage`、`PlaybackState` → `PlaybackStateMessage`，
  `AudioHandlerCallbacks` 的 play/pause/stop/next/previous/seek 映射为
  `MediaAction` 流。D-Bus 不可用时吞错、`isAvailable=false`，播放链路继续。
  非 IO 平台（Web）的 stub 返回 null，保证 Web 构建不引入 D-Bus。
- `lib/playback/media_session_backend_factory.dart`：按平台选择后端；
  `initSystemMediaSession` 在初始化异常时返回 null（与旧 `AudioService.init` 一致）。
- `isSystemMediaSessionSupported`：Android / iOS / macOS / Windows / Linux 为 true，
  Web 为 false（本地播放不可用）。

## 行为对齐（逐项保留）

- 曲目 / 封面 / 时长变化 → 更新元数据；播放状态 / buffering → 更新 playback state；
  seek（位置跳变 >1s）→ 更新位置；
- 播放模式 → `repeatMode` / `shuffleModeEnabled` + Android 通知自定义动作
  「播放顺序」（列表循环 / 顺序 / 单曲 / 随机，文案随语言切换重发）；
- 通知/锁屏/耳机键/媒体浮层：play / pause / stop / next / previous / seek；
- 恢复态无真实曲目时，next/previous 回落到注入的
  `onRestoredSkipToNext/Previous`；
- 暂停 / 停止 / 改播放模式 / seek 后显式 `await` 会话落盘
  （`attachSessionPersister` + `PlaybackSessionStore.pendingWrite` 串行化，
  停止先落盘再清空队列）；
- 歌词元数据覆盖 `setLyricMetadataOverride`：title / artist / album 生效；
  `displaySubtitle` 无对应字段，忽略（原字段只用于 Android 通知副标题，
  `flutter_media_session` 的 `MediaMetadata` 没有该槽位）；
- 省流模式 `artworkBlocked`：媒体元数据不带封面；省流网关在
  `ArtworkCache.cachedFilePath` 里同样生效，不触发网络下载；
- `data:` / 空封面 / 协议相对地址沿用 `parseArtUri` 语义。

### 封面

`MediaMetadata.artworkUri` 没有自定义请求头，而网易云等 CDN 对 Dart/WinRT
默认 UA 返回 403。因此复用统一封面缓存：

- `ArtworkCache.cachedFilePath(url)`：查持久缓存；未命中时用现有请求头
  （浏览器 UA + 平台 Referer）经 `manager.getSingleFile` 下载；省流网关开启时
  只读缓存、绝不触网（`getSingleFile` 绕过 `getFileStream` 的拦截，必须显式判断）；
- 元数据先发远程 URL 兜底，异步拿到本地文件后补发一次平台地址；
- Windows 传裸路径（WinRT `StorageFile` 分支），其余平台传 `file://` URI
  （`lib/playback/media_artwork_uri*.dart` 是唯一转换点）；
- 失败回退远程 URL 或 null，不影响播放。

## 平台配置

- **Android**：`MainActivity` 基类从 `AudioServiceActivity` 改为 `FlutterActivity`；
  manifest 删除 `com.ryanheise.audioservice.AudioService` 与
  `MediaButtonReceiver`（`flutter_media_session` 合并自己的 Media3 service /
  receiver）；`POST_NOTIFICATIONS`、`FOREGROUND_SERVICE_MEDIA_PLAYBACK` 保留。
  `@drawable/audio_service_*` 资源名保留（播放顺序自定义动作按字符串引用，
  `keep.xml` 继续防 shrinkResources 删除）；通知 small icon / channel 由 Media3
  默认决定（`flutter_media_session` 未暴露自定义 provider）——这是已知且可接受的
  差异，后续可单独跟进（通知动作的「收藏」与位置约束见 ADR-0013）。
- **iOS**：`UIBackgroundModes audio` 保留；无 audio_service 专属 AppDelegate 代码。
- **Windows**：`windows/runner/main.cpp` 在 `wWinMain` 开始处
  `SetCurrentProcessExplicitAppUserModelID(L"top.stillmisty.molia")`，
  `windows/installer/molia.iss` 的快捷方式加同名 `AppUserModelID`；不引入
  `smtc_windows`（Rust）或 `audio_service_win`（退出崩溃）。
- **Linux**：MPRIS；无 D-Bus 时静默降级（`isSystemMediaSessionSupported` 仍为
  true，但后端不可用）。
- **Web**：不激活媒体会话，依赖可编过 web。

## 后果

- Windows / Linux 首次获得系统媒体会话（硬件媒体键、媒体浮层、KDE/GNOME 媒体控制）；
- 依赖面变化：`audio_service`（含 `audio_service_web`）移除，新增
  `flutter_media_session` + `audio_service_mpris` + `audio_service_platform_interface`；
- `connectivity_plus` 固定到 `7.3.1`、`file_picker_linux` 随之落到 `2.0.0`：
  两包更新的补丁版都依赖 `nm ^0.6.0` / `dbus ^0.8.0`，与
  `audio_service_mpris` 的 `dbus ^0.7.10` 冲突（7.3.1 是同一行为线的上一
  补丁版，保留 Linux 客户端泄漏修复）；
- Android 通知的 small icon / channel 外观改为 Media3 默认（见上）；
- Linux 上「有会话但 D-Bus 不可用」不弹错误提示，只在日志里降级。

## 验证

- `flutter analyze --no-pub`：0 issue；
- `flutter test --no-pub`：全绿（含 `test/playback/media_session_backend_test.dart`、
  重写的 `local_audio_handler_test.dart`、`media_session_pause_session_test.dart`、
  `artwork_cache_test.dart` 的 `cachedFilePath` 用例）；
- `flutter build apk --debug`：验证 Android 原生 / Manifest / 依赖；
- Linux 桌面积分测试：`tool/agent/test.sh linux`；
- MPRIS 真机（Linux 桌面）用 `playerctl` / `dbus-send` 验证
  Play/Pause/Next/Previous（无会话总线环境只能验证降级分支）。

## 未验证（需人工验收）

- **Windows**：媒体浮层（任务栏 / 音量浮层）元数据与封面、硬件媒体键、
  AUMID 归属、安装器快捷方式；
- **iOS / macOS**：锁屏 Now Playing、远程控制、封面；
- **Android 真机**：Media3 通知外观、耳机键、自定义动作图标在
  release（shrinkResources）下的存在性。
