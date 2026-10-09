# 歌词显示扩展规格（桌面歌词 / 通知栏·锁屏歌词 / 蓝牙歌词）

> 状态：**已实施（Android v1）**。实现映射见 §12；模拟器 / 真机待验证项见 §8。
> 关联：GitHub issue #1（spec：歌词显示扩展）。桌面平台歌词输出在 v1 仅预留抽象，
> 待 Flutter 官方多窗口 API 稳定后实现（§11）。

## 1. 背景与目标

Molia 当前只有在播放页内渲染的滚动歌词。桌面悬浮歌词、通知栏/锁屏歌词、蓝牙（车载）
歌词属于播放器标配能力，需求如下：

- 把"当前歌词行"按行同步投送到三个输出：Android 悬浮窗、媒体通知/锁屏、蓝牙 AVRCP；
- 支持翻译 / 罗马音（双语）在三个输出中显示；
- 可配置项对齐 LX Music 桌面歌词全套能力，并允许各输出独立开关；
- 输出层做成可插拔抽象，未来新增桌面窗口输出时不触碰播放 / 取词 / 配置链路。

**v1 非目标**：

- Linux / Windows 桌面歌词（等待 Flutter 官方 windowing API 进入 stable 后实现，见 §11）；
- 第三方状态栏模块（Lyricon / 墨·状态栏歌词）对接——用户已确认不做；
- iOS / Web 的歌词输出（入口隐藏，全部 no-op）；
- 逐字歌词渲染（yrc / lxlyric 数据存在，v1 仍按行显示）。

## 2. 术语

| 术语 | 含义 |
|---|---|
| **输出（LyricsOutput）** | 一个歌词投送目标：悬浮窗 / 媒体元数据（通知/锁屏与蓝牙两种 profile）/ 未来的桌面窗口。 |
| **歌词行跟踪器（LyricLineTracker）** | `position + lines → 当前行 / 下一行 / 扩展行` 的纯逻辑实现。 |
| **扩展行（extended lines）** | 与主行同时间轴的附加文本：翻译、罗马音。 |
| **元数据合成（MediaLyricComposer）** | 把歌名/歌手 + 当前行按 profile 配置合成为 `MediaItem` 字段的纯函数。 |
| **profile** | 媒体元数据的两套写入规则：通知/锁屏 profile、蓝牙 profile。 |
| **能力（capability）** | 输出在当前平台/环境下的可用状态：`unsupported / needsPermission / ready`（启用态由配置决定）。 |

## 3. 现状与接入点

| 关注点 | 现状 | 本规格的接入方式 |
|---|---|---|
| 播放进度 | `PlaybackProvider.position`（`ValueListenable<Duration>`，≤4Hz，独立通道） | 输出调度订阅它；无输出启用时不订阅。 |
| 播放状态 | `PlaybackProvider.snapshot`（`PlaybackSnapshot`，低频通知） | 用于曲目变化、播放/暂停、seek 后重算。 |
| 歌词会话 | `LyricsProvider`（`LyricsState`：`trackId/status/lines/isSynced/providerName`） | 新增翻译/罗马音字段；输出开启且曲目变化时由组合根触发 `load`（不再依赖播放页打开）。 |
| 取词 | `LyricsService` → `NetEaseProvider`（`WyLyric` 已抓 tlyric/rlyric）、`QQProvider`、`LRCLibProvider` | 扩展为结构化返回（原文 + 翻译 + 罗马音），缓存兼容。 |
| 系统媒体会话 | `LocalAudioHandler`（audio_service，Android/iOS/macOS） | 增加元数据覆盖（歌词行），不改 `LocalPlaybackService`。 |
| 设置持久化 | `DataSaverService`（SharedPreferences + ChangeNotifier）为范本 | 新 `LyricsDisplaySettings` 同模式，单 JSON 键 + 版本号。 |
| 分层约束 | `test/architecture/layering_test.dart` R1–R5 | 新代码放 `lib/services/`、`lib/providers/`，不新增违规。 |

## 4. 功能需求

### FR-1 双语歌词管道

