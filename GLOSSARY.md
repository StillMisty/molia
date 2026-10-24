# GLOSSARY

本仓库的领域词汇表：架构评审、模块命名与代码注释以此为共享语言。新增术语在落地时登记，避免同义多词。

## 曲目与平台对象

- **Raw track（平台 raw 曲目）** — `SourceTrack.raw` / `Track.payload` 承载的平台原始对象（LX `musicInfo` 约定：songmid / hash / copyrightId / qualitys ...）。取链 / 歌词 / 封面请求必须原样回传；只允许「只增不删」地补齐规范 id 字段。
- **Raw track module（raw 约定模块）** — `lib/sources/raw_track.dart`：平台 raw 的 id 取键（`rawIdOf` / `platformRawIdOf`）、规范字段补齐（`withCanonicalId`）与音质解析（`qualitiesFromRaw`）的唯一实现。`SourceTrack.id`、`TrackId`、收藏 / 列表 `songId`、`.lxmc` 导入与发现曲目映射共用它。
- **Canonical id field（规范 id 字段）** — 各平台取链脚本读取的 id 键：wy / tx / kw → `songmid`，kg → `hash`，mg → `copyrightId`。`.lxmc` 导入的 raw 缺少该字段时由 raw track module 补齐。
- **Artist ref（歌手引用）** — raw 的项目内部字段 `_artists`（`[{'name','id'}]`，与 `_types` / `_interval` 同约定：内置平台解析时增补、LX 字段只增不删）：平台内歌手 id 与曲目 payload 同体系（kw `allartistid` / `ARTISTID`（多歌手按 `&` 与名字同序）/ kg `Singers[].id` / tx `singer[].mid` / wy `ar[].id` / mg `singerList[].id`）。唯一读取入口 `raw_track.dart::artistsFromRaw`，由 `track_mapper` 填进 `Track.artists[].id`；UI 只读 `Track.artists`（不读 payload），据此把歌手名做成歌手页链接。脚本扩展源 / 旧数据没有该字段 → 歌手入口按只读降级。
- **Artist label（歌手标签）** — `Track.artistLabel` / `primaryArtistName`（`lib/domain/models/track.dart`）：展示与持久化的唯一歌手文本口径（过滤空名后 `, ` 连接、全空返回空串；领域层不放英文兜底，UI 兜底走 l10n `unknownArtist`）。脚本回传 `SourceTrack.artist` 的 `/` 拼接是 track_mapper 的搜索键口径，不属此列。
- **Platform id（平台 id）** — 不带平台前缀的单曲标识；[`SourceTrack.id`] 为其加上 `sourceKey:` 前缀。`rawIdOf`（通用优先级）与 `platformRawIdOf`（`.lxmc` 导出的平台优先顺序）是它的两个取键入口。
- **Source preferences（渠道偏好模块）** — `lib/sources/source_preferences.dart`：渠道偏好（音质 / 顺序 / 停用）的状态与持久化唯一实现（写失败吞错收拢为统一策略），`settings_registry` 的 reload 由模块自绑；`SourceManager` 保留同名方法委托并向 UI 转发通知。
- **Builtin transport（内置传输模块）** — `lib/sources/builtin/builtin_transport.dart`：五个平台搜索/发现共用的 HTTP 入口（客户端可注入、统一请求头/超时、响应级重试 `retryIf`、JSON 解码与 `cached` 结果缓存）。`BuiltinSearch.transport` 是唯一实例，测试注入 `MockClient` 即可覆盖 fetch 路径；HTTP 重试预算统一为 `BuiltinTransport.defaultRetries`（发现端点的业务级预算见 Builtin retry attempts），结果缓存统一为 `defaultCacheTtl`（5 分钟，single-flight + LRU + TTL），发现适配器不再各自持有静态 `RequestCache`。
- **Builtin platform registry（内置平台注册表）** — `lib/sources/builtin/builtin_platforms.dart`：内置五平台的唯一注册表：规范键 `wy / tx / kg / kw / mg`、展示名、搜索候选排序位，以及类型化能力族适配器（搜索 / 歌词搜索 / 评论 / 专辑 / 歌手 / 发现）。能力位由适配器是否存在推导，各 facade 与 `SourceManager.capabilitiesFor` 读同一条目；新增平台只改这里，不再同步七份 `supportedKeys` 与 switch。
- **Builtin retry attempts（内置尝试循环）** — `builtin_transport.dart::runBuiltinAttempts` + `BuiltinRetryBudget`：`attempt` 返回 null 表示本次失败、未达上限继续；抛异常直接上抛，耗尽抛 `StateError`；退避与传输层同一条策略。`cachedRetry` 与无缓存的发现端点共用这一循环，`discover` / `leaderboard` / `wyLeaderboard` 预算集中命名，平台文件不再各写 3/4/6。
- **Discover call runner（发现端点执行器）** — `lib/sources/builtin/discover_runner.dart`：`DiscoverCall`（`DiscoverRequestCall` 一次请求 + 无效判定 + 解析 / `DiscoverAttemptCall` 多步尝试）与 `runDiscoverCall` 是发现端点的唯一执行入口；有稳定 key 走 `BuiltinTransport.cachedRetry`（single-flight，成功才缓存），没有 key 走 `runBuiltinAttempts`。平台文件只保留 URL / 参数 / parser 与端点自己的缓存键，不再各自拼 `cachedRetry` 形状。
- **Builtin search runner（内置检索 runner）** — `lib/sources/builtin/builtin_search_runner.dart`：五个平台搜索的执行骨架（`runBuiltinSearch`）与策略的唯一实现——重试预算、分页推断、失败归一；平台变体面（请求方式/URL/body、响应级重试判定、业务码判定、列表路径与解析）收进 `BuiltinSearchCall`，各平台文件只剩字面量与 parser。结果语义分界：**平台返回空** = 正常结果（tracks 空、failure 空）；**业务拒绝 / 传输失败** = `SourceSearchResult.failed`（`SourceSearchResult.failure`，不抛异常，UI 收口前只读 tracks）。内置平台「可搜索」判定唯一来源：`SourceManager._isBuiltinSearchable`（channels 候选 / 能力位 / 搜索路由共用）。
- **LX engine bridge（LX 引擎桥）** — `lib/sources/lx/lx_engine_native.dart`：脚本 isolate 与宿主的唯一通道。投递用 JSInvokable 值直投（`__lxDeliver` / `__lxSetup`，不再把消息拼成 JS 源码 evaluate）；HTTP 响应只下行原文 `raw`，`body` 由 prelude 在 JS 侧还原；任务泵按活动状态自适应（有在途 25ms / 空闲 250ms）；调用超时先探活（`ping`/`pong`，有在途 HTTP 时按脚本声明的超时延长预算），只有无应答才重启——单请求超时抛 `LxEngineTimeoutException` 只失败该请求，`LxEngineSupervisor` 对连续超时熔断（默认 3 次 → `failed` + `failureReason`，成功一次清零）。

## 错误模型

- **Failure boundary（失败归一化边界）** — `lib/domain/models/failure.dart` 的
  `SourceFailure` 是跨层错误契约：sources 适配器在边界把结构化异常转换一次
  （any-listen：`AnyListenException.toSourceFailure()` 保留 unauthorized 等语义；
  内置传输：`SourceFailure.from` 按类型名识别 `BuiltinHttpException`），
  providers/UI 只消费 kind / l10nKey / retryable，不再逐层重包装。

## 播放

- **Playback snapshot（播放快照）** — `lib/domain/models/playback.dart`：UI 播放状态的唯一形状
  （`current/previous/next/upNext/context/mode/isPlaying/...`）。`PlaybackProvider.snapshot`
  是其唯一出口：真实播放来自 facade，冷启动恢复态由 `PlaybackSessionCoordinator`
  构造覆盖快照（唯一构造点）；历史兼容 map 形状已删除。
- **Play mode（播放模式）** — `lib/models/play_mode.dart`：列表循环（队尾回队首）、
  顺序播放（播完即停）、单曲循环、随机播放；`PlayMode.next` 是按钮与系统媒体动作
  的循环切换顺序，持久化按枚举 `name`。`lib/playback/queue_navigation.dart` 统一
  线性队列的下一首 / 上一首与列表循环的回绕口径。
- **Played order（播放顺序）** — `lib/playback/playback_order.dart`：实际播放过的队列下标栈
  （最近在后、上限 100、`popPrevious` 供上一首消费）。驱动 `PlaybackSnapshot.previous`
  语义（实际播放顺序最近一首 → 队列前一位）；与播放页队列视图的 `upNext`（队列顺序）是两回事。
- **Queue projection（队列投影）** — `lib/playback/queue_projection.dart`：
  `projectQueue` 是 `next` / `previous` / `upNext` 的唯一实现，`LocalPlaybackService`
  与恢复态共用。恢复态没有洗牌排列 / 播放顺序栈时显式留空 `QueueOrder`：
  shuffle 的 `next` 为 null、`upNext` 为空（不拿下标近似），`previous` 回退队列前一位。
- **Resolved next（下一首解析）** — `PlaybackSnapshot.next`：后端按当前模式解析的下一首
  （shuffle 在单曲内稳定，切歌/切模式重抽）；peek（展示）与 commit（执行）两个语义
  在服务内显式分开（`queueProjection` / `_commitNextIndex`），轮末重洗只发生在 commit。
- **Previous（上一首）** — `PlaybackSnapshot.previous`：可展示的上一首（播放顺序最近一首
  的非破坏性 peek → 队列前一位；无 / 与当前同 id 为 null，队首的「重播当前」不算）。
  封面左槽与切歌会话只读它，不再各自解析。
- **Playback session coordinator（播放会话模块）** — `lib/playback/playback_session_coordinator.dart`：
  恢复态（冷启动未起播）与真实播放（live）之间的唯一交接点，也是
  `PlaybackSessionStore` 的唯一写者。三阶段状态机 `idle → restored → live`（装载进恢复态，
  facade 有当前曲目即接管为 live，停止播放 / 关闭恢复开关回 idle）；命令按阶段路由
  （provider 不再分叉，只消费 `PlaybackCommandOutcome` 的变化域），恢复态展示快照与
  进度覆盖值在这里构造。
  落盘口径收在一处：整份会话（曲目切换 / 暂停 / `flushSession` 强制）、轻量进度键
  （`savePosition`，前台 1s / 后台 15s 节流，满 1min 整份刷新）、`clear`，串行化由 store 的
  `pendingWrite` 承担。改变会话的命令（暂停 / seek / 切歌 / 模式 / 停止 / 换源）返回前
  等 `pendingWrite`（「已提交」语义），live seek 强制整份落盘。系统媒体会话与 UI
  共用 `PlaybackCommandPort`（`lib/playback/playback_commands.dart`，唯一实现是协调者）：
  handler 只把通知 / 耳机键动作翻译成命令，恢复态回落（切歌 / 队列跳转）、阶段路由与
  落盘时机都在命令面，handler 不再直写服务、也不再持有第二个落盘回调。provider
  的失败恢复写入也走同一条命令面：播放失败的同源重试走 `playQueueIndex`，自动换源写回走
  `replaceQueueTrack`（只有 live 生效，恢复态 / 未命中 no-op），不直写 facade。
  壳层 paused
  与桌面退出共用
  `PlaybackProvider.suspendPlaybackSession()`，桌面 `quitApp` 有界等待（2s）后继续退出。
  系统媒体控制（暂停 / 停止 / 切顺序 / seek）与恢复态切歌键
  经组合根接线进来（不再直连 provider）；「启动时恢复上次播放」开关的跨设备重载钩子
  挂在 provider 上，协调者只回答「恢复态是否变化」（撤下 / 装载成功），UI 通知由调用方发。
- **Playback command outcome（播放命令结果）** — `lib/playback/playback_commands.dart` 的
  `PlaybackCommandOutcome`：命令真正改变的 UI 领域（`track` / `queue`）与是否已提交。
  provider 只按变化域通知，不再把「恢复态 / live」翻译成通知类别。协调者是唯一会话
  写者：命令改完 facade 后经 `_commitLiveSession` 按内容去重、等 `pendingWrite`
  （ADR-0010 的「返回前已提交」）；`PlaybackProvider` 必须注入同一个协调者，不能再
  自建 store 形成第二个写队列。
- **Playback session sync port（会话同步端口）** — `lib/domain/ports/playback_session_sync.dart`：
  `PlaybackSessionSyncPort` 只暴露 `loadRaw` / `applyRemote` / `clearRemote`，传输的
  是原始会话 JSON（含 `savedAt`）——同步记录就是会话键里的 wire format，转成领域对象
  会丢字段。`lib/` 内唯一实现是 `PlaybackSessionCoordinator`：远端应用 / 删除与本地
  保存 / 清除共用协调者持有的那一个 `PlaybackSessionStore`（同一条 `pendingWrite`
  队列），同步栈另建 store 会形成第二个写队列，把远端应用插进「本地保存 → 清除」
  之间或复活已清除的会话。
