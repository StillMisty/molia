# GLOSSARY

本仓库的领域词汇表：架构评审、模块命名与代码注释以此为共享语言。新增术语在落地时登记，避免同义多词。

## 曲目与平台对象

- **Raw track（平台 raw 曲目）** — `SourceTrack.raw` / `Track.payload` 承载的平台原始对象（LX `musicInfo` 约定：songmid / hash / copyrightId / qualitys ...）。取链 / 歌词 / 封面请求必须原样回传；只允许「只增不删」地补齐规范 id 字段。
- **Raw track module（raw 约定模块）** — `lib/sources/raw_track.dart`：平台 raw 的 id 取键（`rawIdOf` / `platformRawIdOf`）、规范字段补齐（`withCanonicalId`）与音质解析（`qualitiesFromRaw`）的唯一实现。`SourceTrack.id`、`TrackId`、收藏 / 列表 `songId`、`.lxmc` 导入与发现曲目映射共用它。
- **Canonical id field（规范 id 字段）** — 各平台取链脚本读取的 id 键：wy / tx / kw → `songmid`，kg → `hash`，mg → `copyrightId`。`.lxmc` 导入的 raw 缺少该字段时由 raw track module 补齐。
- **Artist ref（歌手引用）** — raw 的项目内部字段 `_artists`（`[{'name','id'}]`，与 `_types` / `_interval` 同约定：内置平台解析时增补、LX 字段只增不删）：平台内歌手 id 与曲目 payload 同体系（kw `allartistid` / `ARTISTID`（多歌手按 `&` 与名字同序）/ kg `Singers[].id` / tx `singer[].mid` / wy `ar[].id` / mg `singerList[].id`）。唯一读取入口 `raw_track.dart::artistsFromRaw`，由 `track_mapper` 填进 `Track.artists[].id`；UI 只读 `Track.artists`（不读 payload），据此把歌手名做成歌手页链接。脚本扩展源 / 旧数据没有该字段 → 歌手入口按只读降级。
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
- **Sleep timer（定时关闭）** — `lib/providers/sleep_timer.dart`：歌曲信息页入口的
  「到点暂停」。两种模式：倒计时（**仅播放时计时**，暂停冻结，剩余时间按 `now()`
  差值累计）与「播完当前歌曲」（纯事件驱动，无定时器）。判定只读 **facade 原始
  通道**（真实播放），恢复态覆盖值不参与；到点动作经注入的 `onFire` 落地
  （组合根注入 `facade.pause`）。剩余时间每秒走 `ValueListenable`（不进聚合通知），
  不持久化，`stopLocalPlayback` 一并撤销。

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

## 应用壳与导航

- **Shell reselect（底栏重复点击）** — `lib/widgets/shell_reselect.dart::ShellReselectSignal`：
  壳层把「重复点击已选中的底栏 / 导航轨目的地」转交给页面的唯一通道（每个目的地
  一个实例，与 `PlayerMorphController` 同路由注入）。页面自订阅、自决定语义并自给
  反馈：播放页 = 迷你 ⇄ 完整（现有 `_toggleExpand`，进入播放页的共享元素飞行期间
  由壳层忽略），资料库 / 收藏 = 当前可见列表回到顶部
  （`lib/utils/scroll_to_top.dart::animateScrollToTop`）。壳层不消费状态、不给触感。

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
  UI 只渲染状态，不再各自构造 `LyricsService` 或直接写 `LyricsCache`；
  **歌词页不维护镜像**（`lyrics.dart` 只经 `_session` 读会话状态，加载标志由
  `status == loading` 推导，写入路径只有「会话变化 → 重置滚动簿记」一条）。
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
  `tx_qrc.dart`（zlib 走条件导入，Web 优雅降级）。
- **Word timing（逐字时间轴）** — `lib/models/lyric_line.dart`：`LyricLine.words`
  （`LyricWord`：绝对起止 + 文本）由 `lxlyric` 的 `<相对ms,时长ms>` 解析并对齐主行；
  歌词页当前行用 `KaraokeLyricText` 词级高亮（已唱 primary / 未唱 onSurface，
  采样间线性补间），桌面歌词 / 通知 / 蓝牙输出仍按行。
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
  变为可点行（副标题「查看专辑」），否则保持只读信息行。

## 歌手与歌词搜索

