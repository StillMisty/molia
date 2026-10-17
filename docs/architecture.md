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
│   LocalDatabaseProvider（play_contexts）/ ThemeProvider         │
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
   迷你条）与全局 key 在 `lib/app/app_shell.dart`，桌面骨架（顶栏 / 侧栏 /
   常驻底栏播放条 / 队列右面板）在 `lib/app/desktop/**`，测试可直接挂载
   （`MyApp(desktopShell: true/false)` 可强制骨架，默认按平台判定）；
5. UI 禁止 import `lib/sources/**`（Wave 7 后白名单已清空，新增违规必须修复）。

## 2. 领域层

- **模型**（不可变 + 可靠 `==`）：
  - `Track` / `TrackId(sourceKey,id)` / `Artist` / `Artwork` / `AudioQuality`；
    `Track.payload` 承载源脚本原始对象（原 `SourceTrack.raw`），**只在 data/sources 传递、必须原样回传**；
  - `PlaybackSnapshot` / `BackendSnapshot` / `PlaybackRequest` / `PlaybackContext`；
    `PlaybackSnapshot.next` 是后端按当前模式解析出的下一首（shuffle 单曲内稳定），
    `history` 是实际播放顺序（最近在后），`upcoming` 是队列顺序（非播放顺序）；
  - `SearchQuery` / `SearchResult<T>`；`SourceFailure(kind/l10nKey/retryable)`；
  - `Comment` / `CommentPage`（评论正文 / 时间 / IP 归属 / 点赞 / 引用 / 楼中楼，
    `CommentKind` 区分热门与最新）；
  - `Album`（专辑 id / 名称 / 歌手 / 封面 / 年份 / 曲目列表 / 分页）；
  - `ArtistSummary` / `ArtistDetail`（歌手搜索条目 / 歌手页数据：头像、简介、曲目、分页）；
  - `LyricHit`（按歌词搜歌命中：领域 `Track` + 命中片段）；`SearchKind`（song / artist / lyric）；
  - `SourceDescriptor` / `SourceCapabilities`。
- **端口**：`MusicSource`（search/resolve/lyrics/artwork/comments/collection/searchArtists/searchLyrics）、`SourceRegistry`
  （descriptors/byKey/forTrack/setOrder/changes）、`PlaybackBackend`（state ValueListenable +
  load/play/pause/seek/next/previous/setMode/stop）、`PlaybackFacade`（snapshot + position +
  控制方法）、`UiMessenger`（showMessage/showFailure）、`StateListenable<T>`。

## 3. 数据/适配层

- **Catalog**：`SourceManagerMusicSource` 包装 `SourceManager` 按 key 分发；
  `SourceRegistryImpl` 构建 `SourceDescriptor`（排序转发 `lx_source_order`）；
  `CatalogService` 提供 `search`（缓存 5min）、`searchArtists` / `searchLyrics`
  （同一 5min 缓存实例，key=`search:{source}:artist|lyric:{keyword}:{page}:{limit}`，
  前缀失效与单曲搜索共用）与 `resolve`（缓存 10min，key=`url:{source}:{md5(canonical payload)}:{quality}`，
  失败不缓存，可 `invalidatePrefix`），并把异常归一化为 `SourceFailure`。
- **Playback**：`LocalPlaybackBackend` 组合 `LocalPlaybackService`（值变才发快照；
  播放顺序栈 `PlaybackOrder` 记录实际播放过的下标，供 `previous` 与快照 `history`）；
  `DefaultPlaybackFacade` 合并快照通知（`==` 去重）、把进度拆到独立 `position`
  `ValueNotifier`（≥250ms 去重、换曲/seek 直接对齐、**不进快照**）、错误归一化。
  `PlaybackProvider` 对外只暴露领域 `PlaybackSnapshot` + position 通道：
  真实播放取 facade 快照；冷启动恢复态由会话构造覆盖快照（`isPlaying=false`，
  history 为会话队列前缀）。恢复播放：会话模式先落到后端（shuffle 洗牌顺序
  依赖装载前模式）；seek 落地前进度通道继续显示恢复进度（不闪回 0）；装载期间
  用户 seek 优先；生命周期 `paused` 强制落盘会话。旧「远程播放风格 Map 兼容层」
  （facade `compat*` / service `currentTrackMap` 等）已删除。
  播放副作用的扇出（最后播放 / 播放上下文 / 桌面小组件 / 播放历史 / 会话落盘 /
  预取 / 补封面 / 通知权限）唯一实现在 `lib/services/playback_observer.dart`
  （Playback observer）：直连 facade 快照与 position 通道、由组合根挂接，不经
  provider 的节流通知（避免合并窗口丢中间曲目副作用）；恢复态与睡眠定时仍属
  `PlaybackProvider`。与 `PlayStatisticsService` / `ArtworkThemeSync` 同为观察者形态。
- **音频焦点与定时关闭**：`AudioFocusGuard`（`lib/playback/audio_focus_guard.dart`，
  其他应用出声 → 暂停，默认开；`androidWillPauseWhenDucked` 把 duck 升级为暂停语义）
  由 `LocalPlaybackService` 持有；倒计时定时关闭为**绝对 deadline**
  （tick / 快照变化 / 回前台三路补触发），并按平台挂 `SleepTimerAlarm`
  （`lib/services/sleep_timer_alarm*.dart` → Android `SleepTimerChannelHandler` /
  iOS `SleepTimerChannelHandler.swift`）：熄屏 / Doze 下 Dart timer 被节流或
  冻结时，由原生定时器到点唤醒 Dart 执行暂停；原生不可用（桌面 / 测试）
  自动退化为纯 Dart timer。
- **Lyrics**：`LyricsProvider`（`lib/providers/lyrics_provider.dart`）是取词 → 缓存 →
  解析 → 预取的唯一实现，对外只暴露 `LyricsState`（idle/loading/ready/empty + isSynced，
  含按时间戳对齐的翻译 / 罗马音扩展行与逐字时间轴）。时间契约统一在
  `lib/models/lyric_line.dart`：`hasLyricTimestamps` 与 `parseLyrics` 共用同一正则
  （兼容 1–3 位分钟与行内多标签）。
  **取词顺序**：缓存 → 曲目原生（`SourceManager.fetchLyric`：脚本 `lyric` action →
  any-listen → 内置五平台原生实现，用曲目 raw 的精确平台 ID）→ 跨平台名字搜索回退
  （netease / qq / kugou / kuwo / migu / lrclib 并行，**首个非空即返回**，并经
  时长 ±5s + 歌名/歌手/版本词相似度挑选）。`lxlyric` 的 `<相对ms,时长ms>` 经
  `attachWordTimings` 对齐到主行（`LyricLine.words`），歌词页当前行用
  `KaraokeLyricText` 做词级高亮，桌面歌词 / 通知 / 蓝牙仍按行。
  UI（LyricsWidget / 歌词搜索页 / 歌词选择页）只渲染状态与交互，不再各自构造
  `LyricsService` / 直接写 `LyricsCache` / 拼装解析逻辑；歌词页只消费 `LyricsState`
  （不维护字段镜像，加载标志由 `status` 推导），滚动/跟随数学在
  `lib/widgets/lyrics_scroll_policy.dart`（纯函数，可单测）：自动滚动把「主行文本块
  顶边」锚定在可见区域中线偏上（不按整项高度缩放，长行换行 / 扩展行不影响落点）。
  歌词页用「歌词页」独立开关（`page.translationEnabled` / `page.romaEnabled`）
  只在当前行下方渲染翻译 / 罗马音（随行切换淡出 + 收起；未同步歌词无当前行概念，
  保持逐行），与输出侧（桌面歌词 / 通知 / 蓝牙）的翻译·罗马音开关互不影响，
  共用同一份对齐数据。
