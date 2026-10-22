import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/sync/sync_activity.dart';
import '../data/sync/sync_adapter.dart';
import '../data/sync/sync_backup.dart';
import '../data/sync/sync_codec_port.dart';
import '../data/sync/sync_control_plane.dart';
import '../data/sync/sync_engine.dart';
import '../data/sync/sync_passphrase.dart';
import '../data/sync/sync_scheduler.dart';
import '../data/sync/sync_state_store.dart';
import '../data/sync/transport/local_network_permission.dart';
import '../domain/models/device_sync.dart';
import '../domain/models/sync_nearby_pairing.dart';
import '../domain/models/sync_pairing.dart';
import '../domain/ports/sync_pairing.dart';
import '../domain/ports/sync_transport.dart';
import '../services/local_endpoints_service.dart';
import '../utils/peer_address.dart';

/// 跨设备同步的 UI 门面：控制面（身份 / 开关 / 观测）+ 引擎（轮次 / 报告）
/// + 备份（导出 / 导入）+ 恢复动作触发 + 策略转发。
///
/// 口令即信任根：显示/复制/重置都在控制面管理；UI 不直接接触引擎或状态存储。
/// 「什么时候自动同步」由 [SyncScheduler] 决定，本类只做转发；[syncNow]
/// 只服务恢复动作（添加手动对端 / 失败重试），首屏无手动同步入口。
class SyncProvider extends ChangeNotifier {
  SyncProvider({
    required SyncEngine engine,
    required SyncControlPlane controlPlane,
    required SyncBackup backup,
    SyncScheduler? scheduler,
    LocalNetworkPermission? lanPermission,
    LocalEndpointsService? localEndpoints,
    SyncCodecPort? codec,
    SyncPairingPort? pairing,
  })  : _engine = engine,
        _controlPlane = controlPlane,
        _backup = backup,
        _scheduler = scheduler,
        _lanPermission = lanPermission,
        _endpoints = localEndpoints ?? LocalEndpointsService(),
        _codec = codec,
        _pairing = pairing {
    _engine.addListener(notifyListeners);
    _controlPlane.addListener(notifyListeners);
  }

  final SyncEngine _engine;
  final SyncControlPlane _controlPlane;
  final SyncBackup _backup;
  final SyncScheduler? _scheduler;
  final LocalNetworkPermission? _lanPermission;

  /// 载荷编解码端口（生产 = worker isolate）：随 provider 释放。
  final SyncCodecPort? _codec;

  /// 局域网附近设备配对（Phase 2a 只暴露后端能力，UI 尚未接线）。
  final SyncPairingPort? _pairing;

  /// 本机地址枚举（设置页列表 / 配对码 / 探测候选三处共用；内部有缓存）。
  final LocalEndpointsService _endpoints;

  bool get enabled => _controlPlane.enabled;

  /// 是否有一轮同步正在跑（设置页据此显示「正在同步…」并避免重复触发）。
  bool get syncing => _engine.syncing;

  /// 是否注入了调度器（组合根断言用）。
  ///
  /// 生产接线必须注入调度器：自动同步、策略转发与打开同步页的检查轮都经它；
  /// 测试可以省略（省略时相关入口按无操作处理），但不能让生产漏接退化成
  /// 「只有手动同步」还无人发现。
  bool get hasScheduler => _scheduler != null;

  String get deviceId => _controlPlane.deviceId;
  String get deviceName => _controlPlane.deviceName;
  Map<SyncCategory, bool> get categories => _controlPlane.categories;
  Set<String> get enabledTransports => _controlPlane.enabledTransports;
  WebDavConfig get webdav => _controlPlane.webdav;
  int get lastSyncAt => _controlPlane.lastSyncAt;
  List<SyncLogEntry> get log => _controlPlane.log;

  /// 设备名册（不含本机；按最近接触时间倒序）。
  List<SyncPeerState> get peers => _controlPlane.peers;

