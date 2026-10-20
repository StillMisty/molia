/// 资料库与统计栈：同步状态设备戳 → 资料库仓库 / 听歌统计 → 最近播放上下文
/// （play_contexts）→ 换源偏好与自动换源解析服务。
///
/// 这些对象互相独立，但都被播放栈消费（观察者写历史、provider 读换源偏好），
/// 且都在 `syncState.init()` 之后才能拿到设备 id，因此合成一个 builder。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

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
import '../../services/library/library_add_settings.dart';
import '../../services/play_statistics_service.dart';
import '../../services/source_swap/auto_source_swap_service.dart';
import '../../services/source_swap/source_swap_settings.dart';
import 'catalog_stack.dart';
import 'startup_trace.dart';

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
  LibraryAddSettings libraryAddSettings,
  AutoSourceSwapService autoSourceSwapService,
});

/// 装配资料库 / 统计 / 换源相关的仓库与服务（含各自的启动维护）。
///
/// [deferStampSeed] 为 true 时把「全库最大戳」查询留给
/// [startLibraryAfterFirstFrame]（生产组合根用，避免首帧等 DB 打开）；
/// 测试默认 false，builder 返回前就把查询跑起来，写入不会永久等种子。
Future<LibraryStack> buildLibraryStack({
  required CatalogStack catalog,
  bool deferStampSeed = false,
}) async {
  // 跨设备同步状态提前初始化：资料库/统计的写路径需要设备 id 打同步戳。
  final syncStateWatch = Stopwatch()..start();
  final syncState = SyncStateStore();
  await syncState.init();
  markStartupStep('sub.syncState.init', syncStateWatch);
  // 增量日志：资料库 / 统计的本机写入在**同一个 drift 事务**里追加
  // （对端按游标只拉变更；见 ADR-0003 v2 §5）。
  final syncJournal = SyncJournalRepository(
    databaseProvider: () => MoliaDatabase.instance,
    clock: () => syncState.nowMs(),
  );
  // 加入收藏 / 列表的位置偏好（默认放开头）：写入网关按它取新曲目的排序位，
  // 设置页读写同一实例（跟人走，随设置同步）。
  final libraryAddSettings = LibraryAddSettings(
    settings: catalog.settings.scope([kLibraryAddPosition]),
  );
  // 资料库仓库：播放历史 / 我的列表 / 收藏；播放开始时由播放观察者写历史，
  // 资料库页经 LibraryProvider 读取（内存缓存）。版本戳与内容时间分开注入
  // （发号器唯一、时钟管内容时间；见 ADR-0003 v2 §2）。
  final libraryRepository = LibraryRepository(
    clock: () => syncState.nowMs(),
    stamps: syncState.stampIssuer,
    journal: syncJournal,
    addToTop: () => libraryAddSettings.addToTop,
    // 全库最大戳的查询后移到首帧（`startLibraryAfterFirstFrame`）；在那之前
    // 写入方不得取号，否则新戳可能低于库内已有记录。
    beforeWrite: () => syncState.stampSeedReady,
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
    beforeWrite: () => syncState.stampSeedReady,
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
  // 统计服务 init / 换源偏好 init / 加入位置偏好 init 互不依赖：并行执行。
  // 全库最大戳查询要打开 drift 库（含迁移），不参与首帧内容，后移到
  // `startLibraryAfterFirstFrame`。写入方经 `beforeWrite` 等 `stampSeedReady`，
  // 不会在校验前取号。
  final settingsWatch = Stopwatch()..start();
  await (
    playStatisticsService.init(),
    sourceSwapSettings.init(),
    libraryAddSettings.init(),
  ).wait;
  markStartupStep('sub.library.settingsInit', settingsWatch);
  // 统计收尾 / 裁剪同属启动维护，也由首帧后统一触发。
  // 最近播放上下文（play_contexts）：提前创建，同一实例既进 Provider 树，
  // 也直接注入 PlaybackProvider / 播放观察者。
  final localDatabaseProvider = LocalDatabaseProvider();
  final autoSourceSwapService = AutoSourceSwapService(
    catalog: catalog.catalogService,
    registry: catalog.sourceRegistry,
  );

  final stack = (
    settings: catalog.settings,
    syncState: syncState,
    syncJournal: syncJournal,
    libraryRepository: libraryRepository,
    playStatisticsRepository: playStatisticsRepository,
    statisticsSyncStore: statisticsSyncStore,
    playStatisticsService: playStatisticsService,
    localDatabaseProvider: localDatabaseProvider,
    sourceSwapSettings: sourceSwapSettings,
    libraryAddSettings: libraryAddSettings,
    autoSourceSwapService: autoSourceSwapService,
  );
  if (!deferStampSeed) unawaited(_seedStampBaseline(stack));
  return stack;
}

/// 查询全库最大戳并放行写入（幂等：种子只前进，不会倒退）。
Future<void> _seedStampBaseline(LibraryStack library) async {
  final dbMaxWatch = Stopwatch()..start();
  try {
    final version = await library.libraryRepository.maxVersion();
    library.syncState.seedStampBaseline(version);
    markStartupStep('sub.db.maxVersion', dbMaxWatch);
  } catch (error) {
    // 查询失败也放行写入：沿用持久化基线 / 当前时钟，不能让资料库写入
    // 永久挂起（与启动维护的「失败不阻断」口径一致）。
    library.syncState.markStampSeedFailed();
    debugPrint('[Molia] 全库最大同步戳读取失败（写入沿用持久化基线）: $error');
  }
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

/// 首帧后的资料库启动尾巴：补入全库最大戳种子 + 统计收尾/裁剪。
///
/// 为什么后移：`maxVersion` 要打开 drift 库（含迁移），统计收尾/裁剪也写
/// 同一库；它们都不决定首帧内容。写入方在取号前等
/// [SyncStateStore.stampSeedReady]，因此晚到的种子不会造成「新戳低于库内
/// 最大戳」的同步回退。
void startLibraryAfterFirstFrame(LibraryStack library) {
  unawaited(_seedStampBaseline(library));

  unawaited(() async {
    await library.syncState.stampSeedReady;
    try {
      await library.playStatisticsRepository.closeStaleEvents();
      await library.playStatisticsRepository.pruneOldEvents();
    } catch (e) {
      debugPrint('[Molia] 统计启动维护失败（继续运行）: $e');
    }
  }());
}