1. `LyricProvider` 结构化返回：原文必填，翻译 / 罗马音可选；旧调用路径语义不变。
2. 数据来源：
   - 网易云：`WyLyric.fetch` 的 `tlyric` / `rlyric` 直接透传（内部已完成时间标签对齐）；
   - QQ：`GetPlayLyricInfo` 增加 `trans` 字段解析（base64 / 明文兼容，与 `lyric` 同规则）；
   - LRCLib：无翻译，留空；
   - LX / any-listen 路径（`source_manager.fetchLyric` 已有 `tlyric/rlyric/lxlyric`）：本版不改取词路径，只保证模型可承载。
3. `LyricsState` 新增 `translationLines` / `romaLines`（按时间戳对齐到主行）。
4. `LyricsCacheData` 持久化翻译 / 罗马音，**兼容旧缓存**（缺字段 = 无）。
5. 对齐规则：翻译行按 `parseLyrics` 解析（共用时间契约正则），以毫秒时间戳为键；
   主行取同时间戳的翻译（多条合并）；无匹配则该行翻译为空。V1 不做近似匹配。

### FR-2 行跟踪

1. 输入：`lines`（有序）、`translationLines`、`romaLines`、`position`、`offsetMs`。
2. 输出 `LyricsPresentation`：
   - `current`（含 `extended`：翻译 / 罗马音，受全局开关控制）；
   - `upcoming`（当前行后 N 行的主文本，供多行悬浮窗）；
   - 同步态与曲目信息（供无歌词回退）。
3. 偏移语义：`effectivePosition = position + offsetMs`，正值 = 歌词**提前**显示。
4. 未同步歌词（`isSynced=false`）行为由 `unsyncedBehavior` 决定：`title`（显示歌名）/
   `hide`（不显示）/ `firstLine`（显示首行）。
5. 行变化时输出；同一时间戳多行按原顺序全部保留。

### FR-3 Android 桌面悬浮歌词

**窗口与交互**

- `TYPE_APPLICATION_OVERLAY` 悬浮窗；透明背景；不抢焦点（`NOT_FOCUSABLE` + `NOT_TOUCH_MODAL`）。
- 拖动移动，位置以屏幕尺寸比例持久化（横竖屏换算、边缘吸附/夹取）。
- 锁定模式：窗口 `FLAG_NOT_TOUCHABLE`（点击穿透）；解锁才可拖动 / 点按。
- 点按弹出小控制条（各项可配置显隐）：播放/暂停、上一首、下一首、翻译开关、锁定、关闭。
- 权限：`SYSTEM_ALERT_WINDOW`。开启流程：设置页开关 → `canDrawOverlays` 检查 →
  未授权跳 `ACTION_MANAGE_OVERLAY_PERMISSION`；未授权不自动开启；回前台重读状态；
  权限被撤销时自动关闭开关并提示。
- 息屏：`freezeOnScreenOff`（默认开）——原生上报屏幕状态，息屏期间停止下发与重绘，
  亮屏恢复并立即刷新（对齐 LX `isAutoPause` 语义，不暂停音频）。

**渲染**

- 行内容：当前行（主文本）、扩展行（翻译 / 罗马音，字号 = 主字号 × 0.8）、
  其后 `maxLines - 1` 行 upcoming 主文本；`singleLine=true` 时只显示当前行。
- 颜色语义：当前行 = `playedColor`（默认白），其余行 = `unplayedColor`（默认 70% 白），
  文字阴影 = `shadowColor`（默认 60% 黑）；全局 `opacity` 作用于整个视图。
- 行切换动画：`showToggleAnimation`（默认开）——淡入/上移；关闭则直切。
- 无歌词：`noLyricsBehavior = title | hide`（默认 `title`，显示歌名）。
- 暂停：`pauseBehavior = keep | clear | title`（默认 `keep`）。
- 所有策略计算在 Dart 侧完成，原生只渲染 + 交互（保持"原生哑渲染"）。

### FR-4 通知栏 / 锁屏歌词（免模块）

- 通过媒体会话元数据实现：`MediaItem.displaySubtitle` 默认写入当前行，
  Android 13+ 媒体通知与锁屏第二行即显示歌词。
- 字段、格式、是否含翻译、暂停行为可配置（见 §6）。
- 纯播放器原则不破坏：歌名、歌手等基础信息永远保留；歌词只覆盖所选字段。

### FR-5 蓝牙（车载）歌词

- 车机 AVRCP 读取媒体会话元数据，写入字段可配置（默认 `artist`）。
- 生效条件：`bluetooth.enabled` 且（`onlyWhenA2dp=true` 时 A2DP 已连接）；
  断开自动还原；两 profile 同字段冲突时蓝牙优先。
