/// 跨设备同步栈：同步状态 → 六个数据适配器 → 局域网 / WebDAV 传输 →
/// SyncEngine → SyncProvider，以及运行期的同步触发器。
///
/// 引擎与局域网传输互为依赖（传输要引擎最近一轮快照，引擎要传输列表）。
/// 原组合根用 `late final syncEngine` 自引用；这里把「快照提供者」写在同一个
/// builder 内、引擎建好后立刻接线（详见 [buildSyncStack] 注释），
/// 不存在跨 builder 回填。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/sync/adapters/history_sync_adapter.dart';
import '../../data/sync/adapters/playlist_sync_adapter.dart';
import '../../data/sync/adapters/prefs_sync_adapter.dart';
import '../../data/sync/adapters/script_sync_adapter.dart';
import '../../data/sync/adapters/session_sync_adapter.dart';
import '../../data/sync/adapters/statistics_sync_adapter.dart';
import '../../data/sync/sync_crypto.dart';
import '../../data/sync/sync_engine.dart';
import '../../data/sync/transport/lan_sync_transport.dart';
import '../../data/sync/transport/local_network_permission.dart';
import '../../data/sync/transport/webdav_sync_transport.dart';
import '../../domain/models/device_sync.dart';
import '../../domain/ports/sync_transport.dart';
import '../../providers/playback_provider.dart';
import '../../providers/sync_provider.dart';
import '../../services/playback_session_store.dart';
import 'catalog_stack.dart';
import 'library_stack.dart';

/// 同步栈产物（构造顺序见 [buildSyncStack]）。
typedef SyncStack = ({
  SyncEngine engine,
  SyncProvider provider,
});

/// 装配跨设备数据同步（ADR-0003）：口令即信任根，加入同步的设备完全互信
/// （含音源脚本与凭证），因此不逐项审批；Web 端不提供入口。
Future<SyncStack> buildSyncStack({
  required CatalogStack catalog,
  required LibraryStack library,
  required PlaybackProvider playback,
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
    ready: () => sourceManager.initialized,
    reservedKeys: sourceCategoryKeys,
    onScriptsChanged: sourceManager.refreshScriptsFromStorage,
  );
  final prefsSyncAdapter = PrefsSyncAdapter(
    state: syncState,
    settings: catalog.settings,
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
    onChanged: playback.reloadRestoredSessionFromStore,
  );

  // 引擎与局域网传输互为依赖：传输的快照提供者要读引擎最近一轮快照。
  // 用「可空槽位 + 建完引擎立刻接线」把时序写在同一个 builder 内
  // （原组合根是 late final syncEngine 的自引用）。
  SyncEngine? engineRef;
  // 局域网权限门（Android 17 起局域网默认阻断）：申请与状态都在这里，
  // 传输启动前先过门；权限被拒时手动地址也无效（网关级阻断）。
  final lanPermission = LocalNetworkPermission.production();
  final lanSyncTransport = LanSyncTransport(
    deviceId: syncState.deviceId,
    deviceName: () => syncState.deviceName,
    codec: syncCodec,
    passphraseProvider: syncState.readPassphrase,
    snapshotProvider: () async =>
        engineRef?.lastEnvelope ??
        SyncEnvelope(
          deviceId: syncState.deviceId,
          deviceName: syncState.deviceName,
          producedAt: syncState.nowMs(),
        ),
    // 探测应答携带最近一轮快照的内容指纹：对端据此跳过未变的 GET。
    snapshotIdProvider: () => engineRef?.lastEnvelope?.snapshotId ?? '',
    permissionGate: () => lanPermission.ensure(),
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
    clock: () => DateTime.fromMillisecondsSinceEpoch(syncState.nowMs()),
  );
  engineRef = syncEngine;
  final syncProvider = SyncProvider(
    engine: syncEngine,
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

  // 数据变更 → 去抖同步（资料库 / 统计 / 音源配置）；前台恢复补一轮
  // （见 `main.dart` 的 AppLifecycleListener）；运行期间每 10 分钟一轮
  // （局域网对端在线时也能收敛）。
  library.libraryRepository.changes.listen((_) => syncProvider.scheduleSync());
  library.playStatisticsRepository.changes
      .listen((_) => syncProvider.scheduleSync());
  sourceManager.addListener(syncProvider.scheduleSync);
  Timer.periodic(const Duration(minutes: 10), (_) {
    if (syncProvider.enabled) unawaited(syncProvider.syncNow());
  });

  return (engine: syncEngine, provider: syncProvider);
}