  /// 手动对端地址簿（发现失败时的兜底）。
  List<ManualPeer> get manualPeers => _controlPlane.manualPeers;

  /// 本机局域网探测端口（分族 v4 / v6；0 = 该族未运行 / 不可用）。
  ///
  /// 设置页展示与配对码用：两族可独立降级（端口降级 / 单族不可用），
  /// 配对码里的每个候选地址按其地址族取对应端口。
  ({int v4, int v6}) get lanDiscoveryPorts => _controlPlane.lanDiscoveryPorts;

  /// 本机局域网直连端点端口（持久化的 HTTP 端口；0 = 尚未绑定过）。
  int get lanHttpPort => _controlPlane.lanHttpPort;

  /// 附近设备（`MSP/1` 候选；未注入配对端口时为空流）。
  Stream<List<SyncNearbyDevice>> get nearbyDevices =>
      _pairing?.nearbyDevices ?? Stream<List<SyncNearbyDevice>>.empty();

  /// 待用户确认的配对请求（同一时间只有一个）。
  Stream<SyncPairingRequest> get incomingPairingRequests =>
      _pairing?.incomingRequests ?? const Stream<SyncPairingRequest>.empty();

  /// 发起方配对尝试状态（确认码 / 等待 / 最终结局）。
  Stream<SyncPairingAttempt> get pairingAttempts =>
      _pairing?.attempts ?? const Stream<SyncPairingAttempt>.empty();

  /// 是否正在主动扫描附近设备。
  bool get scanningNearby => _pairing?.scanning ?? false;

  /// 本机是否已有同步组。
  ///
  /// 判据与配对服务一致：名册里有设备，或任一路传输曾经成功接触过对端。
  /// 只有自动生成、从未同步过的口令不算「已有同步组」——否则首次配对会被
  /// 误判成双方不同组。
  bool get hasGroup =>
      _controlPlane.peers.isNotEmpty ||
      transportLastSuccessAt(SyncTransportKind.lan) > 0 ||
      transportLastSuccessAt(SyncTransportKind.webdav) > 0;

  /// 开始扫描附近设备（同步页打开时调用；后台 / 蜂窝下返回 false）。
  Future<bool> startNearbyScan() async => await _pairing?.startScan() ?? false;

  /// 停止扫描并清空附近候选（同步页关闭时调用）。
  void stopNearbyScan() => _pairing?.stopScan();

  /// 向附近设备发起配对；UI 等待期间订阅 [pairingAttempts] 显示确认码。
  Future<SyncPairingResult> requestPairing(SyncNearbyDevice device) async {
    final pairing = _pairing;
    if (pairing == null) {
      return const SyncPairingResult(
        outcome: SyncPairingOutcome.unavailable,
      );
    }
    return pairing.requestPairing(device);
  }

  /// 接受 / 拒绝一条待确认请求。
  Future<SyncPairingOutcome> respondPairing(
    String requestId, {
    required bool accept,
  }) async {
    final pairing = _pairing;
    if (pairing == null) return SyncPairingOutcome.unavailable;
    return pairing.respond(requestId, accept: accept);
  }

  /// 取消发起方尚未完成的尝试。
  Future<void> cancelPairing(String requestId) async {
    await _pairing?.cancelPairing(requestId);
  }

  /// 设置页相对时间 / 失联判定用的本机时钟。
  int get nowMs => _controlPlane.nowMs();

  /// 失效本机地址缓存（设置页进入时调用；网络切换后重进即可看到新地址）。
  void refreshLocalEndpoints() => _endpoints.invalidate();

