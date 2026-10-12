# GLOSSARY

本仓库的领域词汇表：架构评审、模块命名与代码注释以此为共享语言。新增术语在落地时登记，避免同义多词。

## 曲目与平台对象

- **Raw track（平台 raw 曲目）** — `SourceTrack.raw` / `Track.payload` 承载的平台原始对象（LX `musicInfo` 约定：songmid / hash / copyrightId / qualitys ...）。取链 / 歌词 / 封面请求必须原样回传；只允许「只增不删」地补齐规范 id 字段。
- **Raw track module（raw 约定模块）** — `lib/sources/raw_track.dart`：平台 raw 的 id 取键（`rawIdOf` / `platformRawIdOf`）、规范字段补齐（`withCanonicalId`）与音质解析（`qualitiesFromRaw`）的唯一实现。`SourceTrack.id`、`TrackId`、收藏 / 列表 `songId`、`.lxmc` 导入与发现曲目映射共用它。
- **Canonical id field（规范 id 字段）** — 各平台取链脚本读取的 id 键：wy / tx / kw → `songmid`，kg → `hash`，mg → `copyrightId`。`.lxmc` 导入的 raw 缺少该字段时由 raw track module 补齐。
- **Platform id（平台 id）** — 不带平台前缀的单曲标识；[`SourceTrack.id`] 为其加上 `sourceKey:` 前缀。`rawIdOf`（通用优先级）与 `platformRawIdOf`（`.lxmc` 导出的平台优先顺序）是它的两个取键入口。
- **Builtin transport（内置传输模块）** — `lib/sources/builtin/builtin_transport.dart`：五个平台搜索/发现共用的 HTTP 入口（客户端可注入、统一请求头/超时、响应级重试 `retryIf`、JSON 解码与 `cached` 结果缓存）。`BuiltinSearch.transport` 是唯一实例，测试注入 `MockClient` 即可覆盖 fetch 路径；重试预算统一为 `BuiltinTransport.defaultRetries`，结果缓存统一为 `defaultCacheTtl`（5 分钟，single-flight + LRU + TTL），发现适配器不再各自持有静态 `RequestCache`。
- **Builtin search runner（内置检索 runner）** — `lib/sources/builtin/builtin_search_runner.dart`：五个平台搜索的执行骨架（`runBuiltinSearch`）与策略的唯一实现——重试预算、分页推断、失败归一；平台变体面（请求方式/URL/body、响应级重试判定、业务码判定、列表路径与解析）收进 `BuiltinSearchCall`，各平台文件只剩字面量与 parser。结果语义分界：**平台返回空** = 正常结果（tracks 空、failure 空）；**业务拒绝 / 传输失败** = `SourceSearchResult.failed`（`SourceSearchResult.failure`，不抛异常，UI 收口前只读 tracks）。内置平台「可搜索」判定唯一来源：`SourceManager._isBuiltinSearchable`（channels 候选 / 能力位 / 搜索路由共用）。

## 错误模型

- **Failure boundary（失败归一化边界）** — `lib/domain/models/failure.dart` 的
  `SourceFailure` 是跨层错误契约：sources 适配器在边界把结构化异常转换一次
  （any-listen：`AnyListenException.toSourceFailure()` 保留 unauthorized 等语义；
  内置传输：`SourceFailure.from` 按类型名识别 `BuiltinHttpException`），
  providers/UI 只消费 kind / l10nKey / retryable，不再逐层重包装。

## 播放

- **Playback snapshot（播放快照）** — `lib/domain/models/playback.dart`：UI 播放状态的唯一形状
  （`current/next/upcoming/history/context/mode/isPlaying/...`）。`PlaybackProvider.snapshot`
  是其唯一出口：真实播放来自 facade，冷启动恢复态由 `PlaybackSession` 构造覆盖快照；
  历史兼容 map 形状已删除。
- **Played order（播放顺序）** — `lib/playback/playback_order.dart`：实际播放过的队列下标栈
  （最近在后、上限 100、`popPrevious` 供上一首消费）。驱动 `PlaybackSnapshot.history` 与
  `previous` 语义；与队列顺序 `upcoming` 是两回事。
