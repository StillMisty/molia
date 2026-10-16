/// 资料库与统计栈：同步状态设备戳 → 资料库仓库 / 听歌统计 → 最近播放上下文
/// （play_contexts）→ 换源偏好与自动换源解析服务。
///
/// 这些对象互相独立，但都被播放栈消费（观察者写历史、provider 读换源偏好），
/// 且都在 `syncState.init()` 之后才能拿到设备 id，因此合成一个 builder。
library;

import 'dart:async';

import '../../data/library_repository.dart';
import '../../data/play_statistics_repository.dart';
import '../../data/sync/sync_state_store.dart';
import '../../providers/local_database_provider.dart';
import '../../providers/playback_provider.dart';
import '../../services/play_statistics_service.dart';
import '../../services/source_swap/auto_source_swap_service.dart';
import '../../services/source_swap/source_swap_settings.dart';
import 'catalog_stack.dart';

/// 资料库栈产物（构造顺序见 [buildLibraryStack]）。
typedef LibraryStack = ({
  SyncStateStore syncState,
  LibraryRepository libraryRepository,
  PlayStatisticsRepository playStatisticsRepository,
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
  // 资料库仓库：播放历史 / 我的列表 / 收藏；播放开始时由播放观察者写历史，
  // 资料库页经 LibraryProvider 读取（内存缓存）。版本戳与内容时间分开注入
  // （发号器唯一、时钟管内容时间；见 ADR-0003 v2 §2）。
  final libraryRepository = LibraryRepository(
    clock: () => syncState.nowMs(),
    stamps: syncState.stampIssuer,
  );
  // 发号器基线 ≧ 全库最大戳：即使状态存储没来得及落盘（进程被杀）或时钟回拨，
  // 重启后的新写入也不会输给库内已有记录。
  final dbMaxVersion = await libraryRepository.maxVersion();
  syncState.stampIssuer.seed(dbMaxVersion);
  // 听歌统计：事件级采集（play_events）与查询；与「最近播放」（play_history，
  // 500 条上限）是两套数据。采集是纯观察者（服务不持有 provider），
  // 快照 / 进度经 [wirePlayStatistics] 接线；上次进程被杀遗留的进行中事件
  // 启动即收尾为 interrupted。
  final playStatisticsRepository = PlayStatisticsRepository(
    clock: () => syncState.nowMs(),
    stamps: syncState.stampIssuer,
  );
  final playStatisticsService = PlayStatisticsService(
    repository: playStatisticsRepository,
    settings: catalog.settings,
  );
  await playStatisticsService.init();
  unawaited(playStatisticsRepository.closeStaleEvents());
  // 最近播放上下文（play_contexts）：提前创建，同一实例既进 Provider 树，
  // 也直接注入 PlaybackProvider / 播放观察者。
  final localDatabaseProvider = LocalDatabaseProvider();
  // 换源偏好（自动换源开关，默认开）与自动换源解析服务：
  // 播放失败同源重试仍失败时，经注入的 resolver 跨音源严格找回并替换。
  final sourceSwapSettings = SourceSwapSettings(settings: catalog.settings);
  await sourceSwapSettings.init();
  final autoSourceSwapService = AutoSourceSwapService(
    catalog: catalog.catalogService,
    registry: catalog.sourceRegistry,
  );

  return (
    syncState: syncState,
    libraryRepository: libraryRepository,
    playStatisticsRepository: playStatisticsRepository,
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