  /// 添加手动对端（非空地址；UI 已做格式校验，这里再兜一层）。
  ///
  /// 返回 false 表示该地址已存在（UI 据此提示「已更新」）。地址先归一
  /// （去方括号 / 空白），同一地址的不同文本写法不会落成两条。配对码导入
  /// 会一并带上设备身份与端点端口（[httpPort] / [deviceId]）。
  Future<bool> addManualPeer(
    String host, {
    String name = '',
    int probePort = 0,
    int httpPort = 0,
    String deviceId = '',
  }) async {
    final normalized = normalizePeerHost(host);
    if (normalized.isEmpty) return false;
    return _controlPlane.addManualPeer(ManualPeer(
      host: normalized,
      name: name.trim(),
      probePort: probePort,
      httpPort: httpPort,
      deviceId: deviceId,
    ));
  }

  /// 配对码里的地址逐个入簿，返回首个地址（供立即接触）。
  ///
  /// 码是**当时的权威地址集合**（同一设备的多条地址 = 双栈 / 多网卡候选，
  /// 全部保留）：该设备的旧地址条目被替换——内网 IP 变动后重新粘贴配对码
  /// 即完成换地址。一轮探测会覆盖全部地址簿条目，所以「立即接触」只需对
  /// 首个地址做一次；无可用地址返回 null（调用方给「码里没有地址」的提示）。
  Future<String?> importPairingAddresses(SyncPairingCode code) async {
    final addresses = [
      for (final address in code.addresses)
        ManualPeer(
          host: normalizePeerHost(address.host),
          probePort: address.probePort,
          httpPort: code.httpPort,
          deviceId: code.deviceId,
          name: code.deviceName,
        ),
    ].where((entry) => entry.host.isNotEmpty).toList();
    if (addresses.isEmpty) return null;
    await _controlPlane.adoptPeerAddresses(code.deviceId, addresses);
    return addresses.first.host;
  }

  /// 更新某条手动地址（设备详情里的「更新地址」）。
  ///
  /// 身份（deviceId）与已学到的端点端口保留：改的是「设备在哪」，不是「是谁」。
  Future<void> moveManualPeer(
    String fromHost, {
    required String toHost,
    int? probePort,
    String? name,
  }) =>
      _controlPlane.moveManualPeer(
        normalizePeerHost(fromHost),
        toHost: normalizePeerHost(toHost),
        probePort: probePort,
        name: name,
      );

  /// 组装本机配对信息（含口令）；未设置口令时返回 null。
  ///
  /// 地址候选 = 可路由本机地址 + **按地址族对应的**探测端口（v4 / v6 可独立
  /// 降级到不同端口，拿错族的端口对端打不通）；HTTP 端口来自持久化状态
  /// （对端拿到它就能纯 HTTP 直连，不依赖 UDP 发现）。
  Future<SyncPairingCode?> pairingCode() async {
    final passphrase = _controlPlane.passphrase;
    if (passphrase == null || passphrase.trim().isEmpty) return null;
    final endpoints = await _endpoints.list();
    final ports = lanDiscoveryPorts;
    return SyncPairingCode(
      deviceName: deviceName,
      deviceId: deviceId,
      passphrase: passphrase,
      addresses: [
        for (final endpoint in endpoints)
          SyncPairingAddress(
            host: endpoint.address,
            probePort: endpoint.isIpv6 ? ports.v6 : ports.v4,
          ),
      ],
      httpPort: lanHttpPort,
    );
  }

  /// 本机可路由地址（设置页地址列表展示用；服务内部缓存枚举结果）。
  Future<List<LocalEndpoint>> localEndpoints() => _endpoints.list();

  /// 移除手动对端。
  Future<void> removeManualPeer(String host) =>
      _controlPlane.removeManualPeer(host);

  /// 从本机列表移除一台设备（名册 + 地址簿条目）。
  ///
  /// 只清理本机观测，不撤销同步授权：对方仍持有口令并在线时会被下一轮
  /// 探测重新发现。真正停止与它同步需要更换口令。
  Future<void> removePeer(String deviceId) async {
    // 先清引擎内存名册，再落状态：避免正在收尾的一轮从旧名册写回。
    _engine.forgetPeer(deviceId);
    await _controlPlane.removePeer(deviceId);
  }

