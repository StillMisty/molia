# GLOSSARY

本仓库的领域词汇表：架构评审、模块命名与代码注释以此为共享语言。新增术语在落地时登记，避免同义多词。

## 曲目与平台对象

- **Raw track（平台 raw 曲目）** — `SourceTrack.raw` / `Track.payload` 承载的平台原始对象（LX `musicInfo` 约定：songmid / hash / copyrightId / qualitys ...）。取链 / 歌词 / 封面请求必须原样回传；只允许「只增不删」地补齐规范 id 字段。
- **Raw track module（raw 约定模块）** — `lib/sources/raw_track.dart`：平台 raw 的 id 取键（`rawIdOf` / `platformRawIdOf`）、规范字段补齐（`withCanonicalId`）与音质解析（`qualitiesFromRaw`）的唯一实现。`SourceTrack.id`、`TrackId`、收藏 / 列表 `songId`、`.lxmc` 导入与发现曲目映射共用它。
- **Canonical id field（规范 id 字段）** — 各平台取链脚本读取的 id 键：wy / tx / kw → `songmid`，kg → `hash`，mg → `copyrightId`。`.lxmc` 导入的 raw 缺少该字段时由 raw track module 补齐。
- **Platform id（平台 id）** — 不带平台前缀的单曲标识；[`SourceTrack.id`] 为其加上 `sourceKey:` 前缀。`rawIdOf`（通用优先级）与 `platformRawIdOf`（`.lxmc` 导出的平台优先顺序）是它的两个取键入口。
- **Builtin transport（内置传输模块）** — `lib/sources/builtin/builtin_transport.dart`：五个平台搜索/发现共用的 HTTP 入口（客户端可注入、统一请求头/超时、响应级重试 `retryIf` 与 JSON 解码）。`BuiltinSearch.transport` 是唯一实例，测试注入 `MockClient` 即可覆盖 fetch 路径；重试预算统一为 `BuiltinTransport.defaultRetries`（旧实现 2/3/5/3/3 漂移）。

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

## 歌词

- **Lyrics session module（歌词会话模块）** — `lib/providers/lyrics_provider.dart`：
  取词 → 缓存 → 解析（统一时间契约）→ 预取的唯一实现；对外只暴露 `LyricsState`
  （idle/loading/ready/empty + isSynced + providerName）与 `load/preload/saveManual`。
  UI 只渲染状态，不再各自构造 `LyricsService` 或直接写 `LyricsCache`。
- **Lyric timing contract（歌词时间契约）** — `lib/models/lyric_line.dart`：
  `hasLyricTimestamps` 与 `parseLyrics` 共用同一正则（兼容 1–3 位分钟、`.`/`:` 毫秒
  分隔与行内多标签）；不再允许「检测用一个正则、解析用另一个」的漂移。

## 资料库

- **Library mutation gateway（资料库变更网关）** — `lib/providers/library_provider.dart`：
  收藏 / 播放历史 / 列表写入的唯一实现。收藏唯一入口 `toggleFavoriteTrack(Track)`
  （播放页不再直连 `LibraryRepository`）；批量操作按 `PlaylistTrack` 规范形状，
  `PlaylistTrack.fromHistoryEntry` 负责历史条目转换。
- **Add-to-library flow（加入列表流程）** — `lib/widgets/add_to_library.dart`：
  选择目标 → 写入 → 解析新建列表名 → 反馈的唯一实现；收藏页与发现页共用。
- **Playlist tracks view（列表曲目视图）** — `LibraryProvider.playlistTracksView` +
  `ensurePlaylistTracks`：页面只读「已缓存/加载中」视图并请求加载，不再探测
  `cachedTracksOf`/`isPlaylistLoading` 之类的缓存内部。

## 缓存

- **Lyrics cache（歌词缓存模块）** — `lib/services/lyrics_cache.dart`：歌词键（`lyrics_cache_{trackId}`）、读写、用量与清理的唯一实现；TTL 策略属于 `CacheService`（取词时读取）。历史 `manual_lyrics_cache_*` 重复键只清不读。
- **Artwork index（封面索引）** — flutter_cache_manager 的元数据存储；`CacheStorage` 直接删文件后，由 `ArtworkCache` 的 `_pruneMissingEntries` 同步清理失效条目（索引不指向缺失文件）。
- **Paged list controller（分页列表状态机）** — `lib/providers/paged_list_controller.dart`：首屏 / 加载更多 / 失败态 / 过期响应丢弃 / 跨页去重的唯一实现；持有方提供 `fetchPage`。发现页歌单 tab 使用它；`SearchProvider` 保留自己的 query/source 请求上下文守卫（同一模式，但状态与搜索上下文耦合）。
- **Library collections（合集策略模块）** — `lib/providers/library_collections.dart`：收藏 / 播放历史 / 自建列表的哨兵、默认选择解析（`resolveSelection`）、顺序应用（`applyOrder`）与持久化（`favorites_collection_order`）的唯一实现；收藏页只保留 UI 状态。
