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

- 启动期仍由 `app_bootstrap.dart` 按序构造服务；`runtime_wiring.dart` 把实例登记进
  `AppRuntime`，provider 只负责暴露与懒构造派生状态。这样保留了启动顺序的既有语义，
  也避免了 4000 行 boot 代码一次性重写带来的回归。
- 仍以 `ChangeNotifier` 实现的业务对象由 `LegacyListenableNotifier` /
  `LazyListenableNotifier` 适配：对外是 Riverpod `Notifier`，通知语义与旧
  `MultiProvider` 一致。后续新增状态必须直接写 `Notifier` / `AsyncNotifier`；
  存量业务对象可按模块继续内聚（去掉内部 `ChangeNotifier`），不影响 UI 契约。
- 可空依赖（`SaveAs` / `NotificationService` / `BiliAccountService` /
  `PlaybackProvider` 的查询路径）保留 `maybeXxxProvider`，避免把“未接线”从可表达
  状态变成启动期异常。

### 内部状态快照（第二批）

以下 UI 状态已从 `ChangeNotifier` 改成真正的 `Notifier<ImmutableState>`，
消费方读 `ref.watch(xProvider)`、命令走 `ref.read(xProvider.notifier)`：

- `ThemeProvider` → `ThemeState`
- `CollectionModeStore` → `CollectionModeState`
- `AnnualReportProvider` → `AnnualReportState`
- `PlayStatisticsProvider` → `PlayStatisticsState`
- `TrackInfoController` → `TrackInfoState`
- `CommentsProvider` → `CommentsState`
- `NavProvider` → `NavState`
- `TraySettings` → `TraySettingsState`

### 启动期状态对象：快照 + 控制器

组合根按启动顺序构造的状态对象（播放会话、资料库、歌词显示、设置与服务）
不改成 `Notifier`：它们与启动顺序、平台通道、服务生命周期强耦合，正是 §2
里「服务不改成 Notifier」的对象。它们统一改成：

- 类不再 `extends ChangeNotifier`，自己的可变字段只留在内部；
- `state` 暴露**不可变快照**（`@immutable`，字段名沿用旧 getter）；
- `changes` 是 `SnapshotSignal`（只通知、不持有状态），保留
  `Listenable` / `ValueListenable` 订阅面给播放服务、原生回调；
- 契约与 Riverpod 镜像分两处：`lib/utils/snapshot_source.dart` 只放
  `SnapshotSource` / `SnapshotSignal`（数据层、播放层与音源层都不得 import
  providers），`lib/providers/snapshot_source.dart` 放镜像与控制器：
  - `xProvider` = `SnapshotNotifier` 镜像快照，UI `ref.watch` 读；
  - `xControllerProvider` = `snapshotController<X>()`，命令 / 服务句柄从这里
    `ref.read`。

这样 UI 契约仍是「watch 快照、read 控制器发命令」，`lib/` 内不再有
`ChangeNotifier`；`LegacyListenableNotifier` / `LazyListenableNotifier` 在
迁移完成后删除。

已按此形态落地的对象：`AudioFocusSettings`（`bool` 快照）、`AiDjProvider`
（`AiDjState`）、`LibraryProvider`（`LibraryState`：历史 / 列表 / 收藏键 / 版本戳）、
`SearchProvider` / `ChannelSelection`、`LyricsDisplayProvider`、`PlaybackProvider`
（`PlaybackState`）、`ScrobbleService`（`ScrobbleState`：连接状态 / 账号 / 待发计数 /
授权阶段）、`SyncEngine`（`SyncEngineSnapshot`：初始化 / 在跑 / 最近报告）、
`SyncControlPlane`（`SyncControlPlaneState`：身份 / 开关 / 名册 / 日志 / 口令）、
`FavoriteFact`（`FavoriteFactState`：键 / 行 / 计数 / 版本）、
`PlaybackPowerPolicy`（前台 / 桌面歌词 / 歌词输出）、
`CastSessionController`（`CastSessionSnapshot`）。

`SyncEngine` / `SyncControlPlane` / `FavoriteFact` / `PlaybackPowerPolicy` /
`CastSessionController` 没有独立 Riverpod provider：它们分别是 `SyncProvider`、
`LibraryProvider` 的内部事实或只在服务内部订阅，对外仍经所属门面；`changes`
是唯一订阅面。

### 设置与偏好（第六批）

设置 / 设备本地偏好统一改成「不可变快照 + `changes`」；命令方法名与签名不变，
加载完成后再通知：