- **封面补取**：曲目起播无封面时 `PlaybackObserver` 经注入 resolver
  （`SourceManager.fetchPic`：脚本 `pic` action → 内置原生取图；省流模式不发请求）
  取图，经 `PlaybackFacade.updateTrackArtwork` 原地回写队列曲目（新 `Track` 触发
  封面堆叠换图淡化、主题取色与系统媒体通知封面更新）。
- **Comments**：`CommentsService`（`lib/data/catalog/comments_service.dart`）是评论分页的
  唯一取数入口（single-flight + LRU + TTL 5min，key=`comments:{source}:{songId}:{kind}:{page}`，
  失败不缓存，`invalidateTrack` 供下拉刷新）。取数经 `MusicSource.comments`
  （能力位 `capabilities.comment`：仅内置五平台）→ `SourceManager.fetchComments`
  → `lib/sources/builtin/{wy,tx,kg,kw,mg}_comment.dart`（移植 LX：热门 / 最新、分页、
  表情还原、引用 / 楼中楼归一化）。页面状态在 `CommentsProvider`（热门 / 最新两个 tab
  懒加载 + 分页 + 错误归一化），UI 为 `lib/pages/song_comments_page.dart` +
  `lib/widgets/comment_list_view.dart`；入口：歌曲信息页「评论」行（能力位判定唯一
  来源 `CommentsProvider.supports`，不支持时行内说明；展开态播放器进度排不再放入口）。
- **专辑**：`AlbumService`（`lib/data/catalog/album_service.dart`）是专辑分页的唯一取数
  入口（single-flight + LRU + TTL 10min，key=`album:{source}:{id}:{page}:{limit}`，
  失败不缓存，`invalidateAlbum` 供重试）；取数函数由组合根注入
  `SourceManager.fetchAlbum`（能力位 `capabilities.collection`：仅内置五平台置真，
  LX 脚本 / any-listen / local 为假）→ `lib/sources/builtin/{wy,tx,kg,kw,mg}_album.dart`
  按专辑 id 精确拉取（wy `api/v1/album`、tx `music.musichallAlbum.AlbumSongList` 模块、
  kg `album/song` + `album/info`、kw `r.s stype=albuminfo`、mg `queryAlbumSong` +
  `MIGUM3.0/resource/album`），解析直接产出领域 `Album`（曲目 payload 经 track_mapper
  原样透传）；真实响应快照见 `test/fixtures/albums/`（抓取脚本
  `tool/gen_album_fixtures.mjs`），端点均需真机复验。端口路由：
  `MusicSource.collection(CollectionRef(type: album))` 在能力位为真时转发
  `fetchAlbum`（playlist / artist 仍 unsupported）。UI 为 `lib/pages/album_page.dart`
  （头部元信息 + 播放全部 + 加入列表 + `TrackRow` 分页列表），入口：歌曲信息页
  「专辑」行（payload 专辑 id + 能力位双判定，`platformAlbumId`；否则保持只读）。
- **系统媒体会话**（Android/iOS/macOS/Windows/Linux）：`LocalAudioHandler`
  把服务状态映射为统一模型（`flutter_media_session` 的 `MediaMetadata` /
  `PlaybackState` / `MediaAction`），后端可注入（见 ADR-0010）：
  Android/iOS/macOS/Windows 走 `FlutterMediaSessionBackend`
  （`FlutterMediaSessionPlatform`，不调用会主动请求通知权限的
  `FlutterMediaSession().activate()`），Linux 走 `MprisMediaSessionBackend`
  （`audio_service_mpris` 的 Dart 平台接口，D-Bus 不可用静默降级）。
  封面经 `ArtworkCache.cachedFilePath` 带浏览器 UA + 平台 Referer 落到本地文件后
  传本地地址（Android/iOS/macOS/Linux `file://`、Windows 裸路径；网易 CDN 对
  默认 UA 返回 403），未命中先发远程 URL 兜底；省流模式整体置空封面地址且不下载。
  恢复态（冷启动未起播）下切歌键回落给 `PlaybackProvider`（保存会话立即恢复
  播放）。`POST_NOTIFICATIONS` 不在启动时请求——由
  `lib/services/notification_permission.dart` 在「首次真正播放 / 首次开启歌词
  输出」时弹窗（每会话一次），被永久拒绝时通知·锁屏设置页给系统设置深链；
  媒体会话初始化失败（平台支持但 `initSystemMediaSession` 返回 null）时歌词显示
  页给可见提示。通知动作含自定义的**播放顺序**（循环模式：顺序 / 单曲 / 随机，
  图标与文案随当前模式，App 内改模式双向一致；`MediaAction.custom('lx.playMode')`，
  Android drawable 名沿用 `audio_service_*`，`keep.xml` 防 shrinkResources 删除）；
  系统控制路径（暂停 / 停止 / 切顺序 / seek）**显式 await 会话落盘**
  （`LocalAudioHandler` 的 `attachSessionPersister` + `PlaybackSessionStore.pendingWrite`
  串行化；停止先落盘再清空队列），保证「系统暂停 → 冷启动」能恢复上一首 + 队列 +
  模式 + 进度且不自动起播。
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
  `PlayStatisticsRepository` 读写；聚合全部查询时计算，口径常量唯一来源是
  `PlayStatisticsLimits`（有效播放 = `min(30s, 50%·时长)`，error 事件不计入
  计数/比率）。采集是 `PlayStatisticsService` 纯观察者——组合根把
  `PlaybackProvider` 快照 + position 接进去，**零改动播放内核**；
  真正出声才开事件、暂停不切断、15s 节流落盘、启动收尾遗留事件。
  统计页（`play_statistics_page.dart`）消费 provider 投影：日历热力图（hero，
  全量历史 + 范围高亮）、作息热力图（7×24，随范围过滤）、汇总/指标/榜单
  （Top 曲目可点播）；导出 JSON 面向 AI 消费（全量汇总 + 最近明细、不含 raw）。
  与 `play_history`（最近播放，500 条上限）是两套数据。