- 更新频率：行变化（默认）/ 1s / 2s，可配置。
- **已知副作用（用户已确认接受）**：同一份元数据驱动通知/锁屏，蓝牙歌词生效时
  手机通知/锁屏也同步显示歌词行，无法拆分。

### FR-6 配置与设置 UI

- 设置页新增「歌词显示」入口 → 子页（沿用 `cache_management_page.dart` 的导航模式）：
  共享项 + 三个分组（桌面歌词 / 通知栏·锁屏歌词 / 蓝牙歌词）。
- 分组按输出能力渲染：`unsupported` 时隐藏（v1 在 iOS/Web/桌面隐藏全部三组）。
- 桌面歌词分组提供「样式预览」卡片（Flutter 渲染，与悬浮窗语义一致）；
  这是未来桌面渲染端复用的第一块积木。
- 文案全部走 l10n（en/zh）；组件用 M3E（含圆角图标、色彩契约）。

### FR-7 平台能力抽象（预留桌面）

1. `LyricsOutput` 接口（§5.2）为输出端唯一契约；Android 悬浮窗、媒体元数据是 v1 实现。
2. 未来桌面输出 = 新增一个 `LyricsOutput` 实现（副窗口/原生窗口渲染）+
   注册能力；`tracker / composer / settings / provider` 不改。
3. 配置模型平台无关：颜色 = ARGB int、宽度/位置 = 0..1 比例、字号 = 逻辑 px；
   Android 侧自行换算为 sp/px。
4. 平台差异只允许出现在 `*_io.dart` / `*_stub.dart` 条件导入实现内。

## 5. 设计

### 5.1 模块图

```
PlaybackProvider ── position / snapshot ─┐
LyricsProvider ── lines / translation ───┤
                                          ▼
                          LyricsDisplayProvider（lib/providers）
                            ├─ LyricLineTracker（纯逻辑）
                            ├─ 输出调度：行变化 / 播放态变化才下发
                            │    ├─ DesktopLyricsOutput ── Android MethodChannel → 悬浮窗
                            │    │      （桌面平台 stub：capability=unsupported，TODO §11）
                            │    ├─ MediaLyricOutput（通知/锁屏 profile）
                            │    └─ BluetoothLyricOutput（蓝牙 profile）
                            │           └─ 均经 MediaLyricComposer → LocalAudioHandler.setLyricOverride
                            └─ AudioRouteMonitor（A2DP 状态，Android）
```

原则：策略全部在 Dart（行定位、偏移、回退、格式、门控）；原生只做渲染与交互事件上报。

### 5.2 接口契约

```dart
/// 输出能力（启用态由配置决定，输出只报告平台/权限事实）。
enum LyricsOutputCapability { unsupported, needsPermission, ready }

/// 一次投送的行数据（策略已应用，接收端直接展示）。
class LyricsPresentation {
  final String title;          // 歌名（无歌词/暂停回退用）
  final String line;           // 当前行主文本（'' = 无）
  final List<String> extended; // 翻译 / 罗马音
  final List<String> upcoming; // 其后行主文本（多行显示用）
  final bool isPlaying;
  final bool hasLyrics;
  final String? trackId;
}

abstract class LyricsOutput {
  String get id;                       // 'desktop_overlay' | 'notification' | 'bluetooth'
  LyricsOutputCapability get capability;
  Future<void> start(LyricsDisplaySettings settings); // 幂等
  Future<void> apply(LyricsPresentation presentation);
  Future<void> clear();
  Future<void> stop();
}
```

`LyricsDisplayProvider` 对外（供设置页/播放页）：

- `capabilityOf(String id)`、`settings`（ChangeNotifier）、`requestPermission(id)`；
- `a2dpConnected`（Android 蓝牙分组展示用）；
- `previewPresentation`（设置页预览用）。

### 5.3 行跟踪算法

1. 周期：随 `position` 通道 tick（≤4Hz）重算；同时响应 seek、切歌、歌词到达、暂停/恢复。
2. 同步歌词：复用 `lyricLineIndexAt`（二分，`lib/models/lyric_line.dart`）。
3. 去重：仅当 `(trackId, index, isPlaying, linesVersion)` 变化时才向输出下发。
4. `extended`：`translationEnabled` / `romaEnabled` 独立开关；空文本过滤。
5. `upcoming`：当前行后最多 `maxLines - 1` 行；未同步 / 无歌词为空。

