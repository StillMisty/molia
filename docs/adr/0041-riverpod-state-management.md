# ADR-0041：状态管理迁移到 Riverpod

- 状态：已采纳（已实施）
- 日期：2026-11-23
- 相关：`lib/app/bootstrap/`、`lib/providers/`、`lib/app/bootstrap/runtime_providers.dart`、
  `pubspec.yaml`、`docs/architecture.md` §1、`test/architecture/layering_test.dart`

## 背景

应用当前以 `provider` + `ChangeNotifier` 作为状态层：`lib/app/bootstrap/provider_tree.dart`
在 `runApp` 前一次性注册 45 个依赖，UI 通过 `context.read/watch` 取实例，测试通过
`MultiProvider` 注入假实现。随着播放会话、资料库、下载、同步等状态增长，这套模型出现三个
结构性问题：

1. **生命周期不可组合**：所有实例在启动阶段创建并常驻；页面级状态（年度报告、统计页、
   评论、歌词搜索）没有自动释放的边界，只能手写 `dispose` 与组合根顺序。
2. **依赖图隐式**：`provider_tree.dart` 的列表顺序即依赖顺序，`create:` 里用
   `context.read` 取前面的实例；新增依赖只能靠注释和启动期断言维持，无法静态检查。
3. **测试成本高**：每个用例都要手工装配 `MultiProvider` 列表；`ChangeNotifier`
   继承迫使状态类与 `flutter/foundation` 绑定，纯 Dart 单测需要 Flutter 测试绑定。

Riverpod 3 提供显式 provider 图、自动释放、`Ref` 依赖注入与 `ProviderScope` override
测试模型，可以同时解决这三点。

## 决策

### 1. 依赖与代码生成

- 依赖：`flutter_riverpod: ^3.5.0`、`riverpod_annotation: ^4.0.8`；
  开发依赖：`riverpod_generator: ^4.0.10`。
- **provider 一律手写注解 + 代码生成**（官方推荐）：`@riverpod` / `@Riverpod(...)`，
  生成物 `*.g.dart` 与 drift 生成物一样提交进仓库，不手改。
- 全局单例状态使用 `@Riverpod(keepAlive: true)`；页面 / 弹层状态使用默认的
  auto-dispose，离开消费面即释放。
- 命名：`@Riverpod(name: 'xxxProvider')` 显式给出 provider 名，避免类名后缀推断出
  `xxxProviderProvider`。新增 provider 必须有唯一名。

### 2. 状态类形态

- UI 状态用 `Notifier<State>` / `AsyncNotifier<State>`，`State` 是**不可变快照**
  （`@immutable`，字段 `final`），对外只暴露快照；命令方法在 Notifier 上，
  经 `ref.read(xProvider.notifier).command()` 调用。
- 旧 `ChangeNotifier` 的公开 getter 一一映射到状态快照；可变字段只保留在 Notifier
  内部（订阅、定时器、服务句柄），不进入 `state`。
- 服务（`lib/services/`、`lib/data/`、`lib/sources/`、`lib/playback/`）**不改成
  Notifier**：它们是纯依赖，用函数式 `Provider` 暴露、由 `ref` 注入。只有“UI 读取并
  需要重建”的状态才进入 Notifier。
- 少量仍以 `Listenable` 为接口的适配层（如桌面歌词输出）由 Notifier 额外暴露
  `changes` 信号；新代码不得依赖它。

### 3. 组合根与容器

- `app_bootstrap.dart` 在核心栈之后创建**唯一** `ProviderContainer`，用
  `settingsRegistryProvider.overrideWithValue(core.catalog.settings)` 注入启动期依赖；
  功能栈通过 `container.read(...)` 取需要参与接线的实例。
- `buildRootWidget` 用 `UncontrolledProviderScope(container: dependencies.container)`
  挂树；`main.dart` 仍是唯一 composition root。
- 迁移期允许 `ProviderScope` 内继续挂 `MultiProvider`（未迁移 provider），
  但**同一状态只能有一个来源**：已迁移的 provider 必须从 `MultiProvider` 删除，
  不得双写。

### 4. 测试

