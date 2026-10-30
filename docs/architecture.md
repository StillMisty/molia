# Molia 架构说明（as-built）

> 状态：**已实施**。本文描述当前实际架构（分层、接口、通知策略、音源引擎、M3E）。
> 历史提案已随「纯播放器化」移除，不再适用。
> 分支：`main`。

## 1. 分层与依赖方向

```
┌───────────────────────────────────────────────────────────────┐
│ UI（lib/pages, lib/widgets）                                   │
│   只依赖 providers + 领域模型；M3E 组件 + material_ui 基础件     │
└──────────────▲────────────────────────────────────────────────┘
               │ Selector / ValueListenableBuilder（低频快照 + 高频独立通道）
┌──────────────┴────────────────────────────────────────────────┐
│ 应用状态层（lib/providers/*）                                   │
│   PlaybackProvider（facade 代理）/ SearchProvider /              │
│   ThemeProvider（取色 / 纯黑 / 字体）                            │
│   禁止 import main.dart；提示走注入的 UiMessenger                │
└──────────────▲────────────────────────────────────────────────┘
               │
┌──────────────┴────────────────────────────────────────────────┐
│ 领域层（lib/domain/**，纯 Dart）                                 │
│   models: Track / PlaybackSnapshot / SearchResult / SourceFailure │
│   ports: MusicSource / SourceRegistry / PlaybackBackend /         │
│          PlaybackFacade / UiMessenger / StateListenable           │
└──────────────▲────────────────────────────────────────────────┘
               │ implements
┌──────────────┴────────────────────────────────────────────────┐
│ 数据/适配层（lib/data/**, lib/sources/**, lib/playback/**）       │
│   catalog: SourceManagerMusicSource / SourceRegistryImpl /        │
│            CatalogService（缓存 + 错误归一化）                     │
│   playback: LocalPlaybackBackend / DefaultPlaybackFacade          │
│   cache: RequestCache（single-flight + LRU + TTL）                │
│   sources: SourceManager + builtin/lx/any_listen                  │
└───────────────────────────────────────────────────────────────┘
```

硬性规则（`test/architecture/layering_test.dart` 扫描 import 强制执行）：

1. `lib/domain/**` 禁止 Flutter/provider/HTTP/其它 lib 层；
2. `lib/data/**`、`lib/sources/**`、`lib/playback/**` 禁止 providers/pages/widgets/main；
3. `lib/providers/**` 禁止 import `lib/main.dart`；
4. `lib/main.dart` 是唯一 composition root，不允许被其它 lib 文件 import；
   接线圈按子系统拆在 `lib/app/bootstrap/**`（catalog / 本地数据 / 资料库 /
   playback / sync / AI / 歌词显示 / 桌面 / 更新 / Provider 树 / 首帧收尾
   各 stack builder：依赖进、装好的子系统出；初始化顺序与前向引用关在 builder
   内，main() 只做顺序调用 + runApp）；应用壳（MyThemedApp / 导航栏 / 顶栏 /
   迷你条）与全局 key 在 `lib/app/app_shell.dart`，桌面骨架（顶栏工具条 /
   恒折叠侧栏 / 常驻底栏播放条）在 `lib/app/desktop/**`，测试可直接挂载
   （`MyApp(desktopShell: true/false)` 可强制骨架，默认按平台判定）；
5. UI 禁止 import `lib/sources/**`（Wave 7 后白名单已清空，新增违规必须修复）。

## 2. 领域层

- **模型**（不可变 + 可靠 `==`）：
  - `Track` / `TrackId(sourceKey,id)` / `Artist` / `Artwork` / `AudioQuality`；
    `Track.payload` 承载源脚本原始对象（原 `SourceTrack.raw`），**只在 data/sources 传递、必须原样回传**；
    raw 的平台 id 取键（含 B 站 `bvid` 优先、`aid` 兜底）统一在
    `lib/sources/raw_track.dart`；
  - `PlaybackSnapshot` / `BackendSnapshot` / `PlaybackRequest` / `PlaybackContext`；
    `PlaybackSnapshot.next` 是后端按当前模式解析出的下一首（shuffle 单曲内稳定，
    列表循环队尾回绕），`previous` 是实际播放顺序最近一首（无则队列前一位，
    列表循环队首回绕），`previousOfPrevious` 是再上一首（播放顺序次顶 → 队列前一位链），
    `upNext` 是队列顺序（列表循环回绕）；
  - `SearchQuery` / `SearchResult<T>`；`SourceFailure(kind/l10nKey/retryable)`；
  - `Comment` / `CommentPage`（评论正文 / 时间 / IP 归属 / 点赞 / 引用 / 楼中楼，
    `CommentKind` 区分热门与最新）；
  - `Album`（专辑 id / 名称 / 歌手 / 封面 / 年份 / 曲目列表 / 分页）；
  - `ArtistSummary` / `ArtistDetail`（歌手搜索条目 / 歌手页数据：头像、简介、曲目、分页）；
  - `LyricHit`（按歌词搜歌命中：领域 `Track` + 命中片段）；`SearchKind`（song / artist / lyric）；
  - `SourceDescriptor` / `SourceCapabilities`：`SourceDescriptor` 是渠道的**唯一形状**
    （key / displayName / kind / capabilities / enabled / discoverable / order），
    由 `SourceProfile.toDescriptor` 投影一次；旧的 `SourceEntry` / `SourceOption`
    双胞胎已删除。
- **端口**：`MusicSource`（search / `resolve`（返回 `PlayableStream`：uri + 请求头 +
  有效期）/ lyrics / artwork / comments / collection / searchArtists / searchLyrics）、`SourceRegistry`
  （descriptors/byKey/forTrack/setOrder/changes）、`PlaybackBackend`（state ValueListenable +
  load/play/pause/seek/next/previous/setMode/stop）、`PlaybackFacade`（snapshot + position +
  控制方法）、`UiMessenger`（showMessage/showFailure）、`StateListenable<T>`。

## 3. 数据/适配层

- **Catalog**：`SourceManagerMusicSource` 包装 `SourceManager` 按 key 分发；
  `SourceRegistryImpl` 构建 `SourceDescriptor`（排序转发 `lx_source_order`）；
  `CatalogService` 提供 `search`（缓存 5min）、`searchArtists` / `searchLyrics`
  （同一 5min 缓存实例，key=`search:{source}:artist|lyric:{keyword}:{page}:{limit}`，
  前缀失效与单曲搜索共用）与 `resolve`（缓存 10min，key=`url:{source}:{md5(canonical payload)}:{quality}`，
  失败不缓存，可 `invalidatePrefix`），并把异常归一化为 `SourceFailure`；
  `resolve` 返回 `PlayableStream`（uri + headers + expiresIn），B 站等需要
  `Referer` / UA 的平台由这一层原样保留请求头。
  目录详情分页（专辑 / 歌手 / 评论）共用 `lib/data/catalog/cached_page_service.dart`
  的 `CachedPageService<T, Q>`：single-flight + LRU + TTL + `SourceFailure` 归一化 +
  前缀失效 / 计数只此一份；三个类型化服务只提供取数函数与 key / 前缀，容量与 TTL
  在各自适配器声明（专辑 / 歌手 64 条 · 10min，评论 96 条 · 5min）。
- **Playback**：`LocalPlaybackBackend` 组合 `LocalPlaybackService`（值变才发快照；
  播放顺序栈 `PlaybackOrder` 记录实际播放过的下标，供快照 `previous`）；
  `DefaultPlaybackFacade` 合并快照通知（`==` 去重）、把进度拆到独立 `position`
  `ValueNotifier`（≥250ms 去重、换曲/seek 直接对齐、**不进快照**）、错误归一化。
  `PlaybackProvider` 对外只暴露领域 `PlaybackSnapshot` + position 通道：
  真实播放取 facade 快照；冷启动恢复态由 `PlaybackSessionCoordinator`
  （`lib/playback/`）构造覆盖快照（`isPlaying=false`）。next / previous /
  previousOfPrevious / upNext 的唯一推导是
  `lib/playback/queue_projection.dart::projectQueue`（真实播放与恢复态
  共用）：恢复态没有洗牌排列与播放顺序栈，显式留空 `QueueOrder`——shuffle 的
  next 为 null、upNext 为空（不拿下标近似），previous / previousOfPrevious
  按队列前一位依次回退。
  恢复播放：会话模式先落到后端（shuffle 洗牌顺序依赖装载前模式）；
  seek 落地前进度通道继续显示恢复进度（不闪回 0）；装载期间用户 seek 优先；
  生命周期 `paused` 强制落盘会话。旧「远程播放风格 Map 兼容层」
  （facade `compat*` / service `currentTrackMap` 等）已删除。
  播放会话模块是**恢复态 ↔ live 的唯一交接点与 `PlaybackSessionStore` 的唯一
  写者**：三阶段状态机 `idle / restored / live`，命令按阶段路由（provider 不再
  分叉，只按 `PlaybackCommandOutcome` 的变化域决定通知类别）；恢复态快照与进度
  覆盖值在这里构造。会话只存在**主库** `molia_database_v2.sqlite` 的两张单行表
  （`playback_session_payloads` 整份队列 JSON / `playback_session_cursors`
  index + position + savedAt），没有独立 session DB、cursor 文件或 prefs 会话：
  - 只在**具体动作**落盘：播放 / 暂停、seek 落点（拖拽只在结束提交）、切歌 /
    系统 next / previous、队列 / 模式 / 上下文变化（含 AI 追加）、曲末完成
    （单曲循环 / 列表循环单曲重播）、停止、换源、退后台、窗口隐藏 / 最小化到
    托盘、退出；没有 1Hz / 15s / 1min 定时写；
  - 队列 / 模式 / 上下文变化才写 payload，且与 cursor 同一事务；切歌 / 暂停 /
    seek 只 UPDATE cursor 单行，绝不重写 MB 级 payload；
  - `savedAt` 随动作刷新；长时间无动作时接受远端旧会话可能压过本地（不重新
    引入定时器）。`pendingWrite` 仍串行化写入，`clear` 不会被在途保存复活。
  改变会话的命令（暂停 / seek / 切歌 / 模式 /
  停止 / 换源）返回前等 `pendingWrite`（已提交语义）；系统媒体 handler 与 UI 共用
  `PlaybackCommandPort`（`lib/playback/playback_commands.dart`），恢复态回落与
  落盘时机只在协调者实现一次，handler 不直写服务；provider 的失败重试与自动
  换源写回也走这条命令面（`playQueueIndex` / `replaceQueueTrack`；库内 / 手动
  换源走同一实现的 `replaceTrack` + `PlaybackReplaceScope.liveAndRestored`，
  自动换源固定 `liveOnly`），不直写 facade；壳层 paused 与桌面退出共用
  `PlaybackProvider.suspendPlaybackSession()`（桌面 `quitApp` 有界等待 2s 后
  继续退出）。退出顺序固定为「会话落盘 → 音频收尾（暂停 + 释放播放器，有界
  500ms）→ 统计落盘（有界 500ms）→ 销毁窗口」：会话必须先把最后一段进度取
  下来，音频收尾要在销毁窗口前停掉设备，否则 Windows 上进程在 libmpv 仍出
  数据时结束会爆音；统计只在动作时写库，退出必须等最后一次写入完成。
  系统媒体控制与恢复态切歌键由组合根接到会话模块（不再直连
  provider）。跨设备同步只经 `PlaybackSessionSyncPort`（`lib/domain/ports/playback_session_sync.dart` 的
  `loadRaw` / `applyRemote` / `clearRemote`）认识会话，唯一实现是协调者：远端
  应用 / 删除与本地保存 / 清除共用同一个 `PlaybackSessionStore` 与同一条
  `pendingWrite` 队列，不会出现第二个写队列插队或复活已清除的会话。
  播放副作用的扇出（最后播放 / 桌面小组件 / 播放历史 /
  预取 / 补封面 / 通知权限）唯一实现在 `lib/services/playback_observer.dart`
  （Playback observer）：直连 facade 快照通道、由组合根挂接，不经 provider 的
  节流通知（避免合并窗口丢中间曲目副作用）；睡眠定时仍属 `PlaybackProvider`。
  与 `PlayStatisticsService` / `ArtworkThemeSync` 同为观察者形态。
- **播放传输语义**：`lib/widgets/playback_transport.dart` 是播放页迷你 / 播放页
  桌面排 / 桌面底栏 / 壳层顶栏共用的控制语义（播放暂停 / 上一首 / 下一首 /
  模式图标与文案 / seek 宿主）：`hasTrack` 启用判据、图标与语义标签、触感与
  provider 命令只此一份；各宿主只保留按钮变体 / 尺寸 / 布局。`PlaybackSeekBar`
  持有 `SeekPreviewController` 生命周期与低频 `Selector`，宿主只选时间标签档位。
  无曲目时播放 / 切歌禁用，模式仍可切换。
- **音频焦点与定时关闭**：`AudioFocusGuard`（`lib/playback/audio_focus_guard.dart`，
  受设置「与其他应用同时播放」控制，默认开：Android 忽略焦点丢失、iOS / macOS 用
  `mixWithOthers` 混播；关闭后其他应用出声 → 暂停，系统可续播时自动补播；
  `androidWillPauseWhenDucked` 把 duck 升级为暂停语义）由 `LocalPlaybackService`
  持有。just_audio 的内建中断处理已关闭（`handleInterruptions: false`），耳机拔出
  由服务自己订阅 `becomingNoisyEventStream`；该流在丢失音频焦点后可能被
  audio_session 反注册，另以 `devicesChangedEventStream` 兜底（只对非内置输出
  设备被移除暂停，规则见 `audio_output_policy.dart`）；倒计时定时关闭为**绝对 deadline**
  （tick / 快照变化 / 回前台三路补触发），并按平台挂 `SleepTimerAlarm`
  （`lib/services/sleep_timer_alarm*.dart` → Android `SleepTimerChannelHandler` /
  iOS `SleepTimerChannelHandler.swift`）：熄屏 / Doze 下 Dart timer 被节流或
  冻结时，由原生定时器到点唤醒 Dart 执行暂停；原生不可用（桌面 / 测试）
  自动退化为纯 Dart timer。「播完当前歌曲」不靠进度通道判定曲末：
  `LocalPlaybackService` 在 `ProcessingState.completed` 时先发
  `trackCompletions`，并通过 `setStopAfterCurrentTrack` 在自动切歌前停住；
  熄屏时位置 tick 被节流也不会把自然播完误判成手动切歌。Windows/Linux 的
  media_kit 自然 EOF 可能不上报 completed，桌面后端另以曲末位置采样与曲末
  解码错误兜底（见已知坑 78）。
- **移动端后台功耗策略**：`PlaybackPowerPolicy`
  （`lib/playback/playback_power_policy.dart`）回答「播放链路与后台工作要不要按
  前台节拍工作」，与 `AppPresence`（桌面窗口可见性）**完全独立**：移动端退后台
  不写入 `AppPresence`，避免污染托盘语义。组合根创建唯一实例并同时注入播放栈、
  观察者、歌词显示栈与下一首预载；`AppLifecycleListener` 只在 Android / iOS 接线
  （`onResume` → 前台，`onPause` / `onHide` → 后台），桌面保持默认前台；启动时若
  `lifecycleState` 已是 paused / hidden 先置后台。
  - 位置采样（`LocalPlaybackService`）：前台或桌面歌词可能展示
    （`LyricsChannel.isSupportedPlatform && lyricsDisplaySettings.desktopEnabled`，
    未授予悬浮窗权限也算）→ 订阅 `positionStream`（约 5Hz）；后台其余情形 →
    1s Timer 读 `_player.position`（值变才通知）；后台暂停 → 不采样。切换档位
    先取消旧订阅 / Timer，避免双采样。
  - 会话落盘（`PlaybackSessionCoordinator`）：不做周期写；进入后台 / 息屏
    时提交一次（`flushSession` → cursor 单行），播放 / 暂停 / seek / 切歌 /
    曲末等动作各自提交。桌面隐藏到托盘 / 最小化走同一提交入口。
  - 系统媒体会话（`LocalAudioHandler`）：仅 Android 取消「位置差 > 1s 就补发
    state」的周期更新（平台按 `lastPositionMs + elapsed × speed` 插值），改由
    `LocalPlaybackService.seekRevision` 识别显式 seek / 内部回跳；歌词覆盖与
    封面本地化补发只发 metadata。Linux MPRIS（`GetPosition` 不插值）与
    iOS / macOS / Windows 保持原周期判定。
  - 后台工作门控（观察者 / 取色 / 歌词 / 预载各自消费同一实例）：
    封面预取只在应用内可见（前台）执行；封面取色在前台或桌面歌词可能展示时
    执行（悬浮窗可跟随封面配色，通知锁屏不消费主题色）；当前 / 下一首歌词
    只在有任一词输出（悬浮窗 / 通知锁屏 / 蓝牙）或前台时加载；下一首直链
    始终预热（切歌不额外等取链），音频字节预取只在前台进行。恢复前台或打开
    输出后各消费者自行补一次，去重由各自模块负责。
  - 定时关闭（`SleepTimerController`）：Android 原生定时器只在后台 / 息屏时
    持有 partial wake lock；前台屏幕亮着时 Handler 正常调度，不持锁。生命周期
    `onPause` / `onHide` / `onResume` 都会按新的前后台状态重排原生定时。
  细节与验收命令见 `docs/mobile-power.md`。