### 5.4 元数据合成（MediaLyricComposer）

输入：原始 `MediaItem` 字段、`LyricsPresentation`、两 profile 配置、`a2dpConnected`。

| 规则 | 说明 |
|---|---|
| 字段 | `notification.target`（默认 `subtitle`）、`bluetooth.target`（默认 `artist`）可选 `subtitle/artist/title/album`。 |
| 格式 | `lyric`（默认）/ `lyricTitle`（`歌词 · 歌名`）/ `titleLyric`（`歌名 · 歌词`）。 |
| 翻译 | profile 各自 `includeTranslation`；拼接 `原文 / 翻译`。 |
| 蓝牙门控 | `enabled && (!onlyWhenA2dp || a2dpConnected)`；断开或关闭时按暂停行为回退。 |
| 冲突 | 两 profile 写同一字段时蓝牙优先；其余字段各自独立。 |
| 暂停 / 无歌词 | `pauseBehavior = keep / title / clear`（clear = 恢复原始元数据，不写该字段）。 |
| 去重 | 合成结果变化时才更新 `MediaItem`（复用 handler 现有去重思想）。 |

`LocalAudioHandler` 增加 `setLyricOverride(LyricMetadataOverride?)`：保存覆盖值，
`_syncFromService` / `_toMediaItem` 合成时应用；原始字段始终来自 `SourceTrack`。

### 5.5 Android 悬浮窗实现

- 文件：`lyrics/LyricsOverlayController.kt`（WindowManager 生命周期 + 位置持久化）、
  `lyrics/LyricsOverlayView.kt`（自绘文本/动画/控制条/触摸）、
  `lyrics/LyricsChannelHandler.kt`（通道 + 权限 + A2DP + 屏幕状态）、
  `MainActivity.kt` 注册通道与 `onResume` 权限回读。
- 位置持久化：原生 `SharedPreferences`（屏幕可用空间比例）；拖动结束由原生直接保存。
- 布局方向变化：`OrientationEventListener` 重新夹取位置。

### 5.6 A2DP 监测

`AudioManager.getDevices(GET_DEVICES_OUTPUTS)` 判断 `TYPE_BLUETOOTH_A2DP` +
`registerAudioDeviceCallback` 监听变化；无需蓝牙权限；经通道推送给 Dart。

### 5.7 配置模型（SharedPreferences 单 JSON 键）

`lyrics_display_settings_v1`：`{"version":1, ...}`；读取时与默认值合并（向前兼容新增键）。

| 键 | 类型 | 默认 | 范围 / 取值 | 生效范围 |
|---|---|---|---|---|
| `offsetMs` | int | 0 | -500..500 | 共享 |
| `translationEnabled` | bool | true | | 共享 |
| `romaEnabled` | bool | false | | 共享 |
| `unsyncedBehavior` | enum | title | title/hide/firstLine | 共享 |
| `desktop.enabled` | bool | false | | 桌面歌词 |
| `desktop.fontSize` | double | 22 | 12..48（Android 侧按 sp 解释） | 桌面歌词 |
| `desktop.opacity` | double | 1.0 | 0.2..1.0 | 桌面歌词 |
| `desktop.playedColor` | int | 0xFFFFFFFF | ARGB | 桌面歌词 |
| `desktop.unplayedColor` | int | 0xB3FFFFFF | ARGB | 桌面歌词 |
| `desktop.shadowColor` | int | 0x99000000 | ARGB | 桌面歌词 |
| `desktop.widthPercent` | double | 100 | 40..100 | 桌面歌词 |
| `desktop.singleLine` | bool | false | | 桌面歌词 |
| `desktop.maxLines` | int | 3 | 1..5（非 singleLine 时） | 桌面歌词 |
| `desktop.textAlignX` | enum | center | left/center/right | 桌面歌词 |
| `desktop.textAlignY` | enum | center | top/center/bottom | 桌面歌词 |
| `desktop.lock` | bool | false | | 桌面歌词 |
| `desktop.freezeOnScreenOff` | bool | true | | 桌面歌词 |
| `desktop.pauseBehavior` | enum | keep | keep/clear/title | 桌面歌词 |
| `desktop.noLyricsBehavior` | enum | title | title/hide | 桌面歌词 |
| `desktop.showToggleAnimation` | bool | true | | 桌面歌词 |
| `desktop.controls` | map | 全开 | playPause/previous/next/translation/lock/close → bool | 桌面歌词 |
| `desktop.position`（原生） | — | 底部居中 | 窗口位置由原生侧按屏幕可用空间比例持久化；「重置位置」可恢复默认 | 桌面歌词 |
| `notification.enabled` | bool | false | | 通知/锁屏 |
| `notification.target` | enum | subtitle | subtitle/artist/title/album | 通知/锁屏 |
| `notification.format` | enum | lyric | lyric/lyricTitle/titleLyric | 通知/锁屏 |
| `notification.includeTranslation` | bool | true | | 通知/锁屏 |
| `notification.pauseBehavior` | enum | title | keep/title/clear | 通知/锁屏 |
| `bluetooth.enabled` | bool | false | | 蓝牙 |
| `bluetooth.onlyWhenA2dp` | bool | true | | 蓝牙 |
| `bluetooth.target` | enum | artist | subtitle/artist/title/album | 蓝牙 |
| `bluetooth.format` | enum | lyric | lyric/lyricTitle/titleLyric | 蓝牙 |
| `bluetooth.includeTranslation` | bool | false | | 蓝牙 |
| `bluetooth.updateIntervalMs` | int | 0 | 0/1000/2000（0 = 仅行变化） | 蓝牙 |
| `bluetooth.pauseBehavior` | enum | title | keep/title/clear | 蓝牙 |