  /// 显式清理某台设备的远端文件（不做自动删除）。
  Future<({bool removed, SyncIssue? error})> cleanupRemote(String deviceId) =>
      _controlPlane.cleanupRemote(deviceId);

  /// 名册里已失联的设备（超过失联阈值无接触；只提示与提供处置动作）。
  List<SyncPeerState> get lostPeers {
    final now = _controlPlane.nowMs();
    return [
      for (final peer in peers)
        if (peer.isLostAt(now)) peer,
    ];
  }

  /// 立刻跑一轮并判断该手动地址是否接触成功。
  ///
  /// 判据：地址簿条目在本轮学到了设备身份，且名册里该设备是本轮接触的
  /// （`lastSeenAt` 不早于本轮开始）——只有本轮真正握手过才算成功。
  ///
  /// 返回 null = 本轮没有真正跑（进行中的轮次把请求排队 / 同步未启用）：
  /// 此时不下结论，调用方按「稍后」处理，等后续轮次给出结果。
  Future<bool?> contactManualPeer(String host) async {
    final startedAt = _controlPlane.nowMs();
    final previous = _engine.lastReport;
    await syncNow(manual: true);
    final report = _engine.lastReport;
    // 本轮没有真正跑：请求被排队时引擎原样返回上一轮报告（同一对象），
    // 轮次开始早于本次调用也同样不是本轮结果——两种情况都不下结论。
    if (report == null ||
        identical(report, previous) ||
        report.startedAt < startedAt) {
      return null;
    }
    ManualPeer? entry;
    for (final peer in manualPeers) {
      if (peer.host == host) {
        entry = peer;
        break;
      }
    }
    final deviceId = entry?.deviceId ?? '';
    if (deviceId.isEmpty) return false;
    return report.peers.any(
      (peer) => peer.deviceId == deviceId && peer.lastSeenAt >= startedAt,
    );
  }

  /// 局域网权限门（Android 17+ 需要；其它平台恒为允许）。
  bool get lanPermissionNeeded => _lanPermission?.needsPermission ?? false;

  /// 权限被永久拒绝（系统不再弹窗）：UI 的动作是「去系统设置」。
  bool get lanPermissionPermanentlyDenied =>
      _lanPermission?.permanentlyDenied ?? false;

  /// 显式申请局域网权限（用户点「授予权限」）；授予后重启局域网传输。
  ///
  /// 先 `refresh` 再申请：用户可能刚在系统设置里开过权限，缓存状态会过时。
  Future<bool> requestLanPermission() async {
    final permission = _lanPermission;
    if (permission == null) return true;
    if (!await permission.refresh()) await permission.ensure(retry: true);
    final granted = permission.granted;
    if (granted) await setTransportEnabled(SyncTransportKind.lan, true);
    notifyListeners();
    return granted;
  }

  /// 跳系统设置（权限被永久拒绝时的唯一出路）。
  Future<void> openSystemSettings() async {
    await _lanPermission?.openSystemSettings();
  }

  /// 最近一轮完整结果；null = 本次进程内还没跑过。
  SyncRoundReport? get lastReport => _engine.lastReport;

  /// 首次连通通知（应用壳消费：每台设备只在第一次真正交换数据后发一次，
  /// 持久化在同步状态里，重启不重复）。
  Stream<SyncPeerState> get peerConnectedNotices =>
      _engine.peerConnectedNotices;

  /// 最近一轮的结论（UI 状态用语）。
  SyncOutcome? get lastOutcome => _engine.lastReport?.outcome;

  /// 传输状态（开关开着但不可用时给出原因）；未知 kind 返回 null。
  SyncTransportReport? transportStatus(String kind) =>
      _controlPlane.transportStatus(kind);

  /// 传输最近一次成功接触对端的时间（0 = 尚未成功过）。
  int transportLastSuccessAt(String kind) =>
      _controlPlane.transportLastSuccessAt(kind);