- **System media session（系统媒体会话）** — `lib/playback/local_audio_handler.dart` +
  `lib/playback/media_session_backend*.dart`：通知栏 / 锁屏 / 耳机键的会话层
  （Android/iOS/macOS/Windows 走 `flutter_media_session`，Linux 走 MPRIS，见 ADR-0010）。
  handler 只负责读路径与动作翻译：读取面 `MediaSessionReadModel`
  （`lib/playback/media_session_read_model.dart`，生产实现投影 `LocalPlaybackService`）
  提供当前曲目 / 状态 / 进度 / seek 版本 / 收藏，文案经注入的 `MediaSessionCopy`
  （不读全局 locale，歌手回退走 l10n `unknownArtist`）。播放 / 暂停 / 停止 / 切歌 /
  seek / 队列跳转 / 切模式都走 `PlaybackCommandPort`，恢复态回落与「返回前已提交」
  由 `PlaybackSessionCoordinator` 负责。
  Android 通知里的两个自定义动作是「收藏」(`lx.favorite`，写路径复用
  `LibraryProvider.toggleFavoriteSourceTrack`）与「播放顺序」(`lx.playMode`)；
  **按钮的最终位置由 Media3 provider 与系统 UI 决定**，Dart 侧只能控制自定义动作
  之间的先后（ADR-0013、已知坑 #61）。
- **Playback power policy（播放功耗策略）** — `lib/playback/playback_power_policy.dart`：
  移动端按应用前后台 + 桌面歌词是否可能展示决定播放链路的节拍。**与 `AppPresence`
  完全独立**：后者是桌面窗口可见性的事实源，驱动封面预取 / 取色停产；移动端退后台
  不写 `AppPresence`，预取 / 取色 / 桌面歌词行为不变。两种节拍：位置采样（前台或
  桌面歌词开启 = 高频流，后台播放 = 1s 轮询，后台暂停 = 不采样，见
  `LocalPlaybackService`）；会话落盘（前台 1s / 后台 15s，进入后台先强制整份落盘
  一次，见 `PlaybackSessionCoordinator`）。桌面端不接生命周期，恒为前台。
- **Playback observer（播放观察者模块）** — `lib/services/playback_observer.dart`：播放副作用扇出的唯一实现（最后播放 / 播放上下文 / 桌面小组件 / 播放历史 / 封面预取与补取 / 通知权限），直连 facade 快照通道（不经 provider 的节流通知），由组合根挂接；会话落盘与恢复态属 `PlaybackSessionCoordinator`，睡眠定时属 `PlaybackProvider`（与 `PlayStatisticsService`、`ArtworkThemeSync` 同为观察者形态）。
- **Sleep timer（定时关闭）** — `lib/providers/sleep_timer.dart`：歌曲信息页入口的
  「到点暂停」。两种模式：倒计时（**仅播放时计时**，暂停冻结；实现为**绝对
  deadline** 而非相对累减——tick / 快照变化 / 回前台三路各自比较 `now >= deadline`，
  熄屏节流或进程冻结后首个获得调度的回调立即补触发）与「播完当前歌曲」（纯事件驱动，
  无定时器；以播放后端的自然完成事件为准，不依赖可能被熄屏节流的进度 tick）。
  判定只读 **facade 原始
  通道**（真实播放），恢复态覆盖值不参与；到点动作经注入的 `onFire` 落地
  （组合根注入播放命令面的 `pause`：与通知 / UI 暂停同一阶段路由，返回前
  已提交会话）。剩余时间每秒走 `ValueListenable`（不进聚合通知），
  不持久化，`stopLocalPlayback` 一并撤销。
- **Audio focus guard（音频焦点守卫）** — `lib/playback/audio_focus_guard.dart`：
  「其他应用出声时暂停 / 继续播放」的唯一实现，受设置「与其他应用同时播放」
  （默认开）控制。just_audio 的内建中断处理已关闭（`AudioPlayer(handleInterruptions:
  false)`），焦点事件与耳机拔出全部由本模块 / 播放服务处理。开启时 Android 忽略
  焦点丢失、iOS / macOS 用 `mixWithOthers` 混播；关闭后中断 `begin == true`
  （含 duck / 永久丢失）→ 暂停，系统发回可续播的结束事件（`type == pause`）时
  自动补播，但用户手动暂停过则不抢播。桌面无插件实现时 no-op。

- **Seek preview（进度预览模块）** — `lib/widgets/seek_preview.dart` +
  `lib/widgets/seek_bar.dart`：进度拖动预览的唯一实现（拖动期显示本地值；
  松手提交后保留显示直到 position 追上（容差 800ms）或 1.5s 兜底；新拖动 /
  新提交作废旧落点；换曲按身份变化清理；时序常量不给宿主配置面）。
  `SeekBar` 是它的渲染面（波浪 ⇄ 平直、气泡与侧时间文案），播放页与桌面
  底栏只是宿主，seek 语义不再各持一份。

## 播放页封面（cover deck）

- **Cover deck（封面堆叠）** — `lib/widgets/player_cover_deck.dart`：播放页封面区
  （三槽位渲染、横滑手势、会话的效果宿主）的唯一实现；播放器只提供布局尺寸、
  顶栏共享飞行锚点与主题联动。会话状态机在 `player_cover_session.dart`，方向判定
  纯函数在 `player_cover_swap.dart`，卡片外观与飞行在 `cover_appearance.dart`。
- **Cover deck metrics（封面堆叠尺寸预算）** — `lib/widgets/cover_deck_metrics.dart`：
  可用宽高 → 封面边长与堆叠尺寸的纯函数（唯一口径，两轴因子具名），硬不变量
  `stackWidth ≤ availableWidth` 且 `stackHeight ≤ availableHeight`；三套版式都走它，
  不再各自手写「可用宽 − 96」与乘因子。
- **Cover appearance（封面外观）** — `lib/widgets/cover_appearance.dart::CoverAppearance`：
  圆角 / 描边 / 阴影 / 回退图标的唯一实现，三个端点是命名值（`bar` / `mini` /
  `page`）；`CoverCard` 按外观渲染卡片（三端真身与飞行副本共用同一渲染），图片
  内容 widget 的差异留在调用侧（真身 `AppNetworkImage`、副本 `MorphCover`——
  同步出帧不闪）。两条不变量是代数关系：描边透明度 = 描边宽度、裁剪半径 =
  外圆角 − 描边宽度；封面 URL / 稳定 key 的归一化（空串视同无封面）也在这里。
- **Cover flight（封面共享元素飞行）** — `CoverFlight`（两端矩形 + 外观 + 方向 →
  `rectAt` / `appearanceAt` / `iconSizeAt`，外观按「播放页端进度」插值，反向飞行
  起飞不跳）+ `CoverFlightLayer`（副本渲染，返回 `Positioned.fromRect`，挂 Stack
  下）；顶栏↔播放页（`PlayerMorphFlight`）与迷你⇄完整（`player.dart` 页内）都是
  它的薄壳。迷你⇄完整在阈值收尾后还有弹簧容差拖尾（状态仍是 `forward`），拖尾内
  反向必须由进度监听重新起飞行。锚点几何读取唯一实现 `player_morph.dart::anchorRectOf(key,
  {container})`（容器为空 = 全局坐标；含祖先缩放的两角映射）。
- **Cover slot（封面槽位）** — 堆叠的三个位置：左 = 上一首（实际播放顺序最近一首 →
  队列前一位 → 空，排除与当前同 id，与后端 `skipToPrevious` 同源）、
  中 = 当前（拖动/提交等待/回退期间为预览目标）、右 = `PlaybackSnapshot.next`；
  左右槽只要展示了身份即可点击切歌，为空时不渲染卡片。
- **Swap session（切歌会话）** — `CoverSwapSession`：一次拖动/切歌从开始到落位的
  唯一状态机（起止身份/方向/旧邻位/阶段/方向提示/6 秒兜底），只决定「什么时候」；
  唯一快照入口 `observe`（切歌检测、空闲缓存与预览目标都从它派生，调用方不再各刷
  一半）；只在离散迁移通知（`ChangeNotifier`），跟手逐帧进度不进会话。
- **Initial identity（初始身份）** — `CoverSwapSession.adoptInitial`：deck 挂载时
  快照已有 `current`（冷启动恢复 / 系统媒体恢复）的稳态接管——只建立身份与邻位
  缓存，不启动切歌入场；首帧三槽位直接按队列渲染。只有空态出现首曲目才走
  `observe` 的入场。
- **Cover swap host（切歌宿主）** — `CoverSwapHost`（实现：deck State）：会话的
  效果面意图接口，决定「怎么做」——控制器编排、post-frame 调度、播放命令与父级
  联动（`startSettle` / `land` / `settleCommit` / `crossfadeCorrection` / `hardReset`
  / `adoptSteadySlots` / `requestSkip` / `notifySwapped` / `armTimeout` …）。
  测试用记录型假宿主（`test/player_cover_session_test.dart`），会话时机因此可脱离
  widget 树断言。
- **Swap phase（会话阶段）** — `idle`（稳态）→ `preview`（拖动跟手）→
  `committed`（提交等待对账）→ `settling`（即时切歌完成中）/ `correcting`
  （对账不匹配校正）/ `returning`（松手回弹中，预览目标保持到落位）；
  提交等待与校正期间忽略新手势。
- **Reconcile（对账）** — 提交后等待快照 current 变为会话目标：匹配无缝落位；
  不匹配（随机目标 / 失败恢复 / 列表变化）走 `correcting`（220ms 中心原位交叉
  淡化校正到实际曲目）；`CoverSwapSession.commitTimeout`（6 秒）无对账回弹。
- **Windowed crossfade（窗口化交叉淡化）** — 切歌进度窗口内的纯透明度交叉：
  目标槽位旧身份 p∈[0,0.4] 淡出、源槽位新身份 p∈[0.6,1] 淡入（无位移/叠影），
  移动卡全程插值；空闲期身份变化另有 180ms 原位交叉淡化。

## 自定义封面（custom covers）

- **Custom cover store（自定义封面存储）** — `lib/services/covers/custom_cover_store.dart`：
  每曲自定义封面 + 全局默认封面的唯一存储（设备本地；索引在 SharedPreferences，
  文件在应用支持目录 `custom_covers/`）。启动只读索引并剔除丢失文件；每次替换写
  新文件名，保证 Flutter ImageCache 与取色 LRU 不会继续显示旧图。查询同步，
  UI 经 `ValueNotifier<int> revision` 刷新，组合根另接 change listener 刷新当前
  播放 / 主题 / 系统媒体。同步面经 `trackEntries` / `defaultEntry` 枚举、经
  `applySynced*` 应用远端结果；`onLocalChange` 只在本机写入时触发（远端应用
  不标脏，避免同步回环）。
- **Cover key（封面键）** — 曲目键 `sourceKey:songId`；`sourceKey == local` 的下载
  副本剥掉一层 `local:` 前缀（`local:wy:123` → `wy:123`），让下载前设置的封面
  继续作用于本地副本；本地导入保持 `local:<path>` 记录键。
- **Default cover（默认封面）** — 设置 › 外观里的全局占位封面：只在歌曲没有
  封面或远端封面加载失败时显示；不参与取色、下载与标签嵌入，也不是一张
  「每曲封面」。
- **Cover image codec（封面图片归一化）** — `lib/services/covers/cover_image_codec.dart`：
  解码 → 烘焙 EXIF 方向 → 最长边 1024px → JPEG 85 的唯一实现；不可读图片抛
  `CoverImageException`，UI 只显示友好文案。
- **Cover picker sheet（封面选择弹层）** — `lib/widgets/cover_picker_sheet.dart`：
  每曲封面 / 默认封面共用的选择、预览与重置交互（歌曲信息页 / 海报预览 /
  设置外观三个入口，不各写一套）。

## 应用壳与导航

- **Bootstrap stack（组合根 stack builder）** — `lib/app/bootstrap/**`：接线圈按子系统分组的 module（catalog / 本地数据 / 资料库 / playback / sync / AI / 歌词显示 / 桌面 / 更新 / Provider 树 / 首帧收尾），每个的 interface 是「依赖进、装好的子系统出」；初始化顺序与前向引用（媒体会话、歌词服务、同步引擎）关在 builder 内，`lib/main.dart` 只做顺序调用 + `runApp`（唯一 composition root）。
- **Shell reselect（底栏重复点击）** — `lib/widgets/shell_reselect.dart::ShellReselectSignal`：
  壳层把「重复点击已选中的底栏 / 导航轨目的地」转交给页面的唯一通道（每个目的地
  一个实例，与 `PlayerMorphController` 同路由注入）。页面自订阅、自决定语义并自给
  反馈：播放页 = 迷你 ⇄ 完整（现有 `_toggleExpand`，进入播放页的共享元素飞行期间
  由壳层忽略），资料库 / 收藏 = 当前可见列表回到顶部
  （`lib/utils/scroll_to_top.dart::animateScrollToTop`）。壳层不消费状态，但重复点击
  命中时统一给一次轻震（`lib/services/haptics.dart`，可在设置里全局关闭）；页面不重复给触感。

- **Shortcut scopes（快捷键分组）** — `lib/services/shortcut_bindings.dart`：`ShortcutScope.inApp`（软件内，窗口聚焦时生效，`lib/app/desktop/desktop_shortcuts.dart` 用 `HardwareKeyboard` 处理器挂载）与 `ShortcutScope.global`（全局，系统级热键，`lib/services/global_hotkeys.dart` 经 `system_hotkeys` 注册）。两组都可开关（`kShortcutsEnabled` 默认开 / `kGlobalShortcutsEnabled` 默认关）、可自定义（`kShortcutBindings` / `kGlobalShortcutBindings` 存 JSON 覆盖，跟人走），录制到冲突组合 / 单行回默认撞上被占用的默认组合时可在确认后互换两者生效组合（`ShortcutSettings.swapBindings`）；命令执行语义唯一实现在 `lib/services/shortcut_actions.dart`。

- **Escape claims（Esc 占用登记）** — `lib/services/escape_claims.dart`：页面级 / 弹层把「此刻的 Esc 归我」提前告诉桌面壳层的唯一协议（`add` / `remove` / `any`；判定现算，隐藏页 / 已关弹层不残留占用，dispose 注销）。壳层 `desktop_shortcuts.dart` 命中 Esc 命令前查登记，有登记方即让位（返回 false、不消费事件）——`HardwareKeyboard` 处理器全部执行、返回值不短路，无法靠返回值裁决谁消费。**同源规则**：登记判定必须与登记方自己的按键处理器同一条件方法，否则出现「壳层让位但登记方不处理」的按键黑洞或双重消费；登记方自己接 Esc 时也不依赖焦点位置（音量弹层即此）。

- **Haptics（触感模块）** — `lib/services/haptics.dart`：全应用触感唯一入口（lightImpact / mediumImpact / selectionClick），带设备本地开关（默认开；关闭后不触碰平台通道）。所有调用点经它；M3E 包内自带的触感（swipe action / 排序等）不在此覆盖范围。

- **Desktop shell（桌面骨架）** — `lib/app/desktop/**`：仅 linux/windows/macOS 生效的壳层版式（顶栏工具条 + 恒折叠侧栏 + 常驻底栏播放条 + 搜索遮罩，播放页里整条让位），由 `lib/app/app_shell.dart` 按平台分流（`MyApp(desktopShell:)` 可强制，测试用）；移动骨架与共享逻辑（页面栈 / 共享元素飞行 / 重复点击通道 / `NowPlayingController`）仍在 `app_shell.dart`，两套骨架同源。

- **Global search overlay（搜索遮罩）** — `lib/widgets/global_search_overlay.dart`：桌面顶栏
  不再挂搜索条，最左是**品牌区**（`MoliaMark` + 应用名，整块可点）——品牌区与 Ctrl+F
  都经 `GlobalSearchController.focus()` 打开遮罩（壳层在内容区中上放隐形锚点，
  `M3ESearchAnchor` docked 从锚点展开成全屏 scrim + 居中搜索条 + 结果面板；结果复用
  `SearchProvider` 与资料库同一条播放语义）。空关键词时结果面留空；Esc 由视图自收
  （壳层经 `EscapeClaims` 让位）；壳层另叠一层整窗 `BackdropFilter` 跟遮罩开合
  淡入淡出（`GlobalSearchController.open` 驱动，关闭时零绘制开销）。

- **Desktop layout（桌面布局解析）** — `lib/widgets/desktop_layout.dart::DesktopLayout`：「是不是桌面宽布局」的唯一解析处（壳层在 `build` 里解析一次并向下提供，页面 / 骨架只消费；独立挂载页面 / 弹层路由按当前 context 回退解析，与生产同一公式）。全部判据都以窗口宽为来源：`masterDetail`（设置首屏两列的页面级增强）、`contentWidth`（窗口宽 − 实际栏宽；侧栏恒折叠 ⇒ 它就是内容区可用宽）、`tableColumns` / `tableColumnsFor`（内容宽 ≥ 720 / 历史档 812）。900 / 720 / 812 等阈值与宽度来源的选择集中在这里，页面 / 骨架只消费。

- **Shell chrome（壳层 chrome spec）** — `lib/app/shell_chrome.dart::ShellChrome`：两套骨架（移动 / 桌面）共用的导航与顶栏 spec（目的地 + 标签 + 选择 + 顶栏槽位）。目的地 → 图标 / 标签映射（`railDestinations` / `barDestinations`）、索引 → 目的地回调（`selectDestinationAt`）、顶栏构造（`appBar`：titleSpacing / 无返回键 / 拖动区包装 / 设置按钮 / 窗口控件）只此一份；骨架不合并——顶栏槽里的内容、侧栏类型与底栏形态仍由各自适配渲染。

- **Now playing bar（底栏播放条）** — `lib/app/desktop/now_playing_bar.dart`：桌面 80dp 播放条（左：封面/歌名/收藏，点击进播放页并复用封面飞行；中：传输 + 可拖波浪进度 + 时间；右：播放模式 / 音量弹层 / 队列入口）。只在非播放页出现（播放页沉浸，整条让位）；队列入口 = 跳播放页 + 切队列 tab。进度拖动语义与播放页共用 **Seek preview**，宿主只负责版式。

- **NowPlayingController（播放页 tab 请求通道）** — `lib/widgets/now_playing_controller.dart`：壳 → 播放页右栏的唯一请求通道（`showQueueTab` / `showLyricsTab` / `showInfoTab`，页序与默认页索引同源）。请求是动作不是状态：重复请求同一页也通知，页面自行判断是否已到位；底栏队列入口与 Esc 的「关闭队列」都经它落点，壳层不读播放页的界面状态。

- **VolumeControl（音量入口组件）** — `lib/widgets/volume_control.dart`：音量图标按钮 + 弹出面板（静音开关 / 滑杆 / 百分比读数，面板夹取进宿主可绘制区）的唯一实现，底栏与播放页共用；锚点 key 由宿主给出，Esc 经 `EscapeClaims` 登记自收。

- **Track row（曲目行模块）** — `lib/widgets/track_row.dart`：所有列表共用的曲目行唯一实现。调用方只给 `TrackRowModel`（标题 / 歌手 / 封面 / 时长 / 行身份 / 选中态）、`TrackRowSurface`（封面尺寸 / 表格列规范 / 勾选策略）与行回调；表格 / 双行版式、当前曲目订阅（`selectCurrentTrackState`）与时长格式化（`durationText`）都在模块内，不再拼 17 个参数或各自算行尾。`TrackRow.extentOf` / `gapOf` 仍是列表行高的唯一来源。

- **TrackRowColumnSpec（表格列宽规范）** — `lib/widgets/track_row.dart`：宽屏表格的列宽与「有没有播放时间列」的唯一宽表（行与表头同源），`minContentWidth` 是本套列不溢出所需的最小内容宽（默认档 720 / 播放历史档 812，判定见 `DesktopLayout.tableColumnsFor`）。

- **EmptyState（空态配方）** — `lib/widgets/empty_state.dart`：空态的唯一配方（图标 40 · `onSurfaceVariant` + 12 + `bodyMedium` 居中文案 + 16 + 可选行动，`Column.mainAxisSize.min` 不占满屏）。收藏 / 资料 / 发现共用；居中与外边距（页面级 `Center` + 24、滚动内容 16/16）由调用方包一层，尺寸与间距只在本文件调整。

- **Startup page（启动首页）** — `kShellHomeDestination`（跟人走）+ `NavProvider.homeDestination` / `effectiveHomeDestination`：冷启动落在用户选定的目的地（设置 › 通用 › 启动时打开，默认播放页）。存储首页不可见时（跨设备同步推来的 hidden 列表）按导航顺序取第一个可见项兜底且**不改写存储**（避免同步回环）；本地隐藏「正在作为首页的目的地」被拒绝（锁定）。

- **App volume（应用内音量）** — `PlaybackProvider.volume` / `muted` / `setVolume` / `toggleMute`（设备本地持久化，不随同步：音量是设备能力）→ `PlaybackFacade.setVolume` → `LocalPlaybackService`（just_audio；桌面 media_kit 同一播放器）。静音以「有效音量 0」下发；音量不进 `PlaybackSnapshot`（低频快照契约不动）。

## 色彩系统

- **Color source model（取色模型）** — 全局主题的解析规则（ADR-0001）：
  **基础配色**（`ColorBaseSource`：壁纸 / 自定义，单选）+ **封面覆盖**
  （`follow_artwork_enabled`：有封面时用封面色盖过基础配色，无封面回退）+
  **纯黑**（深色 surface 覆盖，正交可叠加）。解析唯一：
  `封面 > 壁纸图（桌面，SystemWallpaperSource 探测）> 强调色 > 自定义`。
- **Scheme factory（方案工厂）** — `lib/theme/scheme_builder.dart::buildColorScheme`：
  全 App 唯一的 ColorScheme 派生入口（seed + 亮度 → 方案），禁止各处自行
  `ColorScheme.fromSeed`；`applyPureBlackScheme` 同文件（纯黑覆盖）。
- **Artwork palette（图像色板）** — `lib/services/artwork_palette_service.dart`：
  按封面 URL / 本地图像路径提取 seed 并派生双亮度方案的唯一入口（LRU + 并发
  合并 + 省流安全；`loadLocalFile` 承载桌面系统壁纸），由组合根监听播放快照
  触发。任何模块不得二次提取封面像素。
- **Surface color source（消费面取色来源）** — 桌面歌词 / 海报各自的
  「跟随应用主题 / 跟随封面（/ 自定义色）」选择；经 `resolveSurfaceScheme`
  解析，封面方案缺失回退应用主题。

## 歌词

- **Lyrics session module（歌词会话模块）** — `lib/providers/lyrics_provider.dart`：
  取词 → 缓存 → 解析（统一时间契约）→ 预取的唯一实现；对外暴露 `LyricsState`
  （idle/loading/ready/empty + isSynced + providerName）与 `ensureForTrack` / `retry` /
  `preload` / `saveManual`。曲目变化由组合根订阅播放快照后调 `ensureForTrack`
  （页面是否挂载都加载；空结果允许一次自动重试），页面只渲染状态、不触发取词。
  UI 不再各自构造 `LyricsService` 或直接写 `LyricsCache`；**歌词页不维护加载镜像**
  （`lyrics.dart` 只读会话状态，页面只保留滚动 / 行 key 簿记）。
- **Lyrics scroll policy（歌词滚动策略）** — `lib/widgets/lyrics_scroll_policy.dart`：
  纯函数（对齐比例 / 尾部留白 / 目标偏移夹取 / 死区）；组件只测量（ScrollController /
  MediaQuery）与执行（jumpTo / animateTo），策略数学脱离 widget pump 可单测。
- **Lyric timing contract（歌词时间契约）** — `lib/models/lyric_line.dart`：
  `hasLyricTimestamps` 与 `parseLyrics` 共用同一正则（兼容 1–3 位分钟、`.`/`:` 毫秒
  分隔与行内多标签）；不再允许「检测用一个正则、解析用另一个」的漂移。
- **Track-native lyric/pic（曲目原生取词 / 取图）** — `SourceManager.fetchLyric` /
  `fetchPic`：按曲目 raw 的平台精确 ID 取词取图，顺序为脚本 `lyric`/`pic` action →
  any-listen → 内置五平台原生实现（wy eapi + yrc、tx PlayLyricInfo + QRC、
  kg KRC、kw LRCX、mg MRC；封面 wy 歌曲详情 / tx 专辑 mid / kg `get_res_privilege`
  / kw `pic.web` / mg 资源封面）。解码器在 `lib/sources/builtin/*_lyric.dart` +
  `tx_qrc.dart`（zlib 走 FFI 原生实现）。内置派发的唯一实现（五平台
  switch + 结果缓存）在 `lib/sources/builtin/builtin_lyric_dispatch.dart` /
  `builtin_pic_dispatch.dart`，与平台适配器同门。
- **Word timing（逐字时间轴）** — `lib/models/lyric_line.dart`：`LyricLine.words`
  （`LyricWord`：绝对起止 + 文本）由 `lxlyric` 的 `<相对ms,时长ms>` 解析并对齐主行；
  歌词页当前行用 `KaraokeLyricText` 词级高亮（已唱 primary / 未唱 onSurface，
  采样间线性补间），桌面歌词同样按词渐染（原生 span），通知 / 蓝牙输出按行。
- **Lyric display lead（歌词视觉提前量）** — `lib/services/lyrics_display/lyric_timing_policy.dart::kLyricDisplayLead`：
  应用内歌词页 / 歌词选择页的行号查表与 `KaraokeLyricText` 插值目标统一加 200ms
  （正 = 提前）。补 450ms 切行淡入 / 字重过渡与 ≤4Hz 位置采样造成的滞后，同时抵消
  逐字补间恒定慢一拍；输出侧（桌面歌词 / 通知）仍只走 `offsetMs`。行号策略唯一在
  `LyricTimingPolicy`（`page` / `output`），页面不再各写提前量。
- **Desktop lyric clock（桌面歌词位置时钟）** — `android/.../lyrics/LyricClock.kt`：
  位置样本只做纠偏——先按 `positionAtEpochMs`（Dart 侧「该位置生效的墙上时刻」）
  补偿传输延迟，再按误差分档收敛（≤100ms 10% / 100–300ms 20% / >300ms 落位）；
  逐帧推进与位移跟随（`LyricSpring` 临界阻尼）由宿主 `LyricsOverlayView` 的帧循环
  统一负责，时基不随行视图重建。映射方式由 Dart 决定（`desktop.scrollMode`：
  跟随演唱 / 匀速），原生只执行。
- **Lyrics matching（歌词匹配）** — `lib/services/lyrics/lyrics_match.dart`：
  名字搜索候选按时长 ±5s、归一化歌名、歌手包含与版本词（live/伴奏/翻唱…）挑选；
  全部不匹配时回退首个候选（保持旧行为下限）。判定实现与换源共用
  `lib/services/song_match.dart`（唯一实现）。

## 评论

- **Builtin comments（内置评论取数）** — `lib/sources/builtin/comment_source.dart` +
  `{wy,tx,kg,kw,mg}_comment.dart`：五平台「热门 / 最新」分页取数的唯一实现，
  直接产出领域 `CommentPage`（不经 sources→data 映射层：评论没有脚本回传需求）。
  文本表情还原（wy `[名称]` / tx `[em]eXXXX[/em]`）、IP 归属、点赞、引用
  （wy `beReplied` / kg `pcontent`）与随列表返回的楼中楼（tx / kw / mg）在此归一化。
- **Comment cursor store（评论游标存储）** — `lib/sources/builtin/comment_utils.dart`：
  游标分页会话状态（wy 最新评论的 `cursor`、mg 最新评论的 `commentId`），
  按「曲目 + 页码」保存平台游标（取第 N 页读 key N，第 N-1 页写入），
  只保留最近两页 + 有限曲目数；缺游标时 mg 直接失败（不静默返回首页数据）。
- **Comments service（评论服务）** — `lib/data/catalog/comments_service.dart`：评论分页的
  唯一取数入口（single-flight + LRU + TTL 5min + `SourceFailure` 归一化），
  key 为 `comments:{source}:{songId}:{kind}:{page}`；`invalidateTrack` 供下拉刷新。
- **Comments session（评论会话）** — `lib/providers/comments_provider.dart`：热门 / 最新
  两个 tab 的懒加载、分页（跨页按 id 去重）、刷新与错误态；能力位 `capabilities.comment`
  决定入口显隐与「渠道不支持」空态。

## 专辑

- **Album（专辑模型）** — `lib/domain/models/album.dart`：专辑 id / 名称 / 歌手 /
  封面 / 年份 / 曲目（领域 `Track`）/ `hasMore`，不可变 + 值相等；年份从平台
  发行时间派生（解析失败为 null，UI 不展示）。
- **Builtin albums（内置专辑取数）** — `lib/sources/builtin/album_source.dart` +
  `{wy,tx,kg,kw,mg}_album.dart`：五平台按专辑 id **精确拉取**（不再用专辑名搜索
  兜底）的唯一实现，解析直接产出领域 `Album`（曲目经 `track_mapper` 原样透传
  payload）；真实响应快照在 `test/fixtures/albums/`（抓取脚本
  `tool/gen_album_fixtures.mjs`），端点均需真机复验。
- **Album service（专辑服务）** — `lib/data/catalog/album_service.dart`：专辑分页的
  唯一取数入口（single-flight + LRU + TTL 10min + `SourceFailure` 归一化），
  key 为 `album:{source}:{id}:{page}:{limit}`；取数函数由组合根注入
  `SourceManager.fetchAlbum`（服务不依赖 sources 层）。
- **Collection routing（集合路由）** — `MusicSource.collection(CollectionRef)` 在
  能力位 `capabilities.collection`（仅内置五平台）为真时转发 `SourceManager.fetchAlbum`
  并映射为 `CollectionPage`；目前只支持 `album` 类型，playlist / artist 与
  LX 脚本 / any-listen / local 一律 `SourceFailure(unsupported)`。
- **Album entry（专辑入口）** — 歌曲信息页「专辑」行：payload 专辑 id
  （`platformAlbumId`：wy/kg/kw/mg `albumId`、tx `albumMid`）与能力位双判定为真时
  变为可点行（副标题「查看专辑」），否则保持只读信息行。专辑页曲目行与搜索结果 /
  歌手页同款（`TrackMenuTile`：行动作菜单收藏 / 加入列表，触摸端行尾 ⋮ /
  桌面右键菜单），时长展示统一走 `utils/duration_text.dart`（未知时长不占行尾）。

## 歌手与歌词搜索

- **Artist page（歌手页）** — `lib/pages/artist_page.dart`（头部头像 / 名字 / 简介 +
  播放全部 / 加入列表 + 曲目列表）；曲目行与搜索结果行同款 `TrackMenuTile`
  （行动作菜单收藏 / 加入列表：触摸端行尾 ⋮、桌面行表面右键），入口：歌曲信息页
  「歌手」行、搜索结果行内歌手名、
  搜索「歌手」类型条目；取数走 **Artist service（歌手服务）**
  `lib/data/catalog/artist_service.dart`（single-flight + LRU + TTL 10min，
  key `artist:{source}:{id}:{page}:{limit}`，注入 `SourceManager.fetchArtist`）。
- **Artist name fallback（歌手名回退）** — 曲目 raw 没有歌手 id 时（历史收藏 /
  `.lxmc` 导入 / 部分内置入口）按名字进歌手页：`ArtistService.resolveByName`
  歌手搜索 + 精确匹配（trim、忽略大小写；正负结果都缓存），id 解析在
  `showArtistPageByName` 的页面加载内完成（加载态 / 未找到文案 `artistNotFound`）；
  名字取首个歌手名的首段（历史数据多歌手被拼成 `、` / `, ` / `&` 分隔的一串）。
- **Builtin artists（内置歌手取数）** — `lib/sources/builtin/artist_source.dart`
  （`BuiltinArtists` 调度）+ `{kw,kg,tx,wy,mg}_artist.dart`：五平台歌手搜索与
  「详情 + 歌曲」的唯一实现（解析直接产出领域 `ArtistSummary` / `ArtistDetail`）；
  真实响应快照在 `test/fixtures/artists/`（抓取脚本 `tool/gen_artist_fixtures.mjs`）。
  平台降级口径：kg 歌手搜索无总数（单页 10 条）、tx 歌手歌曲 `begin` 无效（单页约 60 首，
  `hasMore=false`）、mg 歌手详情无简介（`description` 空串）。
- **Artist capability（歌手能力位）** — `SourceCapabilities.artist`：歌手搜索 +
  歌手详情统一切换；内置五平台与 `search` 同门（`BuiltinArtists.isSupported` 且
  脚本可取链），脚本源 / any-listen 为 false → 搜索分段与歌手行入口自动降级为只读
  （不与路由撒谎：能力位为真 ⇔ `searchArtists` 不会必然失败）。
  **Lyric capability（歌词能力位）** `SourceCapabilities.lyricSearch` 同门
  （`BuiltinLyricSearch.isSupported` + 脚本可取链）。
- **Lyric search（按歌词搜歌）** — `lib/sources/builtin/lyric_search.dart`
  （`BuiltinLyricSearch` 调度 + `SourceLyricHit{track, snippet}` / `LyricSearchPage`）
  + `{kw,kg,tx,wy,mg}_lyric_search.dart`（kw `stype=lyric` 模糊匹配 / kg `lyric_search` /
  tx `search_type=7` / wy `type=1006`（ids → `v3/song/detail` 补规范 raw）/
  mg `searchAll` + `lyricSong=1`）；骨架复用搜索的请求 / 校验策略
  （`builtin_search_runner.dart::BuiltinCall` + `sendBuiltinCall`，歌词侧 runner 见
  `builtin/lyric_search_runner.dart`；kw 伪 JSON 容错与 wy ids → detail 保留自定义
  流程）。真实响应快照在 `test/fixtures/lyric_search/`
  （抓取脚本 `tool/gen_lyric_search_fixtures.mjs`）。命中片段作为结果行副标题。
- **Search kind（搜索类型）** — `lib/domain/models/catalog.dart::SearchKind`
  （`song` / `artist` / `lyric`）：搜索页分段（`M3ESegmentedButton`，按能力位显隐），
  `SearchProvider` 为每种类型维护独立会话（分页 / 错误 / 过期守卫；切类型才请求，
  换词清空非激活类型，换源能力不足回退单曲）。端口 `MusicSource.searchArtists` /
  `searchLyrics` 经 `CatalogService`（缓存 key `search:{source}:artist|lyric:...`，
  与单曲共用 5min 缓存实例）路由。
- **Search row（搜索结果行）** — `lib/providers/search_row.dart` 的 `SearchRow`：
  单曲 / 歌词搜索结果的唯一形状（领域 `Track` + 可选 `lyricSnippet`）；`SearchProvider`
  内部保留 `SourceTrack`（raw payload 不跨 provider 边界），播放按行身份回查当前队列。
  UI 不再解码 `Map<String, dynamic>` 或 `_sourceTrack` 私有键，收藏 / 加入列表走
  与其他列表相同的 `Track` 入口。
- **Builtin platform failure（内置平台失败助手）** — `builtin_search.dart::builtinPlatformFailure`：
  专辑 / 歌手 / 歌词等内置接口「业务拒绝 / 字段缺失」的统一失败（`unknown` + 可重试），
  各模块旧助手（`albumPlatformFailure` / `artistPlatformFailure`）委托同一实现。

## 资料库

- **Library store（资料库端口）** — `lib/domain/ports/library_store.dart`：领域意图
  （历史 / 列表 / 曲目 / 收藏 / 导入）+ 类型化变更事件；调用方不感知存储形状
  （列名 / `sortOrder` / 墓碑 / 保留行名）。实现 `lib/data/library_repository.dart`
  同时兼同步面（见下条）。
- **Library sync store（资料库同步端口）** — `lib/domain/ports/library_sync_store.dart`：
  类型化同步记录出 / 入（`PlaylistSyncRecord` / `PlaylistTrackSyncRecord` /
  `PlayHistorySyncRecord` / `SyncTombstoneRecord`，定义在 `device_sync.dart`）；
  列名、行结构与墓碑表只在实现内部；同步适配器只依赖本端口。
- **Library write engine（资料库写入网关）** — `lib/data/library_write_engine.dart`：
  本地变更五步仪式（发号 → 写行 → journal 记录 → 墓碑 → 变更事件）的唯一实现；
  意图方法（`addHistoryEntry` / `replacePlaylistTrack` / `deletePlaylist` /
  `toggleFavorite` / `importPlaylistTracks`…）是 data 层内部 API，
  `LibraryRepository` 的公开写方法只做委托，读路径与同步面仍在仓库。同步面
  （应用远端记录）不走仪式：不发号、不追 journal、版本从远端取，只复用网关的
  墓碑行形状、历史墓碑清除与 syncId 补齐原语。两处既有口径显式保留并在网关内
  注明：导出前补 syncId 不发号（靠 `syncFingerprints` 的 syncId 计数条款补偿）、
  导入路径不追 journal。
- **Library change（资料库变更事件）** — sealed `LibraryChange`（history /
  playlists / playlistTracks(id) / favorites / import）：`changes` 广播的载荷，
  类型即失效范围；取代 `Stream<void>` + 事后回读 `lastChangeKind` /
  `lastChangePlaylistId` 的侧信道（异步边界后读到的是「最近一次」而不是「本次」）。
- **Favorites（收藏）** — 领域概念 `PlaylistInfo.isFavorites`；存储层保留行名
  `__favorites__` 只在实现内部（UI 文案走 l10n，调用方不再按名字比较）。
- **Library mutation gateway（资料库变更网关）** — `lib/providers/library_provider.dart`：
  收藏 / 播放历史 / 列表写入的唯一实现。收藏唯一入口 `toggleFavoriteTrack(Track)`
  （播放页不再直连 `LibraryRepository`）；批量操作按 `PlaylistTrack` 规范形状，
  `PlaylistTrack.fromHistoryEntry` 负责历史条目转换。收藏页批量 / 行写入统一返回
  `LibraryMutationOutcome`（applied / unchanged / failed）：失败在 provider 边界
  收口成 failed（原始异常只进日志），乐观更新回滚，选择只在成功后才清空。
- **Favorite toggle outcome（收藏切换结果）** — `lib/providers/library_outcome.dart` 的
  `FavoriteToggleOutcome`：`toggleFavorite` / `toggleFavoriteTrack` /
  `toggleFavoriteSourceTrack` 的唯一结果类型。成功带切换后的状态，失败带切换前的
  状态（缓存与图标不翻转）；仓库异常在 provider 边界收口。
- **Favorite action（收藏动作）** — `lib/widgets/favorite_action.dart`：收藏意图与
  反馈的唯一实现。`toggleLibraryFavorite` 走 `LibraryProvider.toggleFavoriteTrack`；
  `FavoriteFeedback` 显式区分确认（菜单行：成功 + 失败）与仅失败（播放页心形 /
  AI / 发现行：图标态即成功反馈）；`FavoriteHeart` 是心形图标 / 语义标签 / 颜色的
  唯一映射。写路径、乐观更新与回滚仍归 provider，触感留在各宿主。
- **Add-to-library flow（加入列表流程）** — `lib/widgets/add_to_library.dart`：
  选择目标 → 写入 → 解析新建列表名 → 反馈的唯一实现；收藏页与发现页共用。
- **Channel selection（渠道选择）** — `DiscoverProvider.channelKey` 是渠道状态的唯一持有者；
  渠道变化经注入的 `onChannelChanged`（组合根）触发搜索源跟随（可搜索渠道才跟随），
  资料页不再在两个 provider 之间仲裁同步，只处理「渠道被停用」的 UI 回退。
- **Playlist tracks view（列表曲目视图）** — `LibraryProvider.playlistTracksView` +
  `ensurePlaylistTracks`：页面只读 `PlaylistTracksView`（`tracks` + `LibraryReadState`
  的 loading / ready / failed）并请求加载，不再探测 `cachedTracksOf` /
  `isPlaylistLoading` 之类的缓存内部。列表清单 / 历史同样暴露 `playlistsState` /
  `historyState`：首次读取失败是 failed（可重试），已有旧缓存则保持 ready 展示旧值。

## 换源

- **Source swap（换源）** — `lib/providers/source_swap_provider.dart` + 
  `lib/widgets/source_swap_sheet.dart`：按种子曲目「歌名 + 歌手」在其它可搜索音源
  并行检索（逐源就绪即填充、单源失败隔离），点候选即试听（单曲「换源试听」），
  确认后原位替换。入口：收藏页合集（收藏 / 历史 / 自建列表）行动作
  （移动端左滑胶囊 / 桌面右键菜单）/ 播放页 seek 行（队列入口）；
  本地歌曲不含换源（本地文件无在线音源可换）。
- **Swap placement（换源写回位置）** — `SourceSwapPlacement`：`playlist`
  （收藏/自建列表，仓库事务保 `sortOrder`/`addedAt`）、`history`（保 `playedAt`）、
  `queue`（仅播放队列，不落库）。库内替换与队列跟随**解耦**：队列中同 id 曲目
  命中才跟随（`PlaybackFacade.replaceQueueTrack`），未命中不算失败。
- **Song match（歌曲匹配）** — `lib/services/song_match.dart`：LX `findMusic`
  判定的唯一实现（时长 ±5s、归一化歌名/歌手/专辑、版本词一致、三阶优先级）。
  两种消费面：歌词搜索（非严格，未命中回退首候选）与自动换源（严格，未命中
  返回 null —— 宁可不换，不换错）。
- **Auto source swap（自动换源）** — `lib/services/source_swap/auto_source_swap_service.dart`
  + `PlaybackProvider` 的失败恢复链路：同源重试仍失败后跨源严格找回并**静默**
  替换队列曲目（对齐 LX）；替换经 `PlaybackCommandPort.replaceQueueTrack`
  （live 由协调者转发 facade 并返回前提交会话，恢复态 / 未命中 no-op——自动换源
  只由真实播放失败触发，不改保存的恢复会话）；provenance（每个曲目的已尝试来源）
  保证级联每源至多一次、有界；开关 `SourceSwapSettings`（默认开，设置 › 播放）。

## 听歌统计
- **Listening statistics snapshot（统计快照）** — `ListeningStatisticsSnapshot`：
  一次范围查询的全部聚合（汇总 / 榜单 / 日历 / 作息热力图 / 来源分布）；
  `PlayStatisticsRepository.snapshot(since:)` 并发取回，统计页只渲染它。
- **Play statistics range（统计范围）** — `PlayStatisticsRange`（周 / 月 / 全部）
  + 扩展 `startOf(now)` / `sinceMs(now)`：范围 → 时间窗口的唯一映射，
  查询与热力图高亮共用（本地时间）。
- **Qualified play（有效播放）** — 口径唯一在 `PlayStatisticsLimits`：
  `qualifiedThresholdMs(durationMs)` / `isQualified(...)`
  （`listenedMs ≥ min(30s, 50% × 时长)`，奇数时长向上取整）；SQL 谓词与
  AI 跳过判定都从它派生，SQL↔Dart 一致性由
  `test/play_statistics_formula_test.dart` 用同一批 fixture 行钉住。
- **Statistics sync store（统计同步存储）** — `lib/domain/ports/statistics_sync_store.dart`
  + `lib/data/sync/statistics_sync_store.dart`：`StatisticsSyncEvent` 是类型化的已收尾
  事件（`syncKey` + 版本三元组；`startedAt` / `endedAt` 只是内容时间）；读面
  `StatisticsSyncStore` 拥有导出缓存与廉价指纹、存量事件 `syncKey` 回填、本地下载
  曲目过滤与按 `syncKey` 的合并应用。写面 `StatisticsSyncWriter` 把事件行的创建
  （`startEvent`，含 `syncKey` / 来源设备）与收尾取号 / 日志 / 导出缓存维护收进
  store；`PlayStatisticsRepository` 只依赖 writer，不再 import 同步 wire 模型或
  自己拼同步列。`StatisticsSyncAdapter` 只是「类型化事件 ↔ `SyncRecord`」的映射。


- **Play event（播放事件）** — `play_events` 一行 = 一次播放尝试（append-only）：
  **真正出声才开行**（首个 `position > 0` 的 tick）；切歌 / 播完 /
  单曲循环每遍 / 位置回到开头（restart）/ 停止各收尾一行；暂停不切断；
  进程被杀由启动时 `closeStaleEvents()` 收尾为 interrupted。曲目元数据与取链
  参数在 `play_tracks`（每曲一行，`raw` 为 gzip 字节，供统计页点播）；本表只存
  事件的 `trackId`（v5 起）。与「播放历史」（`play_history`，最近播放 500 条）
  是两套数据。
- **Statistics capture（统计采集）** — `lib/services/play_statistics_service.dart`：
  纯观察者（组合根接 `PlaybackProvider` 快照 + position 两根监听，零改动
  `lib/playback`）；`PlayStatisticsLimits` 是口径常量唯一来源
  （有效播放 = `min(30s, 50%×时长)`；完整播放 = 末尾容差 1s），全部
  **查询时计算**、不改数据（口径变化不需要回填）；采集开关默认为开。
- **Listening stats page（听歌统计页）** — `lib/pages/play_statistics_page.dart` +
  `lib/providers/play_statistics_provider.dart`：范围切换（近 7 天 / 30 天 /
  全部）只作用于汇总/榜单；**日历热力图固定全量历史**，范围切换只做高亮。
  形状与色阶约定见 `lib/widgets/statistics/listening_heatmap.dart`
  （格子静默 `square`、悬停/按压 morph `puffy` 放大，色阶 = `primary`
  四档 alpha，空日 `surfaceContainerHighest`）。
- **Listening export（听歌数据导出）** — `lib/services/play_statistics_export.dart`：
  面向 AI 消费的 JSON（汇总/榜单全量 + 最近 2000 条明细、**不含 raw**、
  带 `instructions` 提示语）；只出不进，不并入 `molia_backup` 备份。

## AI 推歌

- **AI DJ mode（AI 推歌模式）** — `lib/providers/ai_dj_provider.dart` 与
  `lib/providers/ai_dj_history_controller.dart`：`AiDjProvider` 负责推歌会话
  （电台）、通知与对外门面（生成编排在执行器，见下条）；
  `AiDjHistoryController` 独占**当前推荐（active batch）**、**历史推荐**及保留策略。
  `enabled` = 功能启用（持久化；退出队列不关功能）；`status` = 电台状态
  （off/preparing/playing/error：播放全部或点某首才接管队列）。只有显式
  「生成推荐 / 换一批」才切换 active；历史「播放这批 / 设为当前」也会切换。
  跳过 = 切走时未达 `min(30s, 50%×时长)`（复用统计口径，**只做曲目级排除**）；
  喜欢 = 收藏；「不感兴趣」= 列表移除 + 长期记忆（可撤销）；显式生成有
  阶段进度与取消；退出保留队列。播放快照/进度由组合根接进控制器。
- **AI generation executor（生成执行器）** —
  `lib/services/ai/ai_generation_executor.dart`：token / epoch / 取消 / 忙碌位 /
  可见进度的唯一持有者。三条 lane：显式（可见、可取消、互斥）、换一首（不可取消、
  行内进度）、静默补歌（无可见进度、显式操作可抢占）；进度走独立
  `ValueListenable<AiGenerationState>`，provider 的聚合通知只转发忙碌位 /
  行内替换的离散变化（进度分片由 `generationState` 自己通知窄订阅者）。
- **AI radio queue（电台队列视图）** — `lib/services/ai/ai_radio_queue.dart`：
  每次从 live 快照派生 `upcoming` / `contains` / `missing` / `queuedAmong`，不持有
  计数器；`queuedCount` = 当前及之后仍在队的 AI 曲目数（页面「队列中还有 {count}
  首推荐」），随播放递减，不是累计加入数。
- **当前推荐（active batch）** — `AiDjBatch` / `AiDjProvider.recommendations`：
  AI 页与发现页轮播展示的那一批；持久化在推荐历史索引的 `activeBatchId`，
  启动时只加载它（详情懒加载）。换一批后旧 active 留在历史，不丢数据。
- **历史推荐（recommendation history）** —
  `lib/services/ai/ai_recommendation_store.dart` + `lib/pages/ai_dj_history_page.dart`：
  索引键 `ai_dj_history_index_v1` + 每批一键 `ai_dj_history_batch_v1:<id>`；
  保留 20 批 / 400 首 / 30 天，active 永不自动清理；删除 active 回退最近一批，
  清空历史保留 active。索引与批次载荷的写序统一为「先写索引、后删载荷」
  （删除 / 清空 / 保留裁剪都一样），孤儿载荷无害。旧单批键 `ai_dj_pending_batch_v1`
  首次加载迁移为 `restored` active；迁移成功才删旧键。历史批次只读（可播放 /
  加队列 / 设为当前 / 删除），不在历史里编辑反馈。
- **批次（batch）大小** — 10 / 20 / 30 / 50，默认 10，存在
  `AiPreferences.batchSize`；影响 LLM `count`、历史元数据与自动补歌数量，
  「换一首」固定 1；改动只对下一次生成生效。
- **静默补歌（silent auto-feed）** — 队列剩余 ≤5 首、当前上下文为
  `kAiDjContextName` 且功能启用时，后台生成一批并追加队尾 + 写历史
  （`origin=autoFeed`）。不设置 `AiDjProgress`、不显示状态卡 / 骨架 / toast /
  队列计数，**不切换 active**；生成完成时队列已播完则从新追加的第一首静默续播。
  连续 3 次失败停止自动补歌（只留内部错误状态）；显式操作优先并可取消在途
  静默任务。手动「补一批到队尾」是显式操作（可显示进度），同样不切换 active。
- **推荐偏好（recommendation preferences）** — `AiPreferences`：批次大小、
  自动补歌、风格 / 场景 / 语言 / 年代 / 探索度 / 只推荐没听过的 / 补充要求、
  发送范围、种子快照；JSON 持久化在 `kAiDjPreferences`
  （`SyncCategory.settings`）。偏好页即时保存（没有保存按钮），改动只影响
  下一次生成，不自动消耗额度。
- **发送范围（upstream scope）** — `TasteProfileBuilder` 按 `AiPreferences.sections`
  裁剪上行数据（紧凑行格式）：汇总统计 / 常听歌手 / 常听歌曲 / 时段与来源分布 /
  最近播放明细 / 已听排除清单（默认开），收藏歌曲与自建歌单（默认关，opt-in）。
  最近播放最多 50 条；已听清单发送最近 100 首，本地去重仍读最近 500 首；
  收藏最多 100 首；自建歌单最多 10 个、每单 20 首、总计 100 首；只发歌名、
  歌手与歌单名，不含 raw payload / 封面 / 播放链接；开启时曲目进入本地排除集合。
- **找歌渠道（source channels）** — 不在用户界面暴露：解析统一按音源页渠道
  顺序遍历全部可搜索渠道，不设数量上限；一个渠道找不到就继续下一个，停用
  渠道不参与。推荐行不显示命中渠道名；未解析项「重新找一次」只重新搜索、
  不重新调 LLM。
- **发送透明化（prompt transparency）** — AI 页只保留「发送给 AI 的内容」
  入口，点击后用弹窗展示发送范围、本次预览、上次实际发送与上次 LLM 原始
  返回；用户提示词、上次发送与原始返回可复制。预览与实际请求共用
  `AiRecommendationService.buildPrompt`，相同输入下文本必须相等；
  上次实际发送的 prompt 与上次 LLM 原始返回只存内存，不落盘、不打日志。
- **反馈记忆（feedback memory）** — `AiFeedbackMemory`：不感兴趣 / 跳过标签、
  喜欢标签各上限 200，「多来点这种」种子上限 20；JSON 持久化在
  `kAiDjFeedbackMemory`（`SyncCategory.settings`）。生成时合并长期记忆与本轮
  反馈；种子在下一批成功生成后消费；「清空 AI 记忆」删除长期记忆与本轮反馈。
- **Taste profile（听歌画像）** — `lib/services/ai/taste_profile_builder.dart`：
  上行 LLM 的唯一数据出口（按发送范围读聚合统计 + 最近 50 条明细 + 已听排除
  清单前 100 首 + 可选收藏/歌单，上限集中在此）；不含 raw payload / 设备信息；
  首次开启需隐私确认（`AiSettingsStore.consentKey`）。提示词文案（system、
  段名、偏好值、reason 语言）由 `ai_prompt_text.dart` 按应用语言切换。
- **Closed-book + local resolve（闭卷生成 + 本地解析）** —
  `lib/services/ai/ai_recommendation_service.dart`：LLM 只输出
  `{title, artist, reason}` JSON（容错解析 + 规范化去重），本地
  `CatalogService.search` 在用户启用/所选音源里解析成可播放曲目（打分阈值 0.6），
  失败项折叠展示；推荐结果 100% 来自已启用音源。
- **LLM config（AI 服务配置）** — `lib/services/ai/ai_settings_store.dart`：
  Base URL / API Key / 模型（OpenAI-compatible，预设 DeepSeek/OpenAI/自定义）；
  Key 只写 `flutter_secure_storage`、不进日志。
- **Queue enqueue（队列追加）** — `PlaybackFacade/Backend/Service.enqueueTracks` +
  `PlaybackProvider.enqueueDomainTracks`：顺序模式追加队尾；洗牌模式经
  `PlaybackShuffleOrder.extend` 扩展排列（当前轮老歌在前，轮末重洗覆盖全队列）。

## 跨设备同步

- **Sync envelope（同步快照）** — `lib/domain/models/device_sync.dart`：
  一次交换的完整视图（设备身份 + 各类别记录）；全量合并模型，设备间互换快照后
  逐键取新，无增量/版本向量（见 ADR-0003）。协议自始为 v3：快照的 `v` 字段
  自描述格式，当前没有按版本号的分支 / 协商 / 降级。
- **Sync record（同步记录）** — 快照最小单元：`key + version + data`；`version`
  是 `SyncVersion` 三元组，删除表示为 `deleted` 墓碑记录（墓碑另带真实删除
  时间 `deletedAt`），墓碑参与 LWW 并保留 90 天后裁剪（按 `deletedAt` 计时）。
- **SyncVersion（记录版本戳）** — `(versionPhysical, versionCounter, deviceId)`：
  物理分量 = `max(本地物理时间, 已观测最大值)`，同物理值内 `counter` 递增，
  相等按 `deviceId` 字典序；胜负判定的唯一依据（「内容时间分离」）。
- **Peer journal protocol（对端增量协议）** — `lib/data/sync/peer_journal_protocol.dart`：
  纯协议规则，不碰网络 / UI / 持久化：`chooseJournalServeMode` 决定服务端回增量还是
  全量（游标落后窗口起点 / 超前头部都重新引导）、`consumeJournalDelta` 管游标消费
  （-1 夹到 0、只接受连续 seq、空窗口不算截断，缺口 / 截断要求 bootstrap）、
  `selectJournalChunks` 管 WebDAV 分块衔接、`PeerJournalNames` 管协议文件名。引擎、
  局域网 / WebDAV 传输与测试网络共用这一份游标 / 窗口 / 分块语义，边界条件只维护
  一处。
- **Pull plan（拉取计划）** — 形状在 `lib/domain/models/sync_pull_plan.dart`，
  判定在 `lib/data/sync/sync_pull_plan.dart`：每次拉取前由
  `SyncRoundRunner._pullPlan` 现生成一份 `SyncPullPlan`（逐对端
  `cursor` / `forceFull` + discovery），同一轮的各传输消费同一份；缺口二次
  拉取会再生成一份，只带需要 bootstrap 的对端。传输只提供证据——局域网
  `snapshotId + snapshotFresh`，WebDAV `etag` / `lastmodified` + 回执头部；
  skip / delta / full 统一由 `decideSyncPull` 判定，「只有本轮新鲜证据能跳过」
  只有这一处实现。
- **Sync round runner（轮次编排）** — `lib/data/sync/sync_round.dart`：
  `SyncRoundRunner.runRound` 只剩线性编排，阶段 collect / pull /
  consume + apply / publish + compact / report 与轮次上下文都是本文件的私有
  实现；测试经 `runRound` + 假传输 / 假适配器驱动整轮，不能绕过顺序直接调
  阶段。语义保留：应用成功才推进游标、forced delivery、缺口二次拉取、
  anti-entropy、入站轮；`SyncEngine` 只留公共门面（调度器宿主 / 服务端语义 /
  入站合流 / 公告过滤）。
- **Sync book（同步状态的窄接口与单一提交）** — `lib/data/sync/sync_book.dart`：
  按用途声明 `SyncStampLedger`（适配器）/ `SyncPublicationState`（发布台账）/
  `SyncRoundState`（轮次）/ `SyncEngineState`（引擎）/ `SyncTransportState` /
  `SyncSchedulerState` / `SyncBackupState`，`SyncStateStore` 是唯一实现。
  状态 JSON 的形状与键不变，持久化只有一个出口 `commit()`：所有写入先改内存
  并标脏，轮内台账 / 首连提示 / 端点记账不单独落盘（引擎轮末提交一次），
  用户命令（类别 / 传输 / 名称 / 口令、地址簿）仍即时提交。登记类写入必须
  在增量日志追加成功之后（`SyncJournalAppender`），追加失败时旧登记保留，
  下一轮仍能检测到同一变更。
- **Sync state codec（持久化形状）** — `lib/data/sync/sync_state_codec.dart`：
  `SyncPersistedState` 是 `sync_state_v2` 的不可变快照（身份 / 类别与传输开关 /
  WebDAV / 地址簿 / 名册 / 已验证端点 / 登记表 / 指纹 / 日志 / 活动 / 版本基线），
  `SyncStateCodec.encode` / `decode` 是键名、条件字段、容错默认值与保留上限的
  唯一实现；`SyncStateStore` 只负责内存状态、身份恢复与提交时机，不再持有
  JSON 形状（见 `sync_book.dart`）。
- **Sync roster（名册状态）** — `lib/data/sync/sync_roster.dart`：设备名册 /
  已验证局域网端点 / 手动地址簿 / 首连提示 / 单轮移除抑制的唯一持有者；
  `onChanged` 只让状态存储标脏，落盘仍由 `commit()` 决定。端点校验与 180 天
  淘汰、名册按最近接触截断、地址簿合并都在这里；换口令清空旧组观测但保留
  用户配置的地址簿。
- **Sync activity log（轮次流水）** — `lib/data/sync/sync_activity_log.dart`：
  展示日志 / 近 24 小时活动 / 传输成功时间 / 快照发布位置的唯一持有者，追加
  顺序与各自上限在这里；换口令只清传输成功时间，历史日志与活动记录保留。
- **Sync round window（轮次窗口）** — `SyncRoundWindow`（定义在
  `lib/domain/ports/sync_transport.dart`）：一轮的 `pull` 与 `push` 显式共享
  同一个窗口，删除局域网私有的 `_roundStartedAt` 隐式耦合。
- **Sync transport runtime（传输运行时）** — `lib/data/sync/sync_transport_runtime.dart`：
  唯一拥有 ensure / start / stop / resume / hidden / announce 的模块；组合根把
  同一实例注入引擎与控制面（`sync_stack.dart`），两边不再各写一份
  `_ensureTransportsRunning`。
- **Peer candidate（局域网对端候选）** — `lib/data/sync/sync_peer_candidate.dart`：
  候选观测的字段级合并（本轮 presence 优先旧记忆，旧指纹不能覆盖新指纹）与
  HTTP 地址尝试顺序（IPv4 → 全局 / ULA IPv6 → 观测源地址 → link-local 兜底，
  单对端 ≤3 个），纯数据、不碰 socket / HTTP。
- **SyncStampIssuer（版本戳发号器）** — `lib/data/sync/sync_stamp.dart`：
  本机所有同步戳的唯一来源，`next()` 严格单调、`observe()` 吸收远端超前戳
  （记 warning）、`seed()` 接受初始化基线；基线持久化在 `sync_state_v2` 的
  `stampSeq`，初始化 = `max(持久化基线, 当前时钟, 全库最大戳)`，重启不倒退。
- **Content time separation（内容时间分离）** — `playedAt` / `endedAt` /
  `savedAt` / `importedAt` 与墓碑的真实删除时间是内容语义，进记录 `data`、
  **永不参与胜负判定**；历史「删除 vs 播放」由库内按真实时间比较
  （`playedAt <= deletedAt` → 删除生效，否则复活并撤墓碑，见 ADR-0003 v2 §2）。
- **Protocol v3（协议版本）** — `SyncEnvelope.protocolVersion = 3`：线上格式
  只有 v3（帧 `magic + 版本 + nonce`、载荷列式二进制，见 ADR-0003 §1），
  只写只读 v3；**没有版本闸门、协商或降级**，版本不符一律明确失败。备份导入
  只做结构校验（不是 Molia 备份 / 内层 envelope 无效才抛 `FormatException`）。
- **Sync category（同步类别）** — 可开关的数据类别：`playlists` /
  `playlistTracks` / `sources` / `settings` / `credentials` / `statistics` /
  `history` / `session` / `covers`；关闭的类别既不推送也不应用（本机仍持续
  登记本地变化）。`covers`（自定义封面）默认关闭，且不进蜂窝小类别。
- **Cover sync adapter（封面同步适配器）** — `lib/data/sync/adapters/cover_sync_adapter.dart`：
  `covers` 类别的记录桥：每曲封面 + 默认封面保留键 `__default_cover__`；版本
  由 `SyncStampIssuer` 按内容哈希发放，首次登记不写增量日志，真实变化 / 删除
  才追加；远端应用经 `CustomCoverStore.applySynced*`（不触发本地变更回调）。
  单张 > 500KB 或损坏只跳过同步，本地封面保留。
- **Playback session record（会话记录）** — `session` 类别的单例记录：会话 JSON
  （队列/下标/进度/模式）+ `savedAt` 时间戳；正在播放的设备持续刷新从而抢占，
  本地停止播放不回传删除（换设备接着听的轻量实现）。系统控制路径（通知暂停 /
  停止 / 切播放顺序）显式 await 会话模块的强制落盘
  （`PlaybackSessionCoordinator.flushSession` → `PlaybackSessionStore.pendingWrite`
  串行化，停止先落盘再清空队列），冷启动恢复不自动起播。
- **Backup（完整备份）** — `lib/data/sync/sync_backup.dart` 的
  `SyncBackup.exportBackupJson` / `importBackupJson`：与同步共用 envelope、
  适配器与版本戳（本地记录的收集入口由引擎注入，`SyncEngine.collectRecords`），
  但**不构造轮次、不经传输**；不需要启用同步；凭证类默认排除。
- **Sync control plane（同步控制面）** — `lib/data/sync/sync_control_plane.dart`：
  UI 面的控制 / 身份 / 传输开关与运行状态（设备名与设备 id、类别开关、传输开关 +
  `transportStatus`、手动地址簿、`lanDiscoveryPorts`、口令生命周期、观测快照
  的只读 getter）；与引擎共用同一 `SyncStateStore` 与同一份传输实例，成功写入
  后 `notifyListeners`。传输的起停 / 生命周期 / 公告统一归传输运行时
  （`sync_transport_runtime.dart`），引擎只保留公共门面（调度器宿主 / 服务端
  语义 / 入站合流 / 公告过滤，`sync_engine.dart`），轮次内阶段编排在
  `SyncRoundRunner`；两边的 seam 是「控制面改状态 → 引擎下一轮读到」。
- **LWW stamp（逐键版本戳）** — 版本戳 `SyncVersion` 三元组：物理分量大者胜，相同时
  `counter` 大者胜，再同按设备 id 字典序决平局（确定性收敛）；物理分量是
  HLC-lite 的 `max(本地墙上时钟, 已观测最大值)`，不再是「最后的墙上时间」。
- **Sync passphrase（同步口令）** — 信任根：PBKDF2 派生 AES-256-GCM 密钥，
  能解密快照的设备即已授权；生成/归一化在 `sync_passphrase.dart`，加密帧在
  `sync_crypto.dart`；重置口令 = 撤销全部设备，并清空本机对旧组的观测（名册 /
  已验证端点 / 首连提示 / 传输成功时间），所有设备必须重新配对；地址簿
  （host / 端口）作为用户配置保留。
- **Sync transport（同步传输）** — `lib/domain/ports/sync_transport.dart`：
  `pull` / `push` / `incoming` 三动作；实现为局域网直连
  （`transport/lan_sync_transport.dart`）与用户自备 WebDAV
  （`transport/webdav_sync_transport.dart`）。局域网发现、数据与存活检查分开：
  UDP 只发现（`MSD/1`），HTTP `/molia-sync/v2/*` 才是数据通道。
- **LAN discovery（局域网发现）** — `transport/lan_discovery.dart`：`MSD/1`
  二进制公告（magic / version / type / 截断 HMAC / bodyLen + body），发现密钥
  = HKDF(口令根密钥, info `molia-sync-discovery-v1`)；先来源限流再验 MAC 再
  解析，nonce 30 秒去重、boot 标识进程重启、presence 上限 32。公告 burst
  100/500/2000ms，正常轮只单播 ≤8 个已知端点并等 400ms，蜂窝 0 广播、
  后台 0 定时器。
- **LanPeerEndpoint（已验证局域网端点）** — `SyncStateStore.lanEndpoints`：
  `deviceId → {host, httpPort, probePort, verifiedAt}`，只在 MAC + HTTP 解密
  成功（`onPeerVerified`）后回写；32 条上限、180 天淘汰、`removePeer` 一并
  清理。只有持久化端点的对端是「试探性对端」，失败不计数；手动地址与本轮
  presence 是「预期对端」。
- **Sync adapter（同步适配器）** — 类别到本地存储的读写桥
  （`lib/data/sync/adapters/**`）：收集本地记录 / 应用合并结果，写入必须幂等；
  设置类用「登记哈希」（`SyncStamp`）做变化检测，不改造散落的写入方。
- **Sync tombstone（删除墓碑）** — 列表 / 曲目 / 脚本 / 历史的删除不保留原行，
  由 `sync_tombstones` 表或同步状态中的登记项承担「删除也取新」的合并语义；
  表内版本三列 + 真实删除时间 `deletedAt`（历史删除 vs 播放的判据）。
- **Setting stamps（设置登记哈希）** — `SyncStateStore.settingStamps` 维护的
  `key → (值哈希, SyncVersion)`：本地值 vs 登记哈希判定本地修改，变化时向
  `SyncStampIssuer` 取号，应用远端后同步更新，保证重复应用幂等
  （见 `docs/adr/0003` §6 修订）。
- **Settings key（登记键）** — `lib/data/settings/settings_key.dart`：一个设置键的
  全部事实（名字 / 默认值 / 同步类别 / 存放盒）；只有有「第二消费者」的键才登记
  （同步、备份、应用远端后的重载、整表驱动的测试），设备本地键留在各自模块。
- **Settings registry（设置注册表）** — `lib/data/settings/settings_registry.dart`：
  登记键的唯一家（读 / 写 / 同步往返 / 重载钩子）；组合根只构造这一份实例，
  再按模块分发按键作用域（`SettingsScope`），模块把 reload 钩子绑到自己的键，
  应用远端值后按变化的键触发。快捷键开关与绑定四键（`kShortcutsEnabled` /
  `kGlobalShortcutsEnabled` / `kShortcutBindings` / `kGlobalShortcutBindings`）
  同表登记为「跟人走」。键名字面量只有一份（`settings_keys.dart`），由
  `test/architecture/settings_keys_test.dart` 强制；私自
  `SettingsRegistry(keys: kAllSettingsKeys)` 由
  `test/architecture/settings_registry_usage_test.dart` 扫描拦住。
- **Settings access（模块设置访问面）** — `lib/data/settings/settings_access.dart`：
  `SettingsAccess` 只含模块需要的 `read` / `write` / `clear` / `bindReload`；
  整表、`readRaw` / `writeRaw`（同步宽容转换）、`onWrite`（本地写入钩子）与
  `reloadKeys` 都留在注册表，不下放给模块。
- **Settings scope（按键作用域）** — `SettingsRegistry.scope([...])` 返回的
  `SettingsScope`：同一份注册表 / 同一份存储上的按键视图，只暴露声明过的键；
  越界访问在 debug 断言、release 抛错。组合根是唯一构造注册表的地方，模块
  构造参数是 `SettingsAccess` / `SettingsScope`，不再各建私有注册表；模块初始
  默认值取自 `SettingsKey.defaultValue`，不在字段里复制字面量。
- **Sync round report（一轮同步报告）** — `SyncRoundReport`：一轮的**可观察**产物。
  五态结论 `ok / noChanges / noPeers / partial / failed`（「没发现对端」与
  「没有变化」必须分开）+ 每传输明细
  （拉取 / 推送 / 失败数 / 字节 / 耗时 / 不可用原因）+ 每对端名册 + 本轮落地
  变更量（不是全库规模）。`SyncEngine.syncNow` 返回**本次请求所加入的那一轮**报告：
  轮次进行中的请求并入补跑轮并等该轮结束，多个排队请求共同收到同一份报告；同步关闭
  返回 null（不拿上一轮冒充）。
- **Device identity（设备身份）** — `sync_device_id_v2`：独立的 prefs 小键 +
  安全存储备份，用来标识「本机是哪台设备」（版本戳 / 探测 / 附近设备配对 /
  WebDAV 文件名）。**不跟着 `sync_state_v2` 一起重生成**：大状态损坏时从小键 /
  安全存储恢复，避免手机重启或换 IP 后被对端当成一台新设备。
- **Sync peer roster（同步名册）** — `SyncPeerState`：每台对端的最近接触观测
  （名称 / 传输 / 最后拉取·推送 / 时钟偏移 / 落后条数 / 最近失败），持久化在
  `sync_state_v2`，UI 在同步设置页首屏的「设备」区呈现（名册内联）；
  地址簿里尚未进名册的条目（未认领候选折叠为一行「候选地址 N 个」）在
  「高级设置」子页；「落后条数」由增量协议填充。**移除设备只清本机名册与
  该设备的地址簿条目，不撤销授权**：对方仍持有口令并在线时会重新出现；真正
  撤销需更换口令。没有「本地忽略 / 屏蔽」这一层。
- **Nearby devices（附近设备）** — `lib/pages/sync_settings_page.dart`：同步设置页
  首屏顺序固定为「传输方式 → 已配对设备 → 附近设备 → 同步内容 / 日志 / 高级
  设置」，设备名、口令、网络地址、端口与地址簿在 `sync_advanced_page.dart`。
  附近设备来自 `MSP/1` 探测 / 应答（`transport/lan_pairing_packet.dart`）：
  只做候选发现（独立 magic、无 MAC、15 秒 TTL、上限 32），不写名册
  `lastSeenAt`、不触发同步轮次；局域网开启且 App 前台时，点候选即发起配对
  （一次性 P-256 密钥 + 6 位确认码）。自动发现失败时，高级设置里的手动地址会
  向该地址单播 `MSP` 探测，收到应答后走同一套配对请求；手动地址不携带口令。
- **Pairing request（配对请求）** — `lib/data/sync/pairing/lan_pairing_service.dart`：
  `POST /molia-sync/v2/pair/request`、`GET /pair/status`、`POST /pair/complete`
  （invite 方向）。请求体 ≤8KB；pending 上限 8、TTL 60 秒、同一时间只展示一个
  待确认弹窗，每来源限流；只在局域网传输运行、App 前台、非蜂窝时可探测 / 应答。
  requestId 为随机 128-bit；口令只在临时 ECDH（P-256）+ HKDF-SHA256 +
  AES-256-GCM 密封后传输，AAD 绑定 requestId / intent / 双方 deviceId；同组用
  discovery key 的 HMAC 证明识别（直接补端点、不弹窗），双方都有不同同步组则
  返回冲突、不交换口令。
- **Confirmation code（确认码）** — 由双方临时公钥、nonce 与 requestId 派生的
  6 位数字（展示为 `482 193`）：发起方与接收方显示同一个码，由用户口述核对；
  码不一致必须拒绝。确认码不经过口令，也不作为后续认证凭据。
- **Sync group（同步组）** — 持有同一同步口令的设备集合。**接受配对请求 =
  加入同步组 = 对方获得本机同步口令**，能解密全部同步数据（含音源脚本与 API
  Key 等密钥），接受弹窗必须明示；口令只进安全存储，不进日志 / 错误详情 /
  分析事件。已配对的设备继续走 `MSD/1` 发现与 `MSY/3` 载荷协议；旧
  `molia-pair:*` / 二维码 / 粘贴配对码已删除，不识别、不迁移、不兼容。
- **首次连通提示（peer connected notice）** — 某设备第一次真正交换过数据
  （`lastPullAt` / `lastPushAt`，入站推送同样计；只探测应答不算）时，由引擎发
  一次性事件（`SyncEngine.peerConnectedNotices`），应用壳（`MyThemedApp`）订阅
  后经 `NotificationService` 弹「已与『设备』连通」：双方各自触发一次，与用户
  在哪个页面无关。已提示的 deviceId 持久化在 `sync_state_v2.notifiedPeers`，
  重启不重发；设备从本机移除（名册 + 地址簿条目）时标记清掉。
- **Local endpoints（本机地址列表）** — `local_endpoints_service.dart`：
  枚举本机可路由地址（排除回环 / link-local / zone）并私网优先排序；过滤
  判定 `isRoutablePeerAddress`（`lib/utils/peer_address.dart`）与服务 / 传输
  共用，传输侧经注入的 `hosts()` 复用同一枚举（未注入时按同一判定现算），
  因此设置页地址列表、附近设备探测与局域网探测 `addrs` 候选是同一口径。
- **Sync transport status（传输状态）** — `SyncTransport.unavailableReason`
  （`not_configured` / `start_failed` / `permission_denied`）：传输启动失败、
  未配置或缺权限时必须显式可见，不能只留在日志里（开关显示「已打开」而实际
  没有监听是排查事故的主要来源）。传输开关同时是同步的总闸：`enabled` 是
  `enabledTransports` 非空的派生值（没有独立总开关键），两路都关 = 完全停；
  开关的起停与状态读取归**同步控制面**（`sync_control_plane.dart`）。
- **Local network permission（局域网权限门）** —
  `transport/local_network_permission.dart`：Android 17 / API 37 起局域网访问
  默认阻断，LAN 传输启动前先过门；**权限被拒时手动对端地址同样无效**
  （网关级阻断），只能授权或转 WebDAV。申请时机只跟用户动作走：打开局域网
  开关 / 点「去授权」时 `ensure(retry: true)`（先复查再申请），被拒开关回退
  关闭并给底栏 + 常驻警告行；启动与轮次只 `refresh()`，冷启动不弹窗。
  申请 / 查询 / 跳系统设置可注入，单测不触发平台通道。
- **Manual peer（手动对端）** — `ManualPeer{host, probePort?, httpPort, deviceId,
  name}`：**发现失败**（AP 隔离 / 多网段 / 防火墙 / VPN）时的兜底，与广播发现
  合并进同一名册；首次单播探测后认领 `deviceId` 与端点端口并回写，学到端口后
  不再依赖广播。本机端点端口持久化（`lanHttpPort`），否则对端记不住本机。
  未配对设备通过单播 `MSP` 探测出现在「附近设备」，点击后走同一套配对请求；
  学习路径只更新身份与端口（不动地址集合）。地址簿可能累积多条地址（双栈 /
  多网卡 / 换过 IP），设备详情里可逐条更新（`moveManualPeer`，身份与已学端口
  保留）或删除；地址以 deviceId 关联。
- **Sync report / log（同步结果 / 日志）** — `SyncLogEntry`：触发原因 +
  五态结论 + 本轮变更量 + 失败数与错误；设置页只读展示，不拦截合并。
  计数一律是本轮变更量（不随数据量增长）。
- **Sync known versions（已知版本登记）** — `sync_known` 表 +
  `SyncKnownStore`：引擎合并后只把版本与该登记不同的胜者交给适配器（交付成功
  才登记，本地视图以内存播种为基线），因此空闲轮 0 次 apply、落地量与日志计数
  ∝ 本轮变更量；登记不随墓碑清理删除（清理后同版本的旧记录不重新判为新记录）。
- **Transport gating（传输门控）** — 内容未变不传：快照带
  `snapshotId`（记录集规范化哈希，与 `producedAt` 的「时间变」分开），局域网
  公告携带它、WebDAV 用 `getetag` / `getlastmodified`，未变跳过
  GET + 解密 + 合并；「未变」是否成立统一由拉取计划的 `decideSyncPull` 判定
  （只有本轮新鲜证据能跳过）。本机内容指纹与上次成功推送一致时跳过加密 + 上传。
- **Publish ledger（发布台账）** — `lib/data/sync/publish_ledger.dart`：每传输
  一份（局域网 / WebDAV），把「这轮能不能跳过加密 / 上传？journal 能裁到哪」
  的判据收在一处。聚合三处事实：**内存指纹**（本进程成功外发过的载荷身份：
  全量快照按内容指纹、增量窗口按「窗口边界 + ack 集合」）、**持久覆盖**
  （`sync_state_v2` 的 `snapshotPushSeq` = 该传输成功发布过的快照覆盖位置，
  重启不回退）与 **`servesLiveSnapshot` 能力位**。两个动作：`plan(outgoing)`
  回答是否外发，`mark(result)` 记账（成功才记；零对端与失败都遗忘，下轮重发；
  快照成功才推进持久覆盖）；`publishedCoverage` / `journalCoverage` 回答日志
  裁剪的覆盖下限（按需给实时快照的传输不约束）。push 循环与 journal compact
  只消费台账，轮次编排只负责调用顺序。
- **Key derivation cache（密钥派生缓存）** — `SyncCodec`：PBKDF2(口令, 应用级
  固定盐) 得根密钥并按口令会话内缓存一次，帧密钥 = HKDF(根密钥, 帧 nonce)；
  帧不携带盐与迭代数，帧密钥派生与载荷编码在 worker isolate 内执行
  （见 ADR-0003 §1）。
- **Sync level（同步等级）** — `SyncScheduler` 的四个等级：**活跃**（可见 +
  最近交互 / 正在播放，变更去抖 4s）/ **空闲**（退避 10→20→40→60 分钟封顶；
  蜂窝下无本地变更不广播、不发 PROPFIND，非蜂窝网络唤醒照常探测与拉取）/
  **后台**（零定时唤醒，退后台尽力推、回前台拉）/ **省电**（低电量未充电或
  系统省电模式：暂停自动，仅手动）。移动数据下默认只同步小类别
  （设置 / 音源 / 凭证 / 歌单与曲目 / 会话），可切换为「暂停自动同步」。
- **Battery probe（电池探针）** — `lib/services/battery_probe.dart`：经平台通道
  （Android `BatteryChannelHandler` / iOS `AppDelegate`）读电量 / 充电 / 系统
  省电模式；桌面未实现按「未知」处理（不触发省电等级），调度器注入探针。
- **Sync activity summary（同步活动汇总）** — `SyncActivitySummary`：近 24 小时
  的触发轮数 / 有效传输轮数 / 流量，同步页运行状态行与等级 · 网络 · 省电一起
  展示；窗口基于状态存储保留的最近日志条目。

## 缓存
- **Local data（本地数据）** — 单曲在本机的东西，分两档：**已缓存**（易失副本：边播边缓存 / 后台下载 / 取词 / 取图产生，可离线播放，会被 LRU / TTL / 清理回收）与**已下载**（持久副本：`downloads/` + drift 记录，可分享、清缓存不影响），两档都没有就是「未下载」。两档都不是的那首曲目在信息页与页内统一显示「未下载」。唯一读取口 `lib/services/track_local_data_service.dart`（单曲 `load`、列表批量 `loadMany`、只要「已缓存」音频档的批量 `cachedAudioTrackIds`，`TrackLocalData`），词表唯一出处 `LocalPartState`；**禁止** 页面或模块另写「算不算有」的判据（见 ADR-0008）。
- **转存（Save a copy）** — 把已缓存的一档「固化」成持久下载：拷贝缓存内容到 `downloads/`（不触网）+ 落库，动作文案「转存到本地文件夹」。缓存命中时下载动作本身就是转存；转存后状态从「已缓存」变「已下载」。
- **Audio cache store（音频缓存约定模块）** — `lib/services/audio_cache_store.dart`：音频缓存目录磁盘约定的唯一实现（写入 / 读取两侧 key 命名、完整文件判据、完整文件索引、命中路径、按曲目的已缓存音质、半成品清扫、旧命名迁移）。`CacheService` 的实例方法（索引 / 占用 / 清理）是策略面的薄委托；键名与完整判据不再有第二处门面（测试同样只经本模块）。文件存在性由调用方注入（命中探测与其后的拷贝必须同一文件系统视图）。见 ADR-0008。
- **音频缓存键** — 缓存文件名 `{sourceKey}_{songId}_{quality}`（Audio cache store 的 `keyForSource` / `keyForTrack`）。`songId` 必须与 `TrackId.id` 同源（`SourceTrack.songId`，不带 `sourceKey:` 前缀）——写入侧与读取侧同名是硬约束，否则文件写了也没人找得到。
- **半成品（partial）** — 音频缓存目录里未落成的文件：just_audio 边下载边写 `*.part`、字节预取写 `*.predl`、MIME 边车 `*.mime`。它们占磁盘但不是可播放缓存：索引 / 占用 / 命中一律排除（判据在 Audio cache store），单独计为「写入中」，启动时清扫（写入者在本进程内，重启后残留必为孤儿）。
- **Lyrics cache（歌词缓存模块）** — `lib/services/lyrics_cache.dart`：歌词读写、用量与清理的唯一实现。默认构造 / 未接入实例保持旧的 SharedPreferences 行为（不碰 `path_provider` 与文件 IO，widget 测试与降级平台依赖它）；生产组合根用 `LyricsCache.appSupport()` 显式接入文件后端：`<appSupport>/lyrics_cache/{md5(trackId)}.json`（一条一文件、临时文件 + rename 原子写），旧版 `lyrics_cache_{trackId}` prefs 条目在首次读取时懒迁移，目录不可用时回退 prefs。TTL 策略属于 `CacheService`（取词时读取）。历史 `manual_lyrics_cache_*` 重复键只清不读。
- **Artwork index（封面索引）** — flutter_cache_manager 的元数据存储；`CacheStorage` 直接删文件后，由 `ArtworkCache` 的 `_pruneMissingEntries` 同步清理失效条目（索引不指向缺失文件）。
- **Paged list controller（分页列表状态机）** — `lib/providers/paged_list_controller.dart`：首屏 / 加载更多 / 失败态（首屏清空可重试 vs 追加保留）/ 过期响应丢弃（`reset` 与 `dispose` 都使在途请求过期）/ 跨页去重 / 「追加页去重后无新增即 `hasMore=false`」推断的唯一实现；状态以一个值发布（`PagedListState<T>`，一次请求只发终态），持有方提供 `fetchPage`（平台特有的「取满即结束 / 达到总数」判断留在取数回调）。消费面：`SearchProvider`（按 `SearchKind` 三会话）、评论热门 / 最新 tab、发现页歌单 tab 与曲目页、专辑页、歌手页——不再各自手写 flag 机。
- **Library collections（合集策略模块）** — `lib/providers/library_collections.dart`：收藏 / 播放历史 / 本地歌曲 / 自建列表的哨兵（`unset` / `favoritesSentinel` / `historySentinel` / `downloadsSentinel`）、默认选择解析（`resolveSelection`，后两者仅显式选择进入）、顺序应用（`applyOrder`）与持久化（顺序 / 选择的唯一实现）；收藏页只保留 UI 状态。滚动位置见 Collection scroll bookkeeping。
- **Local songs collection（本地歌曲状态机）** — `lib/providers/local_songs_collection.dart`：本地歌曲伪合集的数据状态机：拥有播放历史 × 下载 / 导入记录 × 完整音频缓存的联结、下载优先去重、输入签名（历史键 + 下载记录键 + 缓存 revision）、在途加载令牌（输入变化即丢弃过期结果）与加载态 / 弹层计数；`CollectionLocalSong` 的行形状也从渲染层移到这里。页面每帧只把输入交给 `sync` 并消费 `rows`，不再在 build 里重算联结；缓存列举失败只影响缓存行，不拖垮下载 / 导入行。
- **Collection presenter（合集投影器）** — `lib/providers/collection_presenter.dart`：收藏页合集身份、可见行与行动作构成的唯一推导：先把选集解析成 `CollectionIdentity`（`CollectionKind` / 落库 `playlistId` / 展示名 / 合集键 / 列规范），再按当前合集做过滤与排序，产出 `CollectionView.visibleRows`——统一的 `CollectionRow` 联合（`TrackCollectionRow` / `HistoryCollectionRow` / `LocalSongCollectionRow`）与 `hasItems`；排序结果按源列表身份记忆化，`rowActionsFor` 按行变体给出动作规格。收藏页不再用四个布尔值 + 三份可见列表，也不按 `CollectionKind` 分支拼行或挑动作；标题 / 滚动键 / 多选栏 / 表头都读同一份视图。

- **Collection session（合集会话）** — `lib/providers/collection_session.dart`：收藏页「当前合集」的唯一状态机：恢复（合集顺序 / 选集 / 滚动偏移，一次）、选中合集校准（合集列表首次加载完成、下载能力就绪后校准一次；失效 / 未选的选集回退到默认解析并落盘）、模式（搜索 / 排序 / 调整顺序）、按行 key 的多选与失效、加载组合（首帧列表 / 列表曲目 / 历史首载 / 本地歌曲联结合成为一个 `loading` / `ready` / `failed` 阶段，failed 提供重试）、合集切换与选择 / 顺序持久化、滚动键与恢复时机（同一合集只激活 / 恢复一次）。页面每帧只交一份 `CollectionSessionInput`（资料库读取端口 `CollectionLibrary` + 展示名 + 搜索词 + 下载 / 缓存快照）、消费一个 `CollectionSessionView`；不再在 build 里做 post-frame setState 校准或 `ensure*` 编排。端口只有 `snapshot(playlistId:)`（一帧 `CollectionLibrarySnapshot`：列表清单 / 历史 / 读取阶段 / 当前列表曲目视图）、`load(CollectionLibraryLoad)`（首帧 / 当前列表 / 整页重试 / 历史重排意图）与 `trackFromHistoryEntry`；会话持有最近一帧快照，弹层计数与重试不再依赖「先 sync 一次」的隐藏顺序。本地歌曲联结与展示名以外的合集投影仍由 Collection presenter 提供。
- **Collection selection（合集多选状态机）** — `lib/utils/collection_selection.dart`：收藏页收藏 / 历史 / 本地歌曲共用的多选唯一实现（选择集按**行稳定 key** 而不是可见行下标，Ctrl 切换、Shift 区间与锚点移动、全选三态、`retainKeys` 随视图收缩；插入 / 过滤后选择仍指向原行）；页面只保留点播分支与动作实现，Esc 的可见性 / 焦点判定仍属页面（同源规则见 Escape claims）。
- **Collection list（合集列表模块）** — `lib/widgets/collection_track_list.dart`：收藏页各合集共用的一份列表脚手架（Scrollbar 参数、`itemExtent = TrackRow.extentOf(context, tableColumns: …) + gap`、懒构建、重排模式、空态 / 搜索空态、行动作（触摸端左滑胶囊 / 桌面右键菜单）与行外壳 `CollectionTrackRow`）；行内容由调用方 `itemBuilder` 提供，页内过滤 / 排序口径在 `lib/utils/collection_row_query.dart`（`collectionRowMatches` / `sortCollectionTracks`）。
- **Collection scroll bookkeeping（合集滚动簿记）** — `lib/widgets/collection_scroll_bookkeeping.dart`：按合集键保存 / 恢复滚动位置的唯一实现（节流 ≤2 次/秒、切换合集各自只恢复一次、夹取到可滚动范围）；调度器（`CollectionScrollScheduler`）可注入，脱离 widget 树可单测。
- **Local songs（本地歌曲合集）** — 收藏页的伪合集（`downloadsSentinel` ↔ `downloadsOrderKey`）：数据来自 `DownloadService.downloads`（下载副本 + 本地导入）与 `TrackLocalDataService.cachedAudioTrackIds`（播放历史 × 完整音频缓存命中且无音频下载，一次目录列举），不落列表表；仅在下载能力可用（`DownloadService.supported`）时出现在合集弹层，排序固定按下载 / 导入时间倒序。合集弹层打开前先把缓存行重算到当前输入，弹层计数与列表行数同源。
- **Local import（本地导入）** — `downloads` 表 `imported` 行 = **就地引用**用户自己的音频文件：`originSourceKey = 'local'`、`originSongId` = 文件绝对路径（同路径重复导入幂等），`filePath` 指向原文件；删除记录只移行、不删文件，补发布 / 旧位置迁移都跳过。写入唯一入口 `DownloadService.importLocalFiles`（标签解析见 `lib/data/downloads/audio_tag_reader.dart`：mp3 ID3v2 / flac Vorbis Comment，其余格式按文件名兜底）。
- **Save As（另存服务）** — `lib/services/save_as.dart`：所有用户可见文件导出的唯一入口（备份 JSON / 听歌统计 JSON / 歌词海报 PNG / 音频副本）。桌面弹“另存为”并默认指向另存目录，取消不报错；Android 写临时文件后经 `DownloadsPublisher` 进 MediaStore；iOS 直接写应用文档目录。结果分 saved / cancelled / failed，UI 按 `SaveLocationKind` 选提示文案；文件名与子目录在服务内清洗（拒绝 `..` 与路径分隔符）。
- **Public output root（另存目录 / 公共输出根）** — `lib/data/files/public_downloads_path.dart` + `SaveAs.rootPath`：应用对用户可见的输出根。桌面 = 系统公共下载目录（Windows Known Folder / Linux XDG）下的 `Molia/`，设置页自选目录优先；Android = `Download/Molia`（MediaStore，Dart 不直接写）；iOS = 文件 App 可见的应用文档目录 `Molia/`（没有系统公共 Downloads 概念）。音频在根下，导出 JSON 进 `exports/`，海报进 `posters/`；下载根与另存根共用同一解析（Android 例外：私有播放副本 + 默认公共副本）。
- **Download notifications（下载通知模块）** — `lib/data/downloads/download_notifications*.dart`（平台 seam：IO=MethodChannel，其它平台 no-op，通道异常只记日志、绝不影响下载本身）+ Android `DownloadNotificationService`（`dataSync` 前台服务）：下载进行中在系统通知显示进度（批量共享一条「N/N」），完成 / 失败 / 取消收尾并移除；API 33+ 未授予通知权限时降级为「无通知但继续下载」；开关 `download_notifications`（设备本地键，默认开）。通知生命周期的编排见 Download notification presenter。
- **Download file layout（下载文件命名 / 放置模块）** — `lib/services/download/download_file_layout.dart`：文件名模板（`DownloadSettings.filenameTemplate`）→ 基名 → 清洗（`sanitizeFileName`）→ 唯一基名（磁盘与下载记录双重查重，` (2)` 递增）→ 路径约定（音频 / `.part` 半成品 / `lyrics/` + `.t.lrc` 翻译边车 / `covers/`）与 sidecar 写入（失败回滚）的唯一实现；扩展名推断（直链后缀 / 音质映射 / 封面后缀）与「记录引用的文件集」（删除 / 失败清理 / 孤儿判定共用）也在这里。此前命名有两份实现——下载真正走的模板版与只为测试存在的静态双胞胎（无歌手时命名不同），双胞胎已删除、测试直接打生产实现。
- **Download record assembler（下载记录装配模块）** — `lib/services/download/download_record_assembler.dart`：部分状态 → `DownloadedTrack`（16 字段）的唯一装配点，五种形态各一个意图方法：`forAudioDownload`（完整下载 + 分项合并 / 公共副本回退）、`forPartialDownload`（分项更新保留已有音频与另一分项）、`forLocalImport`（就地引用）、`relocated`（旧根迁移路径重映射）、`republished`（补发布只补定位）。`downloadedAt` 走注入时钟，记录既有时间不重取；`DownloadService` 不再感知记录字段。
- **Download notification presenter（下载通知 presenter 模块）** — `lib/services/download/download_notification_presenter.dart`：下载生命周期 → 系统通知 start / update / stop 的唯一实现（单任务 id `track:{key}`、批量共享 `batch`「N/N」、500ms 系统频率节流「首片 / 窗口 / 完成突破」、收尾只收自己起过的——中途关掉开关也不残留）；端口（`DownloadNotifications`）/ 设置开关 / 时钟都可注入，编排与其测试不依赖 Android。批量并发调用不抢占（同一时刻只有一条批量通知）。