- **Lyrics**：`LyricsProvider`（`lib/providers/lyrics_provider.dart`）是取词 → 缓存 →
  解析 → 预取的唯一实现，对外只暴露 `LyricsState`（idle/loading/ready/empty + isSynced，
  含按时间戳对齐的翻译 / 罗马音扩展行与逐字时间轴）。曲目变化的加载入口只有
  `ensureForTrack`（组合根订阅播放快照后调用，页面是否挂载都加载），空结果允许
  一次自动重试、`retry()` 可显式重来。时间契约统一在
  `lib/models/lyric_line.dart`：`hasLyricTimestamps` 与 `parseLyrics` 共用同一正则
  （兼容 1–3 位分钟与行内多标签）。
  **取词顺序**：缓存 → 曲目原生（`SourceManager.fetchLyric`：脚本 `lyric` action →
  any-listen → 内置平台原生实现（五个音乐平台 + B 站 CC/AI 字幕，B 站需扫码
  登录，见 ADR-0016），用曲目 raw 的精确平台 ID）→ **本渠道名字搜索**
  （`LyricProvider.channelKey` 与曲目来源渠道一致；3s 同源预算，命中即用）→
  其它渠道并行竞速兜底（netease / qq / kugou / kuwo / migu / lrclib；
  同渠道无词 / 抛错 / 超时后首个非空即返回，并经时长 ±5s + 歌名/歌手/
  版本词相似度挑选）。没有同渠道 provider 的曲目（B 站 / 脚本 / 本地）保持
  原来的并行竞速。缓存命中优先（尊重已有跨渠道结果；手动选择永远优先）；
  B 站登录后，缓存来源不是 `bili` 且非手动选择时优先重试原生；登录成功会清
  `bili:` 原生取词缓存并强刷当前歌词。`lxlyric` 的 `<相对ms,时长ms>` 经
  `attachWordTimings` 对齐到主行（`LyricLine.words`），歌词页当前行用
  `KaraokeLyricText` 做词级高亮，桌面歌词 / 通知 / 蓝牙仍按行。
  UI（LyricsWidget / 歌词搜索页 / 歌词选择页）只渲染状态与交互，不再各自构造
  `LyricsService` / 直接写 `LyricsCache` / 拼装解析逻辑；歌词页只消费 `LyricsState`
  （不维护字段镜像，加载标志由 `status` 推导），滚动/跟随数学在
  `lib/widgets/lyrics_scroll_policy.dart`（纯函数，可单测）：自动滚动把「主行文本块
  顶边」锚定在可见区域约 38%–40% 高度（中上；不按整项高度缩放，长行换行 /
  扩展行不影响落点）。
  歌词页用「歌词页」独立开关（`page.translationEnabled` / `page.romaEnabled`）
  逐行在主文本下方渲染翻译 / 罗马音（空文本不占位，随主行滚动；开关切换时
  展开 / 收起），与输出侧（桌面歌词 / 通知 / 蓝牙）的翻译·罗马音开关互不影响，
  共用同一份对齐数据。
- **封面补取**：曲目起播无封面时 `PlaybackObserver` 经注入 resolver
  （`CoverBackfillService`：本渠道原生取图（脚本 `pic` action → 内置原生）→
  本渠道名字搜索（2s 预算）→ 其它音乐平台按名字并行搜索并用 `song_match.dart`
  严格匹配兜底；B 站不作为搜索源，本地 / 离线曲目不跨渠道，播放补图在省流
  模式不发起请求）取图，
  经 `PlaybackFacade.updateTrackArtwork` 原地回写队列曲目（新 `Track` 触发
  封面堆叠换图淡化、主题取色与系统媒体通知封面更新）。下载取封面共用同一
  服务；正结果缓存 10min（空结果不缓存，下次起播可重试）。
- **自定义封面（custom covers）**：`lib/services/covers/custom_cover_store.dart` 是
  每曲封面与全局默认封面的唯一存储（设备本地，不登记设置键；默认随
  `covers` 同步类别跨设备同步，可在同步内容页关闭）。
  文件写应用数据目录 `custom_covers/`（Windows LocalAppData，其余平台应用
  支持目录；与封面缓存隔离，清缓存不丢失；Windows 旧 Roaming 目录首次启动
  复制一次并改写 prefs 索引路径），每次
  替换都换新文件名（避免 ImageCache / 取色 LRU 命中旧图）；索引（路径 + 哈希 +
  更新时间）在 SharedPreferences，启动只读索引并剔除丢失文件。选图经
  `lib/services/covers/cover_image_codec.dart` 解码、烘焙 EXIF 方向、最长边
  1024px、JPEG 85 后落盘。曲目键 = `sourceKey:songId`；`local` 下载副本剥掉
  一层 `local:` 前缀（下载前设置的封面继续作用于本地副本），本地导入保持
  `local:<path>` 记录键。**Cover resolution**（`cover_resolution.dart`）是
  「这一首用哪张封面」的唯一实现：`CoverResolver` 组合 `CoverIndex`（store
  实现），`RealCover` 只允许 custom / original，`DisplayCover` 才带全局默认
  兜底；取色 / 下载 / 标签只接受 `RealCover`。widget 层经 `TrackArtwork` /
  `CoverChangeBuilder` 统一订阅 `revision` 并渲染，歌曲信息页 / 顶部与迷你
  播放器 / 列表行 / 歌词选择与海报 / 系统媒体 / 桌面小组件不再各自查 store；
  换源写回（手动 + 自动）把封面复制到新曲目键。全局默认封面只兜底「歌曲没有
  封面 / 远端加载失败」的展示，不参与取色、下载与标签嵌入；
  `ArtworkPaletteService` 只消费 `RealCover`。
- **查看 / 保存原图**：`lib/widgets/cover_viewer.dart` 全屏 `contain` 展示
  真实封面，方形缩略图仍统一 `cover` 裁切；保存经 `SaveAs` 写公共输出的
  `covers/`（桌面另存为 / Android 系统「下载」/ iOS 文件 App）。网络封面由
  `CoverImageFetcher` 直取原 URL（统一 UA / Referer、8MB 上限、缓存回填），
  **不读**可能已被缩略图覆盖的封面缓存；省流生效时先确认。入口为歌曲信息 /
  封面选择弹层 / 专辑 / 歌手 / 发现详情头图，播放页大封面保持切歌手势。
- **Comments**：`CommentsService`（`lib/data/catalog/comments_service.dart`）是评论分页的
  唯一取数入口（经 `CachedPageService`：single-flight + LRU + TTL 5min，
  key=`comments:{source}:{songId}:{kind}:{page}`，失败不缓存，`invalidateTrack`
  供下拉刷新）。取数经 `MusicSource.comments`
  （能力位 `capabilities.comment`：五个音乐平台 + B 站视频）→ `SourceManager.fetchComments`
  → `lib/sources/builtin/{wy,tx,kg,kw,mg}_comment.dart` + `bili_comment.dart`
  （移植 LX：热门 / 最新、分页、表情还原、引用 / 楼中楼归一化；B 站用
  `pagination_str` 游标，缺 `is_end` 时按下一页游标决定 `hasMore`）。
  页面状态在 `CommentsProvider`（热门 / 最新两个 tab
  懒加载 + 分页 + 错误归一化），UI 为 `lib/pages/song_comments_page.dart` +
  `lib/widgets/comment_list_view.dart`；入口：歌曲信息页「评论」行（能力位判定唯一
  来源 `CommentsProvider.supports`，不支持时行内说明；展开态播放器进度排不再放入口）。
- **专辑**：`AlbumService`（`lib/data/catalog/album_service.dart`）是专辑分页的唯一取数
  入口（经 `CachedPageService`：single-flight + LRU + TTL 10min，
  key=`album:{source}:{id}:{page}:{limit}`，失败不缓存，`invalidateAlbum` 供重试）；
  取数函数由组合根注入
  `SourceManager.fetchAlbum`（能力位 `capabilities.collection`：仅内置音乐五平台置真，
  B 站无专辑、LX 脚本 / any-listen / local 为假）→ `lib/sources/builtin/{wy,tx,kg,kw,mg}_album.dart`
  按专辑 id 精确拉取（wy `api/v1/album`、tx `music.musichallAlbum.AlbumSongList` 模块、
  kg `album/song` + `album/info`、kw `r.s stype=albuminfo`、mg `queryAlbumSong` +
  `MIGUM3.0/resource/album`），解析直接产出领域 `Album`（曲目 payload 经 track_mapper
  原样透传）；真实响应快照见 `test/fixtures/albums/`（抓取脚本
  `tool/gen_album_fixtures.mjs`），端点均需真机复验。端口路由：
  `MusicSource.collection(CollectionRef(type: album))` 在能力位为真时转发
  `fetchAlbum`（playlist / artist 仍 unsupported）。UI 为 `lib/pages/album_page.dart`
  （头部元信息 + 播放全部 + 加入列表 + `PagedTrackCollection` 分页列表），入口：歌曲信息页
  「专辑」行（`track_mapper` 派生的 `Track.platformAlbumId` + 能力位双判定；否则保持只读）。
- **系统媒体会话**（Android/iOS/macOS/Windows/Linux）：`LocalAudioHandler`
  经读取面 `MediaSessionReadModel`（生产实现 `LocalPlaybackMediaSessionReadModel`
  投影 `LocalPlaybackService`；测试注入普通值假实现）把状态映射为统一模型
  （`flutter_media_session` 的 `MediaMetadata` / `PlaybackState` / `MediaAction`），
  文案经注入的 `MediaSessionCopy`（不读全局 locale，歌手回退走 l10n `unknownArtist`），
  后端可注入（见 ADR-0010）：
  Android/iOS/macOS/Windows 走 `FlutterMediaSessionBackend`
  （`FlutterMediaSessionPlatform`，不调用会主动请求通知权限的
  `FlutterMediaSession().activate()`），Linux 走 `MprisMediaSessionBackend`
  （`audio_service_mpris` 的 Dart 平台接口，D-Bus 不可用静默降级）。
  封面经 `ArtworkCache.cachedFilePath` 带浏览器 UA + 平台 Referer 落到本地文件后
  传本地地址（Android/iOS/macOS/Linux `file://`、Windows 裸路径；网易 CDN 对
  默认 UA 返回 403），未命中先发远程 URL 兜底；省流模式整体置空封面地址且不下载。
  恢复态（冷启动未起播）下切歌键回落给 `PlaybackSessionCoordinator`
  （按阶段从保存的会话恢复播放或转发真实播放）。
  `POST_NOTIFICATIONS` 不在启动时请求——由
  `lib/services/notification_permission.dart` 在「首次真正播放 / 首次开启歌词
  输出」时弹窗（每会话一次），被永久拒绝时通知·锁屏设置页给系统设置深链；
  媒体会话初始化失败（平台支持但 `initSystemMediaSession` 返回 null）时歌词显示
  页给可见提示。通知动作含自定义的**播放顺序**（循环模式：列表循环 / 顺序 /
  单曲 / 随机，
  图标与文案随当前模式，App 内改模式双向一致；`MediaAction.custom('lx.playMode')`，
  Android drawable 名沿用 `audio_service_*`，`keep.xml` 防 shrinkResources 删除）；
  系统控制路径（暂停 / 停止 / 切顺序 / seek）**经播放命令面提交**
  （`LocalAudioHandler` 只翻译成 `PlaybackCommandPort` 命令，协调者按阶段路由并
  在返回前 await `PlaybackSessionStore.pendingWrite`；不再由 handler 回填落盘回调；
  停止先落盘再清空队列），保证
  「系统暂停 → 冷启动」能恢复上一首 + 队列 + 模式 + 进度且不自动起播。
- **流请求头（PlayableStream.headers）**：`SourceManagerMusicSource.resolve` 把取链结果
  （uri + headers + expiresIn）原样返回；`LocalPlaybackService` 同时传给
  `AudioSource.uri` 与 `LockCachingAudioSource`，`NextTrackPreloader` /
  `AudioPredownloader` / 桌面 `PlayingTrackCacheWriter` / 下载复用同一份 headers。
  B 站直链缺 `Referer` + 浏览器 UA 会直接 403；这是全路径契约，不能在中间层只留 URL。
- **Cache**：`RequestCache`（single-flight + LRU 64 + TTL + 可注入时钟）。
- **省流**：`DataSaverService`（services 层，默认关闭）持有「开启 + 音质上限 +
  封面省流」策略与 connectivity_plus 网络探测；仅在移动数据（`active`）时生效：
  - 取链：main.dart 的 resolver 以 `effectiveQuality(preferred)` 套 `capQualityFor`
    压低音质（缓存键含音质，切换网络自然重解析）；
  - 封面：`ArtworkCache.networkImageBlocked` 网关让 `ArtworkCacheManager.getFileStream`
    只读本地缓存（未命中抛 `ArtworkNetworkBlockedException` → 占位图标），
    并拦截播放预加载、系统媒体会话通知封面与桌面小组件封面地址；取色链路同样
    只读缓存——命中则照常取色，未命中保持现色（`ArtworkPaletteService` 吞掉异常）；
  - 探测失败保守按「未生效」；Android 回前台时由壳层 `refreshConnectivity()` 补一次检测。
- **失败归一化**：`SourceFailure` 是跨层错误契约（`lib/domain/models/failure.dart`）。
  sources 适配器在边界转换一次：any-listen 经 `AnyListenException.toSourceFailure()`
  （保留 unauthorized / connectionFailed 语义，不再退化为 unknown）；内置传输错误
  由 `SourceFailure.from` 按类型名识别 `BuiltinHttpException`。providers/UI 只消费
  kind / l10nKey / retryable。
- **听歌统计**：`play_events`（一次播放尝试一行，drift 本地库 v1）由
  `PlayStatisticsRepository` 读写；曲目元数据与取链参数（`raw`，gzip 字节）在
  `play_tracks`（每曲一行，见 pitfalls #53），读取一律 join；聚合全部查询时计算，
  口径常量唯一来源是
  `PlayStatisticsLimits`（有效播放 = `min(30s, 50%·时长)`，error 事件不计入
  计数/比率）。采集是 `PlayStatisticsService` 纯观察者——组合根把
  `PlaybackProvider` 快照 + position 接进去，**零改动播放内核**；
  真正出声才开事件、暂停不切断、统计事件只在动作 / 退后台 / 退出时落盘
  （与播放会话无关；播放途中不按 tick / 定时器写库）、启动收尾遗留事件。
  统计页（`play_statistics_page.dart`）消费 provider 投影：日历热力图（hero，
  全量历史 + 范围高亮）、作息热力图（7×24，随范围过滤）、汇总/指标/榜单
  （Top 曲目可点播）；导出 JSON 面向 AI 消费（全量汇总 + 最近明细、不含 raw）。
  与 `play_history`（最近播放，500 条上限）是两套数据。
- **AI 推歌（Phase 2，可选，默认关闭）**：`lib/services/ai/**` 是唯一数据出口与
  网络层——`TasteProfileBuilder`（按发送范围读聚合画像 + 最近 50 条明细 +
  可选收藏/歌单，上限集中；提示词用紧凑行格式并按应用语言切换文案）、
  `LlmClient`（OpenAI-compatible，请求带
  `response_format: json_object`（不支持时自动退回），错误归一化
  `SourceFailure`，Key 不进 message）、`AiRecommendationService`（提示词 →
  容错 JSON → 规范化去重 → `CatalogService.search` 按音源页顺序遍历全部可搜索
  渠道解析，命中无封面时经音源 `artwork()` 补取；预览与实际共用同一
  `buildPrompt`）。
  `AiDjProvider` 负责推歌会话、通知与对外门面；生成编排收在
  **生成执行器** `AiGenerationExecutor`（`lib/services/ai/ai_generation_executor.dart`）：
  token / epoch / 取消 / 忙碌位 / 可见进度唯一持有，三条 lane——显式（可见、
  可取消、互斥）、换一首（不可取消、行内进度）、静默补歌（无可见进度、显式
  操作可抢占）；进度走独立 `ValueListenable<AiGenerationState>`，provider 的
  聚合通知只转发忙碌位 / 行内替换的离散变化（进度分片由 `generationState`
  自己通知窄订阅者）。**电台队列视图** `AiRadioQueue`
  （`lib/services/ai/ai_radio_queue.dart`）从 live 快照派生
  `upcoming` / `contains` / `missing` / `queuedAmong`，不持有计数器：
  `queuedCount` 是「当前及之后仍在队的 AI 曲目数」，随播放递减。
  `AiDjHistoryController`
  （`lib/providers/ai_dj_history_controller.dart`）独占**当前推荐（active batch）**、
  **历史索引**、按需加载缓存与保留策略，批次与存储形状的转换由 Provider 注入：
  历史存储为索引 + 每批一键（`AiRecommendationStore`，启动只读索引 +
  active，详情懒加载，20 批 / 400 首 / 30 天、active 不清理；旧单批键不再读取、
  不迁移），索引与批次载荷的写序统一为「先写索引、后删载荷」（删除 / 清空 /
  保留裁剪都一样），孤儿载荷无害；显式「生成推荐 / 换一批」切换 active，
  旧批留在历史；手动补批与
  低水位**静默补歌**只追加队列 + 写历史（`manualFeed` / `autoFeed`），不切换
  active、不显示进度，自动补歌连续 3 次失败停止（显式操作优先并可取消）；
  历史可播放 / 加队列 / 设为当前 / 删除。生成偏好（批次大小 10/20/30/50，
  默认 10；自动补歌、风格 / 场景 / 语言 / 年代 / 探索度 / 只推荐没听过的 /
  补充要求、发送范围）持久化在 `kAiDjPreferences`，偏好页即时保存、不自动
  生成；找歌渠道不在 UI 暴露，解析按音源页顺序遍历全部可搜索渠道。反馈记忆
  持久化在 `kAiDjFeedbackMemory`（不感兴趣 / 喜欢 / 种子，重启保留，种子成功
  生成后消费）。显式生成有 profile → model → resolving 阶段进度与取消，
  首屏脉冲骨架、轮播细进度条；自动补歌不进入任何进度/提示 UI。发送透明化
  收成弹窗（发送范围、本次预览、上次发送与仅存内存的原始返回）。
  反馈面板含长期记忆与本轮反馈、清空 AI 记忆。发现页 `AiDjCarousel` 只展示
  active 批次，用 carousel 原生槽位展示歌名/歌手
  （`applyDynamicTextContentTransform: false`）：桌面端鼠标拖拽跟手（松手吸附）、
  滚轮翻卡（自接指针信号把 `dy` 转成步进，横向滚动视图默认只吃 `dx`），点卡
  滚到焦点位（`M3ECarouselController.animateToItem`）；卡片流下方信息区只显示
  焦点卡的推荐理由（歌名 / 歌手由卡片槽位承担，不在信息区重复），理由为空 /
  焦点越界不渲染（`aiDjReasonPanel`）。「查看全部」进 AI 页的弹层不带关闭 X
  （`showCloseButton: false`：页面自己的标题栏已有返回，避免双层 chrome，
  关闭走遮罩 / Esc / 下滑 / 系统返回）。功能未启用时整条隐藏；播放页不再有
  AI 徽标。首次开启隐私确认；定位与边界见 ADR-0002。启用后搜索 tab 的
  「输入关键词搜索歌曲」空占位让位给推荐流（关闭时保留占位）。
