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
   应用壳（MyThemedApp / 导航栏 / 顶栏 / 迷你条）与全局 key 在
   `lib/app/app_shell.dart`，测试可直接挂载；
5. UI 禁止 import `lib/sources/**`（Wave 7 后白名单已清空，新增违规必须修复）。

## 2. 领域层

- **模型**（不可变 + 可靠 `==`）：
  - `Track` / `TrackId(sourceKey,id)` / `Artist` / `Artwork` / `AudioQuality`；
    `Track.payload` 承载源脚本原始对象（原 `SourceTrack.raw`），**只在 data/sources 传递、必须原样回传**；
  - `PlaybackSnapshot` / `BackendSnapshot` / `PlaybackRequest` / `PlaybackContext`；
    `PlaybackSnapshot.next` 是后端按当前模式解析出的下一首（shuffle 单曲内稳定），
    `history` 是实际播放顺序（最近在后），`upcoming` 是队列顺序（非播放顺序）；
  - `SearchQuery` / `SearchResult<T>`；`SourceFailure(kind/l10nKey/retryable)`；
  - `SourceDescriptor` / `SourceCapabilities`。
- **端口**：`MusicSource`（search/resolve/lyrics/artwork/collection）、`SourceRegistry`
  （descriptors/byKey/forTrack/setOrder/changes）、`PlaybackBackend`（state ValueListenable +
  load/play/pause/seek/next/previous/setMode/stop）、`PlaybackFacade`（snapshot + position +
  控制方法）、`UiMessenger`（showMessage/showFailure）、`StateListenable<T>`。

## 3. 数据/适配层

- **Catalog**：`SourceManagerMusicSource` 包装 `SourceManager` 按 key 分发；
  `SourceRegistryImpl` 构建 `SourceDescriptor`（排序转发 `lx_source_order`）；
  `CatalogService` 提供 `search`（缓存 5min）与 `resolve`（缓存 10min，key=`url:{source}:{md5(canonical payload)}:{quality}`，
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
  `LyricsService` / 直接写 `LyricsCache` / 拼装解析逻辑；歌词页用「歌词页」独立开关
  （`page.translationEnabled` / `page.romaEnabled`）在每行下方渲染翻译 / 罗马音，
  与输出侧（桌面歌词 / 通知 / 蓝牙）的翻译·罗马音开关互不影响，共用同一份对齐数据。
- **封面补取**：曲目起播无封面时 `PlaybackProvider` 经注入 resolver
  （`SourceManager.fetchPic`：脚本 `pic` action → 内置原生取图；省流模式不发请求）
  取图，经 `PlaybackFacade.updateTrackArtwork` 原地回写队列曲目（新 `Track` 触发
  封面堆叠换图淡化、主题取色与系统媒体通知封面更新）。
- **系统媒体会话**（Android/iOS/macOS）：`LocalAudioHandler` 把服务状态映射为
  `MediaItem`/`PlaybackState`；通知/锁屏封面经 `MediaItem.artHeaders` 统一带
  浏览器 UA + 平台 Referer，并复用 `ArtworkCache` 的共享 CacheManager
  （audio_service 在 Dart 侧下载封面，网易 CDN 对默认 UA 返回 403）；
  省流模式整体置空封面地址。
- **Cache**：`RequestCache`（single-flight + LRU 64 + TTL + 可注入时钟）。
- **省流**：`DataSaverService`（services 层，默认关闭）持有「开启 + 音质上限 +
  封面省流」策略与 connectivity_plus 网络探测；仅在移动数据（`active`）时生效：
  - 取链：main.dart 的 resolver 以 `effectiveQuality(preferred)` 套 `capQualityFor`
    压低音质（缓存键含音质，切换网络自然重解析）；
  - 封面：`ArtworkCache.networkImageBlocked` 网关让 `ArtworkCacheManager.getFileStream`
    只读本地缓存（未命中抛 `ArtworkNetworkBlockedException` → 占位图标），
    并拦截播放预加载、audio_service 通知封面与桌面小组件封面地址；取色链路同样
    只读缓存——命中则照常取色，未命中保持现色（`ArtworkPaletteService` 吞掉异常）；
  - 探测失败保守按「未生效」；Android 回前台时由壳层 `refreshConnectivity()` 补一次检测。
- **失败归一化**：`SourceFailure` 是跨层错误契约（`lib/domain/models/failure.dart`）。
  sources 适配器在边界转换一次：any-listen 经 `AnyListenException.toSourceFailure()`
  （保留 unauthorized / connectionFailed 语义，不再退化为 unknown）；内置传输错误
  由 `SourceFailure.from` 按类型名识别 `BuiltinHttpException`。providers/UI 只消费
  kind / l10nKey / retryable。
