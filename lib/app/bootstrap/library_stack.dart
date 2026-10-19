/// 资料库与统计栈：同步状态设备戳 → 资料库仓库 / 听歌统计 → 最近播放上下文
/// （play_contexts）→ 换源偏好与自动换源解析服务。
///
/// 这些对象互相独立，但都被播放栈消费（观察者写历史、provider 读换源偏好），
/// 且都在 `syncState.init()` 之后才能拿到设备 id，因此合成一个 builder。
library;

import 'dart:async';

import '../../data/library_repository.dart';
import '../../data/molia_database.dart';
import '../../data/play_statistics_repository.dart';
import '../../data/settings/settings_keys.dart';
import '../../data/settings/settings_registry.dart';
import '../../data/sync/statistics_sync_store.dart';
import '../../data/sync/sync_journal.dart';
import '../../data/sync/sync_state_store.dart';
import '../../playback/local_audio_handler.dart';
import '../../providers/library_provider.dart';
import '../../providers/local_database_provider.dart';
import '../../providers/playback_provider.dart';
import '../../services/play_statistics_service.dart';
import '../../services/source_swap/auto_source_swap_service.dart';
import '../../services/source_swap/source_swap_settings.dart';
import 'catalog_stack.dart';

/// 资料库栈产物（构造顺序见 [buildLibraryStack]）。
typedef LibraryStack = ({
  /// 同步栈构造的注册表（与 catalog / playback 同一实例；组合根测试据此
  /// 核对「唯一注册表」）。
  SettingsRegistry settings,
  SyncStateStore syncState,
  SyncJournalRepository syncJournal,
  LibraryRepository libraryRepository,
  PlayStatisticsRepository playStatisticsRepository,
  SqliteStatisticsSyncStore statisticsSyncStore,
  PlayStatisticsService playStatisticsService,
  LocalDatabaseProvider localDatabaseProvider,
  SourceSwapSettings sourceSwapSettings,
  AutoSourceSwapService autoSourceSwapService,
});