- 单元测试用 `ProviderContainer(overrides: [...])`，`addTearDown(container.dispose)`；
  通过 `container.read(xProvider)` 读快照、`container.read(xProvider.notifier)` 执行命令。
- Widget 测试用 `UncontrolledProviderScope(container: ...)` 包住旧 `MultiProvider`
  宿主；依赖注册表用 `settingsRegistryProvider.overrideWithValue(testSettingsRegistry())`。
- 不再为迁移后的状态类写 `ChangeNotifier` 专用的 `addListener` / `dispose` 断言。

## 实施顺序

按依赖方向自下而上，每批保持 `flutter analyze` 与相关测试通过后再进入下一批：

1. ✅ 基础设施：依赖、唯一 `ProviderContainer`、`AppRuntime` 登记表、
   `settingsRegistryProvider`、ADR。
2. ✅ 主题：`ThemeProvider` → `Notifier<ThemeState>`，主题作用域挂载进入 `build()`；
   主壳 / 设置 / 歌词显示页 / 启动接线与测试同步迁移。
3. ✅ 全局偏好、搜索 / 发现 / 音源 / 评论、资料库 / 统计 / 年度报告、播放 / 歌词 /
   AI 推歌、下载 / 本地数据 / 同步 / 更新 / 诊断：全部消费点改为 `ref`。
4. ✅ 移除 `provider` 依赖、`provider_tree.dart` 与 `MultiProvider`；测试统一改用
   `ProviderTestScope`（`ProviderContainer` + `AppRuntime`）。
5. ✅ 架构守卫：domain / data 禁止 import `package:provider/` 与 Riverpod。

### 实施说明（迁移完成时的实际形态）

启动期装配不变：`app_bootstrap.dart` 按序构造服务，`runtime_wiring.dart` 把实例
登记进 `AppRuntime`，provider 只负责暴露与懒构造派生状态。状态层终态只有两种形态：

1. **容器持有的 UI 状态**：`Notifier<State>` / `AsyncNotifier<State>`
   （`@Riverpod` 代码生成）；UI `ref.watch(xProvider)` 读不可变快照，命令走
   `ref.read(xProvider.notifier)`。
2. **启动期 / 页面内部对象**：`SnapshotSource<State>`（`state` 不可变快照 +
   `changes` 信号，`SnapshotSignal` 只通知、不持状态）。这类对象与启动顺序、
   平台通道、服务生命周期强耦合，按 §2 不改成 `Notifier`：
   - 契约在 `lib/utils/snapshot_source.dart`：`lib/data`、`lib/sources`、
     `lib/playback` 不得 import providers，但它们的状态对象同样要实现该契约；
   - Riverpod 镜像在 `lib/providers/snapshot_source.dart`：
     `xProvider` = `SnapshotNotifier`（UI `ref.watch` 读快照），
     `xControllerProvider` = `snapshotController<X>()`（命令 / 服务句柄）；
   - 页面 / widget 自己创建并释放的会话不额外加 provider，宿主用
     `ListenableBuilder(listenable: obj.changes)` 读 `obj.state`。

**不再有**自定义 `ChangeNotifier` 状态类：`lib/**` 由
`test/architecture/snapshot_state_cases.dart` 守卫，白名单为空；迁移期的
`LegacyListenableNotifier` / `LazyListenableNotifier` 适配器已随最后一批删除。
新增状态必须直接写上面两种形态之一。

`extends ValueNotifier<ImmutableValue>` 仍允许：它是标准 `ValueListenable` 窄值
通道，承载 `copyWith` 出来的不可变值（`PagedListState`、`SearchResults`、
`FanOutRunState`、`AppPresenceState`、`MediaSessionCopy`），不是可变状态袋。
重复赋值是否发通知取决于值类型的 `==`：目前只有 `PagedListState` 实现了值相等，
其余按引用判断，因此不要在依赖「值相同就不通知」的路径上用它们。

**高频通道白名单**（不进快照，保持原有细粒度订阅）：

- 播放进度 `PlaybackEngine.position` / `PlaybackProvider.position`（≤4Hz）；
- 下载任务进度 `DownloadTask.progressListenable`、本地扫描进度；
- 更新下载进度 `UpdateProgress`；
- AI 生成进度 `AiDjProvider.generationState`；
- 歌词逐行迁移与预览高亮节拍（快照只带离散状态）；
- 封面 / 播放页过渡的逐帧进度（`pageDeckReveal`、dragging 进度）；
- 滚动位置与输入框文本（`TextEditingController` / `ScrollController`）。

