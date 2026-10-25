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
import '../../data/sync/adapters/cover_sync_adapter.dart';
import '../../data/sync/adapters/history_sync_adapter.dart';
import '../../data/sync/adapters/playlist_sync_adapter.dart';
import '../../data/sync/adapters/prefs_sync_adapter.dart';
import '../../data/sync/adapters/script_sync_adapter.dart';
import '../../data/sync/adapters/session_sync_adapter.dart';
import '../../data/sync/adapters/statistics_sync_adapter.dart';
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
  required DataSaverService dataSaver,

  /// 自定义封面存储（生产 = local stack 的已加载实例；测试可省略）。
  CustomCoverStore? customCovers,

  /// 前台判定由组合根提供（`WidgetsBinding.instance.lifecycleState`）；
  /// 数据层不直接依赖 Flutter 生命周期。
  bool Function()? isForeground,
}) async {
  final sourceManager = catalog.sourceManager;
  final syncState = library.syncState;
  final covers = customCovers ?? CustomCoverStore.instance;
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
      StatisticsSyncAdapter(store: library.statisticsSyncStore);
  final historySyncAdapter =
      HistorySyncAdapter(repository: library.libraryRepository);
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
    // 默认关闭：未请求封面类别时 collect 直接返回空，不读封面文件；重新
    // 开启后由控制面重置快照发布、用全量快照补传已有封面。
    enabled: () => syncState.isCategoryEnabled(SyncCategory.covers),
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
    manualPeersProvider: () => syncState.manualPeers,
    onPeerResolved: (learned) => unawaited(syncState.learnManualPeer(learned)),
    httpPortProvider: () => syncState.lanHttpPort,
    onHttpPortBound: (port) => unawaited(syncState.setLanHttpPort(port)),
    // 换网 / 回前台重新枚举地址（不用进程缓存：旧 IP 会让探测包打空）。
    localAddressesProvider: localEndpoints.hostsFresh,
    // 已验证端点：广播被隔离时靠单播直连；MAC + HTTP 解密成功后才回写。
    knownPeersProvider: () => syncState.lanEndpoints,
    onPeerVerified: (endpoint) =>
        unawaited(syncState.rememberLanEndpoint(endpoint)),
    // 蜂窝下发现层不发任何 UDP（只直连已知端点）。
    isCellular: () => dataSaver.onCellular,
    // 原始 connectivity 事件：Wi-Fi 换网但蜂窝布尔值不变时也要重绑 socket。
    networkChanges: dataSaver.networkEvents,
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
    known: SyncKnownRepository(
      databaseProvider: () => MoliaDatabase.instance,
    ),
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
  final syncControlPlane = SyncControlPlane(
    state: syncState,
    transports: syncTransports,
    runtime: syncTransportRuntime,
  );
  // 备份只需要收集入口 + 适配器 / 状态 / 发号器：不构造轮次，也不经过传输。
  final syncBackup = SyncBackup(
    state: syncState,
    adapters: syncAdapters,
    stamps: syncState.stampIssuer,
    collect: syncEngine.collectRecords,
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
  // 局域网一键配对（Phase 2a 后端）：与局域网传输同生命周期。前台 + 非省电
  // 才应答探测 / 弹接受窗；口令写入必须经控制面（缓存与安全存储一起更新）。
  final pairing = LanPairingService(
    deviceId: syncState.deviceId,
    deviceName: () => syncState.deviceName,
    readPassphrase: syncControlPlane.readPassphrase,
    writePassphrase: syncControlPlane.setPassphrase,
    ensurePassphrase: syncControlPlane.ensurePassphrase,
    // 「已有同步组」判据只在控制面定义一份（名册非空或任一路传输真正
    // 接触成功过）；只有自动生成、从未同步过的口令不算组。
    hasGroup: () => syncControlPlane.hasEstablishedGroup,
    canPrompt: () =>
        (isForeground?.call() ?? true) && !scheduler.powerSaveActive,
    isCellular: () => dataSaver.onCellular,
    httpPortProvider: () => lanSyncTransport.httpPort,
    probePortProvider: () => lanSyncTransport.advertisedProbePort,
    localAddressesProvider: localEndpoints.hostsFresh,
    addPeerEndpoint: syncState.rememberLanEndpoint,
    discoveryKeyProvider: syncCodec.discoveryKey,
    packets: lanSyncTransport.pairingDatagrams,
    sendPacket: lanSyncTransport.sendPairingDatagram,
    nowMs: syncState.nowMs,
  );
  lanSyncTransport.attachPairing(pairing);
  final syncProvider = SyncProvider(
    engine: syncEngine,
    controlPlane: syncControlPlane,
    backup: syncBackup,
    scheduler: scheduler,
    lanPermission: lanPermission,
    localEndpoints: localEndpoints,
    codec: syncCodec,
    pairing: pairing,
  );
  // 仅本地封面写入标脏（远端应用到 store 时走 local=false，不会回环）。
  covers.onLocalChange = (_) => syncProvider.notifyLocalChange(
        categories: const {SyncCategory.covers},
      );

  // 可选子系统（跨设备同步）初始化失败不允许阻断启动：runApp 之前任何
  // 未捕获异常都会让桌面端停在「窗口已显示但没有首帧」的黑窗状态。
  // 口令读取失败已在 SecureSettingsSecretStore 内降级为「未设置」，
  // 这里再兜一层其它初始化异常（日志 + 继续，同步页表现为未配置）。
  //
  // 引擎 init（含安全存储读口令）与调度器启动都后移到首帧之后
  // （见 [startSync]）：两者都要碰安全存储 / 电量与网络探针
  // （sync_scheduler 的 refreshEnvironment），不参与首帧内容，
  // 留在 runApp 前只是让用户多等一次 IPC。

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

/// 首帧后的同步启动：引擎 init（安全存储读口令）→ 调度器启动。
///
/// 为什么拆出来（组合根在 `post_frame_init.dart` 调用）：这两步以前排在
/// `runApp` 之前，实测是启动装配里最大的一段（桌面 release 中位数 ~38ms），
/// 而同步状态面（设置页开关 / 口令）在首帧后才有机会被看到。失败不阻断启动
/// （口径同原 buildSyncStack 里的 try/catch，见 docs/pitfalls.md #31）。
Future<void> startSync(SyncStack sync) async {
  try {
    await sync.provider.init();
    await sync.scheduler.start();
  } catch (e) {
    debugPrint('[Molia] 同步初始化失败（继续启动）: $e');
  }
}