- **Artist page（歌手页）** — `lib/pages/artist_page.dart`（头部头像 / 名字 / 简介 +
  播放全部 / 加入列表 + 触底分页），入口：歌曲信息页「歌手」行、搜索结果行内歌手名、
  搜索「歌手」类型条目；取数走 **Artist service（歌手服务）**
  `lib/data/catalog/artist_service.dart`（single-flight + LRU + TTL 10min，
  key `artist:{source}:{id}:{page}:{limit}`，注入 `SourceManager.fetchArtist`）。
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
- **Library change（资料库变更事件）** — sealed `LibraryChange`（history /
  playlists / playlistTracks(id) / favorites / import）：`changes` 广播的载荷，
  类型即失效范围；取代 `Stream<void>` + 事后回读 `lastChangeKind` /
  `lastChangePlaylistId` 的侧信道（异步边界后读到的是「最近一次」而不是「本次」）。
- **Favorites（收藏）** — 领域概念 `PlaylistInfo.isFavorites`；存储层保留行名
  `__favorites__` 只在实现内部（UI 文案走 l10n，调用方不再按名字比较）。
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
  确认后原位替换。入口：收藏页合集（收藏 / 历史 / 自建列表）左滑 /
  播放页 seek 行（队列入口）；本地歌曲不含换源（本地文件无在线音源可换）。
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


- **Play event（播放事件）** — `play_events` 一行 = 一次播放尝试（append-only）：
  **真正出声才开行**（首个 `position > 0` 的 tick）；切歌 / 播完 /
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
- **Setting stamps（设置登记哈希）** — `SyncStateStore.settingStamps` 维护的
  `key → (值哈希, 时间戳, 设备)`：本地值 vs 登记哈希判定本地修改，
  应用远端后同步更新，保证重复应用幂等（见 `docs/adr/0003` §6 修订）。
- **Settings key（登记键）** — `lib/data/settings/settings_key.dart`：一个设置键的
  全部事实（名字 / 默认值 / 同步类别 / 存放盒）；只有有「第二消费者」的键才登记
  （同步、备份、应用远端后的重载、整表驱动的测试），设备本地键留在各自模块。
- **Settings registry（设置注册表）** — `lib/data/settings/settings_registry.dart`：
  登记键的唯一家（读 / 写 / 同步往返 / 重载钩子）；组合根注入唯一实例，模块在
  构造时把 reload 钩子绑到自己的键，应用远端值后按变化的键触发；键名字面量只有
  一份（`settings_keys.dart`），由 `test/architecture/settings_keys_test.dart` 强制。
- **Sync report / log（同步结果 / 日志）** — 一轮同步的拉取 / 应用 / 跳过计数
  与错误（`SyncReport`、`SyncLogEntry`），设置页只读展示，不拦截合并。

## 缓存
- **Lyrics cache（歌词缓存模块）** — `lib/services/lyrics_cache.dart`：歌词键（`lyrics_cache_{trackId}`）、读写、用量与清理的唯一实现；TTL 策略属于 `CacheService`（取词时读取）。历史 `manual_lyrics_cache_*` 重复键只清不读。
- **Artwork index（封面索引）** — flutter_cache_manager 的元数据存储；`CacheStorage` 直接删文件后，由 `ArtworkCache` 的 `_pruneMissingEntries` 同步清理失效条目（索引不指向缺失文件）。
- **Paged list controller（分页列表状态机）** — `lib/providers/paged_list_controller.dart`：首屏 / 加载更多 / 失败态 / 过期响应丢弃 / 跨页去重的唯一实现；持有方提供 `fetchPage`，并可按需读取 `error`（原始异常）与 `page`。发现页歌单 tab 与 `SearchProvider` 均使用它（搜索的 query/source 上下文通过 `reset()` 使在途请求过期，不再自建守卫）。
- **Library collections（合集策略模块）** — `lib/providers/library_collections.dart`：收藏 / 播放历史 / 本地歌曲 / 自建列表的哨兵（`unset` / `favoritesSentinel` / `historySentinel` / `downloadsSentinel`）、默认选择解析（`resolveSelection`，后两者仅显式选择进入）、顺序应用（`applyOrder`）与持久化（顺序 / 选择 / 滚动位置的唯一实现）；收藏页只保留 UI 状态。
- **Local songs（本地歌曲合集）** — 收藏页的伪合集（`downloadsSentinel` ↔ `downloadsOrderKey`）：数据来自 `DownloadService.downloads`（下载副本 + 本地导入），不落列表表；仅在下载能力可用（`DownloadService.supported`）时出现在合集弹层，排序固定按下载 / 导入时间倒序。
- **Local import（本地导入）** — `downloads` 表 `imported` 行 = **就地引用**用户自己的音频文件：`originSourceKey = 'local'`、`originSongId` = 文件绝对路径（同路径重复导入幂等），`filePath` 指向原文件；删除记录只移行、不删文件，补发布 / 旧位置迁移都跳过。写入唯一入口 `DownloadService.importLocalFiles`（标签解析见 `lib/data/downloads/audio_tag_reader.dart`：mp3 ID3v2 / flac Vorbis Comment，其余格式按文件名兜底）。
