/// 跨设备同步栈：同步状态 → 六个数据适配器 → 局域网 / WebDAV 传输 →
/// SyncEngine（轮次）+ SyncControlPlane（UI 控制面）→ SyncBackup（导出/导入）→
/// SyncScheduler / SyncProvider，以及运行期的同步触发。
///
/// 引擎与局域网传输互为依赖（传输要引擎最近一轮快照，引擎要传输列表）。
/// 把「快照提供者」写在同一个 builder 内、引擎建好后立刻接线
/// （详见 [buildSyncStack] 注释），不存在跨 builder 回填。
/// 引擎 / 控制面 / 备份共享同一状态存储与同一批适配器 / 传输实例。
///
/// 触发策略（何时跑、跑什么范围）统一在 [SyncScheduler]：本 builder 只把
/// 数据变更、播放状态与探针接进去。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/molia_database.dart';
import '../../data/sync/adapters/ai_dj_sync_adapter.dart';
import '../../data/sync/adapters/change_detecting_adapter.dart';
import '../../data/sync/adapters/cover_sync_adapter.dart';
import '../../data/sync/adapters/history_sync_adapter.dart';
import '../../data/sync/adapters/playlist_sync_adapter.dart';
import '../../data/sync/adapters/prefs_sync_adapter.dart';
import '../../data/sync/adapters/script_sync_adapter.dart';
import '../../data/sync/adapters/session_sync_adapter.dart';
import '../../data/sync/adapters/statistics_sync_adapter.dart';
import '../../data/sync/lan_runtime.dart';
import '../../data/sync/pairing/lan_pairing_service.dart';
import '../../data/sync/sync_adapter.dart';
import '../../data/sync/sync_backup.dart';
import '../../data/sync/sync_codec_isolate.dart';
import '../../data/sync/sync_control_plane.dart';
import '../../data/sync/sync_engine.dart';
import '../../data/sync/sync_known_store.dart';
import '../../data/sync/sync_scheduler.dart';
import '../../data/sync/sync_transport_runtime.dart';
import '../../data/sync/transport/lan_sync_transport.dart';
import '../../data/sync/transport/local_network_permission.dart';
import '../../data/sync/transport/webdav_sync_transport.dart';
import '../../domain/models/device_sync.dart';
import '../../domain/models/library.dart';
import '../../domain/ports/sync_transport.dart';
import '../../providers/sync_provider.dart';
import '../../services/covers/custom_cover_store.dart';
import '../../services/data_saver_service.dart';
import '../../services/local_endpoints_service.dart';
import '../../services/sync_trigger_bridge.dart';
import 'ai_stack.dart';
import 'catalog_stack.dart';
import 'library_stack.dart';
import 'playback_stack.dart';

/// 同步栈产物（构造顺序见 [buildSyncStack]）。
typedef SyncStack = ({
  SyncEngine engine,
  SyncControlPlane controlPlane,
  SyncBackup backup,
  SyncScheduler scheduler,
  SyncProvider provider,
});

