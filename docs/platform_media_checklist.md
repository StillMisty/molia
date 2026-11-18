# 平台媒体基线：身份、会话、声明与验证

> 本文是**平台媒体事实的唯一维护处**：应用身份、系统媒体会话的当前后端、必需的权限 /
> 后台模式 / entitlement、明确的禁用项，以及自动守卫与人工验证口径。其它文档只给指针，
> 不重复权限清单。相关决策：ADR-0010（系统媒体会话）、ADR-0035（平台音频会话生命周期）、
> ADR-0036（桌面媒体集成）、`docs/adr/0037-gapless-playback.md`（曲间无缝，已决定暂不实现）。

要求以**可观察契约**表述（例如「锁屏后音频继续」），平台机制只是当前实现；换后端不应
让契约失效。每行都标出状态与最后核对日期；没有真正跑过的真机项明确写「未复验」。

最后核对：**2026-11-18**（静态配置与自动守卫；真机 / 设备观察项按各节标注）。

## 状态矩阵

| 平台 | 身份 | 媒体会话面（当前后端） | 必需声明 | 自动守卫 | 最后核对 |
| --- | --- | --- | --- | --- | --- |
| Android | `top.stillmisty.molia`（manifest `package` / Gradle `namespace` / `applicationId`） | Media3 `MediaSessionService`（`flutter_media_session` 插件合并）：通知、锁屏、耳机键、播放顺序 / 收藏动作 | `INTERNET`、`FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_MEDIA_PLAYBACK`、`POST_NOTIFICATIONS`、`WAKE_LOCK`；下载服务另有 `FOREGROUND_SERVICE_DATA_SYNC` | 部分：`test/architecture/platform_config_test.dart` 钉住应用 manifest；**合并后的 service 需人工核对** | 2026-11-18 静态；真机未复验 |
| iOS | `top.stillmisty.molia`（`PRODUCT_BUNDLE_IDENTIFIER` → `CFBundleIdentifier`） | Now Playing / 远程控制（`MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`，`flutter_media_session`）；音频会话经 `audio_session` / `PlatformAudioPort` | `UIBackgroundModes = [audio]` | 是：后台模式与「无麦克风用途说明」 | 2026-11-18 静态；真机未复验 |
| macOS | `top.stillmisty.molia`（`macos/Runner/Configs/AppInfo.xcconfig` → `CFBundleIdentifier`） | Now Playing / 远程控制（同一后端）；播放菜单；音频走 AVPlayer，不激活移动音频会话 | App Sandbox + `network.client` + `network.server`（两套 entitlement 都要）；无音频输入 entitlement | 是：两套 entitlement 与「无麦克风用途说明」 | 2026-11-18 静态；真机未复验 |
| Windows | AUMID `top.stillmisty.molia`；显示名 `Molia` | SMTC（`flutter_media_session` 的 `ISystemMediaTransportControlsInterop`）；音频走 media_kit / libmpv | runner 注册 AUMID + 注册表身份；安装器每个快捷方式带同一 AUMID；`JustAudioMediaKit.title = 'Molia'` | 是：AUMID 三处一致 + media_kit 标题 | 2026-11-18 静态；真机未复验 |
| Linux | `top.stillmisty.molia`（`.desktop` 文件名、CMake `APPLICATION_ID`、Dart MPRIS `DesktopEntry`、`StartupWMClass` 四处） | MPRIS 2（`flutter_media_session` 原生实现）；音频走 media_kit / libmpv | 桌面入口 `Name` / `Exec` / `Icon` / `StartupWMClass`；MPRIS `Identity` / `DesktopEntry` | 是：跨文件身份 + 名称 / 可执行文件；桌面入口自身键与图标归打包测试 | 2026-11-18 静态；真机未复验 |

## Android

### 身份

- 值：`top.stillmisty.molia`。
- 必须一致：`android/app/src/main/AndroidManifest.xml` 的 `package`、
  `android/app/build.gradle` 的 `namespace` 与 `applicationId`、`FileProvider` authority
  的 `${applicationId}` 前缀。系统按 applicationId 归属通知与媒体会话；改名会同时改变
  升级身份与通知权限归属。
- 自动守卫只覆盖 manifest 内的媒体声明，**不**断言 Gradle 身份；改 applicationId 时人工
  核对这一组。