- **听歌统计**：`play_events`（一次播放尝试一行，v4 迁移）由
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
  首次开启隐私确认、Web 隐藏；定位与边界见 ADR-0002。
- **跨设备数据同步（可选，默认关闭）**：同步歌单 / 收藏 / 音源脚本与配置 /
  跟人走的设置 / 听歌统计 / 播放历史 / 上次播放会话 / AI DJ 与凭证。信任模型是
  **同步口令即信任根**（加入即完全互信，无逐项审批），快照以 PBKDF2 +
  AES-256-GCM 整体加密（帧与信任边界见 ADR-0003）。引擎
  （`lib/data/sync/sync_engine.dart`）一轮 = 各 `SyncAdapter` 收集本地视图 →
  `SyncTransport` 拉取远端快照 → 逐键 LWW 合并（`(updatedAt, updatedBy)`，
  删除为墓碑）→ 适配器写回 → 推送合并视图；全量合并模型天然幂等，推送裁剪
  90 天前墓碑；入站推送触发的轮次不再推送（防两端乒乓）。传输有两个实现、
  可分别开关：局域网直连（UDP 探测 + 内置 HTTP 快照端点）与用户自备 WebDAV
  （`<remoteDir>/<deviceId>.msync` 密文文件，PROPFIND/GET/PUT/MKCOL）。
  资料库 schema v5 引入 `playlists.syncId` / 行级 `updatedAt+updatedBy` /
  `sync_tombstones` / `play_events.syncKey`；设置同步用「登记哈希」做变化检测，
  不改造散落的 SharedPreferences 写入方。播放历史删除（含清空）传播墓碑；
  上次播放会话按 `savedAt` 时间戳单向推进（本地停止不回传删除），应用后经
  `PlaybackProvider.reloadRestoredSessionFromStore` 重载恢复态。**完整备份**
  （数据与存储页导出/导入）复用同一 envelope（`exportBackupJson` /
  `importBackupJson`），凭证类默认排除。组合根在启动 / 数据变更去抖 /
  每 10 分钟 / 回前台触发；同步后的定向重载经 `PrefsSyncAdapter.onApplied`
  接线。设置入口 `settings_page.dart` → `sync_settings_page.dart`，Web 隐藏。
- **渠道选择**：`DiscoverProvider.channelKey` 是渠道状态的唯一持有者；渠道变化经
  注入的 `onChannelChanged`（组合根）同步搜索源（可搜索渠道才跟随），资料页只
  处理「渠道被停用」的 UI 回退，不再在两个 provider 之间仲裁同步。
- **Mapping**：`track_mapper`（`SourceTrack` ↔ `Track`，payload 同一引用往返）。
- **内置平台**：搜索/发现共用 `BuiltinSearch.transport`
  （`lib/sources/builtin/builtin_transport.dart`）——客户端可注入、统一请求头/超时、
  响应级重试（`retryIf`）与结果缓存（`transport.cached`，single-flight + LRU +
  TTL 5min）；平台适配器只保留 URL 构造与解析，不再各自持有静态 `RequestCache`。
  fetch 路径测试通过注入 `MockClient` 覆盖。
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
  `LyricsSourceSearchView`，音频侧为 `SourceSwapView`；入口：播放页歌词快捷操作栏
  默认歌词 tab、收藏页三类合集左滑默认音频 tab）点候选即试听（单曲「换源试听」上下文）、
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

### 设置注册表（settings registry）

`lib/data/settings/`（键声明 / 注册表 / 密钥盒端口）：

- `settings_keys.dart`：登记键总表 —— 键名、默认值、同步类别（跟人走 / 音源 /
  凭证）、存放盒（prefs / secure）的唯一声明处；设备本地键（省流、缓存策略、
  全局字体、桌面歌词悬浮窗、AI 待处理批次、播放会话、曲库数据…）不登记，
  留在各自模块（只有一位消费者，收进来只增加门房面积）；
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
| 曲目/播放/队列/模式 | 事件级 | facade 快照（值变才发） | `Selector`（不可变对象/record） |
| 搜索结果/分页 | 交互级 | `SearchProvider`（分页状态机 `PagedListController`） | 局部 select |
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

- `LxEngineSupervisor` 状态机：`stopped → starting → ready`；invoke 超时/isolate 退出 →
  `restarting`（退避 0.5s/2s/8s，重放同一脚本），连续 3 次 → `failed`；重启期间请求等待
  ready（10s 上限）；重启成功刷新 `activeSources`。