- **AI 推歌（Phase 2，可选，默认关闭）**：`lib/services/ai/**` 是唯一数据出口与
  网络层——`TasteProfileBuilder`（聚合画像 + 最近 200 条明细 + 排除清单）、
  `LlmClient`（OpenAI-compatible，请求带 `response_format: json_object`（不支持时
  自动退回），错误归一化 `SourceFailure`，Key 不进 message）、
  `AiRecommendationService`（提示词 → 容错 JSON → 规范化去重 →
  `CatalogService.search` 并行解析，命中无封面时经音源 `artwork()` 补取）。
  `AiDjProvider` 维护两件事：**今日推荐列表**（持久化在
  `AiRecommendationStore`，任何时刻可浏览/播放，「换一批」替换缓存）与
  **推歌会话**（`enabled` 功能开关 + `status` 电台状态：播放全部/点某首才接管队列，
  低水位续推只在当前队列就是 AI 队列时触发；退出队列不关功能）。列表带
  单曲「换一首」「不感兴趣（可撤销）」与反馈面板；缓存有效期
  （`aiDjCacheTtlDays`，默认 1 天）只影响续推是否消费旧列表，不做过期提示，
  「上次更新」只在 AI 页与发现页推荐区展示。发现页 `AiDjCarousel` 用 carousel
  原生槽位展示歌名/歌手（`applyDynamicTextContentTransform: false`），
  功能未启用时整条隐藏；播放页不再有 AI 徽标。
  首次开启隐私确认；定位与边界见 ADR-0002。