**已落地的对象**

容器持有的 `Notifier<State>`：`ThemeProvider`、`CollectionModeStore`、
`AnnualReportProvider`、`PlayStatisticsProvider`、`TrackInfoController`、
`CommentsProvider`、`NavProvider`、`TraySettings`、`LyricsProvider`、
`LocalLibraryProvider`、`SourceSwapProvider`、`DiscoverProvider`。

启动期对象（`SnapshotSource` + 控制器 provider）：`AudioFocusSettings`（`bool`
快照）、`AiDjProvider`（`AiDjState`）、`LibraryProvider`（`LibraryState`：历史 /
列表 / 收藏键 / 版本戳）、`SearchProvider` / `ChannelSelection`、
`LyricsDisplayProvider` / `LyricsDisplaySettings`、`PlaybackProvider`
（`PlaybackState`）、`ScrobbleService`、`SyncProvider`（`SyncUiState`）、
`UpdateProvider`、`DiagnosticsProvider`、`SourcesProvider`（底层经可注入的
`SourcesBackend`）、`DownloadRecords` / `DownloadQueue` / `DownloadManager` /
`DownloadRequests` / `DownloadSettings`、`LocalLibraryService`、
`LocalPlaybackService`、`SourceManager`（`SourceManagerState`：引擎状态 / 脚本 /
渠道启停 / 首选音质 / 加载错误）、以及设置与偏好批次：`DataSaverService`、
`LibraryAddSettings`、`SourceSwapSettings`、`ShortcutSettings`、
`MusicFoldersStore`、`PlaylistFolderCollapseController`、
`LocalCacheIndexStore`、`BiliAccountService`（只含展示面，Cookie 留在
`BiliSession`）、`SourcePreferences`、`AudioRouteMonitor`。

作为内部事实、没有独立 provider 的对象：`SyncEngine`、`SyncControlPlane`、
`FavoriteFact`、`PlaybackPowerPolicy`、`CastSessionController`、
`LocalPlaybackService`——分别经 `SyncProvider`、`LibraryProvider`、
`PlaybackEngine` 等门面投影；`changes` 是唯一订阅面。

页面 / widget 内部会话（快照 + `changes`，由宿主重建）：`AlbumViewModel`、
`ArtistViewModel`、`FavoritesViewModel`、`LocalSongsCollection`、
`CollectionSession`、`CollectionSelection`、`LyricsSourceSearchSession`、
`LibraryCollectionRequest`、`ShellPresentation`、`NowPlayingController`、
`PlayerMorphController`、`CoverSwapSession`、`LyricsViewSession`。
`ShellReselectSignal` / `ShellLongPressSignal` 是一次性意图通道（无状态，只有
`changes` + `trigger()`），不实现 `SnapshotSource`。

**约定**

- 快照集合按量级冻结：小集合用 `List/Set/Map.unmodifiable`（复制，与真值彻底
  解耦）；大集合（资料库历史、分页结果、本地歌曲行、智能列表行）用
  `dart:collection` 的零拷贝只读视图，并按底层列表身份缓存视图——这样消费方无法
  原地改写，presenter 的列表身份复用也不被破坏。
- 可空依赖（`SaveAs` / `NotificationService` / `BiliAccountService` /
  `PlaybackProvider` 的查询路径）保留 `maybeXxxProvider`，未接线返回 `null`
  而不是抛启动期异常。
- 快照是「上次通知时的值」：需要即时判定的路径（换源、定位当前曲目、音质恢复态）
  读控制器实例，不读快照。

## 后果

- provider 图显式可测；页面级状态可自动释放；测试不再依赖 `ChangeNotifier` 生命周期。
- 容器只有一个：`app_bootstrap.dart` 创建、`UncontrolledProviderScope` 挂树；
  测试通过 `ProviderTestScope` 用同一套 `AppRuntime` 注入 fake。
- 启动阶段仍保留显式装配与登记；这是有意的边界（平台通道、顺序副作用），
  不属于 UI 状态层。
