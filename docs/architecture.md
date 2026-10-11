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
  解析 → 预取的唯一实现，对外只暴露 `LyricsState`（idle/loading/ready/empty + isSynced）。
  时间契约统一在 `lib/models/lyric_line.dart`：`hasLyricTimestamps` 与 `parseLyrics`
  共用同一正则（兼容 1–3 位分钟与行内多标签）；`LyricsService` 失败路径不再重复取词。
  UI（LyricsWidget / 歌词搜索页 / 歌词选择页）只渲染状态与交互，不再各自构造
  `LyricsService` / 直接写 `LyricsCache` / 拼装解析逻辑。
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
  `LlmClient`（OpenAI-compatible，错误归一化 `SourceFailure`，Key 不进 message）、
  `AiRecommendationService`（提示词 → 容错 JSON → 规范化去重 →
  `CatalogService.search` 并行解析）。`AiDjProvider` 是模式状态机
  （批次 20 / 低水位续推 / 跳过与收藏反馈 / 失败降级），经
  `PlaybackProvider.enqueueDomainTracks` 续推（洗牌追加见
  `PlaybackShuffleOrder.extend`）；播放页徽标与 AI 页订阅其状态。
  首次开启隐私确认、Web 隐藏；定位与边界见 ADR-0002。
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

- **模块**：`lib/widgets/player_cover_deck.dart`（组件 + 横滑手势 + 会话状态）、
  `player_cover_session.dart`（`CoverSwapSession` 会话模型）、`player_cover_swap.dart`
  （方向判定纯函数）；播放器只提供布局尺寸、顶栏共享飞行锚点与主题联动。
- **三槽位模型**：左 = 上一首（播放顺序最近一首 history 末位 → 队列前一位 → 空，
  排除与当前同 id，与后端 `skipToPrevious` 同源）、中 = 当前（拖动/提交等待期间
  为预览目标）、右 = `PlaybackSnapshot.next`；左右槽只要展示了身份即可点击切歌。
- **会话与阶段**：`CoverSwapSession` 承载一次拖动/切歌的全部可变状态；阶段
  `idle → preview（跟手）→ committed（提交等待对账）→ settling（即时切歌完成中）`
  或 `correcting`（对账不匹配校正）。唯一一根进度控制器由 deck State 持有，
  拖动跟手按 easeOutCubic 反解写入，松手从同一进度续走或回弹，不跳。
- **窗口时序与常量**：切歌 320ms；目标槽位旧身份 p∈[0,0.4] 淡出、源槽位新身份
  p∈[0.6,1] 淡入（仅透明度、无位移，避免叠影）；移动卡全程插值（位移 ±0.30 卡宽、
  旋转 ±0.05rad、缩放 0.78↔1.0、透明度 0.85↔1.0）；拖动对账落位后源侧 180ms
  纯淡入；空闲槽位身份变化 180ms 原位交叉淡化；对账校正 220ms；中心同 id 换图
  250ms；提交后约 6 秒无对账回弹。
- **对账**：提交后等待快照 current 变为会话目标——匹配无缝落位；不匹配
  （随机目标 / 失败恢复 / 列表变化）先让提交过渡落位，再以 220ms 中心原位
  交叉淡化校正到实际曲目，随后按新快照重建槽位回 idle。
- **检测与缓存**：切歌检测、空闲缓存（下一首身份 / 方向提示）、空闲槽位淡换与
  播放态缩放同步全部由播放快照监听（微任务合并同批通知）驱动，build 期间零写入。
- **与共享飞行的关系**：顶栏↔播放页与迷你↔完整飞行只隐藏/复刻中心封面真身
  （`morph.pageCoverKey`）；侧邻位随页面层自身淡入以稳态出现，无独立入场演出。

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
flutter test integration_test/lx_engine_integration_test.dart -d linux --no-pub
                                         # 3/3；tearDownAll 看门狗自动退出
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
