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
  history 为会话队列前缀），点播放后交还底层。旧「远程播放风格 Map 兼容层」
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
    并拦截播放预加载、取色预取、audio_service 通知封面与桌面小组件封面地址；
  - 探测失败保守按「未生效」；Android 回前台时由壳层 `refreshConnectivity()` 补一次检测。
- **Mapping**：`track_mapper`（`SourceTrack` ↔ `Track`，payload 同一引用往返）。

## 4. 状态与通知策略

| 状态 | 频度 | 承载 | 订阅方式 |
|---|---|---|---|
| 播放进度 | ≤4Hz | `PlaybackProvider.position`（ValueListenable） | `ValueListenableBuilder`（进度条/歌词行） |
| 曲目/播放/队列/模式 | 事件级 | facade 快照（值变才发） | `Selector`（不可变对象/record） |
| 搜索结果/分页 | 交互级 | `SearchProvider` | 局部 select |
| 音源列表/顺序 | 事件级 | `SourceRegistry.changes` | 选择器/管理页 |

硬性规则：高频数值禁止进聚合 `notifyListeners`；`select` 禁止返回 `Map`/`List` 引用；
歌词行高亮用 `PositionLineIndexBuilder`（仅跨行重建）；队列列表用稳定引用。

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
  `ThemeProvider`（系统亮度 + 专辑封面取色）是唯一主题源（`autoTheming/dynamicColoring` 关闭）。
- 主题出口：`lib/theme/app_theme.dart::buildAppThemeData(ColorScheme)` 是唯一 ThemeData 构建处，
  并注册语义色扩展 `AppSemanticColors`（success/warning，固定色调、随亮度派生）；
  `main.dart` 经 `AnimatedSchemeBuilder`（450ms）平滑过渡方案色，两套主题同源重建。
- 色彩契约：`primary` 只用于交互/选中/强调图形；正文 `onSurface`、次要文本 `onSurfaceVariant`；
  容器配 `on*Container`；状态色走 `AppSemanticColors`（错误用 `scheme.error`）。
  禁止 `Colors.*`/`Color(0x...)` 字面量、`withAlpha/withOpacity`、
  `scaffoldBackgroundColor/dividerColor` 双源属性（`test/architecture/color_usage_test.dart` 扫描强制；
  海报艺术预设除外）。
- 组件：UI 全面使用 `M3E*`；基础件（Scaffold/Text/Icon/Theme 等）来自 `material_ui`（M3E 必需依赖）。
- 已知保留（无法等价替换）：带 `bottom:` 槽的 AppBar（2 处）、`_showCenterDialog`、
  `ScaffoldMessenger` 兼容代码。

## 7. 验证与性能

```bash
flutter analyze --no-pub                 # 0 error / 0 warning
flutter test --no-pub                    # 含 domain/catalog/playback/layering/supervisor/update
flutter test integration_test/lx_engine_integration_test.dart -d linux --no-pub
                                         # 3/3；tearDownAll 看门狗自动退出
flutter build apk --debug
flutter build apk --release --split-per-abi   # 发布体积
flutter build web --release
```

已兑现的性能收益：进度 tick 不再触发聚合通知（进度条/歌词行局部重建）；队列列表进度期 0
无谓重建；同曲重播/同词重复搜索命中缓存（0 次引擎/网络往返）；引擎崩溃自愈不再「源列表
残留但全超时」。

## 8. 后续

- any-listen 真实协议（WS IPC）接入；
- 真机验证（Android 17 通知/耳机键、iOS 后台播放）与 M3E 目视复核。