  /// 完整同步口令（显示与复制用；调用方负责提示妥善保管）。
  String? get passphrase => _controlPlane.passphrase;

  /// 打码口令（设置行副标题用；保留首组便于用户核对自己输入的是哪台）。
  String get maskedPassphrase => _controlPlane.maskedPassphrase;

  Future<void> init() async {
    await _controlPlane.init();
    await _engine.init();
    // 口令即设备身份：初始化就绪，配对码 / 配对信息随时可分享。生成口令没有
    // 网络副作用，不依赖任何传输开关——没有总开关后，不能等「首次开启同步」
    // 才生成（否则配对卡片会指向一个不存在的口令）。
    //
    // 无钥匙串的环境（WSLg / 容器）写入会抛：按「未设置」降级继续，可选子
    // 系统的故障不允许阻断启动（与 `SecureSettingsSecretStore.read` 的容错
    // 同一契约，见 docs/pitfalls.md #31）。
    try {
      await _controlPlane.ensurePassphrase();
    } catch (e) {
      debugPrint('[Molia] 同步口令初始化失败（按未设置继续）: $e');
    }
    await _controlPlane.readPassphrase();
    notifyListeners();
  }

  /// 启动已启用的传输（首帧后调用；幂等）。
  Future<void> startTransports() => _controlPlane.startTransports();

  /// 开 / 关一路传输（开关即总闸：两路都关 = 同步完全停）。
  ///
  /// 开传输即启用同步：口令在这里兜一层（正常已由 [init] 生成；init 异常降级
  /// 的路径也能补上），保证「开传输 → 配对 → 分享码」的链路不缺口令。
  Future<void> setTransportEnabled(String kind, bool value) async {
    if (value) await _controlPlane.ensurePassphrase();
    await _controlPlane.setTransportEnabled(kind, value);
  }

  Future<void> setCategory(SyncCategory category, bool value) =>
      _controlPlane.setCategory(category, value);

  Future<void> setDeviceName(String value) =>
      _controlPlane.setDeviceName(value);

  Future<void> setWebdavConfig(WebDavConfig config) =>
      _controlPlane.setWebdavConfig(config);

  Future<void> setWebdavPassword(String password) =>
      _controlPlane.writeWebdavPassword(password);

  Future<String?> readWebdavPassword() => _controlPlane.readWebdavPassword();

  /// 输入已有口令加入同步（归一化后保存；无效输入抛 [ArgumentError]）。
  Future<void> joinWithPassphrase(String raw) async {
    final normalized = SyncPassphrase.normalize(raw);
    if (normalized.length < 16) {
      throw ArgumentError('口令过短');
    }
    await _controlPlane.setPassphrase(normalized);
  }

  /// 重置口令：所有设备需重新输入新口令。
  Future<String> resetPassphrase() => _controlPlane.resetPassphrase();

  /// 跑一轮同步。
  ///
  /// 首屏不再暴露手动主操作；[manual] 只服务恢复动作（添加手动对端、
  /// 日志失败弹层的重试）。引擎自带排队：进行中的轮次结束后会补跑。
  Future<SyncRoundReport?> syncNow({bool manual = false}) async {
    final scheduler = _scheduler;
    if (manual && scheduler != null) {
      // 手动触发经调度器（不受省电 / 蜂窝暂停策略限制）。
      await scheduler.syncNow();
      return _engine.lastReport;
    }
    return await _engine.syncNow(
      trigger: manual ? SyncTrigger.manual : SyncTrigger.timer,
    );
  }

  /// 打开同步页时检查连接状态：经调度器（省电 / 蜂窝暂停 / 同步关闭时不跑）。
  ///
  /// 未注入调度器（测试 / 非生产接线）时什么都不做：直接跑引擎会绕过策略，
  /// 这里不提供那条隐式后门。
  Future<void> checkConnections() async {
    await _scheduler?.checkNow();
  }