- **跨设备数据同步（可选，默认关闭）**：同步歌单 / 收藏 / 音源脚本与配置 /
  跟人走的设置 / 听歌统计 / 播放历史 / 上次播放会话 / AI DJ 与凭证。信任模型是
  **同步口令即信任根**（加入即完全互信，无逐项审批），快照整体加密：根密钥 =
  PBKDF2(口令) 会话内一次派生（按口令缓存），帧密钥 = HKDF(根密钥, 随机帧盐)，
  AES-256-GCM 认证（帧结构保留盐与迭代数，版本 1 帧仍可解密；帧与信任边界见
  ADR-0003）。引擎（`lib/data/sync/sync_engine.dart`）一轮 = 各 `SyncAdapter`
  收集本地视图（按类别廉价指纹缓存：指纹未变不读行）→ `SyncTransport` 拉取
  变化对端（WebDAV 按 `getetag` / 局域网按探测应答的 `snapshotId` 跳过未变
  文件）→ 逐键 LWW 合并（版本三元组
  `(versionPhysical, versionCounter, deviceId)`，删除为墓碑）→ 只把版本变化的
  胜者交给适配器（`sync_known` 登记表：交付成功才登记，空闲轮 0 次 apply）→
  内容未变不推送（与上次成功推送的指纹比对）；版本戳由唯一发号器
  `SyncStampIssuer`（`sync_stamp.dart`，HLC-lite：吸收远端超前戳、同毫秒
  counter 递增、基线持久化 + 重启不倒退）发放，内容时间（playedAt / endedAt /
  savedAt / importedAt / 墓碑删除时间）**不参与胜负判定**（见 ADR-0003 v2 §2）。
  协议自始为 v2（快照里的 `v` 字段用于自描述与将来能力协商）：对端快照直接
  合并，备份只做结构性校验（不是 Molia 备份 / 结构无效才拒绝），都没有按版本号
  的分支。全量合并模型天然幂等，推送裁剪 90 天前墓碑（按真实删除时间）；入站
  推送在 1–2s 窗口内合流成一轮，入站轮只消费收到的快照（不拉取、不推送，防
  两端乒乓与 N 台平方级放大）。一轮的产物是可观察的 `SyncRoundReport`：五态
  结论（`ok / noChanges / noPeers / partial / failed`）+ 每传输明细（含未变跳过
  数）+ 每对端名册 + 本轮变更量；设置页据此呈现结论行、运行状态（近 24 小时
  触发 / 有效传输轮数与流量、当前同步等级 · 网络类型 · 是否省电）、已配对设备
  子页与变更语义日志，失败行给重试入口；同步何时跑完全由调度器声明式决定，
  首屏不提供「立即同步」主操作，也不导出诊断快照。触发
  策略统一在 `SyncScheduler`（`sync_scheduler.dart`）：**活跃**（可见 + 最近
  交互 / 正在播放，变更去抖 4s）/ **空闲**（退避 10→20→40→60 分钟封顶；
  蜂窝下无本地变更不广播、不发 PROPFIND，非蜂窝（Wi-Fi / 以太网 / 桌面）
  唤醒照常探测与拉取）/**后台**（零定时唤醒，退后台尽力推、回前台拉）/
  **省电**（低电量未充电或系统省电模式
  暂停自动，只保留恢复动作的手动触发）；电量经平台通道读取（Android `BatteryChannelHandler` /
  iOS `AppDelegate`），移动数据下默认只同步小类别
  （设置 / 音源 / 凭证 / 歌单与曲目 / 会话），可在
  同步页切换为「暂停自动同步」。传输有两个
  实现、可分别开关：局域网直连（UDP 探测 + 内置 HTTP 快照端点）与用户自备
  WebDAV（`<remoteDir>/<deviceId>.msync` 密文文件，PROPFIND/GET/PUT/MKCOL）。
  局域网在移动端有平台准入：Android 17 / API 37 起必须声明并运行时申请
  `ACCESS_LOCAL_NETWORK`（未授予时状态 `permission_denied`，UI 给授权入口），
  iOS 广播发现需向 Apple 申请 multicast entitlement（未获批时降级手动地址 /
  WebDAV）；发现失败可用手动对端地址簿兜底（单播探测后认领 deviceId 与端点
  端口），本机端点端口持久化避免对端记不住本机。
  资料库 schema（drift，`schemaVersion = 2`）含 `playlists.syncId` / 行级
  `versionPhysical + versionCounter + deviceId` / `sync_tombstones`（版本三列 +
  真实删除时间）/ `sync_known`（已知版本登记）/ `play_events`（syncKey +
  版本列，`originDeviceId` 兼作设备列）；设置同步用「登记哈希」做变化检测，
  不改造散落的 SharedPreferences 写入方。播放历史删除（含清空）传播墓碑，
  「删除 vs 播放」按真实时间判定；上次播放会话按 `savedAt` 内容时间变化取新戳
  （本地停止不回传删除），应用后经
  `PlaybackProvider.reloadRestoredSessionFromStore` 重载恢复态。**完整备份**
  （数据与存储页导出/导入）复用同一 envelope（`exportBackupJson` /
  `importBackupJson`；协议旧版备份拒绝导入），凭证类默认排除。数据变更经
  调度器进入触发链，生命周期回调由 `main.dart` 的 `AppLifecycleListener` 转发；
  同步后的定向重载经 `PrefsSyncAdapter.onApplied` 接线。设置入口
  `settings_page.dart` → `sync_settings_page.dart`。
- **渠道选择**：`DiscoverProvider.channelKey` 是渠道状态的唯一持有者；渠道变化经
  注入的 `onChannelChanged`（组合根）同步搜索源（可搜索渠道才跟随），资料页只
  处理「渠道被停用」的 UI 回退，不再在两个 provider 之间仲裁同步。
- **Mapping**：`track_mapper`（`SourceTrack` ↔ `Track`，payload 同一引用往返）。
- **内置平台**：搜索/发现共用 `BuiltinSearch.transport`
  （`lib/sources/builtin/builtin_transport.dart`）——客户端可注入、统一请求头/超时、
  响应级重试（`retryIf`）与结果缓存（`transport.cached`，single-flight + LRU +
  TTL 5min）；平台适配器只保留 URL 构造与解析，不再各自持有静态 `RequestCache`。
  fetch 路径测试通过注入 `MockClient` 覆盖。取词 / 取图的内置派发（五平台 switch
  + 结果缓存）同样收在同目录 `builtin_lyric_dispatch.dart` /
  `builtin_pic_dispatch.dart`；渠道偏好（音质 / 顺序 / 停用）在
  `lib/sources/source_preferences.dart`，`SourceManager` 同名方法为其委托。
- **内置检索 runner**：`lib/sources/builtin/builtin_search_runner.dart` 是五个平台
  搜索的执行骨架（`runBuiltinSearch`）：重试预算、分页推断与失败归一各写一次；
  平台变体面（请求方式/URL/body、响应级重试判定、业务码判定、列表路径与解析）
  收进 `BuiltinSearchCall`，各平台文件只剩字面量与 parser。结果语义分界：
  **平台返回空** → 正常结果（`tracks` 为空、`failure` 空）；**业务拒绝 / 传输失败**
  → `SourceSearchResult.failed`（`SourceSearchResult.failure`，不抛异常；UI 收口前
  只读 `tracks`）。内置平台「可搜索」的判定唯一来源是
  `SourceManager._isBuiltinSearchable`（channels 候选、能力位与搜索路由共用）。
- **内置歌手 / 歌词检索**：歌手（`builtin/artist_source.dart` + `*_artist.dart`）与
  按歌词搜歌（`builtin/lyric_search.dart` + `*_lyric_search.dart`）与专辑同构——
  平台适配器只留 URL / 签名与 parser，解析直接产出领域模型；失败语义为
  **业务拒绝抛 `SourceFailure`**（`builtinPlatformFailure`，与 `SourceSearchResult.failed`
  的「静默空结果」区分），在 `SourceManager` / data 层边界归一化。
  歌手 id 与曲目 payload 同体系：解析时把 `_artists`（项目内部字段）写进 raw，
  `track_mapper` 填 `Track.artists[].id`，UI 只读领域模型即可跳歌手页。
  平台降级（写进各实现注释）：kg 歌手搜索无分页、tx 歌手歌曲单页、
  mg 歌手详情无简介、kw 歌词搜索为模糊匹配、mg 歌词排序偏翻唱。
- **资料库写入**：`LibraryProvider` 是收藏 / 历史 / 列表写入的唯一入口。收藏唯一
  入口 `toggleFavoriteTrack(Track)`（播放页经它写入，不再直连 `LibraryRepository`）；
  批量操作按 `PlaylistTrack` 规范形状（`PlaylistTrack.fromHistoryEntry` 负责历史转换）；
  「加入列表」流程唯一实现在 `lib/widgets/add_to_library.dart`（收藏页与发现页共用）；
  列表曲目读取经 `playlistTracksView` + `ensurePlaylistTracks`（页面不探测缓存内部）。
- **换源**：`SourceSwapProvider`（`lib/providers/source_swap_provider.dart`）是
  跨音源搜索 + 原位替换的唯一状态机：按种子曲目「歌名 + 歌手」在其它可搜索音源
  并行检索（`CatalogService.search` 复用 5min 缓存；逐源就绪即填充，单源失败进
  `failedSourceKeys` 可重试），载体是统一的「换源」页
  （`lib/pages/source_swap_page.dart`：歌词 / 音频两个 tab，歌词侧为
  `LyricsSourceSearchView`，音频侧为 `SourceSwapView`；入口：歌曲信息页「换源」
  默认音频 tab、歌词页 FAB menu「换歌词」默认歌词 tab、收藏页合集（收藏 / 历史 /
  自建列表）左滑默认音频 tab）点候选即试听（单曲「换源试听」上下文）、
  确认后经 `LibraryProvider.replacePlaylistTrack` / `replaceHistoryEntry` 原位
  替换（仓库事务保 `sortOrder`/`addedAt`/`playedAt`，目标键已存在先确认去重），
  并经 `PlaybackProvider.replaceQueueTrack` 让队列中同 id 曲目跟随换源（新增
  `PlaybackFacade.replaceQueueTrack` 端口；命中当前曲目重新取链从头播放，
  冷启动恢复会话同步替换并落盘）。
  **自动换源**：播放失败同源重试仍失败后，组合根注入的 `AutoSourceSwapService.findMatch`
  用 `lib/services/song_match.dart`（LX `findMusic` 判定的唯一实现，与歌词搜索
  回退共用）**严格匹配**（时长 ±5s、版本词一致）跨源找回并静默替换队列曲目；
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
- **一次快照**：`PlayStatisticsRepository.snapshot(since:)` 并发取回
  `ListeningStatisticsSnapshot`（汇总 / 榜单 / 日历 / 作息热力图 / 来源分布），
  统计页只渲染它（不再分开读 6 个查询）。

### 资料库（library）

`lib/domain/ports/library_store.dart`（UI 面）与 `library_sync_store.dart`
（同步面）是两条 seam：同一个实现类（`lib/data/library_repository.dart`）
兼两者，组合根分别注入。

- **UI 面**：领域意图（历史 / 列表 / 曲目 / 收藏 / 导入）+ 类型化变更事件
  （`LibraryChange`，类型即失效范围）；`sortOrder`、墓碑、保留行名
  `__favorites__` 等存储形状不出实现（收藏是 `PlaylistInfo.isFavorites`）；
- **同步面**：类型化记录出 / 入（`PlaylistSyncRecord` /
  `PlaylistTrackSyncRecord` / `PlayHistorySyncRecord` / `SyncTombstoneRecord`）；
  同步适配器不再逐字段读列名，记录形状（含 JSON 键）由 record 类承担；
- **测试假实现**只实现 UI 面窄 port（不再继承真类）：新方法不会静默走真实 SQL。

### 本地下载（downloads）

`lib/services/download/download_service.dart` 是单曲下载的唯一实现，
组合根（`main.dart`）注入取链 / 取词 / 取图 / 缓存 / 设置与省流上限：

- **目录与位置**：下载根目录按平台解析（`IoDownloadStorage`）——桌面 =
  系统下载目录下 `Molia/`（Linux 读 XDG `XDG_DOWNLOAD_DIR`，回退
  `~/Downloads`；Windows `%USERPROFILE%\Downloads`），iOS = 应用文档目录
  `Molia/`（Files app 可见），Android = 应用支持目录 `downloads/`
  （**公共副本**另经 MediaStore 发布，见下）；设置页可选自定义目录
  （`DownloadSettings.saveDir`，存储层每次解析读取，改设置无需重启）；
  `lyrics/` + `covers/` 子目录与 `cache/audio_cache` 完全隔离——「清理缓存」
  永不触碰下载，「删除下载」是独立动作；`DownloadStorage` 是平台 seam
  （原生 MethodChannel 实现，存储不可用时 `supported=false`，UI 隐藏全部入口）；
- **Android 公共目录发布**（issue #17）：下载完成后把音频 best-effort 拷进
  MediaStore 的 Downloads 集合（`Download/Molia/`，与桌面同构），用户在文件
  管理器 / 其它播放器里可见。**公共副本是发布副本，不参与播放取链**：应用
  目录里的 `filePath` 仍是唯一播放源，`publicUri`（schema v4）只用于删除时
  回收副本；API 29+ `insert + openOutputStream`（应用自己创建的行无需存储
  权限，`IS_PENDING` 防半成品可见），< 29 返回 null 不支持；平台 seam
  `DownloadsPublisher`（`lib/data/downloads/downloads_publisher.dart`：
  MethodChannel `top.stillmisty.molia/downloads`，
  失败 / 通道缺失一律 no-op 只记日志）；发布开关
  `DownloadSettings.publishToPublicDir`（默认开，仅 Android 显示），管理页
  提供「补发布到公共目录」回收旧记录；
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
  （页内「写入中」）。启动清扫中断残留半成品，旧命名（复合曲目 id 时代的
  `{sourceKey}_{sourceKey}:{songId}_*`）文件一次性清理（prefs 版本键）；
  磁盘约定（命名 / 完整判据 / 索引 / 清扫 / 迁移）的唯一实现在
  `lib/services/audio_cache_store.dart`（Audio cache store），`CacheService`
  的同名静态方法是薄委托；缓存文件名写入侧（`SourceTrack.songId`）与读取侧
  （`TrackId.id`）必须同名（回归测试见
  `test/services/track_local_data_service_test.dart`）；
- **落库**：drift `downloads` 表（schema v5，`filePath` 可空——记录可以只含
  歌词或只含封面；`publicUri` 存 Android 公共副本定位；`imported` 标记
  **本地导入**：就地引用用户文件、删除只移行）存原音源曲目键 +
  自包含快照 + 原 raw + 音频路径/音质/大小 + 歌词/封面路径；
  `DownloadsRepository` 负责行 ↔ `DownloadedTrack` 映射；
  半成品 `.part` → 原子改名 → 落库，播放取链只认数据库记录；启动时清扫
  崩溃遗留 `.part`；
- **本地导入**：`DownloadService.importLocalFiles`（收藏页「本地歌曲」合集 →
  「导入本地歌曲」：多选音频文件）**不复制文件**——记录以
  `local:<绝对路径>` 为原音源键（同路径重复导入幂等），`filePath` 指向原文件；
  标签读 `lib/data/downloads/audio_tag_reader.dart`（mp3 ID3v2 / flac Vorbis
  Comment + 时长），其余格式按 `歌手 - 歌名` 文件名兜底。删除导入项只移除
  记录（原文件保留），补发布 / 旧位置迁移 / 孤儿清理都跳过导入项；
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
  `LockCachingAudioSource` 边播边写（`platformSupportsAudioCaching`）；桌面
  media_kit 后端不能走 `StreamAudioSource`，改由 `PlayingTrackCacheWriter`
  起播后后台下载当前曲目字节（`.predl` → 原子改名 → LRU，
  `platformSupportsAudioPrefetch`），重播即命中 `file://`；两者互斥
  （同一文件不双写），切歌 / 停止 / 销毁取消；省流生效时两侧都跳过；
- **离线播放**：封面走本地文件（`AppNetworkImage` / `ArtworkCache` 对
  `file://` 走 `FileImage`）；歌词由组合根的歌词加载器读
  `downloads/lyrics/`（翻译 `.t.lrc` 边车），且 `LyricsService` 对本地
  曲目禁用网络回退（离线播放不触网）；
- **下载通知（Android）**：`DownloadNotificationService`（`dataSync` 前台服务）+ 通道
  `top.stillmisty.molia/download_notifications`，Dart 侧 seam
  `lib/data/downloads/download_notifications*.dart`；进行中显示进度（批量共享
  「N/N」），完成 / 失败 / 取消收尾；API 33+ 未授权通知 → 降级为无通知继续下载；
  开关 `download_notifications`（设备本地键，默认开）。
- **同步过滤**：歌单曲目 / 历史 / 统计 / 播放会话适配器都过滤
  `sourceKey = local` 的条目（含墓碑）——文件是设备本机持久副本，
  同步到其它设备不可播放；
- **设置与管理**：`DownloadSettings`（设备本地键，不登记同步：保存位置 /
  文件名模板 `{artist}`/`{title}`/`{album}` / 标签嵌入开关 /
  Android 公共目录发布开关）；
  下载弹层已并入「本地数据」页（`lib/pages/track_local_data_page.dart`，信息页
  唯一入口）：音质选择（命中缓存的音质标「已缓存」并预选）+ 音频两档状态
  （已下载 / 已缓存 · 可离线使用 / 下载中 / 未下载）+ 动作（下载 / 转存到本地
  文件夹 / 取消 / 分享导出 / 删除下载）+ 歌词/封面各自下载或转存 + 缓存占用
  四项（音频 / 歌词 / 封面 / 取链）逐项清理与全部清理；
  下载管理页（`lib/pages/downloads_manage_page.dart`，设置 › 数据与存储）：
  进行中任务 + 批量下载（当前队列 / 指定歌单，跳过已下载与本地曲目；
  **不做断点续传**：平台直链多为一次性签名地址）+ 文件维护（`.part` 清扫、
  孤儿文件回收、旧位置迁移、Android 补发布公共副本）；已下载列表不再单独成页，
  由收藏页「本地歌曲」合集浏览（下载副本 + 导入的本地文件）；
  省流生效（移动数据 + 已开启）时下载前先确认。

### 设置注册表（settings registry）

`lib/data/settings/`（键声明 / 注册表 / 密钥盒端口）：

- `settings_keys.dart`：登记键总表 —— 键名、默认值、同步类别（跟人走 / 音源 /
  凭证）、存放盒（prefs / secure）的唯一声明处；设备本地键（省流、缓存策略、
  全局字体、桌面歌词悬浮窗、托盘与关闭行为、AI 待处理批次、播放会话、曲库数据…）
  不登记，留在各自模块（只有一位消费者，收进来只增加门房面积）；
- `settings_registry.dart`：`read` / `write` / `clear`（模块面）与 `readRaw` /
  `writeRaw`（同步面，按值类型宽容转换）＋ `bindReload` / `reloadKeys`
  （应用远端值后按变化的键触发模块自绑的重载钩子）；读失败回默认值、写失败
  抛出（由模块决定兜底策略），与迁移前各模块行为一致；
- 键的名字字面量只准出现在 `settings_keys.dart`
  （`test/architecture/settings_keys_test.dart` 扫描 `lib/**` 强制）：
  漏登记 = 显式选择「不同步」，不再是静默漂移。

同步适配器（`PrefsSyncAdapter`）不再自带键表与类型转换：键规格、默认值与读写
都来自注册表；ADR-0003 §6 的「登记哈希」变化检测保留，但适用范围收窄为
未登记的设备本地键。

## 4. 状态与通知策略

| 状态 | 频度 | 承载 | 订阅方式 |
|---|---|---|---|
| 播放进度 | ≤4Hz | `PlaybackProvider.position`（ValueListenable） | `ValueListenableBuilder`（进度条/歌词行） |
| 定时关闭剩余 | 1Hz（仅倒计时且播放中） | `PlaybackProvider.sleepTimer`（ValueListenable） | `ValueListenableBuilder`（歌曲信息页/弹层） |
| 曲目/播放/队列/模式 | 事件级 | facade 快照（值变才发） | `Selector`（不可变对象/record） |
| 搜索结果/分页 | 交互级 | `SearchProvider`（按 `SearchKind` 三会话，分页状态机 `PagedListController` 以状态值发布） | 局部 select |
| 音源列表/顺序 | 事件级 | `SourceRegistry.changes` | 选择器/管理页 |

硬性规则：高频数值禁止进聚合 `notifyListeners`；`select` 禁止返回 `Map`/`List` 引用；
歌词行高亮用 `PositionLineIndexBuilder`（仅跨行重建）；队列列表用稳定引用。

### 播放页封面堆叠（cover deck）

- **模块**：`lib/widgets/player_cover_deck.dart`（组件 + 横滑手势 + 会话的效果宿主）、
  `player_cover_session.dart`（`CoverSwapSession` 状态机 + `CoverSwapHost` 意图接口）、
  `cover_appearance.dart`（`CoverAppearance` 外观 / `CoverFlight` + `CoverFlightLayer`
  飞行 / `CoverCard` 卡片 / `MorphCover` 副本内容 / 封面 URL·key 归一化）、
  `player_cover_swap.dart`（方向判定纯函数）；播放器只提供布局尺寸、顶栏共享飞行
  锚点与主题联动。
- **三槽位模型**：左 = 上一首（播放顺序最近一首 history 末位 → 队列前一位 → 空，
  排除与当前同 id，与后端 `skipToPrevious` 同源）、中 = 当前（拖动/提交等待期间
  为预览目标）、右 = `PlaybackSnapshot.next`；左右槽只要展示了身份即可点击切歌。
- **会话与宿主（时机 / 效果分离）**：会话只决定「什么时候」，宿主（deck State）决定
  「怎么做」——会话经 `CoverSwapHost` 意图接口驱动控制器编排、post-frame 与播放命令
  （`startSettle` / `land` / `releasePreview` / `settleCommit` / `crossfadeCorrection` /
  `hardReset` / `adoptSteadySlots` / `requestSkip` / `notifySwapped` / `armTimeout` …），
  次序不变量（例如「settling 前先把进度钉回起点」）由会话的调用顺序持有。会话是
  `ChangeNotifier`，只在离散迁移通知；拖动跟手的逐帧进度不进会话。
- **会话与阶段**：阶段 `idle → preview（跟手）→ committed（提交等待对账）→ settling
  （即时切歌完成中）` 或 `correcting`（对账不匹配校正）。唯一一根进度控制器由 deck
  State 持有，拖动跟手按位移反解写入，松手从同一进度续走或回弹，不跳；即时切歌由
  motor expressive spatial 弹簧驱动，无固定时长。
- **检测与缓存（唯一写入者）**：deck 把快照喂给 `CoverSwapSession.observe`——切歌检测、
  空闲缓存（左槽身份 / 下一首 / 方向提示）与预览目标全由它派生，调用方不再各刷一半；
  渲染侧只补空闲视觉（中心同 id 换图 250ms、槽位身份 180ms 原位交叉淡化）。空闲刷新
  以宿主的 `progressAnimating`（弹簧尾部也算）门控，快照通知仍按微任务合并同批通知，
  build 期间零写入。
- **窗口时序与常量**：目标槽位旧身份 p∈[0,0.4] 淡出、源槽位新身份
  p∈[0.6,1] 淡入（仅透明度、无位移，避免叠影）；移动卡全程插值（位移 ±0.30 卡宽、
  旋转 ±0.05rad、缩放 0.78↔1.0、透明度 0.85↔1.0）；拖动对账落位后源侧 180ms
  纯淡入；对账校正 220ms；提交后 6 秒（`CoverSwapSession.commitTimeout`）无对账回弹。
- **对账**：提交后等待快照 current 变为会话目标——匹配无缝落位；不匹配
  （随机目标 / 失败恢复 / 列表变化）先让提交过渡落位，再以 220ms 中心原位
  交叉淡化校正到实际曲目，随后按新快照重建槽位回 idle。
- **非视觉路径（可同步断言）**：可见性翻转（TickerMode，两个方向）与隐藏态切歌都走
  会话的 no-animation 落位（`setVisible` / 隐藏态 `observe`：`hardReset` + 身份对齐），
  宿主侧只负责控制器归位与中心身份接管。
- **与共享飞行的关系**：顶栏↔播放页与迷你↔完整飞行只隐藏/复刻中心封面真身
  （`morph.pageCoverKey`）；侧邻位随页面层自身淡入以稳态出现，无独立入场演出。
- **飞行几何与外观**：外观与插值只有一份实现（`cover_appearance.dart`）——三端真身
  （顶栏 r8/图标 22、迷你 r8/图标 24、播放页 r18 + 1px 描边 + 柔和阴影/裁剪 17/图标
  0.35×边长）是 `CoverAppearance` 的命名值，两个飞行是 `CoverFlight` 的薄壳；两条
  代数不变量：描边透明度 = 描边宽度、裁剪半径 = 外圆角 − 描边宽度。飞行副本经
  `CoverFlightLayer` 渲染（`CoverCard` + `MorphCover`），外观按「播放页端进度」
  插值（反向起飞不跳），图标按两端真身尺寸插值。
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

- 壳：`M3EMaterialApp(data: M3EThemeData.fromMaterial(themedData), theme: themedData, ...)`；
  `ThemeProvider` 是唯一主题源（`autoTheming/dynamicColoring` 关闭）。
- 桌面骨架（`lib/app/desktop/**`，仅 linux/windows/macOS；移动骨架逐像素不变）：
  顶栏只留拖动区 + 页面标题 + 设置 + 窗口按钮（无播放控制、无进度线）；左侧
  `M3ENavigationRail` 96⇄240 可展开（窗口宽 <1000 强制折叠、不改记忆值）；底部常驻
  播放条 80dp（左：封面/歌名/收藏 · 中：上一首/播放/下一首 + 可拖波浪进度 + 时间 ·
  右：播放模式/音量/队列）；队列右面板 260–480 可拖（<1200 不渲染）。侧栏展开、队列
  开关与宽度是设备本地偏好（`lib/app/desktop/shell_layout_prefs.dart`）。播放页桌面
  版式 = 左 420 固定 + 右「歌词 / 歌曲信息」分页（`NowPlaying(desktopLayout: true)`，
  队列由右面板承载、无圆点手势）。启动首页由 `NavProvider.effectiveHomeDestination`
  决定（设置 › 通用 › 启动时打开，默认播放页；存储首页被隐藏时按导航顺序兜底且**不改写
  存储**，避免同步回环）。应用内音量（`PlaybackProvider.volume/muted`，设备本地持久化）
  经 `PlaybackFacade.setVolume` 落到 just_audio（桌面 media_kit 同一播放器）。
- 取色模型（唯一优先级，见 ADR-0001）：**基础配色**（壁纸 / 自定义，单选）+
  **封面覆盖**（当前曲目已有封面取色结果时用封面 seed 覆盖基础配色，包括
  盖过莫奈；启动恢复态在首帧前用本地缓存预解析；无封面回退）+
  **纯黑**（深色下覆盖 surface 系列，与来源正交可叠加）。
  解析：`封面 > 壁纸（可用时）> 自定义` → `applyPureBlackScheme`。
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
- 组件：UI 全面使用 `M3E*`；基础件（Scaffold/Text/Icon/Theme 等）来自 `material_ui`
  （M3E 必需依赖，不要试图移除）；禁止 import `package:flutter/material.dart`，
  组件 import 用 `package:material_3_expressive/material_3_expressive.dart`。
- 动效：**spatial（位置/尺寸/形状/缩放）走 motor 弹簧**——token 取
  `M3EMotion.*` / `MaterialSpringMotion.*`，落定统一 `snapToEnd`；
  **effects（透明度/颜色/文本）保持时长+曲线**，与 spatial 同帧耦合的透明度
  从同一份弹簧进度派生并截断 0..1（effects 不过冲）。共享元素飞行（顶栏⇄播放页）
  用 `aospSpatial` 无过冲弹簧并在落定帧零速度交接；不要再用
  `AnimationController` + `Curves`/`SpringSimulation` 手搓 spatial 运动
  （交互细节见 `docs/pitfalls.md` #21）。
- 设置页：首屏 5 个语义分区（外观 / 播放 / 歌词与展示 / 内容与来源 / 通用与数据），
  分组标题 + 分段卡片行：行表面统一走共享的 `lib/widgets/card_list_surface.dart`
  （`CardListSurface`：静止内 4dp / 首末外侧 16dp、hover 12dp、press 16dp，
  expressive spatial 形状弹簧；`TrackRow`、设置行、AI 推荐卡同一套形状语言），
  行间 `cardList.gap`、位置由 `SettingsSectionCard` 下发（`SettingsRowPosition`），
  排版走 `M3ETypeScale`、不写死字号字重；统一行组件在
  `lib/widgets/settings/settings_tiles.dart`（Nav / Switch / Info / Value /
  Choice / Dropdown / Slider / ColorValue），按值类型选型：bool → Switch、
  2–5 项短枚举 → Choice（行内分段，显式宽度，防 `M3ESegmentedButton` 零宽溢出；
  短标签行可配逐项图标——选中段的对勾替换图标，M3E 选中形态；长标签行
  （Sequential / Single repeat）保持纯文字分段，图标或勾都会挤断文案）、
  ≥5 项或长文案 → Dropdown（必设 `fieldStyle.hintText`）、区间数值 → Slider、
  大范围绝对量（缓存上限）→ Value + 输入弹层（带常用预设）；
  子页（音源 / 歌词显示〔二级：歌词页 / 歌词输出 / 桌面歌词 / 通知·锁屏 / 蓝牙〕/
  AI 推歌 / 通用 / 数据与存储 / 缓存 / 统计）经 `SettingsPage`
  的内部 Navigator 在同一弹层内 push（`openSettingsSubPage`）；省流模式不单开
  子页，开关与生效子项并回首屏「播放」分区。音源管理页（`sources_page.dart`）
  与 any-listen 页同样使用这套设置行组件与分段卡片行距。系统返回先退子页、
  再关弹层：底部弹层由 `showAdaptiveModalPage(onDismissRequest:)` guard 读取
  内部 Navigator 的 `canPop()`（M3E 弹层宿主会给层内所有 PopScope 回调发 didPop=false
  并请求关闭，必须由 guard 挡下）；对话框 / 独立挂载由 `NavigatorPopHandler` 承接。
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
  「无预览」的普通返回，故依赖下限 1.1.7（原因见 `pubspec.yaml` 注释）。本仓库大屏的
  侧边弹层（`showGeneralDialog`）与居中对话框（`showDialog`）不是 M3E 组件、不参与
  页面过渡、无预览（侧边弹层的手势支持待补）。嵌套 Navigator（设置弹层内层）由
  `SettingsPage._SettingsPageTransitionsBuilder` 做**手势归属**判定：内层 Android
  过渡保持 fade-forwards 并附一个预测返回 detector，只在
  `内层路由 isCurrent && popGestureEnabled && 内层 Navigator 还能 pop &&
  弹层路由仍是顶层` 时接管。框架会把一次手势派发给**所有**返回 true 的观察者，
  不做归属判定就会和内层子页 / 最上层 dialog 各退一级。归属结果经
  `SettingsSheetBackCoordinator` 传给弹层的动态 `M3EBottomSheetTheme`：
  - 子页手势：弹层 `predictiveBackShrinkX/Y` 归 0，只显示与 push 一致的
    FadeForwards 页面退场；提交只退子页，弹层保留（guard 读 coordinator 返回 false）。
  - 首屏手势：弹层正常收缩，提交关闭设置。
  护栏见 `test/settings_page_test.dart` 的「子页预测返回由页面接管」「根导航器上方
  dialog」两组用例。
- 图标：统一圆角风格 `Icons.*_rounded`（不用 `Icons.adaptive.*`，不混 `_outlined`/基础实心）；
  唯一例外 `library_music_outlined`（资料库未选中半对；音符图标已改用 `MoliaMark` 组件）。
  `test/architecture/icon_usage_test.dart` 扫描强制。**同一按钮的状态图标切换**统一走
  `lib/widgets/icon_swap.dart::IconSwap`（150ms emphasized 交叉淡入 + 0.85→1 轻微缩放、
  减弱动效跳变），不要在调用点裸写 `AnimatedSwitcher`；底部导航 `icon↔selectedIcon`
  由包内 `M3ENavIconScale` 负责，不要再叠。
- 弹层观感差异（M3E 统一 inverseSurface Snackbar、无红底错误色、Dialog/BottomSheet 圆角与
  spring 入场）属预期，不是 bug。
- 播放页操作按作用对象分三域（见 ADR-0007）：**歌词域**（会话 / 来源 / 展示 / 导出）
  在歌词页，操作收敛为底部左侧 `M3EFabMenu`（换歌词 / 复制模式 / 歌词选择·海报 /
  居中跟随；无歌词时 = 换歌词 + 歌词显示设置；无曲目隐藏）；**曲目域**
  （身份 / 渠道 / 音质 / 本地数据 / 评论）在歌曲信息页，段落顺序 =
  操作（评论 / 定时关闭 / 换源）→ 本地数据（两档状态 / 下载转存 / 缓存清理）→
  信息（音质 / 可用音质 / 专辑 / 来源 / 歌词来源）；**播放域**（模式 / 收藏 /
  定时）在播放器进度排 + 信息页。
  曲目级操作的打开编排（能力位、守卫、换源页 tab）唯一实现在
  `lib/widgets/track_actions.dart`；单曲本地数据在
  `lib/pages/track_local_data_page.dart`（读取唯走 `TrackLocalDataService`，
  两档词表见 ADR-0008），缓存内容变更经 `CacheService.revision`、下载记录经
  `DownloadService` 通知跨页刷新。
- 列表行统一走 `lib/widgets/track_row.dart`（队列/收藏/历史/本地歌曲/发现/搜索结果共用）：形状按 M3E 列表规范
  （静止内 4dp、首末外侧 16dp；hover 12dp；press/选中 16dp），带 expressive spatial 弹簧
  morph；分段列表用 `cardList.gap`（2dp）行距、`itemExtent = TrackRow.extent + gap`，
  列表一律懒构建（发现详情滚到底自动加载下一页）。不要改回 `M3EListItem`（原因见 pitfalls #20）。
  收藏页四个合集共用一份列表脚手架 `lib/widgets/collection_track_list.dart`
  （顺序列表 / 重排模式、空态与搜索空态、左滑动作形状），滚动位置簿记在
  `lib/widgets/collection_scroll_bookkeeping.dart`（调度器可注入，脱离 widget 树可单测），
  页内过滤 / 排序口径在 `lib/utils/collection_row_query.dart`。
- 曲目行尾的 ⋮ 菜单统一走 `lib/widgets/track_actions_menu.dart`（发现详情 / 搜索结果 /
  AI 推歌共用）：锚点固定 standard 图标按钮 + tooltip，条目一律「leading 图标 + 文案」，
  收藏这类开关态用图标 + 文案表达（选中即关菜单，不留勾选态）。行本体（收藏 / 加入列表
  两条动作 + 领域接线）见 `lib/widgets/track_menu_tile.dart`，发现详情与搜索结果共用，
  领域状态由调用方 `select` 后传入；收藏域的行适配（歌手页 / 专辑页 / 收藏页 / 搜索行）
  统一走 `lib/widgets/favorite_track_tile.dart`。
- 按钮选型（按作用对象与意图，已按 M3E 实测校正）：
  - 同一批对象的 2–3 个平级动作 → `M3EButtonGroup`（`standard` 间距；命令式动作
    组级统一 `tonal`，把 `selectedIndex` 恒留空、回调里直接分发，避免留下选中态）。
    图标 + 文案是常态；只给图标（如合集弹层标题行的新建 / 导入）或只给文案都可，
    icon-only 动作按方形静止宽渲染（sm 40×40），语义与悬浮提示走
    `tooltip` + `semanticLabel`——纯图标动作需要中性色时用 `style: text` +
    组级 `decoration.foregroundColor`（`material_3_expressive ≥ 1.1.8`）；
    **例外：桌面顶栏**（设置 / 最小化 / 最大化 / 关闭）按用户要求不做悬浮
    提示（一排窗口按钮弹提示反而吵），只留 `semanticLabel` 保无障碍；
  - 「主操作 + 变体 / 次要出口」→ `M3ESplitButton`（播放全部 ▾ 随机播放全部·加入列表、
    下载并安装 ▾ 打开发布页、复制 ▾ 复制全部）；纯文本样式不支持（包内断言
    `style != text`）；「随机播放全部」先 `setPlayMode(shuffle)` 再装载队列、
    起点在可见列表内随机（与收藏页同一约定）；
  - 组内动作没有 key，且组会构建一份不可见测量副本：测试用
    `find.byIcon(...).hitTestable()`（或自定义 finder）定位真实动作；
  - 对话框 action 区保持「text 取消 + filled 确认」两颗独立按钮：弹窗宽度放不下
    带图标的分组，且主次层级要保住；
  - 紧凑位置（行内重试、状态卡内取消）用 `M3EIconButton`（语义交给 tooltip）；
    纯图标按钮保留稳定 key，测试按 key 定位。
- 触感：全应用唯一入口 `lib/services/haptics.dart`（设置 › 通用与数据 › 通用 ›
  震动反馈，默认开，设备本地键）；底栏重复点击的轻震由壳层给一次、页面不重复给
  （原「壳层不给触感」的口径已反转）。
- 已知保留（无法等价替换）：带 `bottom:` 槽的 AppBar（2 处）、`_showCenterDialog`、
  `ScaffoldMessenger` 兼容代码。

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
- 真机验证：Android 17 通知/耳机键、iOS 15+ 后台播放；歌词显示的模拟器交互与通知栏验证、
  A2DP 车载字段映射（见 `docs/lyrics_display.md` §9）；
- 桌面歌词平台输出等 Flutter windowing stable（同上 §11）；M3E 组件目视复核（弹层观感/间距）；
- 发布前：release 体积与签名检查。
