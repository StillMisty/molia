/// 跨设备同步栈：同步状态 → 六个数据适配器 → 局域网 / WebDAV 传输 →
/// SyncEngine → SyncScheduler / SyncProvider，以及运行期的同步触发。
///
/// 引擎与局域网传输互为依赖（传输要引擎最近一轮快照，引擎要传输列表）。
/// 把「快照提供者」写在同一个 builder 内、引擎建好后立刻接线
/// （详见 [buildSyncStack] 注释），不存在跨 builder 回填。
///
/// 触发策略（何时跑、跑什么范围）统一在 [SyncScheduler]：本 builder 只把
/// 数据变更、播放状态与探针接进去。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/molia_database.dart';
import '../../data/sync/adapters/history_sync_adapter.dart';
import '../../data/sync/adapters/playlist_sync_adapter.dart';
import '../../data/sync/adapters/prefs_sync_adapter.dart';
import '../../data/sync/adapters/script_sync_adapter.dart';
import '../../data/sync/adapters/session_sync_adapter.dart';
import '../../data/sync/adapters/statistics_sync_adapter.dart';
import '../../data/sync/sync_crypto.dart';
import '../../data/sync/sync_engine.dart';
import '../../data/sync/sync_known_store.dart';
import '../../data/sync/sync_scheduler.dart';
import '../../data/sync/transport/lan_sync_transport.dart';
import '../../data/sync/transport/local_network_permission.dart';
import '../../data/sync/transport/webdav_sync_transport.dart';
import '../../domain/models/device_sync.dart';
import '../../domain/models/library.dart';
import '../../domain/ports/sync_transport.dart';
import '../../providers/sync_provider.dart';
import '../../services/data_saver_service.dart';
import '../../services/playback_session_store.dart';
import 'catalog_stack.dart';
import 'library_stack.dart';
import 'playback_stack.dart';

/// 同步栈产物（构造顺序见 [buildSyncStack]）。
typedef SyncStack = ({
  SyncEngine engine,
  SyncScheduler scheduler,
  SyncProvider provider,
});