  /// 启动后首轮（音源仓库就绪后调用）：受等级策略约束（省电 / 移动数据暂停
  /// 时不跑；移动数据下只同步小类别）。
  Future<void> startupSync() async {
    final scheduler = _scheduler;
    if (scheduler != null) {
      await scheduler.syncStartup();
      return;
    }
    if (_controlPlane.enabled) {
      await _engine.syncNow(trigger: SyncTrigger.startup);
    }
  }

  /// 导出完整备份 JSON（数据与存储页使用；凭证类默认排除）。
  Future<String> exportBackupJson({bool includeCredentials = false}) =>
      _backup.exportBackupJson(includeCredentials: includeCredentials);

  /// 导入完整备份（与本地数据逐键 LWW 合并）。
  ///
  /// 备份模块不持有 listener：导入落地后由 provider 统一通知 UI。
  Future<SyncApplyOutcome> importBackupJson(
    String json, {
    bool includeCredentials = false,
  }) async {
    final outcome = await _backup.importBackupJson(
      json,
      includeCredentials: includeCredentials,
    );
    notifyListeners();
    return outcome;
  }

  /// 数据变更通知（资料库 / 统计 / 音源 / 设置与凭证 / 会话）。
  ///
  /// 活跃等级去抖 3–5s 后跑一轮；空闲 / 后台 / 省电等级只标记待外发，
  /// 等下次唤醒或回前台。高频写入（会话进度）用 `immediate: false`：
  /// 只标记、不排即时轮次。
  void notifyLocalChange({
    Set<SyncCategory>? categories,
    bool immediate = true,
  }) =>
      _scheduler?.notifyLocalChange(
        categories: categories,
        immediate: immediate,
      );

  /// 用户交互（界面操作）。
  void notifyInteraction() => _scheduler?.notifyInteraction();

  /// 回到前台：先让已启用的局域网传输恢复（重绑 / 公告），再拉一次
  /// （有本地变更时一并推送）。
  Future<void> onAppResumed() async {
    await _controlPlane.onAppResumed();
    _scheduler?.onAppVisible();
  }

  /// 退后台 / 锁屏：先让传输停止发现（公告 / 重连计时器），再取消调度器
  /// 定时器并尽力推一次——pause 轮只走已知端点 HTTP，不再广播。
  void onAppHidden() {
    _controlPlane.onAppHidden();
    _scheduler?.onAppHidden();
  }

  /// 当前同步等级（未注入调度器时为 null）。
  SyncLevel? get syncLevel => _scheduler?.level;

  /// 近 24 小时活动汇总（独立于展示日志的 20 条上限）。
  SyncActivitySummary get activity24h => SyncActivitySummary.fromEntries(
        _controlPlane.activity,
        nowMs: _controlPlane.nowMs(),
      );

  /// 当前是否在移动数据上（观测面展示用）。
  bool get onCellular => _scheduler?.onCellular ?? false;

  /// 省电等级是否生效（低电量未充电或系统省电模式）。
  bool get powerSaveActive => _scheduler?.powerSaveActive ?? false;

  /// 蜂窝网络下的自动同步策略。
  SyncCellularPolicy get cellularPolicy => _controlPlane.cellularPolicy;

  Future<void> setCellularPolicy(SyncCellularPolicy value) =>
      _controlPlane.setCellularPolicy(value);

  @override
  void dispose() {
    // 先摘掉监听再释放被监听对象：调度器 / 引擎在销毁路径里仍可能通知，
    // 已 dispose 的 provider 不应再把通知转发给 UI。
    _engine.removeListener(notifyListeners);
    _controlPlane.removeListener(notifyListeners);
    _scheduler?.dispose();
    // 配对服务随 provider 释放：清 pending 临时密钥并关闭流。
    unawaited(_pairing?.dispose() ?? Future<void>.value());
    // worker isolate 随 provider 释放（进程退出前不留常驻 isolate）。
    unawaited(_codec?.dispose() ?? Future<void>.value());
    super.dispose();
  }
}