### 5.8 通道协议（Android）

通道：`top.stillmisty.molia/lyrics`

| 方向 | 方法 / 事件 | 载荷 | 说明 |
|---|---|---|---|
| Dart→原生 | `desktop.isSupported` | → bool | 平台/ROM 能力。 |
| | `desktop.canDrawOverlays` | → bool | 权限状态。 |
| | `desktop.openOverlayPermission` | — | 跳系统授权页。 |
| | `desktop.show` | style config map | 显示悬浮窗（已授权时）。 |
| | `desktop.update` | `{title,line,extended[],upcoming[],isPlaying,hasLyrics}` | 策略已应用，直接展示。 |
| | `desktop.setConfig` | style config map | 样式 + 锁定点击穿透即时生效。 |
| | `desktop.hide` | — | 关闭并释放窗口。 |
| | `desktop.resetPosition` | — | 清除原生持久化并回到默认位置。 |
| | `audioRoute.isA2dpConnected` | → bool | 初始值。 |
| 原生→Dart | `desktop.onAction` | `{action}` | playPause/previous/next/toggleTranslation/lock/close。 |
| | `desktop.onPermissionChanged` | `{granted}` | 权限被撤销时上报（回前台复查）。 |
| | `desktop.onScreenState` | `{on}` | 息屏冻结用。 |
| | `audioRoute.onA2dpChanged` | `{connected}` | 连接状态变化。 |

> 悬浮窗拖动位置由原生侧直接持久化，不经通道回传。

## 6. 非功能需求

- **性能**：无输出启用时不订阅 position；行跟踪 O(log n)；通道流量只含行/状态变化
  （不流式发送 position）；原生不轮询。
- **内存**：v1 不新增 Flutter 引擎 / 常驻线程；A2DP 回调用系统回调。
- **安全**：唯一新权限 `SYSTEM_ALERT_WINDOW`（特殊权限，走系统设置授权）；
  不新增网络访问；悬浮窗不接收文件/不执行外部输入。
- **稳定性**：任一输出失败只降级该输出（日志 + capability 状态），不得影响播放与 UI。
- **兼容**：旧歌词缓存无翻译字段可读；旧版本设置键不存在时全量默认值。
- **可测试**：tracker / composer / settings / 调度逻辑均为纯 Dart，单测覆盖；
  原生交互留模拟器与真机清单。

## 7. 任务拆解与验收（DoD）

### Phase 1：核心（纯 Dart）