/// 装配跨设备数据同步（ADR-0003）：口令即信任根，加入同步的设备完全互信
/// （含音源脚本与凭证），因此不逐项审批；Web 端不提供入口。
Future<SyncStack> buildSyncStack({
  required CatalogStack catalog,
  required LibraryStack library,
  required PlaybackStack playback,
  required DataSaverService dataSaver,
}) async {
  final sourceManager = catalog.sourceManager;
  final syncState = library.syncState;
  final syncCodec = SyncCodec();
  // 脚本同步的保留键：音源类别的设置键（避免脚本墓碑与设置键同名冲突）。
  final sourceCategoryKeys = {
    for (final key in catalog.settings.keys)
      if (key.category == SyncCategory.sources) key.name,
  };
  final playlistSyncAdapter =
      PlaylistSyncAdapter(repository: library.libraryRepository);
  final scriptSyncAdapter = ScriptSyncAdapter(
    repository: sourceManager.repository,
    state: syncState,
    journal: library.syncJournal,
    ready: () => sourceManager.initialized,
    reservedKeys: sourceCategoryKeys,
    onScriptsChanged: sourceManager.refreshScriptsFromStorage,
  );
  final prefsSyncAdapter = PrefsSyncAdapter(
    state: syncState,
    settings: catalog.settings,
    journal: library.syncJournal,
    // 应用远端设置后：注册表按键触发模块自绑的重载钩子。
    onApplied: catalog.settings.reloadKeys,
  );
  final statisticsSyncAdapter =
      StatisticsSyncAdapter(repository: library.playStatisticsRepository);
  final historySyncAdapter =
      HistorySyncAdapter(repository: library.libraryRepository);
  final sessionSyncAdapter = SessionSyncAdapter(
    // 会话适配器用独立的会话存储实例（与播放栈的实时会话落盘互不影响）。
    store: PlaybackSessionStore(),
    state: syncState,
    journal: library.syncJournal,
    onChanged: playback.playbackProvider.reloadRestoredSessionFromStore,
  );

  // 引擎与局域网传输互为依赖：传输的快照提供者要读引擎最近一轮快照。
  // 用「可空槽位 + 建完引擎立刻接线」把时序写在同一个 builder 内。
  SyncEngine? engineRef;
  // 局域网权限门（Android 17 起局域网默认阻断）：申请与状态都在这里，
  // 传输启动前先过门；权限被拒时手动地址也无效（网关级阻断）。
  final lanPermission = LocalNetworkPermission.production();
  final lanSyncTransport = LanSyncTransport(
    deviceId: syncState.deviceId,
    deviceName: () => syncState.deviceName,
    codec: syncCodec,
    passphraseProvider: syncState.readPassphrase,
    // 全量快照：最近一轮的快照；本轮还没跑过时就地收集一份（避免对端
    // 拿到空快照后游标推进到 0）。
    snapshotProvider: () async =>
        engineRef?.serveSnapshot() ??
        SyncEnvelope(
          deviceId: syncState.deviceId,
          deviceName: syncState.deviceName,
          producedAt: syncState.nowMs(),
        ),
    // 增量端点：按请求方游标返回变更窗口（游标落后于窗口起点时回全量快照）。
    journalProvider: (since) async =>
        engineRef?.serveJournal(since: since) ??
        SyncEnvelope(
          deviceId: syncState.deviceId,
          deviceName: syncState.deviceName,
          producedAt: syncState.nowMs(),
        ),
    // 探测应答携带最近一轮快照的内容指纹与日志头部：对端据此跳过未变的 GET。
    snapshotIdProvider: () => engineRef?.lastEnvelope?.snapshotId ?? '',
    journalHeadProvider: () => engineRef?.lastEnvelope?.journalHead ?? 0,
    permissionGate: () => lanPermission.ensure(),
    ignoredPeersProvider: syncState.isPeerIgnored,
    manualPeersProvider: () => syncState.manualPeers,
    onPeerResolved: (learned) => unawaited(syncState.learnManualPeer(learned)),
    httpPortProvider: () => syncState.lanHttpPort,
    onHttpPortBound: (port) => unawaited(syncState.setLanHttpPort(port)),
  );
  final webdavSyncTransport = WebDavSyncTransport(
    deviceId: syncState.deviceId,
    codec: syncCodec,
    passphraseProvider: syncState.readPassphrase,
    configProvider: () => syncState.webdav,
    passwordProvider: syncState.readWebdavPassword,
    ignoredPeersProvider: syncState.isPeerIgnored,
  );
  final syncEngine = SyncEngine(
    state: syncState,
    adapters: [
      playlistSyncAdapter,
      historySyncAdapter,
      scriptSyncAdapter,
      prefsSyncAdapter,
      statisticsSyncAdapter,
      sessionSyncAdapter,
    ],
    transports: {
      SyncTransportKind.lan: lanSyncTransport,
      SyncTransportKind.webdav: webdavSyncTransport,
    },
    // 引擎与各仓库共用同一个发号器（唯一）与同一时钟源。
    stamps: syncState.stampIssuer,
    // 变更集基线（sync_known）：跨重启只把版本变化的胜者交给适配器。
    known: SyncKnownRepository(
      databaseProvider: () => MoliaDatabase.instance,
    ),
    clock: () => DateTime.fromMillisecondsSinceEpoch(syncState.nowMs()),
  );
  engineRef = syncEngine;
  // 蜂窝判定用调度器默认的真实探针（connectivity_plus）：省流服务的 onCellular
  // 只是缓存值，Wi-Fi 启动后切蜂窝不会反映到它上面。
  final scheduler = SyncScheduler(
    host: syncEngine,
    state: syncState,
    isPlaying: () => playback.playbackProvider.snapshot.isPlaying,
  );
  final syncProvider = SyncProvider(
    engine: syncEngine,
    scheduler: scheduler,
    lanPermission: lanPermission,
  );

  // 可选子系统（跨设备同步）初始化失败不允许阻断启动：runApp 之前任何
  // 未捕获异常都会让桌面端停在「窗口已显示但没有首帧」的黑窗状态。
  // 口令读取失败已在 SecureSettingsSecretStore 内降级为「未设置」，
  // 这里再兜一层其它初始化异常（日志 + 继续，同步页表现为未配置）。
  try {
    await syncProvider.init();
  } catch (e) {
    debugPrint('[Molia] 同步初始化失败（继续启动）: $e');
  }

  // 数据变更 → 调度器（活跃等级去抖 3–5s、空闲等级标记待外发）；所有启用
  // 类别的本地写入都要置待发标记：资料库 / 统计 / 音源 / 设置与凭证 / 会话。
  library.libraryRepository.changes.listen(
    (change) => syncProvider.notifyLocalChange(
      categories: change.syncCategories,
    ),
  );
  library.playStatisticsRepository.changes.listen(
    (_) => syncProvider.notifyLocalChange(
      categories: const {SyncCategory.statistics},
    ),
  );
  sourceManager.addListener(
    () => syncProvider.notifyLocalChange(
      categories: const {SyncCategory.sources},
    ),
  );
  // 设置 / 凭证写入（SettingsRegistry 是登记键的唯一写入口）：标记待发 +
  // 写入点即时追加增量日志（不依赖下一轮的登记哈希检测）。
  catalog.settings.onWrite = (key) {
    syncProvider.notifyLocalChange(categories: {key.category});
    unawaited(prefsSyncAdapter.noteKeyWritten(key));
  };
  // 脚本写入（导入 / 更新 / 删除）：即时取版本并追加日志（新导入的脚本没有
  // 历史登记，只靠下一轮检测会被当成「首次登记」而不外发）。
  sourceManager.onScriptWritten =
      (id) => unawaited(scriptSyncAdapter.noteScriptWritten(id));
  sourceManager.onScriptRemoved =
      (id) => unawaited(scriptSyncAdapter.noteScriptRemoved(id));
  // 播放会话：高频进度落盘，只标记待发、不触发即时轮次（下次自然唤醒 /
  // 回前台 / 退后台时外发）。
  playback.sessionStore.onSaved = () {
    syncProvider.notifyLocalChange(
      categories: const {SyncCategory.session},
      immediate: false,
    );
    unawaited(sessionSyncAdapter.noteLocalSave());
  };
  // 网络类型变化（connectivity_plus）→ 立即重估环境：Wi-Fi 与蜂窝之间切换
  // 后，小类别限制 / 「移动数据下暂停」不再等下一次唤醒。
  dataSaver.addListener(() => unawaited(scheduler.refreshEnvironment()));
  await scheduler.start();

  return (engine: syncEngine, scheduler: scheduler, provider: syncProvider);
}