- **Resolved next（下一首解析）** — `PlaybackSnapshot.next`：后端按当前模式解析的下一首
  （shuffle 在单曲内稳定，切歌/切模式重抽）；`upcoming` 只用于队列面板展示。

## 播放页封面（cover deck）

- **Cover deck（封面堆叠）** — `lib/widgets/player_cover_deck.dart`：播放页封面区
  （三槽位渲染、横滑手势、会话的效果宿主）的唯一实现；播放器只提供布局尺寸、
  顶栏共享飞行锚点与主题联动。会话状态机在 `player_cover_session.dart`，方向判定
  纯函数在 `player_cover_swap.dart`，卡片外观与飞行在 `cover_appearance.dart`。
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
  它的薄壳。锚点几何读取唯一实现 `player_morph.dart::anchorRectOf(key,
  {container})`（容器为空 = 全局坐标；含祖先缩放的两角映射）。
- **Cover slot（封面槽位）** — 堆叠的三个位置：左 = 上一首（播放顺序最近一首
  history 末位 → 队列前一位 → 空，排除与当前同 id，与后端 `skipToPrevious` 同源）、
  中 = 当前（拖动/提交等待期间为预览目标）、右 = `PlaybackSnapshot.next`；
  左右槽只要展示了身份即可点击切歌，为空时不渲染卡片。
- **Swap session（切歌会话）** — `CoverSwapSession`：一次拖动/切歌从开始到落位的
  唯一状态机（起止身份/方向/旧邻位/阶段/方向提示/6 秒兜底），只决定「什么时候」；
  唯一快照入口 `observe`（切歌检测、空闲缓存与预览目标都从它派生，调用方不再各刷
  一半）；只在离散迁移通知（`ChangeNotifier`），跟手逐帧进度不进会话。
- **Cover swap host（切歌宿主）** — `CoverSwapHost`（实现：deck State）：会话的
  效果面意图接口，决定「怎么做」——控制器编排、post-frame 调度、播放命令与父级
  联动（`startSettle` / `land` / `settleCommit` / `crossfadeCorrection` / `hardReset`
  / `adoptSteadySlots` / `requestSkip` / `notifySwapped` / `armTimeout` …）。
  测试用记录型假宿主（`test/player_cover_session_test.dart`），会话时机因此可脱离
  widget 树断言。
- **Swap phase（会话阶段）** — `idle`（稳态）→ `preview`（拖动跟手）→
  `committed`（提交等待对账）→ `settling`（即时切歌完成中）/ `correcting`
  （对账不匹配校正）；提交等待与校正期间忽略新手势。
- **Reconcile（对账）** — 提交后等待快照 current 变为会话目标：匹配无缝落位；
  不匹配（随机目标 / 失败恢复 / 列表变化）走 `correcting`（220ms 中心原位交叉
  淡化校正到实际曲目）；`CoverSwapSession.commitTimeout`（6 秒）无对账回弹。
- **Windowed crossfade（窗口化交叉淡化）** — 切歌进度窗口内的纯透明度交叉：
  目标槽位旧身份 p∈[0,0.4] 淡出、源槽位新身份 p∈[0.6,1] 淡入（无位移/叠影），
  移动卡全程插值；空闲期身份变化另有 180ms 原位交叉淡化。

## 色彩系统

- **Color source model（取色模型）** — 全局主题的解析规则（ADR-0001）：
  **基础配色**（`ColorBaseSource`：壁纸 / 自定义，单选）+ **封面覆盖**
  （`follow_artwork_enabled`：有封面时用封面色盖过基础配色，无封面回退）+
  **纯黑**（深色 surface 覆盖，正交可叠加）。解析唯一：`封面 > 壁纸 > 自定义`。
- **Scheme factory（方案工厂）** — `lib/theme/scheme_builder.dart::buildColorScheme`：
  全 App 唯一的 ColorScheme 派生入口（seed + 亮度 → 方案），禁止各处自行
  `ColorScheme.fromSeed`；`applyPureBlackScheme` 同文件（纯黑覆盖）。