/// 装配资料库 / 统计 / 换源相关的仓库与服务（含各自的启动维护）。
Future<LibraryStack> buildLibraryStack({
  required CatalogStack catalog,
}) async {
  // 跨设备同步状态提前初始化：资料库/统计的写路径需要设备 id 打同步戳。
  final syncState = SyncStateStore();
  await syncState.init();
  // 增量日志：资料库 / 统计的本机写入在**同一个 drift 事务**里追加
  // （对端按游标只拉变更；见 ADR-0003 v2 §5）。
  final syncJournal = SyncJournalRepository(
    databaseProvider: () => MoliaDatabase.instance,
    clock: () => syncState.nowMs(),
  );
  // 资料库仓库：播放历史 / 我的列表 / 收藏；播放开始时由播放观察者写历史，
  // 资料库页经 LibraryProvider 读取（内存缓存）。版本戳与内容时间分开注入
  // （发号器唯一、时钟管内容时间；见 ADR-0003 v2 §2）。
  final libraryRepository = LibraryRepository(
    clock: () => syncState.nowMs(),
    stamps: syncState.stampIssuer,
    journal: syncJournal,
  );
  // 发号器基线 ≧ 全库最大戳：即使状态存储没来得及落盘（进程被杀）或时钟回拨，
  // 重启后的新写入也不会输给库内已有记录。
  //
  // 听歌统计：事件级采集（play_events）与查询；与「最近播放」（play_history，
  // 500 条上限）是两套数据。采集是纯观察者（服务不持有 provider），
  // 快照 / 进度经 [wirePlayStatistics] 接线；上次进程被杀遗留的进行中事件
  // 启动即收尾为 interrupted。
  //
  // 同步形状（`syncKey` / 版本戳 / 日志 / 导出缓存 / 远端合并）在独立的
  // 统计同步存储里：仓库只拿它的写入面（`StatisticsSyncWriter`），适配器
  // 只拿读取面（`StatisticsSyncStore`），具体类只在组合根相遇。
  final statisticsSyncStore = SqliteStatisticsSyncStore(
    databaseProvider: () => MoliaDatabase.instance,
    stamps: syncState.stampIssuer,
    journal: syncJournal,
  );
  final playStatisticsRepository = PlayStatisticsRepository(
    clock: () => syncState.nowMs(),
    statisticsSync: statisticsSyncStore,
  );
  final playStatisticsService = PlayStatisticsService(
    repository: playStatisticsRepository,
    settings: catalog.settings.scope([kPlayStatisticsEnabled]),
  );
  // 换源偏好（自动换源开关，默认开）与自动换源解析服务：
  // 播放失败同源重试仍失败时，经注入的 resolver 跨音源严格找回并替换。
  final sourceSwapSettings = SourceSwapSettings(
    settings: catalog.settings.scope([kSourceSwapAutoEnabled]),
  );
  // 统计服务 init / 换源偏好 init / 全库最大戳查询三者互不依赖：
  // 并行执行，启动等待取最大值（串行等待会累加启动耗时）。
  final (_, _, dbMaxVersion) = await (
    playStatisticsService.init(),
    sourceSwapSettings.init(),
    libraryRepository.maxVersion(),
  ).wait;
  syncState.stampIssuer.seed(dbMaxVersion);
  unawaited(playStatisticsRepository.closeStaleEvents());
  // 事件保留裁剪（行数 + 时长上限）与载荷预算：统计查询 / 同步导出与指纹都随
  // 库龄线性变慢，超出上限的已收尾事件在启动维护时裁掉；载荷（gzip 字节）另按
  // 最近播放保留一份预算，病态大载荷脚本不会把库顶穿。
  unawaited(playStatisticsRepository.pruneOldEvents());
  // 最近播放上下文（play_contexts）：提前创建，同一实例既进 Provider 树，
  // 也直接注入 PlaybackProvider / 播放观察者。
  final localDatabaseProvider = LocalDatabaseProvider();
  final autoSourceSwapService = AutoSourceSwapService(
    catalog: catalog.catalogService,
    registry: catalog.sourceRegistry,
  );

  return (
    settings: catalog.settings,
    syncState: syncState,
    syncJournal: syncJournal,
    libraryRepository: libraryRepository,
    playStatisticsRepository: playStatisticsRepository,
    statisticsSyncStore: statisticsSyncStore,
    playStatisticsService: playStatisticsService,
    localDatabaseProvider: localDatabaseProvider,
    sourceSwapSettings: sourceSwapSettings,
    autoSourceSwapService: autoSourceSwapService,
  );
}

/// 听歌统计接线：曲目/播放态快照 + 进度 tick → 采集服务（纯观察者，零改动
/// 播放内核）。与歌词显示同一模式：composition root 只做两根监听。
///
/// 与 [buildLibraryStack] 分开：统计服务需要 provider 才能接线，
/// 而 provider 属于播放栈（两者顺序由 `main()` 决定，与原组合根一致）。
void wirePlayStatistics({
  required PlaybackProvider playback,
  required PlayStatisticsService service,
}) {
  playback.addListener(() => service.onSnapshot(playback.snapshot));
  playback.position
      .addListener(() => service.onPosition(playback.currentPosition));
  service.onSnapshot(playback.snapshot);
}

/// 系统媒体会话「收藏」动作接线：通知点击 → 曲库改写，曲库变化 → 通知图标。
///
/// handler 在播放栈里创建、曲库 provider 之后才建好，所以用 attach 晚绑定
/// （与 `attachSessionPersister` 同一个原因）。没有媒体会话（平台不支持 /
/// 初始化失败时 `audioHandler == null`）时是空操作。
void wireNotificationFavorite({
  required LocalAudioHandler? audioHandler,
  required LibraryProvider libraryProvider,
}) {
  final handler = audioHandler;
  if (handler == null) return;
  handler.attachFavoriteActions(
    // 键口径：`isFavorite` 收的是裸的 (sourceKey, songId)。`SourceTrack.id` 是
    // `sourceKey:songId` 复合键，直接传进去会算成 `wy:wy:186016`，读出来永远是
    // false（表现为「点收藏图标不变」）。
    isFavorite: (track) =>
        libraryProvider.isFavorite(track.sourceKey, track.songId),
    toggle: (track) => libraryProvider.toggleFavoriteSourceTrack(track),
  );
  // 收藏变化只影响通知动作的图标：handler 自己现查当前曲目，这里只负责叫醒它。
  libraryProvider.addListener(handler.refreshFavoriteState);
}