- `DataSaverService` → `DataSaverState`（开关 / 音质上限 / 封面省流 / 网络态）；
  `blockNetworkArtwork` / `effectiveQuality` 是即时判定，仍直接读实例；
- `DownloadSettings` → `DownloadSettingsState`；`LibraryAddSettings` →
  `LibraryAddSettingsState`；`SourceSwapSettings` → `SourceSwapSettingsState`；
- `ShortcutSettings` → `ShortcutSettingsState`（两组开关与绑定）；录制态不进
  快照（只影响按键让位，不驱动 UI）；
- `MusicFoldersStore` → `MusicFoldersState`；`PlaylistFolderCollapseController` →
  `PlaylistFolderCollapseState`；`LocalCacheIndexStore` → `LocalCacheIndexState`；
- `BiliAccountService` → `BiliAccountState`（只含展示面；Cookie 留在
  `BiliSession`，不进快照、不写日志）；
- `SourcePreferences` → `SourcePreferencesState`；`SourceManager` 订阅
  `preferences.changes` 转发自己的通知。

仍以 `ChangeNotifier` 实现、经 `LegacyListenableNotifier` 暴露的类有两类：
启动期服务（`SourceManager`、`DownloadService`、数据层 store…）与体量较大的
页面状态（`SyncProvider` 等）。它们与启动顺序 / 服务生命周期强耦合，内部快照化
按模块继续推进；UI 契约已经统一为 `ref`，后续替换不改变页面代码。

### 页面级视图模型（第七批）

由页面自己创建、`dispose` 的视图模型同样统一成「不可变快照 + `changes`」，
但**不**额外加 Riverpod provider：它们的生命周期就是页面 State，消费方用
`ListenableBuilder(listenable: vm.changes)` 读 `vm.state`：

- `AlbumViewModel` → `AlbumViewState`（头部实体 + `PagedListState`）；
  `ArtistViewModel` → `ArtistViewState`（同形）；条目与实体同一响应写入，
  分页列表本身仍由 `PagedListController` 发布，快照不复制列表；
- `FavoritesViewModel` → `FavoritesViewState`（多选 / 搜索 / 排序 / 当前合集 /
  合集顺序 / 本地歌曲计数 / 定位挂起）；搜索词仍在页面的
  `TextEditingController`，智能列表 `displayRows` 的版本计数是同帧投影结果，
  不进快照；
- `LocalSongsCollection` → `LocalSongsState`（行 / 计数 / 加载态 / 行列表版本）；
  它由 `CollectionSession` 内部持有，会话改订阅 `changes`。行列表仍是合集自己
  缓存的那份（presenter 按引用复用视图），快照不复制、不重新包装。

### 搜索 / 渠道 / 扇出（第三批）

- `ChannelSelection` → `ChannelSelectionState`（当前 key + 可用渠道顺序），
  `SearchProvider` → `SearchState`（关键词 / 类型 / 结果 / 投影 / 预览高亮）。
  两者仍是组合根按启动顺序构造的实例：Riverpod 侧
  `channelSelectionProvider` / `searchProvider` 只镜像快照，命令经
  `channelSelectionControllerProvider` / `searchControllerProvider`。
- `SearchSession` / `SearchPreviewSession` / `FanOutSearchSession` 不再是
  `ChangeNotifier`：可变状态留在会话内部，`changes` 是唯一订阅面。
  `SearchProvider` 把同一轮事件循环内的会话 / 预览通知合并成**一次**快照更新；
  查询防抖、结果批量更新节拍与输入框（`TextEditingController`）持有高频值的
  分工都不变。
- `SearchAssistController` 改用 `Listenable` 信号（`changes`），宿主仍用
  `ListenableBuilder` / `addListener` 消费。
- 消费方改为 watch 快照 + read 控制器：`library_search_tab`、`search_section`、
  `global_search_overlay`、`search_results_view`（后者只接收不可变投影，分页 /
  重试命令仍经会话）。
- 仍未快照化：`SourcesProvider`（音源管理门面，字段多、页面按对象读取，单独
  一批）；`PlaybackProvider` / `LibraryProvider` / `AiDjProvider` 等按上文说明
  继续推进。

## 后果

- provider 图显式可测；页面级状态可自动释放；测试不再依赖 `ChangeNotifier` 生命周期。
- 容器只有一个：`app_bootstrap.dart` 创建、`UncontrolledProviderScope` 挂树；
  测试通过 `ProviderTestScope` 用同一套 `AppRuntime` 注入 fake。
- 启动阶段仍保留显式装配与登记；这是有意的边界（平台通道、顺序副作用），
  不属于 UI 状态层。