- 在线更新：脚本 meta `@updateUrl` / 运行时 `updateAlert` → `checkScriptUpdate`（版本 +
  内容 hash）→ `applyScriptUpdate`（原地替换，激活中自动重放）；下载 10s 超时 / 1MB 上限 /
  HTML 识别。
- any-listen：配置页 + `AnyListenSource` 适配器骨架（当前 HTTP 占位端点；官方为 WS IPC）。

## 6. M3E 设计语言

- 壳：`M3EMaterialApp(data: M3EThemeData.fromMaterial(themedData), theme: themedData, ...)`；
  `ThemeProvider` 是唯一主题源（`autoTheming/dynamicColoring` 关闭）。
- 取色模型（唯一优先级，见 ADR-0001）：**基础配色**（壁纸 / 自定义，单选）+
  **封面覆盖**（播放有封面的曲目时用封面 seed 覆盖基础配色，包括盖过莫奈；
  无封面回退）+ **纯黑**（深色下覆盖 surface 系列，与来源正交可叠加）。
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
- 设置页：首屏按功能分区（外观 / 播放 / 歌词 / 内容 / 通用 / 数据与存储），分组标题 +
  分段卡片行：行表面统一走共享的 `lib/widgets/card_list_surface.dart`
  （`CardListSurface`：静止内 4dp / 首末外侧 16dp、hover 12dp、press 16dp，
  expressive spatial 形状弹簧；`TrackRow`、设置行、AI 推荐卡同一套形状语言），
  行间 `cardList.gap`、位置由 `SettingsSectionCard` 下发（`SettingsRowPosition`），
  排版走 `M3ETypeScale`、不写死字号字重；统一行组件在
  `lib/widgets/settings/settings_tiles.dart`（`Nav` / `Switch` / `Info` / `Value` 四种）；
  子页（音源 / 歌词显示 / AI 推歌 / 通用 / 数据与存储 / 缓存 / 统计）经 `SettingsPage`
  的内部 Navigator 在同一弹层内 push（`openSettingsSubPage`）。系统返回先退子页、
  再关弹层：底部弹层由 `showAdaptiveModalPage(onDismissRequest:)` guard 读取
  `SettingsPage.subPageOpen`（M3E 弹层宿主会给层内所有 PopScope 回调发 didPop=false
  并请求关闭，必须由 guard 挡下）；对话框 / 独立挂载由 `NavigatorPopHandler` 承接。
  弹层内 dialog 挂在 root navigator（`M3EDialog.show` 语义），关闭须显式
  `rootNavigator: true`。
- 图标：统一圆角风格 `Icons.*_rounded`（不用 `Icons.adaptive.*`，不混 `_outlined`/基础实心）；
  唯一例外 `library_music_outlined`（资料库未选中半对；音符图标已改用 `MoliaMark` 组件）。
  `test/architecture/icon_usage_test.dart` 扫描强制。
- 弹层观感差异（M3E 统一 inverseSurface Snackbar、无红底错误色、Dialog/BottomSheet 圆角与
  spring 入场）属预期，不是 bug。
- 列表行统一走 `lib/widgets/track_row.dart`（队列/收藏/历史/发现共用）：形状按 M3E 列表规范
  （静止内 4dp、首末外侧 16dp；hover 12dp；press/选中 16dp），带 expressive spatial 弹簧
  morph；分段列表用 `cardList.gap`（2dp）行距、`itemExtent = TrackRow.extent + gap`，
  列表一律懒构建（发现详情滚到底自动加载下一页）。不要改回 `M3EListItem`（原因见 pitfalls #20）。
- 已知保留（无法等价替换）：带 `bottom:` 槽的 AppBar（2 处）、`_showCenterDialog`、
  `ScaffoldMessenger` 兼容代码。

## 7. 验证与性能

```bash
flutter analyze --no-pub                 # 0 error / 0 warning
flutter test --no-pub                    # 含 domain/catalog/playback/layering/supervisor/update
tool/agent/test.sh linux                 # 集成测试 3/3；桌面看门狗自动退出；无 DISPLAY 自动 xvfb-run
tool/agent/test.sh android               # 同一份集成测试跑模拟器（播放用例跳过，跑完自动卸载）
flutter build apk --debug
flutter build apk --release --split-per-abi --split-debug-info=build/symbols --obfuscate \
  --extra-gen-snapshot-options=--strip   # 发布体积（APK 压缩打包见 android/app/build.gradle：~50%↓）
flutter build web --release
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