/// 装配跨设备数据同步（ADR-0003）：口令即信任根，加入同步的设备完全互信
/// （含音源脚本与凭证），因此不逐项审批。
Future<SyncStack> buildSyncStack({
  required CatalogStack catalog,
  required LibraryStack library,
  required PlaybackStack playback,
  required AiStack ai,
  required DataSaverService dataSaver,

  /// 自定义封面存储（本地数据栈构造的唯一实例，经 Provider / 构造参数传递）。
  required CustomCoverStore customCovers,

  /// 前台判定由组合根提供（`WidgetsBinding.instance.lifecycleState`）；
  /// 数据层不直接依赖 Flutter 生命周期。
  bool Function()? isForeground,
}) async {
  final sourceManager = catalog.sourceManager;
  final syncState = library.syncState;
  final covers = customCovers;
  // 编解码在 worker isolate 里跑（载荷编码 / 压缩 / PBKDF2 / AES 都是纯计算，
  // 放主 isolate 会让 UI 在首轮与整库快照时卡住数秒）。
  final syncCodec = IsolateSyncCodecPort();
  // 本机地址枚举（设置页地址列表 / 附近设备探测 / 探测 addrs 共用同一口径）。
  final localEndpoints = LocalEndpointsService();
  // 脚本同步的保留键：音源类别的设置键（避免脚本墓碑与设置键同名冲突）。
  final sourceCategoryKeys = {
    for (final key in catalog.settings.keys)
      if (key.category == SyncCategory.sources) key.name,
  };
  // 行表适配器只导出 / 应用记录；指纹缓存与 fresh 绕过由同一装饰器拥有。
  final playlistRecords = PlaylistSyncAdapter(
    repository: library.libraryRepository,
  );
  final playlistSyncAdapter = ChangeDetectingAdapter(
    source: playlistRecords,
    fingerprint: () async => syncFingerprintKey(
      await library.libraryRepository.syncFingerprints(
        playlistRecords.categories,
      ),
    ),
  );
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
  );
  final statisticsRecords = StatisticsSyncAdapter(
    store: library.statisticsSyncStore,
  );
  final statisticsSyncAdapter = ChangeDetectingAdapter(
    source: statisticsRecords,
    fingerprint: library.statisticsSyncStore.syncFingerprint,
  );
  final historyRecords = HistorySyncAdapter(
    repository: library.libraryRepository,
  );
  final historySyncAdapter = ChangeDetectingAdapter(
    source: historyRecords,
    fingerprint: () async => syncFingerprintKey(
      await library.libraryRepository.syncFingerprints(
        historyRecords.categories,
      ),
    ),
  );
  final sessionSyncAdapter = SessionSyncAdapter(
    // 远端会话写入必须经过播放会话模块：与本地保存 / 清除共用同一个 store
    // 写队列（另建 store 会在同一组 prefs 键上形成第二个写者）。
    port: playback.sessionCoordinator,
    state: syncState,
    journal: library.syncJournal,
    onChanged: playback.playbackProvider.reloadRestoredSessionFromStore,
  );
  final coverSyncAdapter = CoverSyncAdapter(
    store: covers,
    state: syncState,
    journal: library.syncJournal,
    // 未请求封面类别时 collect 直接返回空，不读封面文件；用户关闭后再
    // 开启时由控制面重置快照发布、用全量快照补传已有封面。
    enabled: () => syncState.isCategoryEnabled(SyncCategory.covers),
  );
  final aiDjSyncAdapter = AiDjSyncAdapter(
    store: ai.historyStore,
    state: syncState,
    journal: library.syncJournal,
    // 远端历史落地后重读 Provider 的内存索引 / active，历史页与 AI 页
    // 不需要重启就能看到另一台设备生成的推荐。
    onApplied: ai.djProvider.reloadHistory,
  );

  // 引擎与局域网传输互为依赖：传输的快照提供者要读引擎最近一轮快照。
  // 用「可空槽位 + 建完引擎立刻接线」把时序写在同一个 builder 内。
  SyncEngine? engineRef;
  // 局域网权限门（Android 17 起局域网默认阻断）：申请与状态都在这里，
  // 传输启动前先过门；权限被拒时手动地址也无效（网关级阻断）。
  final lanPermission = LocalNetworkPermission.production();
  // 控制面在传输之后才建（它要持有传输列表），但配对写口令必须走控制面
  // （缓存与凭据库一起更新）。这里先声明、用惰性闭包接线；真正的调用都
  // 发生在启动之后，不会读到未赋值的槽位。
  late final SyncControlPlane syncControlPlane;
  // 本机局域网事实的唯一实例：传输 / 发现 / 配对都读这一份，组合根不再把
  // 端口、地址、蜂窝与端点回写分别传给三者。
  final lanRuntime = LanRuntime(
    deviceId: syncState.deviceId,
    deviceName: () => syncState.deviceName,
    readPassphrase: () => syncControlPlane.readPassphrase(),
    writePassphrase: (passphrase) => syncControlPlane.setPassphrase(passphrase),
    ensurePassphrase: () => syncControlPlane.ensurePassphrase(),
    // 「已有同步组」判据只在控制面定义一份（名册非空或任一路传输真正
    // 接触成功过）；只有自动生成、从未同步过的口令不算组。
    hasGroup: () => syncControlPlane.hasEstablishedGroup,
    discoveryKey: syncCodec.discoveryKey,
    // 启动 / 每轮同步只查询权限，不弹窗；权限窗只由用户打开局域网开关
    // 或点「去授权」触发（见 SyncProvider.setTransportEnabled）。
    permissionGate: () async {
      try {
        return await lanPermission.refresh();
      } catch (e) {
        debugPrint('[Molia] 查询局域网权限失败: $e');
        return false;
      }
    },
    // 蜂窝下发现层不发任何 UDP（只直连已知端点）。
    isCellular: () => dataSaver.onCellular,
    // 换网 / 回前台重新枚举地址（不用进程缓存：旧 IP 会让探测包打空）。
    localAddresses: localEndpoints.hostsFresh,
    // 已验证端点：广播被隔离时靠单播直连；MAC + HTTP 解密成功后才回写。
    knownPeers: () => syncState.lanEndpoints,
    manualPeers: () => syncState.manualPeers,
    rememberPeerEndpoint: syncState.rememberLanEndpoint,
    onPeerResolved: (learned) => unawaited(syncState.learnManualPeer(learned)),
    // 原始 connectivity 事件：Wi-Fi 换网但蜂窝布尔值不变时也要重绑 socket。
    networkChanges: dataSaver.networkEvents,
    preferredHttpPort: () => syncState.lanHttpPort,
    onHttpPortBound: (port) => unawaited(syncState.setLanHttpPort(port)),
    // 发现层由传输创建；绑定前端口未知，先按「已接线但不可用」处理。
    probePort: 0,
  );
  final lanSyncTransport = LanSyncTransport(
    runtime: lanRuntime,
    codec: syncCodec,
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
  );
  final webdavSyncTransport = WebDavSyncTransport(
    deviceId: syncState.deviceId,
    codec: syncCodec,
    passphraseProvider: syncState.readPassphrase,
    configProvider: () => syncState.webdav,
    passwordProvider: syncState.readWebdavPassword,
    // 块的裁剪边界：本机日志只在所有对端 ack 之后前移 baseSeq，
    // 因此 `end <= baseSeq` 的远端块可以安全删除。
    journalBaseSeqProvider: library.syncJournal.baseSeq,
  );
  // 引擎、控制面与备份共用同一批适配器 / 传输实例（控制面只用传输，备份只用
  // 适配器）：三个模块对「有哪些类别、哪路传输」不能有各自的副本。
  final syncAdapters = <SyncAdapter>[
    playlistSyncAdapter,
    historySyncAdapter,
    scriptSyncAdapter,
    prefsSyncAdapter,
    statisticsSyncAdapter,
    sessionSyncAdapter,
    coverSyncAdapter,
    aiDjSyncAdapter,
  ];
  final syncTransports = <String, SyncTransport>{
    SyncTransportKind.lan: lanSyncTransport,
    SyncTransportKind.webdav: webdavSyncTransport,
  };
  // 传输运行时的唯一所有者：引擎（每轮 ensure、释放 stop、本地变更公告）与
  // 控制面（设置开关、App 生命周期）共享同一实例，避免两份启动循环。
  final syncTransportRuntime = SyncTransportRuntime(
    state: syncState,
    transports: syncTransports,
  );
  final syncEngine = SyncEngine(
    state: syncState,
    adapters: syncAdapters,
    transports: syncTransports,
    // 引擎与各仓库共用同一个发号器（唯一）与同一时钟源。
    stamps: syncState.stampIssuer,
    // 全库指纹也走 worker（一次本地变更就要重算一遍，主 isolate 上会掉帧）。
    fingerprintPort: syncCodec,
    // 变更集基线（sync_known）：跨重启只把版本变化的胜者交给适配器。
    known: SyncKnownRepository(databaseProvider: () => MoliaDatabase.instance),
    // 增量日志：**引擎与仓库共用同一实例**——写入点在仓库侧追加、引擎侧
    // 读窗口 / 按 ack 裁剪。漏传这一项不报错，但引擎会整体退化为
    // 「每轮全量快照」：全库指纹、整库加密推送、日志永不裁剪；
    // 组合根冒烟测试（`test/app/bootstrap_smoke_test.dart`）守住这条接线。
    journal: library.syncJournal,
    runtime: syncTransportRuntime,
    clock: () => DateTime.fromMillisecondsSinceEpoch(syncState.nowMs()),
  );
  engineRef = syncEngine;
  // 接线契约显式化：漏传增量日志会让引擎静默退化为「每轮全量」（全库指纹 +
  // 整库加密推送）。冒烟测试是主守卫，这里再兜一层 debug 断言。
  assert(syncEngine.incrementalEnabled, '同步引擎必须注入 library.syncJournal');
  // 控制面与引擎共享同一个状态存储：设置页的开关 / 身份写入就是引擎下一轮
  // 读到的状态，不存在第二份内存副本。
  syncControlPlane = SyncControlPlane(
    state: syncState,
    transports: syncTransports,
    runtime: syncTransportRuntime,
  );
  // 备份只需要收集入口 + 适配器 / 状态 / 发号器：不构造轮次，也不经过传输。
  final syncBackup = SyncBackup(
    state: syncState,
    // 与引擎共用同一记录管道：收集 / 合并 / 登记只有一份实现，备份导入不会
    // 与线上同步的应用规则漂移。
    pipeline: syncEngine.recordPipeline,
    stamps: syncState.stampIssuer,
    // 完整备份导出后放掉整库导出缓存：备份是低频动作，事件 / 各适配器的
    // 上轮记录没必要在导出后继续常驻；下一次同步按需重读。
    onExported: () {
      library.statisticsSyncStore.releaseExportCaches();
      syncEngine.releaseIdleCaches();
    },
    clock: () => DateTime.fromMillisecondsSinceEpoch(syncState.nowMs()),
  );
  // 蜂窝判定用调度器默认的真实探针（connectivity_plus）：省流服务的 onCellular
  // 只是缓存值，Wi-Fi 启动后切蜂窝不会反映到它上面。
  final scheduler = SyncScheduler(
    host: syncEngine,
    state: syncState,
    isPlaying: () => playback.playbackProvider.snapshot.isPlaying,
    // 网络变化与对端公告都接到调度器：换网 1.5s 后跑强制发现轮，收到公告
    // 1s 去抖 + 10s 冷却后跑发现轮；后台 / 蜂窝 / 省电由调度器自己拦住。
    networkChanges: dataSaver.networkEvents,
    peerSightings: syncEngine.peerSightings,
  );
  // 局域网一键配对：与局域网传输同生命周期。前台 + 非省电
  // 才应答探测 / 弹接受窗；口令写入必须经控制面（缓存与凭据库一起更新）。
  final pairing = LanPairingService(
    runtime: lanRuntime,
    canPrompt: () =>
        (isForeground?.call() ?? true) && !scheduler.powerSaveActive,
    packets: lanSyncTransport.pairingDatagrams,
    sendPacket: lanSyncTransport.sendPairingDatagram,
    nowMs: syncState.nowMs,
  );
  lanSyncTransport.attachPairing(pairing);

  // 同步触发的唯一 owner：资料库 / 统计流、音源通知、设置写入、脚本导入 /
  // 删除、会话落盘与本地封面写入全部在这里注册；provider dispose 时统一
  // 取消订阅并恢复回调钩子。scheduler 仍是「何时跑轮次」的唯一策略。
  final triggerBridge = SyncTriggerBridge(
    localChange: scheduler.notifyLocalChange,
  );
  triggerBridge
    ..attach(
      library.libraryRepository.changes.map(
        (change) => SyncChange(categories: change.syncCategories),
      ),
    )
    ..attach(
      library.playStatisticsRepository.changes.map(
        (_) => const SyncChange(categories: {SyncCategory.statistics}),
      ),
    )
    ..bindSourceManager(sourceManager)
    ..bindSettingsWrites(
      catalog.settings,
      // 设置 / 凭证写入（SettingsRegistry 是登记键的唯一写入口）：标记待发 +
      // 写入点即时追加增量日志（不依赖下一轮的登记哈希检测）。
      onKeyWritten: (key) => unawaited(prefsSyncAdapter.noteKeyWritten(key)),
    )
    ..bindScriptWrites(
      sourceManager,
      // 脚本写入（导入 / 更新 / 删除）：即时取版本并追加日志（新导入的脚本
      // 没有历史登记，只靠下一轮检测会被当成「首次登记」而不外发）。
      // 音源类别的待发标记由 bindSourceManager 的监听统一发出。
      onScriptWritten: (id) =>
          unawaited(scriptSyncAdapter.noteScriptWritten(id)),
      onScriptRemoved: (id) =>
          unawaited(scriptSyncAdapter.noteScriptRemoved(id)),
    )
    ..bindSessionSaves(
      playback.sessionStore,
      // 播放会话：高频进度落盘，只标记待发、不触发即时轮次（下次自然唤醒 /
      // 回前台 / 退后台时外发）。
      onSaved: () => unawaited(sessionSyncAdapter.noteLocalSave()),
    )
    // 仅本地封面写入标脏（远端应用到 store 时走 local=false，不会回环）。
    ..bindLocalCoverChanges(covers)
    // AI 推荐历史本地变化（远端应用不走这个钩子，不会回环）。
    ..bindAiHistoryWrites(ai.historyStore);

  final syncProvider = SyncProvider(
    engine: syncEngine,
    controlPlane: syncControlPlane,
    backup: syncBackup,
    scheduler: scheduler,
    lanPermission: lanPermission,
    localEndpoints: localEndpoints,
    codec: syncCodec,
    pairing: pairing,
    triggers: triggerBridge,
  );

  // 可选子系统（跨设备同步）初始化失败不允许阻断启动：runApp 之前任何
  // 未捕获异常都会让桌面端停在「窗口已显示但没有首帧」的黑窗状态。
  // 这里兜一层初始化异常（日志 + 继续，同步页表现为未配置）。
  //
  // 引擎 init 与调度器启动都后移到首帧之后（见 [startSync]）：启动路径
  // 不读写凭据库，调度器
  // 还要跑电量 / 网络探针（sync_scheduler 的 refreshEnvironment），都不
  // 参与首帧内容。
  //
  // 网络变化统一由 SyncScheduler.onNetworkChanged 处理（它自己订阅
  // dataSaver.networkEvents）：这里不再挂 ChangeNotifier 监听，避免同一次
  // 网络切换触发两次环境重估 / 轮次。

  return (
    engine: syncEngine,
    controlPlane: syncControlPlane,
    backup: syncBackup,
    scheduler: scheduler,
    provider: syncProvider,
  );
}

/// 首帧后的同步启动：引擎 init → 调度器启动。
///
/// 组合根在 `post_frame_init.dart` 调用：调度器要跑电量 / 网络探针
/// （桌面 release 中位数 ~38ms），而同步状态面（设置页开关 / 口令）
/// 在首帧后才有机会被看到。失败不阻断启动
/// （见 docs/pitfalls.md #31）。
Future<void> startSync(SyncStack sync) async {
  try {
    await sync.provider.init();
    await sync.scheduler.start();
  } catch (e) {
    debugPrint('[Molia] 同步初始化失败（继续启动）: $e');
  }
}