- **Artwork palette（封面色板）** — `lib/services/artwork_palette_service.dart`：
  按封面 URL 提取 seed 并派生双亮度方案的唯一入口（LRU + 并发合并 + 省流安全），
  由组合根监听播放快照触发。任何模块不得二次提取封面像素。
- **Surface color source（消费面取色来源）** — 桌面歌词 / 海报各自的
  「跟随应用主题 / 跟随封面（/ 自定义色）」选择；经 `resolveSurfaceScheme`
  解析，封面方案缺失回退应用主题。

## 歌词

- **Lyrics session module（歌词会话模块）** — `lib/providers/lyrics_provider.dart`：
  取词 → 缓存 → 解析（统一时间契约）→ 预取的唯一实现；对外只暴露 `LyricsState`
  （idle/loading/ready/empty + isSynced + providerName）与 `load/preload/saveManual`。
  UI 只渲染状态，不再各自构造 `LyricsService` 或直接写 `LyricsCache`。
- **Lyric timing contract（歌词时间契约）** — `lib/models/lyric_line.dart`：
  `hasLyricTimestamps` 与 `parseLyrics` 共用同一正则（兼容 1–3 位分钟、`.`/`:` 毫秒
  分隔与行内多标签）；不再允许「检测用一个正则、解析用另一个」的漂移。
- **Track-native lyric/pic（曲目原生取词 / 取图）** — `SourceManager.fetchLyric` /
  `fetchPic`：按曲目 raw 的平台精确 ID 取词取图，顺序为脚本 `lyric`/`pic` action →
  any-listen → 内置五平台原生实现（wy eapi + yrc、tx PlayLyricInfo + QRC、
  kg KRC、kw LRCX、mg MRC；封面 wy 歌曲详情 / tx 专辑 mid / kg `get_res_privilege`
  / kw `pic.web` / mg 资源封面）。解码器在 `lib/sources/builtin/*_lyric.dart` +
  `tx_qrc.dart`（zlib 走条件导入，Web 优雅降级）。
- **Word timing（逐字时间轴）** — `lib/models/lyric_line.dart`：`LyricLine.words`
  （`LyricWord`：绝对起止 + 文本）由 `lxlyric` 的 `<相对ms,时长ms>` 解析并对齐主行；
  歌词页当前行用 `KaraokeLyricText` 词级高亮（已唱 primary / 未唱 onSurface，
  采样间线性补间），桌面歌词 / 通知 / 蓝牙输出仍按行。
- **Lyrics matching（歌词匹配）** — `lib/services/lyrics/lyrics_match.dart`：
  名字搜索候选按时长 ±5s、归一化歌名、歌手包含与版本词（live/伴奏/翻唱…）挑选；
  全部不匹配时回退首个候选（保持旧行为下限）。判定实现与换源共用
  `lib/services/song_match.dart`（唯一实现）。

## 资料库

- **Library mutation gateway（资料库变更网关）** — `lib/providers/library_provider.dart`：
  收藏 / 播放历史 / 列表写入的唯一实现。收藏唯一入口 `toggleFavoriteTrack(Track)`
  （播放页不再直连 `LibraryRepository`）；批量操作按 `PlaylistTrack` 规范形状，
  `PlaylistTrack.fromHistoryEntry` 负责历史条目转换。
- **Add-to-library flow（加入列表流程）** — `lib/widgets/add_to_library.dart`：
  选择目标 → 写入 → 解析新建列表名 → 反馈的唯一实现；收藏页与发现页共用。
- **Channel selection（渠道选择）** — `DiscoverProvider.channelKey` 是渠道状态的唯一持有者；
  渠道变化经注入的 `onChannelChanged`（组合根）触发搜索源跟随（可搜索渠道才跟随），
  资料页不再在两个 provider 之间仲裁同步，只处理「渠道被停用」的 UI 回退。
- **Playlist tracks view（列表曲目视图）** — `LibraryProvider.playlistTracksView` +
  `ensurePlaylistTracks`：页面只读「已缓存/加载中」视图并请求加载，不再探测
  `cachedTracksOf`/`isPlaylistLoading` 之类的缓存内部。

## 换源