- [ ] `LyricProvider` 结构化返回 + 网易云 / QQ 翻译透传 + LRCLib 留空
- [ ] `LyricsState` / `LyricsCacheData` 增字段 + 旧缓存兼容
- [ ] `LyricLineTracker`（对齐 / 偏移 / 未同步 / upcoming）
- [ ] `LyricsDisplaySettings`（JSON 持久化 + 默认值合并）
- [ ] `LyricsOutput` 抽象 + `LyricsDisplayProvider` 骨架（调度、去重、能力状态）
- [ ] 单测全绿；`flutter analyze` 0 error / 0 warning；架构扫描通过

**DoD**：无 UI、无原生改动；播放页现有歌词行为不回归。

### Phase 2：Android 悬浮窗

- [ ] Kotlin 窗口 / 视图 / 通道 / 权限 / 息屏冻结
- [ ] 样式与交互（对齐 §4 FR-3 与 §5.7 配置）
- [ ] 设置子页（桌面歌词分组 + 预览卡片）+ l10n
- [ ] 模拟器截图验证：显示、拖动、锁定、控制条、权限拒绝/撤销、横竖屏

**DoD**：模拟器全流程可用；Web 构建通过且入口隐藏。

### Phase 3：通知/锁屏 + 蓝牙

- [ ] `MediaLyricComposer` + `LocalAudioHandler.setLyricOverride`（叠加现有去重）
- [ ] `AudioRouteMonitor`（A2DP）+ 蓝牙门控 / 回退 / 还原
- [ ] 设置子页两个分组 + A2DP 状态展示
- [ ] 单测：合成规则、优先级、门控、暂停回退
- [ ] 模拟器验证：通知栏 / 锁屏第二行变化；A2DP 字段映射留真机项

**DoD**：关闭输出后元数据完全还原；暂停/停止不残留歌词字段。

### 收尾

- [ ] 播放页歌词快捷操作栏加「桌面歌词」开关（可选）
- [ ] `docs/architecture.md`、`AGENTS.md` 同步；本文件更新为 as-built
- [ ] 全量验证：`flutter analyze` / `flutter test` / `flutter build web --release` /
      桌面端集成测试保持可跑

## 8. 测试计划

| 层 | 文件 | 覆盖 |
|---|---|---|
| 单测 | `test/lyric_line_tracker_test.dart` | 行边界、同时间戳、翻译对齐、偏移、未同步、upcoming |
| | `test/media_lyric_composer_test.dart` | 字段映射、格式、翻译拼接、A2DP 门控、优先级、暂停回退 |
| | `test/lyrics_display_settings_test.dart` | 默认值、JSON 往返、缺键合并、版本兼容 |
| | `test/lyrics_display_provider_test.dart` | 曲目切换、去重、能力状态、输出启停 |
| | `test/lyric_providers_translation_test.dart` | 网易云 / QQ 翻译解析（夹具）、缓存兼容 |
| | `test/lyrics_display_channel_test.dart` | 通道协议编解码（`TestDefaultBinaryMessenger`） |
| 架构 | `test/architecture/*` | 分层 / 图标 / 色彩扫描保持全绿 |
| 模拟器 | `tool/agent/*` | 悬浮窗全交互 + 通知/锁屏歌词 + 截图留档 |
| 真机 | 清单 | A2DP 车载显示（字段默认值微调）、ROM 通知副标题差异、权限撤销 |

## 9. 风险与开放问题

1. **Flutter 官方多窗口**：stable 3.47.6 的 `flutter config --help` 明确标注
   `--enable-windowing` "applies only to the master channel"；框架源码标注 production 禁用、
   随时破坏性变更，且现属性面（size/title/min/max/fullscreen/resizable）**不含**
   置顶 / 透明 / 无边框 / 点击穿透 / 不占任务栏。桌面输出实现时大概率仍需平台逃逸口代码，
   工作量按此预期评估。跟踪：flutter/flutter#30701。
2. **AVRCP 字段差异**：车机对 `artist` / `displaySubtitle` 读取行为不一，默认字段以真机实测微调。
3. **ROM 差异**：Android 13+ 媒体通知副标题展示受 ROM 定制影响；必要时提供字段选择。
4. **主工作树 WIP**：合并本分支到 `main` 前，主工作树里 `lib/playback/local_audio_handler.dart`
   等未提交改动需先提交或暂存——本分支也在同一文件上叠加了歌词元数据覆盖。
5. **R8**：新增 Kotlin 类均由 `MainActivity` 可达，无需额外 keep 规则；
   若未来接入第三方 SDK（如 Lyricon）需补 keep。