- **跨设备数据同步（可选，默认关闭）**：同步歌单 / 收藏 / 音源脚本与配置 /
  跟人走的设置 / 听歌统计 / 播放历史 / 上次播放会话 / 自定义封面 /
  AI DJ 与凭证。信任模型是
  **同步口令即信任根**（加入即完全互信，无逐项审批），快照整体加密：根密钥 =
  PBKDF2(口令) 会话内一次派生（按口令缓存），帧密钥 = HKDF(根密钥, 帧 nonce)，
  AES-256-GCM 认证；帧 = `magic + 版本 + nonce`，载荷是列式二进制，编解码与
  加解密在 worker isolate 内执行（帧与信任边界见 ADR-0003 §1）。
  **同步控制面**（`sync_control_plane.dart`）承担 UI 面的身份 / 类别与传输开关 /
  运行状态 / 手动地址簿 / 口令生命周期，与引擎共享同一状态存储与传输实例；
  **传输运行时**（`sync_transport_runtime.dart`）是 ensure / start / stop /
  resume / hidden / announce 的唯一所有者，组合根把同一实例注入引擎与控制面
  （不再有两份 `_ensureTransportsRunning`）。
  引擎（`lib/data/sync/sync_engine.dart`）只保留公共门面：调度器宿主 / 服务端
  语义（`serveSnapshot` / `serveJournal`）/ 入站合流 / 公告过滤。轮次内的阶段
  由**轮次编排器**（`sync_round.dart` 的 `SyncRoundRunner`）线性编排：`runRound`
  = collect → pull → consume + apply → publish + compact → report；轮次上下文与
  阶段都是该文件的私有实现，测试只能经 `runRound` + 假传输 / 假适配器驱动整轮
  （避免绕过顺序直接调阶段）。应用成功才推进游标、forced delivery、缺口二次
  拉取、anti-entropy 与入站轮语义都不变。同步状态的依赖按用途收窄为
  `sync_book.dart` 的窄接口（登记 / 发布覆盖 / 轮次 / 引擎 / 运行时 / 调度 /
  备份），`SyncStateStore` 仍是唯一实现与持久化所有者：所有写入先改内存 +
  标脏，`commit()` 是唯一落盘出口（轮内台账 / 首连提示 / 端点记账只标脏，
  引擎轮末提交一次；用户命令仍即时提交）。自动轮「零对端 / 无变化」只更新
  内存展示、不标脏；名册没有真实观测变化也不标脏，失败探测只刷新
  `lastSeenAt` 时同样不落盘——空闲轮 / 重连阶梯探测不再反复重写整份
  `sync_state_v2`（Windows 实测约 142KB/次）。
  拉取前由 `SyncRoundRunner._pullPlan` 生成一份**拉取计划**（`SyncPullPlan`：逐对端
  `cursor` / `forceFull` + discovery）；局域网与 WebDAV 只提供证据（局域网
  `snapshotId + snapshotFresh`，WebDAV `etag` / `lastmodified` + 回执头部），
  skip / delta / full 统一由 `decideSyncPull`（`sync_pull_plan.dart`）判定——
  「只有本轮新鲜证据能跳过」只有这一处实现。pull 与 push 共享显式
  **轮次窗口** `SyncRoundWindow`（不再依赖局域网私有的 `_roundStartedAt`）；
  局域网对端候选的合并与地址尝试顺序在 `sync_peer_candidate.dart`。
  一轮 = 各 `SyncAdapter` 收集本地视图（按类别廉价指纹缓存：指纹未变不读行）→
  `SyncTransport` 按计划拉取变化对端 → 逐键 LWW 合并（版本三元组
  `(versionPhysical, versionCounter, deviceId)`，删除为墓碑）→ 只把版本变化的
  胜者交给适配器（`sync_known` 登记表：交付成功才登记，空闲轮 0 次 apply）→
  按**发布台账**外发与裁剪（`publish_ledger.dart`：每传输一份，聚合内存指纹 /
  `sync_state_v2` 的 `snapshotPushSeq` 持久覆盖 / `servesLiveSnapshot` 能力位；
  「跳过加密 + 上传」与「journal 能裁到哪」都在台账里回答）；版本戳由唯一发号器
  `SyncStampIssuer`（`sync_stamp.dart`，HLC-lite：吸收远端超前戳、同毫秒
  counter 递增、基线持久化 + 重启不倒退）发放，内容时间（playedAt / endedAt /
  savedAt / importedAt / 墓碑删除时间）**不参与胜负判定**（见 ADR-0003 v2 §2）。
  `covers` 类别由 `CoverSyncAdapter`（`lib/data/sync/adapters/cover_sync_adapter.dart`）
  承担：记录键 = 封面键 + 默认封面保留键，内容 = base64 图片 / mime / 哈希 /
  updatedAt；本地变化登记 `SyncStamp`，墓碑后重设取新版本（避免输给旧墓碑）。
  类别未被本轮请求时适配器立即返回空（不读封面文件、不算哈希 / base64），因此
  蜂窝小类别轮不携带封面字节；手动完整备份请求全部类别，仍会导出 / 导入
  封面。重新开启类别时控制面把各传输的快照发布覆盖置为未发布，下一轮强制重发
  全量快照补传已有封面——开启后的**第一次**收集只登记这些已有封面、不逐张追加
  增量；此后的首次登记 / 真实变化 / 删除 / 墓碑后重设才写日志。远端 LWW 落盘走
  `CustomCoverStore` 的 `applySynced*` 接缝（不触发本地变更回调），只接受归一化
  JPEG（PNG / GIF / WebP 与损坏载荷跳过）；单张超限（> 500KB）只跳过，接收侧在
  base64 解码前先按长度拒绝。类别默认开启、不进蜂窝小类别；封面字节不进入
  非封面轮次，自动同步按类别开关执行，手动完整备份不受该开关限制。
  协议自始为 v3（帧带版本与 nonce，载荷是列式二进制；见 ADR-0003 §1）：对端快照直接
  合并，备份只做结构性校验（不是 Molia 备份 / 结构无效才拒绝），都没有按版本号
  的分支。全量合并模型天然幂等，推送裁剪 90 天前墓碑（按真实删除时间）；入站
  推送在 1–2s 窗口内合流成一轮，入站轮只消费收到的快照（不拉取、不推送，防
  两端乒乓与 N 台平方级放大）。一轮的产物是可观察的 `SyncRoundReport`：五态
  结论（`ok / noChanges / noPeers / partial / failed`）+ 每传输明细（含未变跳过
  数）+ 每对端名册 + 本轮变更量；设置页据此呈现结论行、运行状态（近 24 小时
  触发 / 有效传输轮数与流量、当前同步等级 · 网络类型 · 是否省电）与变更语义
  日志，失败行给重试入口；同步何时跑完全由调度器声明式决定，
  首屏不提供「立即同步」主操作，也不导出诊断快照。触发
  策略统一在 `SyncScheduler`（`sync_scheduler.dart`）：**活跃**（可见 + 最近
  交互 / 正在播放，变更去抖 4s）/ **空闲**（退避 10→20→40→60 分钟封顶；
  蜂窝下 0 广播 / 组播、无本地变更不发轮次，非蜂窝（Wi-Fi / 以太网 / 桌面）
  唤醒照常探测与拉取）/**后台**（零定时唤醒，退后台尽力推、回前台拉）/
  **省电**（低电量未充电或系统省电模式
  暂停自动，只保留恢复动作的手动触发）；电量经平台通道读取（Android `BatteryChannelHandler` /
  iOS `AppDelegate`），移动数据下默认只同步小类别
  （设置 / 音源 / 凭证 / 歌单与曲目 / 会话）；统计 / 历史 / 自定义封面等
  大类别留到 Wi-Fi，可在同步页切换为「暂停自动同步」。
  **事件驱动重连**：`DataSaverService.networkEvents` →
  `SyncScheduler.onNetworkChanged`（重置空闲退避 → 1.5s 去抖 →
  `SyncTrigger.network` 强制发现）；回前台隐藏 ≥15s 时重绑 UDP + loopback
  探活 HTTP（失败重绑，再失败置 `start_failed`）；已配对但零对端按
  `5 / 20 / 60 / 180s` 阶梯重连（仅前台、非省电、非蜂窝）；认证通过的对端
  公告经引擎过滤（新设备 / boot 变化 / snap 变化 / head 前进且仍落后）→
  调度器 1s 去抖 + 10s 冷却 → `SyncTrigger.discovery`。传输有两个
  实现、可分别开关：局域网直连（`MSD/1` 二进制公告发现 + 内置 HTTP
  `/molia-sync/v2/*` 数据端点；UDP 只发现、HTTP 是数据与存活通道）与用户自备
  WebDAV（`<remoteDir>/<deviceId>.p2.*.msync` 密文文件，PROPFIND/GET/PUT/MKCOL；
  `.p2` 是硬断代命名空间，旧文件按幽灵文件忽略、不读不删）。打开任一路传输
  成功后经调度器排一次 `checkNow()`（仍受省电 / 移动数据暂停与在途轮次约束，
  关闭不触发）；WebDAV 配置弹层用 `saveWebdavConfig(config, password)` 一次写
  配置与密码，已启用且已配置时同样立即检查，避免配置与密码之间跑一轮必然
  失败的轮次。
  局域网发现报文（`MSD/1`：magic / version / type / HMAC / bodyLen + 认证
  body）先按来源限流（20 包/10s，全局 100 包/10s）再验 MAC 再解析；正常轮
  只对 presence / 手动地址 / `lanEndpoints` 做 ≤8 个单播并等 400ms，冷启动 /
  回前台 / 换网才广播（v4 `255.255.255.255` + `224.0.0.169`、v6
  `ff02::4d4f:4c49`）并等 1.2s；蜂窝 0 广播、后台 0 定时器。`lanEndpoints`
  只在 MAC + HTTP 解密成功后回写（32 条上限、180 天淘汰、移除设备一并清理），
  广播被隔离时用它单播兜底。
  局域网在移动端有平台准入：Android 17 / API 37 起必须声明并运行时申请
  `ACCESS_LOCAL_NETWORK`（未授予时状态 `permission_denied`；申请只在用户开
  局域网开关 / 点「去授权」时触发，启动与轮次只查状态不弹窗，被拒开关回退
  关闭并给底栏 + 常驻警告行），
  iOS 广播发现需向 Apple 申请 multicast entitlement（未获批时降级手动地址 /
  WebDAV）；发现失败可用手动对端地址簿兜底（单播探测后认领 deviceId 与端点
  端口），本机端点端口持久化避免对端记不住本机。学习路径（广播 / 单播观测）
  只更新身份与端口并把条目提到最前，不动地址集合：同一设备的多条地址本来
  就是合法候选；设备详情里可逐条「更新地址」（身份与已学端口保留）或删除。
  **同步设置页**首屏顺序固定：传输方式（局域网与 WebDAV 两路开关 + 最近一轮
  五态结论）→ 已配对设备名册（含连接状态，空名册给引导）→ 附近设备（一键
  配对）→ 同步内容 / 日志 / 高级设置入口；设备名、设备 id、口令、网络地址
  （一行入口，明细进弹窗：双栈 + 多网卡不铺成列表）、探测端口与直连端点端口、
  地址簿（手动连接 + 未认领候选）在「高级设置」子页
  （`sync_advanced_page.dart`）——底层细节不占首屏，但传输状态必须留在首屏
  （「开关已开而实际没有监听」是排查同步事故的主要来源）。
  同步内容子页只列类别开关，关闭后果在卡片 footer 说明一次；自定义封面
  类别（默认随同步发送）也只在这里出现，外观页不再提供第二份快捷开关。
  同步页每 30 秒只重算一次相对时间（不额外跑轮次）；名册有设备但本轮全部
  未连接、且自动检查未被省电 / 移动数据暂停挡住时，设备卡给「重新检查连接」
  （`checkConnections()` → `SyncTrigger.check`）。
  **配对只有一条路径**（`data/sync/pairing/**`）：`MSP/1` 局域网附近设备发现
  （probe / announce，只做候选，不写名册、不触发同步轮次）→ 点击候选发起
  `/molia-sync/v2/pair/*` 请求 → 双方核对 6 位确认码 → 对方接受后加入同步组。
  接受 = 加入同步组 = 对方获得本机口令、可解密全部同步数据（含密钥），弹窗
  必须明示；确认码由双方临时公钥 / nonce / requestId 派生，不一致必须拒绝。
  口令只在临时 ECDH（P-256）+ HKDF-SHA256 + AES-256-GCM 密封后传输，AAD
  绑定 requestId / intent / 双方 deviceId；pending TTL 60 秒、上限 8、每来源
  限流，且只在 App 前台 / 局域网传输运行 / 非蜂窝时探测与弹窗。双方口令相同
  用 group proof 直接补端点；都已有不同同步组则返回冲突，不静默换组。
  附近设备扫描在初始 100 / 500 / 1500ms 三波之后，扫描期间复用 sweep 定时器
  按 `scanRefreshInterval`（默认 5 秒）补发新 nonce 的 probe；候选 TTL 仍是
  15 秒，补探只续期不清空。退后台 / 关页 / 停传输立即停，回前台补一次；
  本机探测端口不可用（`advertisedProbePort == 0`）时 `startScan` 返回 false，
  不再假装正在查找。空态按 `SyncNearbyAvailability` 分层（权限 / 开关 /
  传输未启动 / 移动数据 / 省电 / UDP 两族不可用 / 配对端口不可用 / 可用），
  同步页只在可用时启停扫描；权限、传输与发现原因分别指向授权、同步日志与
  手动地址 / WebDAV，不把本机原因说成对端原因。
  `LanPairingService`（`lan_pairing_service.dart`）负责协议与 pending 状态机，
  `PairingCrypto`（`pairing_crypto.dart`）负责密封与确认码，候选 / 请求模型在
  `domain/models/sync_nearby_pairing.dart`。**旧配对码（`molia-pair:*`）/
  二维码 / 粘贴 / 扫码已删除**，不识别、不迁移、不兼容；自动发现失败时只手填
  地址，向该地址单播 `MSP` 探测后走同一配对流程（手动地址不携带口令）。
  **没有独立总开关：传输开关就是总闸**，任一开启即启用同步，两路都关 =
  引擎轮次 / 入站接收 / 调度器一并停摆（新 key `sync_state_v2` 缺失即全新
  安装：旧状态不读，升级后 transports 为空、同步保持关闭，需重新开启并
  配对）。设备身份 `deviceId` 独立持久化在 `sync_device_id_v2`（prefs 小键 +
  安全存储备份），`sync_state_v2` 损坏时恢复旧身份而不是重新生成（否则重启 /
  换 IP 后对端会多出一台新设备）。口令在初始化即生成（信任根，不依赖任何开关），
  首次开启同步不再弹口令窗（附近设备配对确认后由协议交给对端）。**首次连通
  双方各弹一次提示**：某设备第一次真正交换过数据（`lastPullAt` /
  `lastPushAt`，入站推送同样计）时引擎发一次性事件（`peerConnectedNotices`，
  已提示的 deviceId 持久化在 `notifiedPeers`，重启不重发；设备从本机移除时
  标记随之清掉），应用壳订阅后弹「已与『设备』连通」。**移除设备只清本机名册
  与地址簿条目，不撤销授权**：对方仍持有口令并在线时会重新出现；真正撤销需
  更换口令。**本机地址**（`LocalEndpointsService`：IPv4 + 全局 / ULA IPv6，
  排除回环 / link-local / zone，私网优先排序；过滤判定
  `isRoutablePeerAddress` 与服务 / 传输共用）是地址列表、附近设备探测与探测
  `addrs` 候选的同一口径。
  主库 schema（drift，`schemaVersion = 2`，库文件 `molia_database_v2.sqlite`；
  旧 `molia_database.sqlite` 保留但不读、不迁移）含播放会话两表
  （`playback_session_payloads` / `playback_session_cursors`）、
  `playlists.syncId` / 行级
  `versionPhysical + versionCounter + deviceId` / `sync_tombstones`（版本三列 +
  真实删除时间）/ `sync_known`（已知版本登记）/ `play_events`（syncKey +
  版本列，`originDeviceId` 兼作设备列）；设置同步用「登记哈希」做变化检测，
  不改造散落的 SharedPreferences 写入方。播放历史删除（含清空）传播墓碑，
  「删除 vs 播放」按真实时间判定；上次播放会话按 `savedAt` 内容时间变化取新戳
  （本地停止不回传删除），应用后经
  `PlaybackProvider.reloadRestoredSessionFromStore` 重载恢复态。**完整备份**
  （数据与存储页导出/导入）是独立模块（`sync_backup.dart` 的
  `SyncBackup.exportBackupJson` / `importBackupJson`）：复用同一 envelope、
  适配器与版本戳，收集入口由引擎注入（`collectRecords`），但不构造轮次也不经
  传输；默认导出全部类别与凭证（换机状态一致，备份文件为明文 JSON，调用方
  负责保管），备份只做结构校验（kind / 内层 envelope，不按协议
  版本判定）。数据变更经
  调度器进入触发链，生命周期回调由 `main.dart` 的 `AppLifecycleListener` 转发；
  同步后的定向重载经 `PrefsSyncAdapter.onApplied` 接线。设置入口
  `settings_page.dart` → `sync_settings_page.dart`。
- **对端增量协议**：`lib/data/sync/peer_journal_protocol.dart` 是游标 / 窗口 /
  分块规则的唯一实现——`chooseJournalServeMode`（游标落后 / 超前转全量）、
  `consumeJournalDelta`（游标 -1 夹到 0、只接受连续 seq、空窗口不算截断、缺口 /
  截断要求 bootstrap）、`selectJournalChunks`（WebDAV 分块衔接）与
  `PeerJournalNames`（协议文件名）；引擎、局域网 / WebDAV 传输与
  `test/support/sync_network.dart` 共用同一份语义，边界条件只维护一处。
- **渠道选择**：`DiscoverProvider.channelKey` 是渠道状态的唯一持有者；渠道变化经
  注入的 `onChannelChanged`（组合根）同步搜索源（可搜索渠道才跟随），资料页只
  处理「渠道被停用」的 UI 回退，不再在两个 provider 之间仲裁同步。
- **内置发现**：`lib/sources/builtin/discover_source.dart` 的渠道与能力位从
  `BuiltinPlatforms.discoverSources` 派生（六平台同一份注册表）。B 站
  （`bili_discover.dart`）只有音乐榜（`bili__music_3d` / bangid `3:3`）+ 热搜 +
  收藏夹详情：`supportsPlaylists` / `supportsPlaylistSearch` 恒为 false（UI 隐藏
  歌单 tab），`playlistDetail` 接受收藏夹链接 / ID 并按 `media_count` 拉全。
- **Mapping**：`track_mapper`（`SourceTrack` ↔ `Track`，payload 同一引用往返）。
- **内置平台**：搜索/发现共用 `BuiltinSearch.transport`
  （`lib/sources/builtin/builtin_transport.dart`）——客户端可注入、统一请求头/超时、
  响应级重试（`retryIf`）与结果缓存（`transport.cached`，single-flight + LRU +
  TTL 5min）；平台适配器只保留 URL 构造与解析，不再各自持有静态 `RequestCache`。
  fetch 路径测试通过注入 `MockClient` 覆盖。取词 / 取图适配器登记在
  `BuiltinPlatforms`，派发（`builtin_lyric_dispatch.dart` /
  `builtin_pic_dispatch.dart`）只查表 + 结果缓存，不再维护平台 switch；渠道偏好
  （音质 / 顺序 / 停用）在 `lib/sources/source_preferences.dart`，
  `SourceManager` 同名方法为其委托。
- **内置平台注册表**：`lib/sources/builtin/builtin_platforms.dart` 的
  `BuiltinPlatforms` 是六平台 × 能力族的唯一声明（规范键 `wy / tx / kg / kw / mg / bili`、
  展示名、搜索候选排序位、类型化适配器：搜索 / 原生取链 / 原生取词 / 原生取图 /
  歌词搜索 / 评论 / 专辑 / 歌手 / 发现）；能力位由适配器是否存在推导，新增平台只改
  这一处（不再维护七份 `supportedKeys` 与 switch）。B 站只注册搜索 / 原生取链 /
  评论 / 歌手 / 发现（无专辑、无按歌词搜歌）。
- **音源画像**：`lib/sources/source_profiles.dart` 的 `SourceProfiles.build` 把
  注册表 × 激活脚本 × any-listen × 渠道偏好合成每个 key 一份不可变
  `SourceProfile`（身份 / 启用 / 可发现 / `SourceCapabilities`），
  `channels` / `searchable` / `forKey` 是一轮快照。`SourceManager` 的渠道、能力位
  与搜索 / 评论 / 专辑 / 歌手 / 歌词搜索路由，`SourceRegistryImpl` 与
  `SourcesProvider` 读同一份，不再各自推导「能不能」。搜索能力 = 搜索适配器存在
  且（原生取链或脚本可取链）；歌词 / 封面 = 注册表适配器或脚本 action；停用项
  仍进 `channels` 但不进 `searchable`；内置 key 的脚本声明只补能力，不生成第二个
  同名 LX 源。
- **B 站音源（bili）**：`bili_api.dart` 是匿名会话唯一入口（buvid3/4 + WBI
  mixinKey，1 小时缓存 + single-flight）；`bili_client.dart` 收请求生命周期
  （WBI 签名 / 匿名 vs 会话头 / 业务码口径 / 风控刷新；搜索与 UP 搜索按
  ADR-0014 任何失败刷新一次）。`bili_search` /
  `bili_play` / `bili_lyric` / `bili_comment` / `bili_artist` / `bili_ranking` /
  `bili_favorites` / `bili_discover` 分别覆盖全站视频搜索、原生取链（dash 192k/128k/64k
  + `durl` 回退）、CC/AI 字幕歌词、游标评论、UP 主页、音乐榜 / 热搜与公开收藏夹导入。
  取链返回 `PlayableStream(headers: UA + Referer, expiresIn: deadline)`；
  收藏夹按 `media_count` 拉全（上限 50 页 / 1000 条）。可选 B 站扫码登录
  （`BiliAccountService` + `BiliSession`）只为字幕提供账号 Cookie：字幕走
  `accountSession`（buvid + WBI + Cookie）/ `account` 回退，播放、搜索、评论、
  字幕 CDN 继续匿名；凭据是凭证类别设置键，默认随同步与完整备份。`BiliSession`
  是 Cookie / 账号 / 就绪 Future 的唯一持有者（账号服务只保留 UI 状态），
  `BiliClient` / `BiliLyric` 接受注入会话；账号请求与字幕取词都在读取 Cookie
  前 await `ready`，过期标记由会话持有。决策与边界见 ADR-0014 / ADR-0016。
- **内置尝试循环 / 发现执行器**：`builtin_transport.dart::runBuiltinAttempts` 是
  「`attempt` 返回 null 即重试、异常直接上抛、耗尽抛 `StateError`」的唯一循环，
  `cachedRetry` 与无缓存的发现端点共用；`BuiltinRetryBudget` 集中命名
  `discover` / `leaderboard` / `wyLeaderboard` 预算，平台文件不再各写 3/4/6。
  `discover_runner.dart::runDiscoverCall` 是发现端点的唯一执行入口：`DiscoverCall`
  描述缓存键 / 预算 / 请求 / 无效判定 / 解析（或多步尝试），有 key 走
  `cachedRetry`、无 key 走共享尝试循环；平台文件只保留 URL / 参数 / parser。
- **内置检索 runner**：`lib/sources/builtin/builtin_search_runner.dart` 是五个
  音乐平台搜索的执行骨架（`runBuiltinSearch`）：重试预算、分页推断与失败归一
  各写一次；平台变体面（请求方式/URL/body、响应级重试判定、业务码判定、列表
  路径与解析）收进 `BuiltinSearchCall`，各平台文件只剩字面量与 parser。B 站
  搜索走 **Bili client**（会话 / WBI 与 ADR-0014 的 any-failure 刷新），结果仍
  走 `SourceSearchResult` 的 empty / failed 分界：**平台返回空** → 正常结果
  （`tracks` 为空、`failure` 空）；**业务拒绝 / 传输失败** → `SourceSearchResult.failed`
  （`SourceSearchResult.failure`，不抛异常；UI 收口前只读 `tracks`）。内置平台
  「可搜索」的判定唯一来源是 **Source profile**（channels 候选、能力位与搜索路由
  共用）。
- **内置歌手 / 歌词检索**：歌手（`builtin/artist_source.dart` + `*_artist.dart`，
  含 B 站 UP：`bili_artist.dart`）与按歌词搜歌
  （`builtin/lyric_search.dart` + `*_lyric_search.dart`；B 站没有该能力）与专辑同构——
  平台适配器只留 URL / 签名与 parser，解析直接产出领域模型；失败语义为
  **业务拒绝抛 `SourceFailure`**（`builtinPlatformFailure`，与 `SourceSearchResult.failed`
  的「静默空结果」区分），在 `SourceManager` / data 层边界归一化。
  歌手 id 与曲目 payload 同体系：解析时把 `_artists`（项目内部字段）写进 raw，
  `track_mapper` 填 `Track.artists[].id`，UI 只读领域模型即可跳歌手页。
  平台降级（写进各实现注释）：kg 歌手搜索无分页、tx 歌手歌曲单页、
  mg 歌手详情无简介、kw 歌词搜索为模糊匹配、mg 歌词排序偏翻唱；
  B 站空间投稿风控（`-352` / 空 `vlist` + `count>0`）回退全站视频搜索并按 mid 过滤。
- **资料库写入**：`LibraryProvider` 是收藏 / 历史 / 列表写入的唯一入口。收藏唯一
  入口 `toggleFavoriteTrack(Track)`（播放页经它写入，不再直连 `LibraryRepository`）；
  批量操作按 `PlaylistTrack` 规范形状（`PlaylistTrack.fromHistoryEntry` 负责历史转换）；
  「加入列表」流程唯一实现在 `lib/widgets/add_to_library.dart`（收藏页与发现页共用）；
  列表曲目读取经 `playlistTracksView` + `ensurePlaylistTracks`（页面不探测缓存内部）。
- **曲目交接**：`lib/widgets/track_handoff.dart` 是「把一组曲目交给播放 / 资料库」
  的唯一编排；页面只提供曲目与上下文名。空列表 no-op、洗牌先落模式、起播下标
  夹取、上下文名归一、批量 `addedAt` 都在这里；`PlaylistTrack.fromTrack` 生产代码
  只在此调用，加入列表仍复用 `add_to_library.dart` 的目标选择流程。发现详情页
  的 `DiscoverTrack` 经 `DiscoverProvider.domainTracksOf` 归一为领域曲目后走同一
  交接，不再维护 `playTracks` 的第二套洗牌 / 触感 / 起播口径。
- **分页曲目集合**：`lib/widgets/paged_track_collection.dart` 是专辑 / 歌手 / 发现
  详情页的分页曲目骨架。`PagedTrackCollection<T,R>` 在 `PagedListController` 上
  捕获同页实体（`reset` 同时作废列表与实体），`PagedTrackCollectionBody<R>` 收口
  loading / 首屏失败 / 空态 / 列表 / 页脚 / 可选钉住表头 / 表格档行高；页面只保留
  头部、行与播放动作。
- **换源**：`SourceSwapProvider`（`lib/providers/source_swap_provider.dart`）是
  跨音源搜索 + 原位替换的唯一状态机：按种子曲目「歌名 + 歌手」在可搜索音源
  并行检索（**保留种子源**，种子曲目自身按 URI 排除——同一渠道可能有其它版本 /
  投稿；B 站曲目的 artists 是 UP 主、不当歌手关键词；每个源的口径由
  `SourceSwapStrategies`（`lib/services/source_swap/source_swap_strategy.dart`）
  声明，未声明渠道走默认；
  `CatalogService.search` 复用 5min 缓存；逐源就绪即填充，单源失败进
  `failedSourceKeys` / `failedSourceNames` 可重试），载体是统一的「换源」页
  （`lib/pages/source_swap_page.dart`：歌词 / 音频两个 tab，歌词侧为
  `LyricsSourceSearchView` + `LyricsSourceSearchSession`（逐源搜索 / 过期结果 /
  可用性 / 选中写缓存的状态机，视图只渲染与提示），音频侧为 `SourceSwapView`；
  入口：歌曲信息页「换源」
  默认音频 tab、歌词页 FAB menu「换歌词」默认歌词 tab、收藏页合集（收藏 / 历史 /
  自建列表）行动作（触摸端左滑胶囊 / 桌面右键菜单）默认音频 tab）点候选即试听
  （单曲「换源试听」上下文）、
  确认后经 `LibraryProvider.replacePlaylistTrack` / `replaceHistoryEntry` 原位
  替换（仓库事务保 `sortOrder`/`addedAt`/`playedAt`，目标键已存在先确认去重），
  并经 `PlaybackProvider.replaceQueueTrack` 让队列中同 id 曲目跟随换源（新增
  `PlaybackFacade.replaceQueueTrack` 端口；命中当前曲目重新取链从头播放，
  冷启动恢复会话同步替换并落盘）。
  **歌词 tab**：来源来自 `LyricsSourceRegistry`
  （`lib/services/lyrics/lyrics_source_registry.dart`）——五个音乐平台 + LRCLIB
  参与自动名字回退；`BuiltinPlatforms` 中同时有 `search` + `lyric` 适配器的渠道
  自动获得通用 `BuiltinLyricProvider`（当前为 B 站 CC/AI 字幕），新增渠道无需改
  UI。B 站字幕需登录：未登录时该来源只显示提示、不发搜索请求；且只进手动换源，
  不参与自动回退。停用渠道从其歌词来源中隐藏（LRCLIB 不是渠道，不受影响）。
  **自动换源**：播放失败同源重试仍失败后，组合根注入的 `AutoSourceSwapService.findMatch`
  用 `lib/services/song_match.dart`（LX `findMusic` 判定的唯一实现，与歌词搜索
  回退共用）**严格匹配**（时长 ±5s、版本词一致）跨源找回并静默替换队列曲目
  （经 `PlaybackSessionCoordinator.replaceQueueTrack` 命令：live 转发 facade 并
  返回前提交会话，恢复态 / 未命中 no-op，provider 不直写 facade）；
  provenance（每个曲目的已尝试来源）保证级联每源至多一次、有界；
  开关 `SourceSwapSettings`（`source_swap_auto_enabled`，默认开）在设置 › 播放。

### 听歌统计（listening statistics）

- **口径唯一**：`PlayStatisticsLimits.qualifiedThresholdMs` / `isQualified`
  （`listenedMs ≥ min(30s, 50% × 时长)`）是「有效播放」的唯一实现；SQL 谓词
  （查询实现内的 `_qualifiedPredicate`）与 AI 跳过判定都从它派生，SQL↔Dart
  一致性由 `test/play_statistics_formula_test.dart` 用同一批 fixture 行对照
  （曾经 SQL / Dart / AI 三份手写，奇数时长上 AI 还差 1ms）；
- **范围值类型**：`PlayStatisticsRange` + `startOf(now)` / `sinceMs(now)`
  （领域扩展）是范围 → 时间窗口的唯一映射，查询与热力图高亮共用；
- **曲目内容表**：`play_events` 只存事件字段 + `trackId`；元数据与载荷
  （gzip BLOB）在 `play_tracks` 每曲一行，写入按「内容时间取新」（旧事件不顶
  新内容），读取（`topTracks` / `dayEvents` / `listEventsForExport` / 同步导出）
  一律 join 补齐；载荷另有字节预算（`maxRetainedPayloadBytes`），超出按最近
  播放保留、其余清 `raw`（点播回退重新解析）；
- **一次快照**：`PlayStatisticsRepository.snapshot(since:)` 并发取回
  `ListeningStatisticsSnapshot`（汇总 / 榜单 / 日历 / 作息热力图 / 来源分布），
  统计页只渲染它（不再分开读 6 个查询）。
- **同步存储**：`StatisticsSyncStore`
  （`lib/domain/ports/statistics_sync_store.dart` +
  `lib/data/sync/statistics_sync_store.dart`）以类型化 `StatisticsSyncEvent`
  出 / 入，拥有导出缓存与廉价指纹、本地下载曲目过滤
  与按 `syncKey` 合并；写面 `StatisticsSyncWriter` 负责事件行创建
  （`startEvent`，含 `syncKey` / 来源设备）与收尾取号 / 日志 / 导出缓存维护。
  `StatisticsSyncAdapter` 只做类型化事件 ↔ `SyncRecord` 的映射，
  `PlayStatisticsRepository` 只依赖 writer，不再 import 同步 wire 模型或自己
  拼同步列（列名 / 版本列 / 增量日志形状都收在 store）。

### 资料库（library）

`lib/domain/ports/library_store.dart`（UI 面）与 `library_sync_store.dart`
（同步面）是两条 seam：同一个实现类（`lib/data/library_repository.dart`）
兼两者，组合根分别注入。

- **写入网关**：`lib/data/library_write_engine.dart` 拥有本地写入的五步仪式
  （发号 → 写行 → journal 记录 → 墓碑 → 变更事件），仓库的公开写方法只做委托
  ——漏步（漏号 / 漏日志 / 漏墓碑 / 漏通知）在结构上不再可能；同步面应用远端
  记录不走仪式（版本由远端给、不发号、不追 journal），只复用网关的墓碑行形状
  与 syncId 补齐原语；
- **UI 面**：领域意图（历史 / 列表 / 曲目 / 收藏 / 导入）+ 类型化变更事件
  （`LibraryChange`，类型即失效范围）；`sortOrder`、墓碑、保留行名
  `__favorites__` 等存储形状不出实现（收藏是 `PlaylistInfo.isFavorites`）；
- **同步面**：类型化记录出 / 入（`PlaylistSyncRecord` /
  `PlaylistTrackSyncRecord` / `PlayHistorySyncRecord` / `SyncTombstoneRecord`）；
  同步适配器不再逐字段读列名，记录形状（含 JSON 键）由 record 类承担；
- **测试假实现**只实现 UI 面窄 port（不再继承真类）：新方法不会静默走真实 SQL。
- **收藏页合集状态**：`CollectionSession`（`lib/providers/collection_session.dart`）
  拥有「当前合集」的恢复 / 校准 / 模式 / 按行 key 的多选 / 加载组合 / 滚动键
  激活与切换持久化；`LocalSongsCollection`
  （`lib/providers/local_songs_collection.dart`）拥有本地歌曲的历史 × 下载 /
  导入 × 完整音频缓存联结、下载优先去重、输入签名、在途令牌 / 过期丢弃与
  加载态 · 弹层计数；`CollectionPresenter`（`lib/providers/collection_presenter.dart`）
  拥有合集身份（kind / 落库 id / 展示名 / 合集键 / 列规范）、可见行投影（过滤 /
  排序）与行动作构成。`CollectionView.visibleRows` 是统一的 `CollectionRow` 联合
  （列表曲目 / 播放历史 / 本地歌曲），`rowActionsFor` 按行变体给动作规格；收藏页
  每帧只把资料库读取端口 + 下载 / 缓存快照交给会话，消费一个
  `CollectionSessionView`（视图 + 当帧 `CollectionFrame` + loading / ready /
  failed），不在 build 里做 post-frame 校准或 `ensure*` 编排，也不按 kind
  分支拼行或挑动作。端口只有
  「一帧快照 + 一条加载意图」：`CollectionLibrary.snapshot(playlistId:)` 返回
  `CollectionLibrarySnapshot`（列表清单 / 播放历史 / 两者读取阶段 / 当前选集
  的 `PlaylistTracksView`），`load(CollectionLibraryLoad)` 表达首帧、当前列表
  曲目、整页重试与历史重排（playlist id 与 force 在意图里）；`LibraryProvider`
  的其余成员不再逐个映射成 getter。会话不缓存上一帧快照：弹层计数
  （`ensureLocalSongsReady`）与失败重试（`retry`）只接受 `sync` 交回的
  `CollectionFrame`（端口 / 快照 / 下载 / 缓存 / 落库列表 id），页面不存在
  「先 sync 一次」的隐藏调用顺序；多选的生产入口也收在会话意图
  （`clearSelection` / `selectAllVisible` / `isSelected` / `selectedCount`），
  页面不直接持有 `CollectionSelection`。资料库读取
  阶段与写入结果都是类型化值（`LibraryReadState` / `LibraryMutationOutcome`）：
  读取失败给重试态而不是空资料库，批量写入只在成功（含无变化）后清空选择。
  列表曲目读取失败会保留错误，只有显式重试（`force`）或仓库变更事件才重读
  ——每次 build 清错重试会把收藏页变成永久 loading（pitfalls #90）；读取有
  10s 超时兜底。列表 / 历史刷新失败也给终态（有旧数据 ready，空数据 failed），
  不把状态留在 loading。
- **合集行动作**：`lib/providers/collection_actions.dart` 是收藏页「选中的行 /
  当前视图 → 类型化命令」的唯一翻译层（播放 / 收藏 / 移除 / 历史删除 / 本地
  删除 / 重排 / 复制）；行变体归一与 provider / 下载 / 缓存选择在模块内，页面
  只留确认 / 提示 / 清选择与布局。播放 / 加入列表接 `track_handoff.dart`
  （context 适配在 `widgets/collection_handoff.dart`）；本地删除返回
  `CollectionLocalDeleteOutcome` 逐项状态，失败不再逃进 `unawaited`。收藏页
  不再出现 `as ...Row` 强转。
- **链接导入**：收藏页合集弹层的「导入收藏」有文件 / 链接两条路径；链接路径
  `showLinkImportDialog` 的平台列表来自 `BuiltinPlatforms.discoverSources`
  （六平台），`DiscoverProvider.playlistDetail` 拉详情后写入本地列表。
  B 站收藏夹由 `bili_favorites.dart` 解析数字 / `fid` / `media_id` / `ml<id>` /
  `space...favlist` / `b23.tv` 短链并按 `media_count` 全量拉取（上限 50 页 /
  1000 条），只收公开视频；私密 / 失效收藏夹归一为 `notFound`。
  `importTracks` 返回 `created`：新建列表的曲目就是本次写入的全量，
  `LibraryProvider.importTracksAsPlaylist` 直接预置列表头与曲目缓存，收藏页
  切过去不再依赖一次读库（后台变更加载到位后原地校准）；同名复用列表仍有
  旧曲目，继续走读库。

### 本地下载（downloads）

`lib/services/download/download_service.dart` 是单曲下载的唯一编排实现
（下载一首 / 一批：取链 / 缓存拷贝 / 分项 / 标签 / 发布 / 落库），
`download_queue.dart` 是任务队列（严格串行 FIFO / 去重 / 取消 / 重试 /
进度通道）；组合根（`main.dart`）注入取链 / 取词 / 取图 / 缓存 / 设置与省流
上限；任务队列、命名 / 放置、记录装配、提交日志与通知 presenter 是五个独立
module（见下）：

- **模块拆分**：`DownloadService` 只做编排，五个 module 各有一份唯一实现——
  `lib/services/download/download_records.dart`（记录只读面：记录表 / 排序
  列表 / `initialized` / `supported` / `revision` 的唯一持有者；收藏、单曲
  本地数据与分享只依赖它，下载进度不经过这里）、
  `lib/services/download/download_manager.dart`（命令面：管理页 / 本地数据页 /
  分享 / 导入使用的窄接口，唯一实现是 `DownloadService`）、
  `lib/services/download/download_queue.dart`（下载任务队列：`DownloadTask`
  进度 / 状态、单 worker FIFO、同 key 去重、排队 / 运行取消、失败保留重试；
  不持久化、无跨重启恢复）、
  `lib/services/download/download_journal.dart`（提交日志：rename 前写 pending、
  启动恢复音频记录；详见下文「下载提交日志 / 崩溃恢复」）、
  `lib/services/download/download_file_layout.dart`（命名 / 放置：文件名模板 →
  基名 → sanitize → 磁盘与记录双重查重的 ` (2)` 去重 → 音频 / `.part` /
  `lyrics/` + `.t.lrc` 翻译边车 / `covers/` 路径约定与 sidecar 写入回滚 →
  扩展名推断（B 站 `.m4s` 音频归一为 `.m4a`） → 记录引用文件集，删除 / 失败清理 / 孤儿判定共用）、
  `lib/services/download/download_record_assembler.dart`（记录装配：部分状态 →
  `DownloadedTrack` 16 字段的唯一装配点，四种形态各一个意图方法）、
  `lib/services/download/download_notification_presenter.dart`（通知 presenter：
  单任务 / 批量 id 分配、批量共享一条「N/N」、500ms 系统频率节流、收尾只收自己
  起过的；端口 / 设置 / 时钟可注入）。命名不再有「测试双胞胎」，测试直接打生产
  实现；
- **任务队列与进度通道**：音频 / 歌词 / 封面共用同一条队列，全局严格串行
  （单 worker、FIFO），`enqueue` 同步进入等待列表（批量一次入队全部，页面
  立即看到等待列表）；同 key 已有排队 / 运行任务时返回同一 future，失败 /
  取消任务再入队则替换。完成 / 取消后从队列移除，**失败音频任务保留供本次
  进程重试**（重试生成不带批量位置的新任务，批次结束后按单任务通知），
  歌词 / 封面等分项失败直接移除（由调用方 snackbar 呈现）。
  **队列不持久化**：重启只保留既有的 `.part` 清扫，不做断点续传或任务恢复。
  进度只由 `DownloadTask` 通知并做 100ms 合并（首个分片 / 100% / 终态立即
  送达），队列只在任务增删 / 状态变化时通知；系统通知仍逐分块上报（presenter
  自己 500ms 节流）。严格串行同时消除了同名 `.part` 竞争与分项记录并发覆盖；
- **取消**：`cancelTrack` 先撤排队任务（队列移除并抛 `cancelled`），运行中再
  取消 dio `CancelToken`；半成品清理后统一以 `cancelled` 失败收尾（UI 静默）；
- **目录与位置**：下载根目录按平台解析（`IoDownloadStorage`）——桌面 =
  系统公共下载目录下 `Molia/`（Windows 走 Known Folder，OneDrive 重定向时
  不会写到 `%USERPROFILE%\Downloads`；Linux 读 XDG `XDG_DOWNLOAD_DIR`，回退
  `~/Downloads`），iOS = 应用文档目录 `Molia/`（文件 App 可见），Android =
  应用数据目录 `downloads/`（**公共副本**另经 MediaStore 发布到
  `Download/Molia`，见下）；设置页可选自定义目录
  （`DownloadSettings.saveDir`，存储层每次解析读取，改设置无需重启）；
  `lyrics/` + `covers/` 子目录与 `cache/audio_cache` 完全隔离——「清理缓存」
  永不触碰下载，「删除下载」是独立动作；`DownloadStorage` 是平台 seam
  （原生 MethodChannel 实现，存储不可用时 `supported=false`，UI 隐藏全部入口）；
- **Android 公共目录发布**（issue #17）：下载完成后把音频 best-effort 拷进
  MediaStore 的 Downloads 集合（`Download/Molia/`，与桌面同构），用户在文件
  管理器 / 其它播放器里可见。**公共副本是发布副本，不参与播放取链**：应用
  目录里的 `filePath` 仍是唯一播放源，`publicUri`（drift 列）只用于删除时
  回收副本；API 29+ `insert + openOutputStream`（应用自己创建的行无需存储
  权限，`IS_PENDING` 防半成品可见），< 29 返回 null 不支持；平台 seam
  `DownloadsPublisher`（`lib/data/downloads/downloads_publisher.dart`：
  MethodChannel `top.stillmisty.molia/downloads`，
  失败 / 通道缺失一律 no-op 只记日志）；发布开关
  `DownloadSettings.publishToPublicDir`（默认开，仅 Android 显示），管理页
  提供「补发布到公共目录」回收旧记录；
- **另存目录（导出）**：`lib/services/save_as.dart` 统一所有用户可见的文件
  导出——桌面 = 系统公共下载目录下 `Molia/`（下载设置的自定义目录同时生效），
  Android = `Download/Molia/`（临时文件 + `DownloadsPublisher` 进 MediaStore），
  iOS = 应用文档目录 `Molia/`（文件 App 可见）。桌面弹“另存为”并预填文件名 /
  默认目录，取消静默；Android / iOS 直接写默认目录并提示位置；对话框不可用时
  回退直接写。布局：音频在 `Molia/` 根下，备份 / 听歌统计进 `exports/`，海报
  PNG 进 `posters/`，封面原图进 `covers/`；导出文件不落库、不参与同步；
- **缓存优先**：所选音质的完整音频缓存（`CacheService.audioCacheKeyForTrack`
  同名且无 `.part`）命中时直接拷贝不触网；歌词经注入的 `LyricsService`（缓存 →
  原生取词 → 跨平台回退，与播放页同一链路）；封面经 `ArtworkCache.bytesOf`
  命中直读、未命中取图后 `putBytes` 回填；
- **两档本地数据（ADR-0008）**：缓存（易失）与下载（持久）分开命名、合在一个
  页面（`lib/pages/track_local_data_page.dart`）呈现。完整音频缓存按「已缓存」
  识别——信息页「本地数据」行与页内状态（体积 · 音质 · 可离线使用），动作是
  「转存到本地文件夹」（拷贝成持久副本，不触网）；播放取链在下载记录之后回退
  缓存（`localUriFor`：精确音质优先、未命中用其它已缓存音质）→ `file://`
  离线可播；收藏页「本地歌曲」合集按播放历史 × 缓存目录前缀匹配列出缓存行
  （保留原曲身份，删除 = 清缓存）。缓存可被 LRU / 用户清理移除，状态与列表随
  `CacheService.revision` 回退（不承诺持久可用）；
- **音频缓存只认完整文件**：`CacheService.audioCacheIndex` /
  `audioUsageForTrack` 排除半成品（`.part` / `.predl`）与 MIME 边车
  （`.mime`）：占用展示、命中探测、「缓存曲目」列表同一口径；半成品单独统计
  （页内「写入中」）。启动清扫中断残留半成品；磁盘约定（命名 / 完整判据 /
  索引 / 清扫）的唯一实现在
  `lib/services/audio_cache_store.dart`（Audio cache store），`CacheService`
  的同名静态方法是薄委托；缓存文件名写入侧（`SourceTrack.songId`）与读取侧
  （`TrackId.id`）必须同名（回归测试见
  `test/services/track_local_data_service_test.dart`）；
- **落库**：drift `downloads` 表（`filePath` 可空——记录可以只含
  歌词或只含封面；`publicUri` 存 Android 公共副本定位；`imported` 标记
  **本地导入**：就地引用用户文件、删除只移行）存原音源曲目键 +
  自包含快照 + 原 raw + 音频路径/音质/大小 + 歌词/封面路径；
  `DownloadsRepository` 负责行 ↔ `DownloadedTrack` 映射；
  半成品 `.part` → 原子改名 → 落库，播放取链只认数据库记录；启动时先恢复
  提交日志，再清扫崩溃遗留 `.part`；
- **下载提交日志 / 崩溃恢复**：`lib/services/download/download_journal.dart`
  是文件型 write-ahead journal（**不新增 DB 表、不迁移 drift**）。位置 =
  应用数据目录 `download_journal/`（Windows LocalAppData，其余平台应用支持
  目录；`DownloadStorage.journalRoot()`，与下载根
  解耦：改保存位置 / 清公共目录不影响恢复；它也不是用户文件，不放进下载夹）。
  音频 `.part` 写完后、rename 前写一条 pending `DownloadedTrack`（仅音频，
  继承旧 sidecar / publicUri；文件名 `<md5(key)>.json`，`.tmp` 写 + rename
  原子替换）；**写失败会在 rename 前中止下载**，不留下没有恢复保障的最终文件；
  rename 后继续歌词 / 封面 / 标签 / 发布，最终落库后删除 marker。
  启动 `init` 在加载记录后、`.part` 清扫前恢复：已有**音频**记录或最终文件不存在
  只删 marker；只有分项记录（歌词 / 封面）不算已落库，文件存在则补库 + 删 marker；
  补库失败保留 marker 下次再试。
  journal 只包裹单个音频提交，**不是队列持久化**（排队 / 失败任务重启仍清空）；
- **本地导入**：`DownloadService.importLocalFiles`（收藏页「本地歌曲」合集 →
  「导入本地歌曲」：多选音频文件）**不复制文件**——记录以
  `local:<绝对路径>` 为原音源键（同路径重复导入幂等），`filePath` 指向原文件；
  标签读 `lib/data/downloads/audio_tag_reader.dart`（mp3 ID3v2 / flac Vorbis
  Comment + 时长），其余格式按 `歌手 - 歌名` 文件名兜底。删除导入项只移除
  记录（原文件保留），补发布 / 孤儿清理都跳过导入项；
- **标签嵌入**：音频就绪后把标题 / 歌手 / 专辑 / 歌词 / 封面写进文件标签
  （`lib/data/downloads/audio_tag_writer.dart`：自写 MP3 ID3v2.3
  UTF-16+BOM 文本 / USLT / APIC 与 FLAC Vorbis Comment + PICTURE，ffprobe
  验证可读；不引入 FFI/TagLib 依赖），失败保留 sidecar；开关在下载设置；
- **`local` 音源**：`lib/data/catalog/local_music_source.dart`
  （capabilities 只有 `resolveUrl`，读 payload.path → `Uri.file`；
  文件缺失归一化 `notFound` + `downloadFileMissing`）；
  `SourceRegistryImpl.byKey('local')` 特殊路由（manager 不认识该 key），
  不出现在搜索 / 发现 / 渠道排序；本地曲目 `origin = localFile`，
  自动换源与「换源」入口都按来源跳过；
- **本地副本优先取链**：组合根在 `LocalPlaybackBackend` 的 resolver 外层
  装饰（`DownloadService.localUriFor`：下载记录 → 完整缓存 → `file://`），
  未命中回落 `CatalogService.resolve`，取链缓存策略不变；
- **缓存写入分平台**（ADR-0008）：移动端由 just_audio 的
  `LockCachingAudioSource` 边播边写（`platformSupportsAudioCaching`，写入请求带
  取链 headers）；桌面 media_kit 后端不能走 `StreamAudioSource`，改由
  `PlayingTrackCacheWriter` 起播后带 headers 后台下载当前曲目字节（`.predl` →
  原子改名 → LRU，`platformSupportsAudioPrefetch`），重播即命中 `file://`；两者互斥
  （同一文件不双写），切歌 / 停止 / 销毁取消；省流生效时两侧都跳过；
- **离线播放**：封面走本地文件（`AppNetworkImage` / `ArtworkCache` 对
  `file://` 走 `FileImage`）；歌词由组合根的歌词加载器读
  `downloads/lyrics/`（翻译 `.t.lrc` 边车），且 `LyricsService` 对本地
  曲目禁用网络回退（离线播放不触网）；
- **下载通知（Android）**：`DownloadNotificationService`（`dataSync` 前台服务）+ 通道
  `top.stillmisty.molia/download_notifications`，Dart 侧 seam
  `lib/data/downloads/download_notifications*.dart`（生命周期编排在通知
  presenter 模块）；进行中显示进度（批量共享
  「N/N」），完成 / 失败 / 取消收尾；API 33+ 未授权通知 → 降级为无通知继续下载；
  开关 `download_notifications`（设备本地键，默认开）。
- **同步过滤**：歌单曲目 / 历史 / 统计 / 播放会话适配器都过滤
  `sourceKey = local` 的条目（含墓碑）——文件是设备本机持久副本，
  同步到其它设备不可播放；
- **设置与管理**：`DownloadSettings`（设备本地键，不登记同步：保存位置 /
  文件名模板 `{artist}`/`{title}`/`{album}` / 标签嵌入开关 /
  Android 公共目录发布开关）；保存位置在桌面同时作用于导出，Android / iOS
  的展开位置由 `SaveAs.rootPath()` 展示（播放副本 vs 系统「下载」另存）；
  下载弹层已并入「本地数据」页（`lib/pages/track_local_data_page.dart`，信息页
  唯一入口）：音质选择（命中缓存的音质标「已缓存」并预选）+ 音频两档状态
  （已下载 / 已缓存 · 可离线使用 / 下载中 / 未下载）+ 动作（下载 / 转存到本地
  文件夹 / 取消 / 分享导出 / 删除下载）+ 歌词/封面各自下载或转存 + 缓存占用
  四项（音频 / 歌词 / 封面 / 取链）逐项清理与全部清理；
  下载管理页（`lib/pages/downloads_manage_page.dart`，设置 › 数据与存储）：
  **任务区只展示运行 / 等待 / 失败**（运行在前；等待超过 20 首折叠成「还有
  N 首等待中」），任务区订阅队列结构、每行只订阅自己的 `DownloadTask` 进度，
  不再整页 10Hz 重建；失败区给出原因 + 单条重试 / 移除 + 顶部全部重试；
  **不展示已完成列表**，完成即从任务区消失，批量结束用 snackbar 汇总成功 /
  失败。批量下载（当前队列 / 指定歌单，跳过已下载与本地曲目）只负责入队，
  页面不锁；**不做断点续传**（平台直链多为一次性签名地址）。文件维护
  （`.part` 清扫、孤儿文件回收、Android 补发布公共副本）单独占用维护 busy，
  不影响下载操作；孤儿扫描只收应用可识别的格式（音频扩展名 / `.lrc` +
  `.t.lrc` / 封面图片），用户手放的 `notes.txt` 等任意文件不参与；运行中
  任务已产生 / 即将产生的输出（音频 / `.part` / 歌词 / 翻译 / 封面）也排除
  在外；删除前弹层展示数量与前几个文件名，随后按这一批路径再校验记录引用
  与活跃输出后删除。已下载列表不再单独成页，由收藏页「本地歌曲」合集浏览
  （下载副本 + 导入的本地文件）。
  省流生效（移动数据 + 已开启）时下载前先确认：本地数据页、下载管理批量、
  来源行「下载并分享」三处共用
  `lib/widgets/download_data_saver_guard.dart::confirmDownloadOnDataSaver`，
  弹层统一挂 root navigator（设置弹层 / 二级页的内层 Navigator 不能误退页面）。

### 设置注册表（settings registry）

`lib/data/settings/`（键声明 / 模块访问面 / 注册表 / 密钥盒端口）：

- `settings_keys.dart`：登记键总表 —— 键名、默认值、同步类别（跟人走 / 音源 /
  凭证）、存放盒（prefs / secure）的唯一声明处；设备本地键（省流、缓存策略、
  全局字体、桌面歌词悬浮窗、托盘与关闭行为、播放会话、曲库数据…）
  不登记，留在各自模块（只有一位消费者，收进来只增加门房面积）。快捷键开关 /
  绑定四键（`kShortcutsEnabled` / `kGlobalShortcutsEnabled` /
  `kShortcutBindings` / `kGlobalShortcutBindings`）按「跟人走」登记，此前漏在
  总表外、现已进入同步范围；
- `settings_access.dart`：模块面 `SettingsAccess`（`read` / `write` / `clear` /
  `bindReload`）；整表与同步面（`readRaw` / `writeRaw` / `onWrite` /
  `reloadKeys`）不下放。`SettingsRegistry.scope([...])` 返回 `SettingsScope`
  （同一注册表 / 同一存储上的按键视图），只能访问声明过的键，越界在 debug
  断言、release 抛 `StateError`；模块构造参数只依赖 `SettingsAccess`，漏注入
  是编译错误；
- `settings_registry.dart`：登记键的唯一实现（读 / 写 / 同步往返 / 重载钩子）；
  `onWrite` 只允许组合根绑定一次（第二次绑定断言 / 抛错），避免同步标记被
  静默覆盖。组合根只在 `catalog_stack.dart` 构造唯一实例，其它 stack builder
  按模块分发 `scope`（catalog / library / playback / lyrics display / AI）；
  `CatalogStack` / `LibraryStack` / `PlaybackStack` 的 `settings` 字段指向同一
  实例，组合根冒烟测试据此核对身份；模块初始默认值取自
  `SettingsKey.defaultValue`（主题 / 导航 / 快捷键 / 统计等），字段里不再复制
  一份字面量；
- 键的名字字面量只准出现在 `settings_keys.dart`
  （`test/architecture/settings_keys_test.dart` 扫描 `lib/**` 强制）；
  整表注册表只准在组合根与设置层构造
  （`test/architecture/settings_registry_usage_test.dart` 扫描强制）：
  漏登记 = 显式选择「不同步」，私建注册表 = 漏同步钩子，都不再是静默漂移。

同步适配器（`PrefsSyncAdapter`）不再自带键表与类型转换：键规格、默认值与读写
都来自注册表；ADR-0003 §6 的「登记哈希」变化检测保留，但适用范围收窄为
未登记的设备本地键。

## 4. 状态与通知策略

| 状态 | 频度 | 承载 | 订阅方式 |
|---|---|---|---|
| 播放进度 | ≤4Hz | `PlaybackProvider.position`（ValueListenable） | `ValueListenableBuilder`（进度条/歌词行） |
| 定时关闭剩余 | 1Hz（仅倒计时且播放中） | `PlaybackProvider.sleepTimer`（ValueListenable） | `ValueListenableBuilder`（歌曲信息页/弹层） |
| 曲目/播放/队列/模式 | 事件级 | facade 快照（值变才发） | `Selector`（不可变对象/record） |
| 搜索结果/分页 | 交互级 | `SearchProvider`（按 `SearchKind` 三会话，分页状态机 `PagedListController` 以状态值发布）；详情页用 `PagedTrackCollection` 捕获同页实体 | 局部 select |
| 音源列表/顺序 | 事件级 | `SourceRegistry.changes` | 选择器/管理页 |

硬性规则：高频数值禁止进聚合 `notifyListeners`；`select` 禁止返回 `Map`/`List` 引用；
歌词行高亮用 `PositionLineIndexBuilder`（仅跨行重建）；队列列表用稳定引用。
歌词页可见性门控：播放页内部再包一层 `ShellPageVisibility`（nearest scope =
壳层可见 && 当前 tab），隐藏时 `PositionLineIndexBuilder(enabled: false)` 不订阅
position、不自动滚动 / 不起快捷操作弹簧，重新可见时同步一次当前行。

### 播放页封面堆叠（cover deck）

- **模块**：`lib/widgets/player_cover_deck.dart`（组件 + 横滑手势 + 会话的效果宿主）、
  `player_cover_session.dart`（`CoverSwapSession` 状态机 + `CoverSwapHost` 意图接口）、
  `cover_appearance.dart`（`CoverAppearance` 外观 / `CoverFlight` + `CoverFlightLayer`
  飞行 / `CoverCard` 卡片 / `MorphCover` 副本内容 / 封面 URL·key 归一化）、
  `player_cover_swap.dart`（方向判定纯函数）；播放器只提供布局尺寸、顶栏共享飞行
  锚点与主题联动。
- **三槽位模型**：左 = 上一首（实际播放顺序最近一首 → 队列前一位 → 空，
  排除与当前同 id，与后端 `skipToPrevious` 同源）、中 = 当前（拖动/提交等待/回退期间
  为预览目标）、右 = `PlaybackSnapshot.next`；拖动预览时源侧槽位提前显示目标之后的
  身份（前进 = `upNext` 的再下一首，后退 = `previousOfPrevious`），窗口随进度连续
  滑动；左右槽只要展示了身份即可点击切歌。
- **会话与宿主（时机 / 效果分离）**：会话只决定「什么时候」，宿主（deck State）决定
  「怎么做」——会话经 `CoverSwapHost` 意图接口驱动控制器编排、post-frame 与播放命令
  （`startSettle` / `land` / `releasePreview` / `settleCommit` / `crossfadeCorrection` /
  `hardReset` / `adoptSteadySlots` / `requestSkip` / `notifySwapped` / `armTimeout` …），
  次序不变量（例如「settling 前先把进度钉回起点」）由会话的调用顺序持有。会话是
  `ChangeNotifier`，只在离散迁移通知；拖动跟手的逐帧进度不进会话。
- **会话与阶段**：阶段 `idle → preview（跟手）→ committed（提交等待对账）→ settling
  （即时切歌完成中）` / `correcting`（对账不匹配校正）/ `returning`（松手未达标、
  取消或提交超时后的回退，预览目标保持到弹簧落位）。唯一一根进度控制器由 deck
  State 持有，拖动跟手按位移反解写入，松手从同一进度续走或回弹，不跳；回弹是
  拖动预览的严格反向，落位前不得换回当前封面；回拖/回弹期间当前封面压在目标
  封面之上（只改绘制顺序，不改中心身份）；即时切歌由 motor expressive spatial
  弹簧驱动，无固定时长。
- **检测与缓存（唯一写入者）**：deck 把快照喂给 `CoverSwapSession.observe`——切歌检测、
  空闲缓存（左槽身份 / 下一首 / 方向提示）与预览目标全由它派生，调用方不再各刷一半；
  渲染侧只补空闲视觉（中心同 id 换图 250ms、槽位身份 180ms 原位交叉淡化）。空闲刷新
  以宿主的 `progressAnimating`（弹簧尾部也算）门控，快照通知仍按微任务合并同批通知，
  build 期间零写入。
- **窗口时序与常量**：目标槽位旧身份 p∈[0,0.4] 淡出、源槽位新身份
  p∈[0.6,1] 淡入（仅透明度、无位移，避免叠影）；拖动预览的源侧新身份同样走这个
  窗口，对账到同一身份时从预览透明度连续接管（p=1 直接满值），不一致 / 不可预测
  时保留 180ms 纯淡入兜底；移动卡全程插值（位移 ±0.30 卡宽、
  旋转 ±0.05rad、缩放 0.78↔1.0、透明度 0.85↔1.0）；对账校正 220ms；提交后
  6 秒（`CoverSwapSession.commitTimeout`）无对账回弹。
- **侧槽外观缩放**：侧槽卡不是另一套外观，而是 `CoverAppearance.page` 的
  圆角 / 描边 / 阴影 / 裁剪按侧槽缩放 0.78 同步缩放（图标仍按侧槽边长取
  比例）。换场终点滑出卡是「主封面尺寸 × scale 0.78」，只有外观也缩放，
  落位帧的圆角 / 描边 / 阴影才与滑出卡逐像素重合，不会在动画完成后二次跳变。
- **连切接管**：弹簧途中再次切歌时，`startSettle(direction, nextTrack)` 捕获
  上一段中心卡（上一段进场卡）与滑出卡在 `p0` 的视觉状态，分两种模式：
  - **continuous**（同方向且 `p0 < 0.75`）：新会话的滑出卡用
    `q = (p - p0) / (1 - p0)` 从捕获位置连续插值到目标侧槽，弹簧不重置、
    直接从当前进度续走；新中心卡在 `p0` 已进入 source neighbor 淡入窗口
    （≥0.6）时，从该侧槽卡的实际位置/透明度按 q 接管到中心，否则仍用
    全局 p 的侧槽入场公式；
  - **restart**（方向反转 / `p0 ≥ 0.75` / 新中心就是上一段滑出卡）：先把
    controller 停掉并置 0，post-frame 起全新弹簧；旧中心 B 从捕获视觉按
    p 0→1 插到新方向目标侧槽；新中心 C 若就是上一段滑出卡 A（方向反转最
    常见），从 A 的捕获视觉插到中心；否则若 C 已作为上一段 source neighbor
    半透明出现，接住它在**旧方向**侧槽的实际位置/透明度按 p 插到中心；
    两者都不成立时才从新方向侧槽全槽位入场。controller 置 0 会合成一次
    completed 状态，宿主用重置标记屏蔽，不能让它清掉刚捕获的 handoff。
  两种模式都：上一段更早的滑出卡作为独立 tail 层短淡出；tail 按 track id
  去重（同一身份最多一张），layer key 只依赖 track 身份（restart rebase
  p0 时 Element 不重建）；新中心身份会先从 tail 列表移除，避免回绕/重复
  id 时 tail + center 同曲两张卡；restart 时旧 tail 按当前渲染值 rebase 到
  新 p=0，且若旧滑出卡成为新中心就不再作为 tail 重复渲染；接管期间
  `oldNeighbor` 层被抑制。接管快照记录上一段实际中心 track
  （`centerFromTrack`，含 restart 的 C==A / source neighbor 与 continuous
  的 source neighbor），链式接管按实际捕获视觉继续，不退回公式位置。
  `hardReset`、会话完成与非接管路径清空接管快照。中心/预览卡不再借用
  上一首封面作加载占位，目标图未命中时走曲目自己的默认封面 / 中性回退，
  避免旧封面从新卡下面透出。
- **对账**：提交后等待快照 current 变为会话目标——匹配无缝落位；不匹配
  （随机目标 / 失败恢复 / 列表变化）先让提交过渡落位，再以 220ms 中心原位
  交叉淡化校正到实际曲目，随后按新快照重建槽位回 idle。
- **冷启动首帧**：deck 首次绑定若快照已有 `current`，`CoverSwapSession.adoptInitial`
  只建立身份与邻位缓存，不播切歌入场；首帧三槽位直接按恢复队列稳态渲染。只有
  从空态出现首曲目才走 `observe` 的首帧入场。邻位占位只在槽位身份过渡时借用当前
  封面，稳态使用中性占位（避免冷启动首帧三张同图）。
- **非视觉路径（可同步断言）**：可见性翻转（TickerMode，两个方向）与隐藏态切歌都走
  会话的 no-animation 落位（`setVisible` / 隐藏态 `observe`：`hardReset` + 身份对齐），
  宿主侧只负责控制器归位与中心身份接管。
- **与共享飞行的关系**：顶栏↔播放页与迷你↔完整飞行只隐藏/复刻中心封面真身
  （`morph.pageCoverKey`）；页中心显隐是零时长 `Opacity`（飞行副本精确承接，
  进入首帧就隐藏、落位帧与副本移除同帧亮出，离开方向飞行期间也收起）。
  侧邻位由 `PlayerMorphController.pageDeckReveal` 驱动：复用同一根飞行弹簧，
  进入时只在飞行最后约 45% 让侧槽**原位淡入**（透明度 0→0.85；位置与倾角
  始终保持稳态 ±0.30 卡宽 / ±0.05rad，不做平移/缩放/转正）；离开时间对称，
  前 45% 原位淡出。这样侧图从第一帧可见时就是其最终姿态，不会先水平平移
  再倾斜。每个侧槽由窄包装器直接监听该 `ValueListenable`，卡片作为稳定
  child，reveal 逐帧只重建 Opacity/IgnorePointer，不重建 deck 主 builder 或
  图片子树；reveal=0 保留布局与图片状态（opacity 0），避免尾段淡入时重新
  解码闪占位。reveal 只作用于左右槽，中心锚点始终是稳态
  矩形，reveal=1 时不叠加 transform，减弱动效直接落位。飞行期间整层
  `IgnorePointer` 关闭中心点击、侧槽点击、横滑与按压反馈；已按下的拖动由
  morph 隐藏翻转主动收尾，不依赖 PointerCancel。
- **飞行几何与外观**：外观与插值只有一份实现（`cover_appearance.dart`）——三端真身
  （顶栏 r8/图标 22、迷你 r8/图标 24、播放页 r18 + 1px 描边 + 柔和阴影/裁剪 17/图标
  0.35×边长）是 `CoverAppearance` 的命名值，两个飞行是 `CoverFlight` 的薄壳；两条
  代数不变量：描边透明度 = 描边宽度、裁剪半径 = 外圆角 − 描边宽度。飞行副本经
  `CoverFlightLayer` 渲染（`CoverCard` + `MorphCover`），外观按「播放页端进度」
  插值（反向起飞不跳），图标按两端真身尺寸插值。迷你⇄完整飞行在阈值收尾后仍有
  弹簧容差拖尾（`AnimationStatus` 仍为 `forward`）：拖尾内反向切换必须由进度监听
  补起新飞行，不能只依赖状态变化。
- **飞行性能结构**：`PlayerMorphFlight` 与 `CoverFlightLayer` 都包
  `RepaintBoundary`，逐帧重绘不扩散到整条 Overlay；`CoverFlightLayer` 把
  `MorphCover` 图片子树做成 `AnimatedBuilder.child`（稳定 child），逐帧只更新
  几何、裁剪、描边/阴影与回退图标尺寸。阴影按「页端进度」降级：飞行前 80%
  不画 24px blur，80%→95% 线性恢复、最后 5% 保持真身强度（避免落点前一帧
  阴影突然变重；`t=1` / 反向 `t=0` 与真身完全一致）。这是先保飞行平滑、
  尾段恢复阴影的取舍，仍需真机 profile 确认收益。
- **飞行几何不变量**：锚点在点击那一刻**同步**抓取（封面 URL 同刻确定，飞行中不换
  图），因此①隐藏页层（出场过渡结束/未参与过渡）必须 `scale == 1`
  （`app_shell.dart::shellPageLayerPresentation`，出场微缩只存在于过渡进行中）；
  ②矩形读取必须映射两角得到真实屏幕矩形（唯一实现
  `player_morph.dart::anchorRectOf`，容器为空 = 全局坐标），祖先稳态缩放
  （暂停态 0.98、按压 0.96）不得让副本尺寸/位置错位。

## 5. 音源引擎

- `LxEngineSupervisor` 状态机：`stopped → starting → ready`；invoke 探活判定引擎无响应 /
  isolate 退出 → `restarting`（退避 0.5s/2s/8s，重放同一脚本），连续 3 次 → `failed`；
  单个请求超时（引擎仍在响应）不再重启，只失败该请求并计入连续超时熔断（3 次 → `failed`
  + `failureReason`，成功一次清零）；重启期间请求等待 ready（10s 上限）；重启成功刷新
  `activeSources`。
- 在线更新：脚本 meta `@updateUrl` / 运行时 `updateAlert` → `checkScriptUpdate`（版本 +
  内容 hash）→ `applyScriptUpdate`（原地替换，激活中自动重放）；下载 10s 超时 / 1MB 上限 /
  HTML 识别。
- any-listen：配置页 + `AnyListenSource` 适配器骨架（当前 HTTP 占位端点；官方为 WS IPC）。

## 6. M3E 设计语言

- 壳：`M3EMaterialApp(data: buildM3EThemeData(themedData), theme: themedData, ...)`；
  `ThemeProvider` 是唯一主题源（`autoTheming/dynamicColoring` 关闭）。
  `buildM3EThemeData` 把应用字体同步到 baseline + emphasized 两套 typeScale
  （`M3EThemeData.fromMaterial` 只映射 baseline）。
- 桌面骨架（`lib/app/desktop/**`，仅 linux/windows/macOS；移动骨架逐像素不变）：
  两套骨架的导航 / 顶栏共享 spec 在 `lib/app/shell_chrome.dart`（目的地 → 图标 /
  标签映射、设置按钮、窗口控件、标题槽左缘 / 拖动区只一份；骨架各自适配渲染），
  布局阈值在 `lib/widgets/desktop_layout.dart`（壳层解析一次，页面 / 骨架只消费）。
  顶栏本体是 `lib/app/shell_app_bar.dart::ShellAppBar`：`M3EAppBar.top(density:
  compact)`（56dp 工具行）+ 可选底部槽（移动骨架的波浪进度）+ `WindowDragArea`
  + `AnnotatedRegion<SystemUiOverlayStyle>`。**整条工具条（标题 + 按钮）放进
  M3E 的 title 槽**：桌面窗口控件是一整块可变宽的 Row（约 180dp），而
  `M3EAppBar.actions` 按 48dp/个预留标题宽度，直接放会重叠；title 槽拿到的是
  左 16 / 右 4 的整宽，按钮由这一行自己排。
  顶栏是纯工具条（无当前页标题、无播放控制、无进度线）：最左是**品牌区**
  （`MoliaMark` + 自定义应用名，贴窗口左缘（`ShellChrome.appBarTitleSpacing`，
  16 = 包内 `M3EAppBarTheme.titleInset`）处、不再与内容左缘对齐，品牌区左缘
  从 12 变 16 是预期；整块可点打开搜索遮罩，**不做 tooltip**：键位提示只留在
  设置 › 快捷键）；
  品牌区右侧的空白是拖动区（双击最大化，只有它包 `WindowDoubleTapMaximize`，
  双击品牌 / 按钮不最大化）+ 设置 + 窗口按钮（仅 Linux / Windows 自画；macOS
  保留原生标题栏与红绿灯，`WindowChrome.usesCustomTitleBar` 为 false；图标
  按钮一律不做悬浮提示，语义走 `semanticLabel`，全应用同口径——见「按钮选型」）。
  **全局搜索**是 Ctrl+F / 品牌区打开的全屏遮罩（`lib/widgets/global_search_overlay.dart`）：
  壳层在内容区中上放一个隐形占位盒，遮罩打开时实测它的矩形，把搜索条与结果面板
  摆在同一条位置（自建 route 挂在根导航器上，坐标是整窗口径）；结果与资料库共用
  同一 `SearchProvider`，空关键词时结果面留空（只剩搜索条）；遮罩打开时壳层 Esc
  让位（`EscapeClaims` 登记），另有一层整窗 `BackdropFilter` 跟遮罩开合淡入淡出
  （自绘 scrim 只压暗，模糊由壳层补；关闭时 `Opacity` 为 0、不参与合成）。
  **不要换回 `M3ESearchAnchor`**：包内 docked 视图的目标矩形完全由锚点推导，锚点
  就在静止位置时容器变换位移为 0（开合没有过渡动画），且包内只在弹簧落定后才给
  输入框聚焦（Ctrl+F 后立刻打字的按键会被吞掉）；自建 route 自己走「scrim 淡入 +
  内容淡入轻微缩放」，输入框首帧 autofocus。
  左侧 `M3ENavigationRail` **恒折叠** 96dp（`alwaysCollapse` + `alwaysShow`：
  无展开按钮、标签常显，改窗口宽不改变形态；有标签时选中指示器是包内
  56×32 胶囊，无标签会退化成 56×56 圆，横向展开在桌面大图标下很违和）。
  底部播放条 80dp 只在非播放页出现（左：封面/歌名/收藏 · 中：上一首/
  播放/暂停/下一首 + 可拖波浪进度 + 时间 · 右：播放模式/音量（图标 + 弹出
  滑杆）/队列入口）：
  播放页是沉浸主场，整条让位（瞬时，不做收起动画——进入方向的共享飞行以底栏
  封面为起点，动画会把起点拖走）。队列是播放页右栏的一栏：底栏队列入口 =
  跳播放页 + 切队列 tab（`NowPlayingController`），Esc 的可配置「关闭队列」
  在播放页里把队列视图收成默认页（其它目的地 no-op —— 壳层看不到页内 tab，
  命令按目的地生效）。播放页桌面版式 = 左 **480** 固定
  （封面/歌名·歌手两行/进度/传输控制 + 音量，不显示专辑行）+ 右「队列 / 歌词 /
  详细」三 tab（**次 tab**：图标 + 文案一行、行高 48、默认歌词，图标走 `M3EIcons`；
  tab 栏与内容同一内容边距 **16**（队列列表 / 宽版式歌词行 / 歌曲信息页都对齐
  tab 栏，页面边距 24 只用于浏览 / 详情页），队列列表不再分「正在播放 / 接下来」
  小标题（tab 文案已表达分组，只有 `includeCurrent` 面板保留「正在播放」小节）；
  `NowPlaying(desktopLayout: true)`，无圆点手势）。
  桌面专属交互：**快捷键分「软件内」与「全局」两组**（用户口径：都可关闭、可自定义）。
  绑定模型在 `lib/services/shortcut_bindings.dart`（动作 ↔ 组合、两组默认表、JSON 覆盖），
  开关与自定义持久化在 `lib/services/shortcut_settings.dart`（跟人走），设置入口
  「设置 › 快捷键」（设置首屏「通用」卡，与听歌统计同一层；
  录制交互见 `lib/widgets/settings/shortcut_recorder_tile.dart`；
  录到已被占用的组合、或单行「回默认」撞上被占用的默认组合时弹确认层，确认后
  互换两者的生效组合——`ShortcutSettings.swapBindings`；「同组无重复」由
  `ShortcutSettings.setBinding` 单点保证）。
  软件内挂载点是 `lib/app/desktop/desktop_shortcuts.dart`（`HardwareKeyboard` 处理器——
  **不要**换回顶层 `Focus.onKeyEvent`：焦点落到壳层 Focus 的祖先（route 作用域）后按键会
  整体失效；输入框聚焦 / 录制中 / 总开关关闭时全部让位）；全局热键是
  `lib/services/global_hotkeys.dart`（`system_hotkeys`：Windows RegisterHotKey / macOS
  RegisterEventHotKey / Linux `org.freedesktop.portal.GlobalShortcuts` 门户，**纯 Dart +
  D-Bus、零原生依赖**；只收字母 / 数字 / F1–F12 / 空格，默认全 Ctrl+Alt 前缀且默认关闭；
  注册结果 conflict/unsupported/declined 逐条记 `lastError` 并在设置页提示）。两组共用
  `lib/services/shortcut_actions.dart` 的命令执行器。曲目行操作入口 = 桌面行表面右键在
  鼠标落点弹菜单（`lib/widgets/track_actions_menu.dart::showTrackActionsMenuAtPointer`）、
  触摸端行尾 ⋮ 常显（队列行维持无 ⋮）、收藏页桌面同样走右键 / 触摸端左滑胶囊
  （同一组动作）、可点元素手型光标（M3E 自带）、收藏页桌面多选（Ctrl 点选 /
  Shift 范围 / Esc 退出，移动端长按语义不变）。
  Esc 裁决：`HardwareKeyboard` 处理器**全部执行、返回值不短路**（无法靠返回值
  裁决谁消费），页面级 / 弹层经 `lib/services/escape_claims.dart` 登记「此刻的
  Esc 归我」（判定现算，隐藏页 / 已关弹层不残留占用），壳层命中 Esc 命令前先让位
  （返回 false，不消费事件）——**页面级 / 弹层 Esc 优先于
  壳层可配置命令**（用户把别的命令绑到 Esc 也一样让位）；登记方自己的按键处理器
  接 Esc（与登记同源、不依赖焦点位置；收藏页多选与音量弹层都是 `HardwareKeyboard`
  处理器）。
  内容版式（阈值与宽度来源的选择唯一在 `DesktopLayout`，判据一律「窗口宽 /
  窗口宽 − 侧栏折叠宽」，页面不再自己量宽）：宽屏表格列（`TrackRowModel` / `TrackRowSurface` /
  `TrackTableHeader`；`tableColumns` / `tableColumnsFor`，阈值 = 内容宽 ≥ 720
  （播放历史档 812），使用点：搜索 / 收藏 / 发现详情；行高两档走
  `TrackRow.extentOf`（表格单行 56 / 列表双行 72）；发现页表头为 pinned sliver
  （封面头部滚走后列标题仍在），搜索 / 收藏页表头固定在滚动区之上）、
  设置首屏两列（`masterDetail`：桌面 + 窗口宽 ≥ 900；列优先瀑布式，分区按
  内容量显式分列，短卡不再按行留空）、设置弹层宽屏 880 + 首屏两列
  （`showSettingsSheet` 显式 `maxWidth`，公共 modal 档保持 560）、二级页侧滑桌面档 720。
  页边距：桌面档与平板档同宽（24），内容区宽度由「窗口宽 − 侧栏折叠宽」表达。
  启动首页由 `NavProvider.effectiveHomeDestination` 决定（设置 › 通用 › 启动时打开，
  默认播放页；存储首页被隐藏时按导航顺序兜底且**不改写存储**，避免同步回环）。
  应用内音量（`PlaybackProvider.volume/muted`，设备本地持久化、落盘防抖 400ms）
  经 `PlaybackFacade.setVolume` 落到 just_audio（桌面 media_kit 同一播放器）。
- 取色模型（唯一优先级，见 ADR-0001）：**基础配色**（壁纸 / 自定义，单选）+
  **封面覆盖**（当前曲目已有封面取色结果时用封面 seed 覆盖基础配色，包括
  盖过莫奈；启动恢复态在首帧前用本地缓存预解析；无封面回退）+
  **纯黑**（深色下覆盖 surface 系列，与来源正交可叠加）。
  解析：`封面 > 壁纸图 seed（Linux / Windows；macOS 暂无壁纸读取入口）> 强调色方案 > 自定义` → `applyPureBlackScheme`。
- 封面取色 seed 持久化（`ArtworkPaletteSeedStore`）：键 = 封面内容身份
  （`CoverImageIdentity`：URL + 本地文件 size + mtime），值 = seed。它是可从像素
  重算的派生缓存，只存设备本地，不登记 `SettingsRegistry`、不参与同步 / 备份；
  换设备或清数据只会多一次取色。启动预解析先读 seed，命中直接
  `ArtworkPalette.fromSeed`，不读图片字节、不解码、不跑量化；内存 LRU 与并发
  合并也按内容身份索引，稳态链路随后直接复用。封面命中时启动**不解析桌面壁纸**
  （壁纸 seed 只在封面未命中时按原逻辑解析；代价是本次启动切到壁纸档没有壁纸
  seed，重启或封面未命中时补上）。壁纸的 `loadLocalFile` 不读 / 不写 seed。
- 主题出口：`lib/theme/app_theme.dart::buildAppThemeData(ColorScheme)` 是唯一 ThemeData 构建处，
  并注册语义色扩展 `AppSemanticColors`（success/warning，固定色调、随亮度派生）；
  `ColorScheme` 派生唯一入口 `lib/theme/scheme_builder.dart::buildColorScheme`；
  `main.dart` 经 `AnimatedSchemeBuilder`（450ms）平滑过渡方案色，两套主题同源重建。
- 封面取色：`lib/services/artwork_palette_service.dart` 是唯一取色入口（像素 → seed →
  双亮度方案 + LRU），由组合根监听 `PlaybackProvider` 触发（任何页面/后台切歌同一链路；
  省流时本地缓存可取色、未命中保持现色，无封面清除回退）。**任何模块不得二次提取
  封面像素**；消费面（桌面歌词 / 海报）按各自的 `SurfaceColorSource` 经
  `resolveSurfaceScheme` 解析（封面方案缺失回退应用主题）。
- 色彩契约：`primary` 只用于交互/选中/强调图形；正文 `onSurface`、次要文本 `onSurfaceVariant`；
  容器配 `on*Container`；状态色走 `AppSemanticColors`（错误用 `scheme.error`）。
  禁止 `Colors.*`/`Color(0x...)` 字面量、`withAlpha/withOpacity`、
  `scaffoldBackgroundColor/dividerColor` 双源属性（`test/architecture/color_usage_test.dart` 扫描强制）。
- 当前曲目（曲目列表）：标题 `primary` + 封面右下角 `primary` 圆形状态角标
  （播放中自绘均衡器动画（PlayingIndicator 3 柱起伏）/ 暂停同一均衡器原地冻结、
  不换暂停图标，见 `widgets/current_track_cover.dart`）；减弱动效时静态显示，
  含播放行的 widget 测试不要 `pumpAndSettle`；`selected`（多选勾选）优先，
  选中时只显示勾选、不叠角标。队列的「正在播放」小节保留既有高亮，不叠角标。
- 组件：UI 全面使用 `M3E*`；基础件（Scaffold/Text/Icon/Theme 等）来自 `material_ui`
  （M3E 必需依赖，不要试图移除）；禁止 import `package:flutter/material.dart`，
  组件 import 用 `package:material_3_expressive/material_3_expressive.dart`。
- 可点击封面统一走 `lib/widgets/cover_tap_target.dart`（透明 `M3ECard` 状态层：
  hover / press / 焦点环 / 键盘激活）；页面只保留封面裁切与打开原图。
- **二级页 chrome**：`ResponsiveNavigation.showSecondaryPage(title:, body:)` 收口
  窄屏全屏（`M3EAppBar.top`）与宽屏 `M3ESideSheet`。页面用 `embedded: true` 只出
  正文（不带 Scaffold / AppBar），两种 chrome 由宿主提供；宽屏宽度用
  `M3ESideSheetTheme.copyWith(width/maxWidth)` 覆盖到详情页档位（平板 520 /
  桌面 720，包内默认上限只有 400），body 外包透明 `Material` 补 ink 祖先并补
  键盘 bottom inset。**设置子页是例外**：`SettingsSubPage`
  （`lib/widgets/settings/settings_subpage.dart`）是设置内层 Navigator 的 chrome
  （Scaffold / AppBar / `kSettingsPadding` 滚动正文的唯一实现），因为预测返回
  要按「子页 / 弹层首屏」分派手势归属，普通返回也要先退子页再关弹层；设置域
  之外仍走 `showSecondaryPage`。
- **页面型弹窗**：`showPageModal` —— 窄屏 `M3EBottomSheet`，宽屏 `M3EDialog.show`
  + `PageModalCard`（`M3ECard` 取 `M3EDialogTheme` 的圆角 / elevation / scrim；
  容器色取 `surface`，与页面自带 Scaffold 的底色一致）。简单弹层（定时关闭 /
  来源分享）用 `showSimpleModal`：窄屏底部弹层、宽屏 `M3EDialog` 本体。底部弹层
  header 因 `M3EBottomSheetHeader` 未公开导出，按 `fullScreenHeaderHeight`(64) /
  `titleLarge` / `M3EDivider` 自绘。
- **排序**：三处 `ReorderableListView`（`lib/widgets/settings/settings_reorderable_rows.dart`、
  `lib/pages/favorites.dart`、`lib/widgets/collection_track_list.dart`）是长期例外——
  material_3_expressive 1.2.0 未公开导出 `M3EListReorderHost` /
  `M3EListReorderExclude`，公开的 `M3EList(reorder: true)` 会二次包裹行并顶掉行尾
  操作；保留显式手柄与 `itemExtent`，白名单在
  `test/architecture/m3e_component_usage_test.dart`。
- **排版**：UI 一律 `context.typeScale`（`lib/theme/m3e_context.dart`），强调位
  （品牌名 / 播放页标题 / 收藏合集标题）用 `emphasizedTypeScale`；不直接读
  `ThemeData.textTheme`、不写 `w600/w800/w900`；护栏
  `test/architecture/m3e_typography_test.dart`（`lyrics_poster_service.dart` 例外：
  无 context、固定设计稿排版）。
- **已知例外**（`m3e_component_usage_test` 白名单）：3 处 `ReorderableListView`；
  2 处 `SelectableText`（M3E 无可选文本件）；热力图 `Tooltip`（需要 400ms wait，
  `M3ETooltip` 无 wait API）；M3E 弹层 / 歌词滚动区 / 全局搜索遮罩 / 音量面板 /
  壳层底栏的透明或容器 `Material`（补 ink 祖先 / 浮层表面，不是可点组件）；
  全局搜索自建 route（pitfalls #57）。
- 动效：**spatial（位置/尺寸/形状/缩放）走 motor 弹簧**——token 取
  `M3EMotion.*` / `MaterialSpringMotion.*`，落定统一 `snapToEnd`；
  **effects（透明度/颜色/文本）保持时长+曲线**，与 spatial 同帧耦合的透明度
  从同一份弹簧进度派生并截断 0..1（effects 不过冲）。共享元素飞行（顶栏⇄播放页）
  用 `aospSpatial` 无过冲弹簧并在落定帧零速度交接；不要再用
  `AnimationController` + `Curves`/`SpringSimulation` 手搓 spatial 运动
  （交互细节见 `docs/pitfalls.md` #21）。壳层 tab fade-through 的控制器是
  `BoundedSingleMotionController` + `M3EMotion.expressiveSpatialDefault`
  （`snapToEnd`；`shellPageLayerPresentation` 消费处 clamp 0..1），形状配方仍在
  `shellPageLayerPresentation` 的 Curves 里。歌词页行高亮 / 翻译展开是 effects
  （`medium1` / `short4` + emphasized 曲线），自动滚动用 `long4` +
  `emphasizedDecelerate`；effects 时长 / 减弱动效统一经
  `lib/theme/motion_policy.dart`（`reduceMotionOf` / `effectDurationOf`）收口
  （减弱动效零时长，自动滚动直接落位）；网络封面 `AppNetworkImage` 显式覆盖
  `CachedNetworkImage` 默认 500/1000ms 淡入淡出，走 `short4` / `short2` +
  emphasized 曲线。翻译展开只为当前行播放（其余行零时长硬切）。音量浮层 /
  收藏页多选栏也走这套收口：浮层缩放是 spatial 弹簧、透明度从同一进度截断
  0..1；多选栏与页头同高交叉淡入淡出（effects 时长 + 曲线，离场层
  `IgnorePointer`）。
- 设置页：首屏 7 个语义分区（外观 / 封面 / 播放 / 歌词与展示 / 内容与来源 /
  通用 / 数据），分组标题 + 分段卡片行：行表面统一走共享的
  `lib/widgets/card_list_surface.dart`
  （`CardListSurface`：静止内 4dp / 首末外侧 16dp、hover 12dp、press 16dp，
  expressive spatial 形状弹簧；`TrackRow`、设置行、AI 推荐卡同一套形状语言），
  行间 `cardList.gap`、位置由 `SettingsSectionCard` 下发（`SettingsRowPosition`），
  排版走 `M3ETypeScale`、不写死字号字重；统一行组件在
  `lib/widgets/settings/settings_tiles.dart`（Nav / Switch / Info / Value /
  Choice / Dropdown / Slider / ColorValue），行骨架（图标 / 标题副标题 /
  行尾间距 / 禁用态）由同一个私有 `_SettingsTileRow` 下发，行尾动作图标统一
  20dp；按值类型选型：bool → Switch、
  2–5 项短枚举 → Choice（行内分段，显式宽度，防 `M3ESegmentedButton` 零宽溢出；
  短标签行可配逐项图标——选中段的对勾替换图标，M3E 选中形态；长标签行
  （Repeat all / Sequential / Single repeat）保持纯文字分段，图标或勾都会挤断文案）、
  ≥5 项或长文案 → Dropdown（必设 `fieldStyle.hintText`）、区间数值 → Slider、
  大范围绝对量（缓存上限）→ Value + 输入弹层（带常用预设）；
  子页（音源 / 歌词显示〔二级：歌词页 / 歌词输出 / 桌面歌词 / 通知·锁屏 / 蓝牙〕/
  AI 推歌 / 通用 / 数据与存储 / 缓存 / 统计）经设置弹层壳
  （`lib/widgets/settings/settings_sheet.dart`）的内部 Navigator 在同一弹层内
  push（`openSettingsSubPage`）；省流模式不单开
  子页，开关与生效子项并回首屏「播放」分区。音源管理页（`sources_page.dart`）
  与 any-listen 页同样使用这套设置行组件与分段卡片行距。系统返回先退子页、
  再关弹层：窄屏底部弹层由 `showPageModal(onDismissRequest:)` guard 读取
  内部 Navigator 的 `canPop()`（M3E 弹层宿主会给层内所有 PopScope 回调发 didPop=false
  并请求关闭，必须由 guard 挡下）；宽屏设置弹窗是 `M3EDialog.show` + `PageModalCard`，
  返回仍由弹层壳自己的 `NavigatorPopHandler` 先退子页。
  弹层内 dialog 挂在 root navigator（`M3EDialog.show` 语义），关闭须显式
  `rootNavigator: true`。
- 页面过渡 / 预测返回：Android 侧 `PageTransitionsTheme` 必须保留
  `PredictiveBackPageTransitionsBuilder`（`lib/theme/app_theme.dart`）——手势跟手预览
  只由它插入的手势 detector 提供，换成普通 builder 会静默退化成「能返回、无预览」
  （`WidgetsBinding._handleCommitBackGesture` 无观察者时走 `handlePopRoute`）。
  由此根导航器上 push 的页面（二级页）都有预览。M3E 的弹层类表面（底部弹层）由包内
  宿主自实现预览：宿主自己当手势观察者，guard（`onDismissRequest`）非空时也接管
  （material_3_expressive ≥ 1.1.7），提交后交给 guard 裁决——guard 拒绝则预览回弹、
  表面留在原位；1.1.6 及以下宿主在 guard 非空时直接放弃手势，那条链路会静默退化成
  「无预览」的普通返回，故依赖下限 1.1.7（当前 1.2.0；原因见 `pubspec.yaml` 注释）。
  二级页宽屏侧滑走 `M3ESideSheet.show`、页面型弹窗走 `M3EDialog.show` 路由，scrim /
  弹簧 / 键盘 inset / 关闭手势都由 M3E 宿主处理；自建 route 只剩全局搜索遮罩。
  嵌套 Navigator（设置弹层内层）由
  `settings_sheet.dart` 的 `_SettingsPageTransitionsBuilder` 做**手势归属**判定：内层 Android
  过渡保持 fade-forwards 并附一个预测返回 detector，只在
  `内层路由 isCurrent && popGestureEnabled && 内层 Navigator 还能 pop &&
  弹层路由仍是顶层` 时接管。框架会把一次手势派发给**所有**返回 true 的观察者，
  不做归属判定就会和内层子页 / 最上层 dialog 各退一级。归属结果经
  `SettingsSheetBackCoordinator` 传给弹层的动态 `M3EBottomSheetTheme`：
  - 子页手势：弹层 `predictiveBackShrinkX/Y` 归 0，只显示与 push 一致的
    FadeForwards 页面退场；提交只退子页，弹层保留（guard 读 coordinator 返回 false）。
  - 首屏手势：弹层正常收缩，提交关闭设置。
  护栏见 `test/settings_page_test.dart` 的「子页预测返回由页面接管」「根导航器上方
  dialog」两组用例；协议本身由 `test/settings_sheet_back_coordinator_test.dart`
  直接覆盖（含微任务重置时机）。
- 图标：统一圆角风格 `Icons.*_rounded`（不用 `Icons.adaptive.*`，不混 `_outlined`/基础实心）；
  唯一例外 `library_music_outlined`（资料库未选中半对；音符图标已改用 `MoliaMark` 组件）。
  `test/architecture/icon_usage_test.dart` 扫描强制。**同一按钮的状态图标切换**统一走
  `lib/widgets/icon_swap.dart::IconSwap`（150ms emphasized 交叉淡入 + 0.85→1 轻微缩放、
  减弱动效跳变），不要在调用点裸写 `AnimatedSwitcher`；底部导航 `icon↔selectedIcon`
  由包内 `M3ENavIconScale` 负责，不要再叠。
- 弹层观感差异（M3E 统一 inverseSurface Snackbar、无红底错误色、`M3EDialog` /
  `M3EBottomSheet` / `M3ESideSheet` 圆角与 spring 入场）属预期，不是 bug。
- 播放页操作按作用对象分三域（见 ADR-0007）：**歌词域**（会话 / 来源 / 展示 / 导出）
  在歌词页，操作收敛为底部右侧 `M3EFabMenu`（换歌词 / 复制模式 / 歌词海报 /
  居中跟随；无歌词时 = 换歌词 + 歌词显示设置；无曲目隐藏）——`position: right`
  让胶囊自右缘生长、右边缘对齐，项文案统一取「动作 + 对象」的短名（3–6 字）；
  **曲目域**
  （身份 / 渠道 / 音质 / 本地数据 / 评论）在歌曲信息页，段落顺序 =
  操作（评论 / 定时关闭 / 换源）→ 本地数据（两档状态 / 下载转存 / 缓存清理）→
  信息（音质 / 可用音质 / 专辑 / 来源 / 歌词来源）；**播放域**（模式 / 收藏 /
  定时）在播放器进度排 + 信息页。
  曲目级操作的打开编排（能力位、守卫、换源页 tab）唯一实现在
  `lib/widgets/track_actions.dart`；单曲本地数据在
  `lib/pages/track_local_data_page.dart`（读取唯走 `TrackLocalDataService`，
  两档词表见 ADR-0008），缓存内容变更经 `CacheService.revision`、下载记录经
  `DownloadRecords` 通知跨页刷新。
- 列表行统一走 `lib/widgets/track_row.dart`（队列/收藏/历史/本地歌曲/发现/搜索结果共用）：形状按 M3E 列表规范
  （静止内 4dp、首末外侧 16dp；hover 12dp；press/选中 16dp），带 expressive spatial 弹簧
  morph；分段列表用 `cardList.gap`（2dp）行距、
  `itemExtent = TrackRow.extentOf(context, tableColumns: …) + gap`，
  列表一律懒构建（发现详情滚到底自动加载下一页）。不要改回 `M3EListItem`（原因见 pitfalls #20）。
  收藏页四个合集共用一份列表脚手架 `lib/widgets/collection_track_list.dart`
  （顺序列表 / 重排模式、搜索空态、行动作形状：触摸端左滑胶囊 `SwipeRevealRow` /
  桌面右键菜单，动作词汇 `RowAction`）；
  空态配方统一在 `lib/widgets/empty_state.dart`（图标 40 + 文案 + 可选行动，
  收藏 / 资料 / 发现共用，居中与页边距由调用方包一层），滚动位置簿记在
  `lib/widgets/collection_scroll_bookkeeping.dart`（调度器可注入，脱离 widget 树可单测），
  页内过滤 / 排序口径在 `lib/utils/collection_row_query.dart`。
- 曲目行操作动作与入口：动作词汇 / 条目映射 / 两平台入口在
  `lib/widgets/row_actions.dart`（`RowAction` 回调不可空；`rowMenuEntries` /
  `rowMenuSelection` 是动作 → 菜单条目的唯一映射；触摸端 `RowActionMenuButton`
  常显 ⋮，桌面端 `rowActionsAtPointer` 给行表面右键回调）。低层菜单面
  `lib/widgets/track_actions_menu.dart`：触摸端锚点固定 standard 图标按钮且语义走
  `semanticLabel`；桌面端行尾无 ⋮、行表面右键在鼠标落点弹同一份菜单
  （`showTrackActionsMenuAtPointer`：零尺寸锚点 + root overlay 坐标换算，贴边由
  M3E placer 夹取）；条目一律「leading 图标 + 文案」，收藏这类开关态用图标 +
  文案表达（选中即关菜单，不留勾选态）。动作定义（收藏 / 加入列表两条动作 +
  领域接线）见 `lib/widgets/track_menu_tile.dart`（`trackRowActionMenu` /
  `…ForTrack` / `…ForSearchItem`，行组件与自建行共用，领域状态由构造处
  `select` 后传入）；收藏域的行适配（歌手页 / 专辑页）走
  `lib/widgets/favorite_track_tile.dart`；收藏页合集的行动作由
  `lib/widgets/collection_track_list.dart` 的 `buildCollectionRowActions` 从
  投影器的动作声明 + 接线编译（接线缺席的动作不出现），触摸端编译成左滑胶囊
  （`collectionSwipeActions`）、桌面端经 `rowActionsAtPointer` 作右键菜单。
- 按钮选型（按作用对象与意图，已按 M3E 实测校正）：
  - 同一批对象的 2–3 个平级动作 → `M3EButtonGroup`（`standard` 间距；命令式动作
    组级统一 `tonal`，把 `selectedIndex` 恒留空、回调里直接分发，避免留下选中态）。
    图标 + 文案是常态；只给图标（如合集弹层标题行的新建 / 导入）或只给文案都可，
    icon-only 动作按方形静止宽渲染（sm 40×40）；**图标按钮的语义一律走
    `semanticLabel`、不做悬浮提示**（icon 自解释时，hover / 长按 / 键盘焦点弹的
    气泡只是噪音，桌面鼠标扫过尤其明显；`tooltip` 只留给图标表达不了的文本：
    热力图数据值、页圆点隐藏标题；护栏 `test/architecture/tooltip_usage_test.dart`）。
    纯图标动作需要中性色时用 `style: text` +
    组级 `decoration.foregroundColor`（`material_3_expressive ≥ 1.2.0`）；
  - 「主操作 + 变体 / 次要出口」→ `M3ESplitButton`（播放全部 ▾ 随机播放全部·加入列表、
    下载并安装 ▾ 打开发布页、复制 ▾ 复制全部）；纯文本样式不支持（包内断言
    `style != text`）；「随机播放全部」先 `setPlayMode(shuffle)` 再装载队列、
    起点在可见列表内随机（与收藏页同一约定）；
  - 组内动作没有 key，且组会构建一份不可见测量副本：测试用
    `find.byIcon(...).hitTestable()`（或自定义 finder）定位真实动作；
  - 对话框 action 区保持「text 取消 + filled 确认」两颗独立按钮：弹窗宽度放不下
    带图标的分组，且主次层级要保住；
  - 紧凑位置（行内重试、状态卡内取消）用 `M3EIconButton`（语义交给
    `semanticLabel`）；
    纯图标按钮保留稳定 key，测试按 key 定位。
- 触感：全应用唯一入口 `lib/services/haptics.dart`（设置 › 通用 › 通用设置 ›
  震动反馈，默认开，设备本地键）；底栏重复点击的轻震由壳层给一次、页面不重复给
  （原「壳层不给触感」的口径已反转）。
- 已知保留（无法等价替换）：全局搜索遮罩的自建 route（`showGeneralDialog`）、
  `ScaffoldMessenger` 兼容代码（M3ESnackbar 宿主）；组件级白名单见上文「已知例外」。

## 7. 验证与性能

```bash
flutter analyze --no-pub                 # 0 error / 0 warning
flutter test --no-pub                    # 含 domain/catalog/playback/layering/supervisor/update
tool/agent/test.sh linux                 # 集成测试（引擎/设置页/窗口/托盘；不含播放）；默认 Xvfb 无窗口
tool/agent/test.sh android               # 同一份集成测试跑模拟器（跑完自动卸载）
flutter build apk --debug
flutter build apk --release --split-per-abi --split-debug-info=build/symbols --obfuscate \
  --extra-gen-snapshot-options=--strip   # 发布体积（APK 压缩打包见 android/app/build.gradle：~50%↓）
```

已兑现的性能收益：进度 tick 不再触发聚合通知（进度条/歌词行局部重建）；队列列表进度期 0
无谓重建；同曲重播/同词重复搜索命中缓存（0 次引擎/网络往返）；引擎崩溃自愈不再「源列表
残留但全超时」；发现曲目行只订阅本行收藏态，详情页无限滚动按页去重追加（无新增即停）。

## 8. 后续

- any-listen 真实协议（WS IPC）接入（当前为 HTTP 占位端点，抽象已就绪）；
- 真机验证：Android 17 通知/耳机键、iOS 18+ 后台播放；歌词显示的模拟器交互与通知栏验证、
  A2DP 车载字段映射（见 `docs/lyrics_display.md` §9）；
- 桌面歌词平台输出等 Flutter windowing stable（同上 §11）；M3E 组件目视复核（弹层观感/间距）；
- 发布前：release 体积与签名检查。