- **Source swap（换源）** — `lib/providers/source_swap_provider.dart` + 
  `lib/widgets/source_swap_sheet.dart`：按种子曲目「歌名 + 歌手」在其它可搜索音源
  并行检索（逐源就绪即填充、单源失败隔离），点候选即试听（单曲「换源试听」），
  确认后原位替换。入口：收藏页三类合集左滑 / 播放页 seek 行（队列入口）。
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
  替换队列曲目（对齐 LX）；provenance（每个曲目的已尝试来源）保证级联每源
  至多一次、有界；开关 `SourceSwapSettings`（默认开，设置 › 播放）。

## 听歌统计

- **Play event（播放事件）** — `play_events` 一行 = 一次播放尝试（append-only，
  v4 迁移）：**真正出声才开行**（首个 `position > 0` 的 tick）；切歌 / 播完 /
  单曲循环每遍 / 位置回到开头（restart）/ 停止各收尾一行；暂停不切断；
  进程被杀由启动时 `closeStaleEvents()` 收尾为 interrupted。元数据为播放时
  快照、自包含（`raw` 供统计页点播）。与「播放历史」（`play_history`，
  最近播放 500 条）是两套数据。
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

- **AI DJ mode（AI 推歌模式）** — `lib/providers/ai_dj_provider.dart`：两件事的唯一
  状态机——**今日推荐列表**（持久、可浏览）与**推歌会话（电台）**。
  `enabled` = 功能启用（持久化；退出队列不关功能）；`status` = 电台状态
  （off/preparing/playing/error：播放全部或点某首才接管队列）。批次 20 首、
  队列剩余 ≤5 首且当前队列就是 AI 队列时后台续推
  （`PlaybackProvider.enqueueDomainTracks`）；跳过 = 切走时未达
  `min(30s, 50%×时长)`（复用统计口径，**只做曲目级排除**）；喜欢 = 收藏；
  「不感兴趣」= 列表移除 + 会话排除（可撤销）；连续 3 次失败自动停止续推；
  退出保留队列。播放快照/进度由组合根接进控制器。
- **Today's picks（今日推荐列表）** —
  `lib/services/ai/ai_recommendation_store.dart` + `lib/widgets/ai_dj_carousel.dart`：
  持久化的推荐列表（列表项 = 曲目 + AI 理由），「换一批」替换缓存；
  `aiDjCacheTtlDays`（默认 1 天）只决定续推是否消费旧列表——过期不提示、不删除、
  不打断播放，「上次更新」在 AI 页与发现页推荐区展示；
  **功能未启用时发现页整条隐藏**（开启入口在设置 › 内容 › AI 推歌）。
- **Taste profile（听歌画像）** — `lib/services/ai/taste_profile_builder.dart`：
  上行 LLM 的唯一数据出口（聚合统计 + 最近 200 条明细 + 已听排除清单，
  上限集中在此）；不含 raw payload / 设备信息；首次开启需隐私确认
  （`AiSettingsStore.consentKey`）。
- **Closed-book + local resolve（闭卷生成 + 本地解析）** —
  `lib/services/ai/ai_recommendation_service.dart`：LLM 只输出
  `{title, artist, reason}` JSON（容错解析 + 规范化去重），本地
  `CatalogService.search` 在用户启用音源里解析成可播放曲目（打分阈值 0.6），
  失败项折叠展示；推荐结果 100% 来自已启用音源。
- **LLM config（AI 服务配置）** — `lib/services/ai/ai_settings_store.dart`：
  Base URL / API Key / 模型（OpenAI-compatible，预设 DeepSeek/OpenAI/自定义）；
  Key 只写 `flutter_secure_storage`、不进日志；Web 平台隐藏入口（`aiDjSupportedPlatform`）。
- **Queue enqueue（队列追加）** — `PlaybackFacade/Backend/Service.enqueueTracks` +
  `PlaybackProvider.enqueueDomainTracks`：顺序模式追加队尾；洗牌模式经
  `PlaybackShuffleOrder.extend` 扩展排列（当前轮老歌在前，轮末重洗覆盖全队列）。

## 跨设备同步

- **Sync envelope（同步快照）** — `lib/domain/models/device_sync.dart`：
  一次交换的完整视图（设备身份 + 各类别记录）；全量合并模型，设备间互换快照后
  逐键取新，无增量/版本向量（见 ADR-0003）。