### 媒体会话面

- 契约：播放时出现媒体通知与锁屏控制；耳机 / 蓝牙媒体键可播放、暂停、上一首、下一首；
  通知里保留「收藏」与「播放顺序」两个自定义动作；锁屏与切后台后音频继续。
- 当前实现：`FlutterMediaSessionBackend` → `flutter_media_session` → Media3
  `MediaSessionService`。**service 与 `MediaSessionReceiver` 由插件 manifest 合并**，
  应用 manifest 刻意不再声明第二套（ADR-0010）。
- 音频焦点与混播语义见 ADR-0035；本页不重复。

### 必需声明

- `INTERNET`：音源取链、封面、歌词、同步。
- `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MEDIA_PLAYBACK`：Media3 前台播放服务
  （[前台服务类型](https://developer.android.com/develop/background-work/services/fgs/service-types)）。
- `POST_NOTIFICATIONS`：Android 13+ 媒体通知；**不在冷启动请求**，由首次真正播放 /
  首次开启歌词输出时申请（[通知权限](https://developer.android.com/develop/ui/views/notifications/notification-permission)）。
- `WAKE_LOCK`：播放期间保持 CPU 唤醒。
- `FOREGROUND_SERVICE_DATA_SYNC`：下载服务 `DownloadNotificationService` 的类型权限。
  它不是媒体声明，但「每种前台服务类型都要有匹配权限」同样适用于它。
- 参考：[Media3 后台播放](https://developer.android.com/media/media3/session/background-playback)、
  [音频焦点](https://developer.android.com/media/optimize/audio-focus)。

### 禁止声明

- 音频采集权限：`RECORD_AUDIO`、`CAPTURE_AUDIO_OUTPUT`、`CAPTURE_AUDIO_HOTWORD`。
  应用只输出音频；多声明只会在系统授权界面制造无关请求。
- 在应用 manifest 再声明一套 Media3 `MediaSessionService` / `MediaButtonReceiver`：
  会与插件合并结果冲突，并改变通知归属（ADR-0010）。

### 自动守卫覆盖

`test/architecture/platform_config_test.dart` 断言：

- 上述五个媒体权限都存在；
- 应用 manifest 声明的每个 `foregroundServiceType` 都有
  `FOREGROUND_SERVICE_<TYPE>` 匹配权限（当前是 `dataSync`）；
- 三类音频采集权限都不存在；
- manifest / `<application>` / 至少一种前台服务类型都能解析到（防止改名后空转）。

**仍然手动**：合并后的 manifest 里 Media3 service 的
`android:foregroundServiceType="mediaPlayback"`、service 名与 intent-filter。它属于
依赖产物，不在仓库文件里。

### 人工验证 recipe

1. `flutter build apk --debug`，用 `apkanalyzer manifest print <apk>`（或
   `aapt dump xmltree <apk> AndroidManifest.xml`）确认合并结果含
   `androidx.media3.session.MediaSessionService` 且
   `foregroundServiceType` 含 `mediaPlayback`。
2. 真机播放，锁屏：通知 / 锁屏出现曲目、封面、播放暂停、上一首 / 下一首；息屏 30 秒后
   音频仍在继续。
3. 下拉通知检查「收藏」「播放顺序」动作存在且生效；用耳机线控与蓝牙媒体键各验证一次。
4. 拒绝通知权限后再播放：音频仍可播放，应用不崩溃；通知·锁屏设置页能深链到系统设置。
5. `adb shell dumpsys media_session` 能看到本应用会话与当前播放状态。

### 已知限制与缓解

- Media3 通知的 small icon / channel 外观由插件默认决定，应用未暴露自定义 provider；
  接受该差异（ADR-0010）。缓解：`keep.xml` 保留 `audio_service_*` 资源，避免
  shrinkResources 删掉自定义动作图标。
- `usesCleartextTraffic="true"` 是**已知取舍**，不是媒体守卫项：部分音源返回 http 直链，
  与 LX Music 行为一致。未来若改成 scoped network-security config，媒体守卫不应因此失败；
  只需更新本页和发布说明。
- 音频焦点 / 混播 / 会话释放的行为限制见 ADR-0035；不要在平台媒体改动里顺手改它。

## iOS

### 身份

- 值：`top.stillmisty.molia`。
- 必须一致：`ios/Runner.xcodeproj/project.pbxproj` 的 `PRODUCT_BUNDLE_IDENTIFIER` 与
  `ios/Runner/Info.plist` 的 `CFBundleIdentifier`（后者引用构建设置，最终应展开为同一值）；
  显示名 `CFBundleDisplayName` / `CFBundleName` 为 `Molia`。
- 该身份**没有**自动守卫；改 bundle id 时人工核对，并确认签名 profile 同步更新。

### 媒体会话面

- 契约：锁屏 / 控制中心显示 Now Playing；耳机与蓝牙媒体键可控；锁屏后音频继续；暂停后
  卡片按 ADR-0035 的宽限与释放策略变化。
- 当前实现：`MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`（`flutter_media_session`）；
  音频会话 category / 激活由 `audio_session` 经 `PlatformAudioPort` 统一管理，
  **播放器不再自行激活**（ADR-0035）。

### 必需声明

- `UIBackgroundModes` 包含 `audio`
  （[UIBackgroundModes](https://developer.apple.com/documentation/bundleresources/information-property-list/uibackgroundmodes)）。
  没有它，锁屏或切后台后系统会挂起音频。
- `NSLocalNetworkUsageDescription` 属于局域网同步，不是媒体要求；本页不展开。
- 参考：[AVAudioSession](https://developer.apple.com/documentation/avfaudio/avaudiosession)、
  [MPNowPlayingInfoCenter](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter)、
  [MPRemoteCommandCenter](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter)。

### 禁止声明

- `NSMicrophoneUsageDescription`：应用不做音频输入。声明它会让 App Store 审核与用户都以为
  应用要采集音频（[用途说明](https://developer.apple.com/documentation/bundleresources/information-property-list/nsmicrophoneusagedescription)）。
- 不要为了「后台保活」追加无关 `UIBackgroundModes`（如 `location` / `voip`）；音频后台
  只需要 `audio`。

### 自动守卫覆盖

`test/architecture/platform_config_test.dart` 断言 `UIBackgroundModes` 数组存在且含
`audio`，并断言 `Info.plist` 没有 `NSMicrophoneUsageDescription`。解析失败（key 改名）
会直接失败，不会静默通过。

### 人工验证 recipe（真机）

1. 播放后锁屏：锁屏与控制中心显示曲目 / 封面 / 进度；播放暂停、上一首 / 下一首可用。
2. 切到其他应用再回前台：播放不中断；暂停超过 ADR-0035 的宽限后，其他应用可以恢复音频。
3. 拔耳机 / 断开蓝牙：按 ADR-0035 的设备移除策略暂停，不继续外放。
4. 设置 › Molia：不应出现麦克风权限项。
5. 冷启动（未播放）不打断其他应用正在播放的音频（ADR-0035）。

### 已知限制与缓解

- 暂停释放音频会话后 Now Playing 卡片可能消失或变暗；真机矩阵若证明这比冷启动打断更糟，
  回退点见 ADR-0035（只改策略常量，不加用户设置）。
- 媒体会话初始化失败时歌词输出页给可见提示；播放本身不被阻断。

## macOS

### 身份

- 值：`top.stillmisty.molia`。
- 必须一致：`macos/Runner/Configs/AppInfo.xcconfig` 的 `PRODUCT_BUNDLE_IDENTIFIER` 与
  `CFBundleIdentifier`；`CFBundleDisplayName` 为 `Molia`。
- 该身份**没有**自动守卫；改 bundle id / 团队签名时人工核对。

### 媒体会话面

- 契约：控制中心 / 媒体键显示并控制 Molia；菜单栏「播放」菜单可播放暂停、上一首、下一首；
  输出设备消失时暂停（ADR-0036）。
- 当前实现：Now Playing / 远程控制（`flutter_media_session`）；音频走 `just_audio` 的
  AVPlayer 后端，不安装 libmpv；播放菜单由 `AppDelegate` 程序化插入（ADR-0036）。

### 必需声明

- 两套 entitlement（`macos/Runner/DebugProfile.entitlements`、
  `macos/Runner/Release.entitlements`）都保留：
  - `com.apple.security.app-sandbox = true`；
  - `com.apple.security.network.client = true`（音源 / 歌词 / 更新 / WebDAV 出站）；
  - `com.apple.security.network.server = true`（局域网同步监听）。
- 默认下载目录与用户选择目录的读写 entitlement 见各文件；它们不是媒体要求。
- 参考：[App Sandbox](https://developer.apple.com/documentation/bundleresources/entitlements/com_apple_security_app-sandbox)、
  [network.client](https://developer.apple.com/documentation/bundleresources/entitlements/com_apple_security_network_client)。

### 禁止声明

- `com.apple.security.device.audio-input`（音频输入）：应用只输出音频
  （[entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com_apple_security_device_audio-input)）。
- `NSMicrophoneUsageDescription`：同上，避免无意义的麦克风提示。
- 不要为了媒体键再引入第二套全局快捷键：媒体键由系统会话接收，应用内快捷键另有入口
  （ADR-0036）。

### 自动守卫覆盖

`test/architecture/platform_config_test.dart` 对两套 entitlement 分别断言 sandbox、
network client、network server 为 `true`，并断言没有开启 `device.audio-input`；
同时断言 `macos/Runner/Info.plist` 没有 `NSMicrophoneUsageDescription`。

### 人工验证 recipe

1. 播放后打开控制中心：出现 Now Playing，播放暂停 / 上一首 / 下一首可用；键盘媒体键同样生效。
2. 菜单栏「播放」菜单三项可用，VoiceOver 能读出标题。
3. 执行 `codesign -d --entitlements :- <Molia.app>`：确认 sandbox 与两个 network 权限存在，
   `device.audio-input` 不存在。
4. 播放中在系统声音设置里切换输出、断开 AirPods / USB 声卡：按 ADR-0036 暂停，不继续
   从新默认设备外放。

### 已知限制与缓解

- 没有 `audio_session` 的桌面激活 / 释放：macOS 不参与 ADR-0035 的会话状态机。
- 媒体键与应用内快捷键刻意不共享绑定；这是设计选择，不是缺陷。

## Windows

### 身份

- 值：AUMID `top.stillmisty.molia`；显示名 `Molia`。
- 必须一致：
  - `windows/runner/shell_identity.h` 的 `kAppUserModelId` 与 `kAppDisplayName`；
  - `windows/runner/main.cpp` 的 `SetCurrentProcessExplicitAppUserModelID(...)`（必须使用
    同一常量）；
  - `windows/installer/molia.iss` 每个快捷方式的 `AppUserModelID`；
  - `lib/playback/desktop_audio_init_io.dart` 的 `JustAudioMediaKit.title = 'Molia'`。
- AUMID 是 shell 归档身份：媒体浮层、通知、任务栏按钮、音量合成器都按它归属。只设进程
  AUMID 而不注册身份，shell 会退回缓存中的旧图标 / 名字。
- 参考：[AppUserModelID](https://learn.microsoft.com/en-us/windows/win32/shell/appids)、
  [SMTC 集成](https://learn.microsoft.com/en-us/windows/uwp/audio-video-camera/integrate-with-systemmediatransportcontrols)。

### 媒体会话面

- 契约：系统媒体浮层（任务栏 / 音量浮层）显示 Molia、曲目、封面与传输控件；硬件媒体键
  可控；音量合成器把音频流归到 Molia 而不是绑定库。
- 当前实现：`flutter_media_session` 的 SMTC 后端；音频走 media_kit / libmpv；AUMID 在
  runner 启动路径设置并写入 `HKCU\Software\Classes\AppUserModelId\<AUMID>`。
- 输出设备丢失监听（`IMMNotificationClient`）见 ADR-0036，本页只记录媒体身份。

### 必需声明

- runner 在创建窗口 / 初始化 SMTC **之前**调用 `SetCurrentProcessExplicitAppUserModelID`，
  并注册 `DisplayName` + `IconUri`（当前 exe）。
- 安装器的开始菜单与桌面快捷方式都带同一 `AppUserModelID`；卸载 / 升级不会留下另一种身份。
- `JustAudioMediaKit.title` 在 `ensureInitialized()` / 创建播放器之前设为产品显示名
  （[just_audio_media_kit](https://pub.dev/packages/just_audio_media_kit)）。
- 参考：[IMMNotificationClient](https://learn.microsoft.com/en-us/windows/win32/api/mmdeviceapi/nn-mmdeviceapi-immnotificationclient)（输出丢失）。

### 禁止声明

- 不要内联第二份 AUMID 字面量；一律引用 `shell_identity::kAppUserModelId`。
- 不要把 `JustAudioMediaKit.title` 留给库默认值 `JustAudioMediaKit`，也不要让它跟随应用内
  可改的显示标题（它是进程品牌身份）。
- 不引入 `audio_service_win` / `smtc_windows`（ADR-0010 的决策）。

### 自动守卫覆盖

`test/architecture/platform_config_test.dart` 断言：

- header 能解析出 `kAppUserModelId[] = L"..."`；
- `main.cpp` 存在 `SetCurrentProcessExplicitAppUserModelID` 调用，参数是同一常量（或与
  header 相等的字面量）；
- 安装器至少声明一个 `AppUserModelID`，且每个值都与 header 相等；
- `desktop_audio_init_io.dart` 显式设置 `JustAudioMediaKit.title`，值等于 Linux 桌面入口的
  `Name`（共享产品显示名），且不是库默认值。

**仍然手动**：runner 里「先设 AUMID、后建窗口 / 初始化 SMTC」的顺序；安装后快捷方式与
运行中进程确实归到同一身份。

### 人工验证 recipe

1. 安装后播放：任务栏媒体浮层显示 `Molia`、曲目与封面；硬件媒体键可控。
2. 打开音量合成器：Molia 的应用条目显示 `Molia`，不是 `JustAudioMediaKit`，图标不是
   Flutter 默认图。
3. `Get-Process molia | Select-Object Path` 与快捷方式目标一致；开始菜单 / 桌面快捷方式
   指向同一 exe，升级后不产生两个应用条目。
4. 播放中拔有线耳机、关闭蓝牙耳机、拔 USB DAC：按 ADR-0036 暂停。

### 已知限制与缓解

- 应用是未打包（unpackaged）win32 程序：AUMID 是唯一身份来源，没有 MSIX 清单兜底。
- 任务栏图标 / 名字由 shell 按 AUMID 缓存；换图标后需重建身份注册，见 `shell_identity.h`
  的注释与 `docs/pitfalls.md` 对应条目。
- SMTC 的媒体键由 `flutter_media_session` 注册，应用内快捷键不与其共享配置。

## Linux

### 身份

- 值：`top.stillmisty.molia`；显示名 `Molia`；可执行文件 `molia`。
- 必须一致：
  - `.desktop` 文件名（去掉 `.desktop`）：`linux/packaging/share/applications/top.stillmisty.molia.desktop`；
  - `linux/CMakeLists.txt` 的 `APPLICATION_ID`；
  - `lib/playback/flutter_media_session_backend.dart` 的 `linuxMediaSessionAppId`（MPRIS
    `DesktopEntry`）；
  - 桌面入口的 `StartupWMClass`。
- 显示名一致：桌面入口 `Name` 与 `linuxMediaSessionDisplayName`（MPRIS `Identity`）。
- 可执行文件一致：桌面入口 `Exec` 与 CMake `BINARY_NAME`。
- 参考：[Desktop Entry Specification](https://specifications.freedesktop.org/desktop-entry-spec/latest/)、
  [MPRIS 2 Specification](https://specifications.freedesktop.org/mpris-spec/latest/)。

### 媒体会话面

- 契约：桌面媒体 applet / `playerctl` 能看到 Molia，显示曲目与封面，播放暂停 / 上一首 /
  下一首 / stop 可用；dock 与 app menu 显示真实图标。
- 当前实现：`flutter_media_session` 的原生 Linux MPRIS 2 后端；激活前
  `setAppId(linuxMediaSessionAppId, displayName: linuxMediaSessionDisplayName)`；无 session
  bus 时静默降级，播放不受影响。
- 音频走 media_kit / libmpv；默认输出变化监听用 `pactl subscribe`（PulseAudio 与
  PipeWire-pulse 共用），见 ADR-0036。

### 必需声明

- 打包资产必须安装 `.desktop` 到 `share/applications/`，并按应用 id 命名；hicolor 图标
  尺寸齐全（`linux/packaging/README.md` 记录每个字段的理由）。
- 桌面入口保留 `Type`、`Name`、`Comment`、`Exec`、`Icon`、`Terminal`、`Categories`、
  `StartupWMClass`；`Name` 不本地化（品牌名全平台统一）。
- 启动反馈与单主窗口：`StartupNotify=true`、`SingleMainWindow=true`；
  通知归属：`X-GNOME-UsesNotifications=true`。
- 参考：[PulseAudio](https://www.freedesktop.org/wiki/Software/PulseAudio/)、
  [PipeWire](https://docs.pipewire.org/)。

### 禁止声明

- `MimeType`、`Actions`、`DBusActivatable`、文件关联：应用不解析 argv 文件参数，声明后会
  让文件管理器提供不可用的「打开方式」（ADR-0036）。
- 本地化 `Name` / 每个平台各写一个应用 id：Wayland 门户与 MPRIS 靠文件名与 DesktopEntry
  认领身份，分裂后会退回通用图标 / 名字。
- 不要 fork / vendored patch `flutter_media_session` 来补 `Raise` / `Quit`（见下）。

### 自动守卫覆盖

`test/architecture/platform_config_test.dart` 断言：桌面入口文件名、CMake `APPLICATION_ID`、
Dart `linuxMediaSessionAppId`、`StartupWMClass` 四处相等；桌面入口 `Name` 等于 Dart
`linuxMediaSessionDisplayName`；`Exec` 等于 CMake `BINARY_NAME`。桌面入口的键 / 图标契约
仍由 `test/packaging/linux_desktop_test.dart` 拥有，本守卫不重复。

**仍然手动**：`desktop-file-validate`、安装后 dock / app menu 图标、真实 MPRIS 总线上的
控制响应。

### 人工验证 recipe

1. `dart run tool/agent/cli.dart test linux` 或安装 release bundle 后启动；`playerctl -l`
   应列出 Molia 的 MPRIS 名，`playerctl metadata` 显示曲目 / 封面。
2. `playerctl play-pause`、`playerctl next`、`playerctl previous`、`playerctl stop` 均生效。
3. 打开 GNOME / KDE 媒体 applet：显示 `Molia`、曲目、封面；控制按钮可用。
4. dock / app menu 显示 Molia 图标，而不是通用可执行文件图标。
5. `desktop-file-validate linux/packaging/share/applications/top.stillmisty.molia.desktop`
   返回 0。
6. 无 session bus 的环境（容器 / 精简桌面）启动应用：播放正常，无错误弹窗。

### 已知限制与缓解

- **MPRIS `CanRaise` / `CanQuit` 恒为 false，`Raise` / `Quit` 方法是 no-op**：这是
  `flutter_media_session` 当前的 Linux 实现，不是本仓缺陷。缓解：需要「唤起窗口」时用托盘
  或再次启动应用（单实例激活路径 `window/reopen` → `WindowChrome.show()`）；需要退出时用
  应用内退出 / 托盘退出。上游跟踪另行处理，**本仓不维护 fork / vendored patch**。
- MPRIS `LoopStatus` / `Shuffle` 的写入只触发不带目标值的媒体动作，应用无法得知目标模式，
  因此不映射成 toggle（ADR-0010）。
- 没有 `pactl`（如 Flatpak 沙箱）时输出丢失检测静默停用；播放不受影响（ADR-0036）。
- D-Bus 不可用时 MPRIS 名字不被占用，播放链路照常，只在日志里降级。

## 已评估但暂不实现的缺口

共享判断标准（每个缺口都用同一套口径，避免「现在不想做」变成主观结论）：

1. **用户可见收益**是什么，怎么测量；
2. **实现面 / 归属层**（播放服务、平台配置、UI、构建）；
3. **上游 / 依赖要求**；
4. **跨平台差异**；
5. 与现有不变量的交互：可播流请求头、队列投影、会话持久化、淡变包络、播放功耗策略、
   桌面缓存；
6. **成本与风险**；
7. **结论 + 明确触发条件**（什么时候重新评估）。

### Baseline Profile

- 收益：减少 Android 冷启动时平台 / JVM / 插件代码的解释与 JIT 成本。测量口径是
  `tool/agent/startup.sh android` 的 `Activity TotalTime` 与应用内首帧，需真机 release。
  （[Baseline Profiles](https://developer.android.com/topic/performance/baselineprofiles/overview)）
- 归属层：Android 构建（profile 模块 / Gradle），不改 Dart 播放行为。
- 上游：AndroidX / Media3 / Flutter 引擎已自带 baseline profile 的部分覆盖；应用模块需要
  自己的 profile。
- 跨平台：仅 Android。
- 交互：不影响队列、会话、请求头；只影响启动耗时与包体积。
- 成本 / 风险：生成与维护 profile 需要基准设备与每次依赖升级后的再生成；错误 profile 可能
  反而增加启动成本。
- **结论：暂缓，先做一次廉价的真机启动测量。** 现有 Android 数据只有模拟器
  （`docs/performance.md` §7，2026-10-18：`Activity TotalTime` 中位 1353ms、应用内首帧
  451ms），且模拟器上「第一个平台通道调用」本身约 400ms，无法判断平台 / JVM 代码占比。
  Dart AOT 才是首帧主路径；Baseline Profile 的收益集中在平台 / JVM / 插件侧。不要先写
  benchmark 模块再证明它有用。
- **触发**：真机 release 启动测量显示平台 / JVM / 插件部分占首帧的可观比例（例如与 Dart
  装配相比不是噪声），且优化目标仍是冷启动而不是帧率。

### Android audio offload

- 收益：息屏播放时把解码 / 渲染交给硬件音频 DSP，降低 CPU 与耗电。测量口径：真机息屏
  播放的 `cpu.sh` / 电池统计对比。
- 归属层：`just_audio` 的 `AudioPlayer` 构造参数，不改媒体会话或队列。
- 上游：**不是上游缺口**。`just_audio` 已暴露 `androidAudioOffloadPreferences` /
  `AndroidAudioOffloadMode`（`AndroidAudioOffloadPreferences`），可直接传
  `audioOffloadMode` 与 `isGaplessSupportRequired` / `isSpeedChangeSupportRequired`
  （[API](https://pub.dev/documentation/just_audio/latest/just_audio/AndroidAudioOffloadPreferences-class.html)）。
- 跨平台：仅 Android；桌面 / iOS 无对应开关。
- 交互：offload 只对设备支持直接播放的编码生效；gapless 与变速是**约束条件**，设备可能
  错误地宣称支持（上游文档明确要求只在已验证的设备 / 系统组合上启用）；失败时必须回退到
  普通解码。与淡变包络 / duck 的音量写入、播放速度、音效链的兼容性需要逐设备验证。
- 成本 / 风险：需要真机兼容矩阵；错误开启会产生杂音 / 无声 / 进度漂移，比省电收益更伤
  用户。
- **结论：暂缓，等电池 / 兼容性测量。** 本次不改 `AudioPlayer` 构造，也不加设置项。
- **触发**：真机息屏播放测量显示解码是主要耗电项，且目标设备矩阵能验证 offload 与
  gapless / 变速 / 音量写入的兼容性；或出现可复现的「息屏播放耗电异常」报告。

### 桌面屏保抑制

- 收益：播放时阻止系统屏保 / 自动锁屏，避免用户在看播放页 / 桌面歌词时被黑屏打断。
  测量口径：三端桌面播放后保持空闲，记录屏幕多久进入屏保 / 锁定。
- 归属层：桌面播放后端（media_kit / libmpv）或平台窗口层；不应进移动端。
- 上游：`just_audio_media_kit` 没有暴露 mpv 的 `stop-screensaver` 选项
  （[mpv 选项](https://mpv.io/manual/master/#options-stop-screensaver)）；要改策略需要上游
  增加绑定，或在 `just_audio_media_kit` 里 patch。media_kit 自身与平台窗口层是否已有默认
  行为需要先测。
- 跨平台：Windows / Linux 走 media_kit；macOS 走 AVPlayer，机制不同（`IOPMAssertion` /
  `NSProcessInfo`），不能假定同一开关覆盖三端。
- 交互：与「播放功耗策略」「省流模式」「后台听歌」可能冲突——用户可能正希望息屏省电；
  不应默认全局开启。
- 成本 / 风险：上游改动 + 三端策略差异 + 用户预期不一致；成本明显高于收益，除非测量
  证明这是高频投诉。
- **结论：先测量，暂不改策略。** 当前没有应用级屏保抑制代码；是否被 libmpv 默认抑制
  尚未验证。把测量结果和上游跟进记录在这里，而不是先 fork 依赖。
- **触发**：测量显示播放时屏幕仍会进入屏保 / 锁定，且用户反馈集中；或上游绑定暴露
  `stop-screensaver`（或等价 API）后，评估是否做成「仅播放页 / 桌面歌词可见时」的窄策略。

### 响度均衡（loudness normalization）

- 收益：不同曲目 / 音源之间音量一致，减少手动调音量。测量口径：本地与流播曲目的
  LUFS / 峰值采样对比 + 用户音量调整频率。
- 归属层：播放服务的音量路径（与淡变包络、duck、用户基值同一处），以及本地文件的标签
  读取 / 分析。
- 上游：无需上游改动；但流播曲目没有可靠响度标签，实时分析会推迟起播。
- 跨平台：算法可共享，但本地文件标签覆盖率与流媒体能力不同。
- 交互：**必须**与淡变包络、用户音量、duck 组合成唯一有效音量路径；不能绕开现有
  `基值 × 包络 × duck` 的数学。标签增益只覆盖本地 / 已下载素材；实时分析会和流播起播
  延迟直接冲突。
- 成本 / 风险：标签解析、增益元数据、真流播无标签的降级、与音量 UI 的解释成本；错误
  增益会产生削波或「越调越小」。
- **结论：暂缓。** 不做标签解析、不做实时分析、不改音量路径。
- **触发**：出现稳定的「本地与在线曲目音量差太大」反馈，且能接受「只对本地 / 已下载
  素材做标签增益」的窄范围；或上游 / 平台提供可直接消费的响度元数据。

### 曲间无缝（gapless）

已单独决策：见 `docs/adr/0037-gapless-playback.md`。本节只保留指针，不重复方案矩阵。
当前结论是**暂不实现**；若未来推进，从「本地文件 + 已完成缓存条目」的窄路径开始。

## 变更规则

### 改平台配置 / 身份时

1. 先查本页对应平台小节的「必须一致」列表，把所有出现位置一起改；不要只改一个文件。
2. 改完跑 `flutter test test/architecture/platform_config_test.dart --no-pub`。自动守卫
   失败时按 reason 指到的小节核对；如果这是有意的契约变化，先改本页，再改测试。
3. 跑 `dart run tool/agent/cli.dart docs check`，确认路径 / 链接 / 章节号 / ADR 编号。
4. 在状态矩阵更新「最后核对」日期；真机没跑就写「未复验」，不要用静态检查冒充真机结论。

### 改媒体相关依赖 / 工具链时

- `flutter_media_session`：重查各平台会话面、Linux `CanRaise` / `CanQuit` 限制、合并后的
  Android manifest、Windows SMTC 身份；必要时更新本页与 ADR-0010 的「后续」段。
- `just_audio` / `audio_session`：重查焦点、会话激活 / 释放、Android 前台服务类型、
  offload 能力位；行为变化先看 ADR-0035。
- `just_audio_media_kit` / `media_kit`：重查 Windows 标题 / 进程身份、libmpv 选项暴露
  （含 `prefetch-playlist` / `stop-screensaver`）、桌面输出丢失；必要项进 ADR-0036 或
  本页缺口小节。
- 生成式项目文件（Flutter 重新生成 Android / iOS / macOS / Windows / Linux 工程）是静默
  回归的高发源：每次 stable 工具链升级后至少跑一次本页的自动守卫与 `docs check`。

### 新增平台 / 播放后端时

- 在状态矩阵加一行，在平台小节按固定顺序插入（Android、iOS、macOS、Windows、Linux；
  新平台放在最后并说明顺序例外）。
- 写下：身份值 + 所有必须一致的位置；媒体会话面与后端；必需 / 禁止声明；自动守卫覆盖；
  人工验证 recipe；已知限制与缓解。
- 能自动断言的跨文件关系进 `test/architecture/platform_config_test.dart`；不能断言的
  明确写「手动」及原因。新增文档必须登记进 `docs/README.md`。

### 更新节奏

- 任何平台配置 / 身份 / 依赖变化时；
- 每次发布前的媒体人工验证；
- 每次 stable 工具链升级后（生成文件最容易漂移）；
- 评估结论变化时：缺口升级为 ADR（真正的架构决策）、实现 issue（测量证明有害且方案
  已知），或「明确不做 + 触发条件」（上游阻塞且成本大于收益）。