6. **开源许可**：本规格不引入任何新第三方依赖。

## 10. 附录：LX Music 桌面歌词配置对照

| LX 配置 | 本规格键 | 备注 |
|---|---|---|
| `desktopLyric.enable` | `desktop.enabled` | |
| `desktopLyric.isLock` | `desktop.lock` | 锁定 = 点击穿透 |
| `desktopLyric.width` | `desktop.widthPercent` | |
| `desktopLyric.maxLineNum` | `desktop.maxLines` | |
| `desktopLyric.isSingleLine` | `desktop.singleLine` | |
| `desktopLyric.textSize` | `desktop.fontSize` | LX 存 0.1 倍值；本项目存 sp 数值（Android 侧按 sp 解释） |
| `desktopLyric.opacity` | `desktop.opacity` | |
| `unplayColor/playedColor/shadowColor` | `desktop.unplayedColor/playedColor/shadowColor` | |
| `desktopLyric.textPosition.x/y` | `desktop.textAlignX/textAlignY` | |
| `desktopLyric.isShowToggleAnima` | `desktop.showToggleAnimation` | |
| 视图位置（原生持久化） | — | 原生按屏幕比例保存；「重置位置」恢复默认 |
| `desktopLyric.isAutoPause`（息屏） | `desktop.freezeOnScreenOff` | 冻结歌词更新，不暂停音频 |
| 翻译 / 罗马音开关 | `translationEnabled` / `romaEnabled` | 本项目为全局共享项 |
| —（LX 无） | `desktop.pauseBehavior` / `noLyricsBehavior` | 本项目新增 |
| —（LX 无） | `notification.*` / `bluetooth.*` | 本项目新增 |

## 12. 实现映射（as-built）

| 模块 | 文件 | 说明 |
|---|---|---|
| 双语管道 | `lib/services/lyrics/lyric_provider.dart`、`lib/services/lyrics/netease_provider.dart`、`lib/services/lyrics/qq_provider_mobile.dart`、`lib/services/lyrics_service.dart`、`lib/providers/lyrics_provider.dart`、`lib/models/lyric_line.dart` | `LyricsPayload`（原文+翻译+罗马音）、`LyricsState.translations/romas` 时间戳对齐、缓存兼容 |
| 配置 | `lib/services/lyrics_display/lyrics_display_settings.dart` | 单 JSON 键 `lyrics_display_settings_v1` |
| 行跟踪 | `lib/services/lyrics_display/lyric_line_tracker.dart` | 纯逻辑（偏移/未同步/扩展行/后续行） |
| 输出契约 | `lib/services/lyrics_display/lyrics_output.dart` | `LyricsOutput` / `InteractiveLyricsOutput` / `LyricsPresentation` |
| 调度 | `lib/providers/lyrics_display_provider.dart` | 去重投送、自动取词、动作分发、能力查询 |
| 桌面歌词（Dart） | `lib/services/lyrics_display/desktop_lyrics_output.dart`、`lyrics_channel.dart` | 通道封装 + 暂停/无歌词回退映射 |
| 桌面歌词（原生） | `android/.../lyrics/LyricsChannelHandler.kt`、`LyricsOverlayController.kt`、`LyricsOverlayView.kt`、`MainActivity.kt`、`AndroidManifest.xml` | 悬浮窗渲染/拖动/锁定/控制条/息屏冻结/A2DP 监测 |
| 媒体元数据 | `lib/services/lyrics_display/media_lyric_composer.dart`、`media_lyric_output.dart`、`lib/playback/local_audio_handler.dart` | 通知/锁屏 + 蓝牙 profile 合成 → `MediaItem` 覆盖 |
| 设置页 | `lib/pages/lyrics_display_page.dart`、`lib/pages/settings_page.dart` | 三分组 + 预览 + 权限引导 |
| 测试 | `test/lyric_line_tracker_test.dart`、`test/services/media_lyric_composer_test.dart`、`test/services/lyrics_display_settings_test.dart`、`test/services/lyrics_display_provider_test.dart`、`test/services/desktop_lyrics_output_test.dart`、`test/services/audio_route_monitor_test.dart`、`test/services/lyrics_cache_translation_test.dart`、`test/lyrics_provider_translation_test.dart` | 单一新 seam：`LyricsOutput` 假输出 |