- **Sync record（同步记录）** — 快照最小单元：`key + updatedAt + updatedBy +
  data`；删除表示为 `deleted` 墓碑记录，墓碑参与 LWW 并保留 90 天后裁剪。
- **Sync category（同步类别）** — 可开关的数据类别：`playlists` /
  `playlistTracks` / `sources` / `settings` / `credentials` / `statistics` /
  `history` / `session`；关闭的类别既不推送也不应用（本机仍持续登记本地变化）。
- **Playback session record（会话记录）** — `session` 类别的单例记录：会话 JSON
  （队列/下标/进度/模式）+ `savedAt` 时间戳；正在播放的设备持续刷新从而抢占，
  本地停止播放不回传删除（换设备接着听的轻量实现）。
- **Backup（完整备份）** — `SyncEngine.exportBackupJson` / `importBackupJson`：
  与同步共用 envelope 与适配器的本地文件备份/合并恢复；不需要启用同步；
  凭证类默认排除。
- **LWW stamp（逐键时间戳）** — `(updatedAt, updatedBy)`：时间大者胜，
  相同时按设备 id 字典序决平局（确定性收敛）；时间戳是设备墙上时钟。
- **Sync passphrase（同步口令）** — 信任根：PBKDF2 派生 AES-256-GCM 密钥，
  能解密快照的设备即已授权；生成/归一化在 `sync_passphrase.dart`，加密帧在
  `sync_crypto.dart`；重置口令 = 撤销全部设备。
- **Sync transport（同步传输）** — `lib/domain/ports/sync_transport.dart`：
  `pull` / `push` / `incoming` 三动作；实现为局域网直连
  （`transport/lan_sync_transport.dart`）与用户自备 WebDAV
  （`transport/webdav_sync_transport.dart`）。
- **Sync adapter（同步适配器）** — 类别到本地存储的读写桥
  （`lib/data/sync/adapters/**`）：收集本地记录 / 应用合并结果，写入必须幂等；
  设置类用「登记哈希」（`SyncStamp`）做变化检测，不改造散落的写入方。
- **Sync tombstone（删除墓碑）** — 列表 / 曲目 / 脚本的删除不保留原行，
  由 `sync_tombstones` 表或同步状态中的登记项承担「删除也取新」的合并语义。
- **Settings registry（设置登记表）** — `SettingsSyncAdapter` 维护的
  `key → (值哈希, 时间戳, 设备)`：本地值 vs 登记哈希判定本地修改，
  应用远端后同步更新，保证重复应用幂等。
- **Sync report / log（同步结果 / 日志）** — 一轮同步的拉取 / 应用 / 跳过计数
  与错误（`SyncReport`、`SyncLogEntry`），设置页只读展示，不拦截合并。

## 缓存
- **Lyrics cache（歌词缓存模块）** — `lib/services/lyrics_cache.dart`：歌词键（`lyrics_cache_{trackId}`）、读写、用量与清理的唯一实现；TTL 策略属于 `CacheService`（取词时读取）。历史 `manual_lyrics_cache_*` 重复键只清不读。
- **Artwork index（封面索引）** — flutter_cache_manager 的元数据存储；`CacheStorage` 直接删文件后，由 `ArtworkCache` 的 `_pruneMissingEntries` 同步清理失效条目（索引不指向缺失文件）。
- **Paged list controller（分页列表状态机）** — `lib/providers/paged_list_controller.dart`：首屏 / 加载更多 / 失败态 / 过期响应丢弃 / 跨页去重的唯一实现；持有方提供 `fetchPage`，并可按需读取 `error`（原始异常）与 `page`。发现页歌单 tab 与 `SearchProvider` 均使用它（搜索的 query/source 上下文通过 `reset()` 使在途请求过期，不再自建守卫）。
- **Library collections（合集策略模块）** — `lib/providers/library_collections.dart`：收藏 / 播放历史 / 自建列表的哨兵、默认选择解析（`resolveSelection`）、顺序应用（`applyOrder`）与持久化（`favorites_collection_order`）的唯一实现；收藏页只保留 UI 状态。
