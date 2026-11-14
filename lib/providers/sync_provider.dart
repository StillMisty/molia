import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/sync/sync_activity.dart';
import '../data/sync/sync_adapter.dart';
import '../data/sync/sync_backup.dart';
import '../data/sync/sync_codec_port.dart';
import '../data/sync/sync_control_plane.dart';
import '../data/sync/sync_engine.dart';
import '../data/sync/sync_scheduler.dart';
import '../data/sync/sync_state_codec.dart';
import '../data/sync/transport/local_network_permission.dart';
import '../domain/models/device_sync.dart';
import '../domain/models/sync_nearby_pairing.dart';
import '../domain/ports/sync_pairing.dart';
import '../domain/ports/sync_transport.dart';
import '../services/local_endpoints_service.dart';
import '../services/manual_peer_service.dart';
import '../services/sync_trigger_bridge.dart';
import 'sync_commands.dart';
import 'sync_nearby_availability.dart';
import 'sync_peer_view.dart';
import 'sync_ui_state.dart';

export '../services/manual_peer_service.dart' show SyncManualPeerOutcome;

/// 跨设备同步的 Provider 树绑定：UI 只读 [state]、只写 [commands]。
///
/// 口令即信任根：显示/复制/重置都在控制面管理；UI 不直接接触引擎或状态存储。
/// 「什么时候自动同步」由 [SyncScheduler] 决定；本类只保留应用生命周期入口
/// （[init] / [startTransports] / [startupSync] / [onAppResumed] /
/// [onAppHidden]）与两个窄面：
/// - [state]：每次通知后重建的不可变 UI 投影（transports 用类型化枚举）；
/// - [commands]：低频用户动作，按配对 / 附近扫描 / 备份 / 地址读取分组。
///
/// 手动恢复动作仍直接走引擎（添加手动对端 / 失败重试 / 配对成功）：手动请求
/// 一律加入引擎的轮次链并等补跑轮，不经调度器，也不提供首屏「立即同步」。
class SyncProvider extends ChangeNotifier
    implements
        SyncCommands,
        SyncPairingCommands,
        SyncNearbyCommands,
        SyncBackupCommands,
        SyncLocalEndpointsCommands {
  SyncProvider({
    required this._engine,
    required this._controlPlane,
    required this._backup,
    this._scheduler,
    this._lanPermission,
    LocalEndpointsService? localEndpoints,
    this._codec,
    this._pairing,
    this._triggers,
  }) : _endpoints = localEndpoints ?? LocalEndpointsService() {
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

  /// 局域网附近设备配对（`MSP/1` 发现 + `/pair/*` 请求）。
  final SyncPairingPort? _pairing;

  /// 本机地址枚举（设置页列表 / 附近设备探测候选共用；内部有缓存）。
  final LocalEndpointsService _endpoints;

  /// 本地变更触发桥：provider 持有其生命周期，dispose 时统一取消订阅。
  final SyncTriggerBridge? _triggers;

  late final ManualPeerService _manualPeerService = ManualPeerService(
    manualPeers: () => _controlPlane.manualPeers,
    addManualPeer: _controlPlane.addManualPeer,
    moveManualPeer: (fromHost, {required toHost, probePort, name}) =>
        _controlPlane.moveManualPeer(
          fromHost,
          toHost: toHost,
          probePort: probePort,
          name: name,
        ),
    probeAddress: (host, {probePort = 0}) async {
      final pairing = _pairing;
      if (pairing == null) return false;
      return pairing.probeAddress(host, probePort: probePort);
    },
    syncNow: syncNow,
  );

  /// UI 只读的不可变投影：每次读取按当前快照重建（纯计算、廉价）。
  SyncUiState get state {
    final nowMs = _controlPlane.nowMs();
    final ports = _controlPlane.lanDiscoveryPorts;
    final transportStates = <SyncTransportId, SyncTransportUiState>{
      for (final id in SyncTransportId.values) id: _transportState(id),
    };
    final lan = transportStates[SyncTransportId.lan]!;
    final permissionNeedsAttention = _lanPermissionNeedsAttention(lan);
    final peers = _controlPlane.peers;
    final manualPeers = _controlPlane.manualPeers;
    final lastReport = _engine.lastReport;
    final onCellular = _scheduler?.onCellular ?? false;
    final powerSaveActive = _scheduler?.powerSaveActive ?? false;
    final nearbyAvailability = resolveSyncNearbyAvailability(
      lanEnabled: lan.enabled,
      // 传输自己报告权限被拒时也算：启动路径可能还没让权限门记下
      // `needsUserAction`，但「开关已开、传输没起来」的原因是缺权限。
      permissionDenied:
          permissionNeedsAttention ||
          lan.unavailableReason == SyncUnavailableReason.permissionDenied,
      transportUnavailable:
          !lan.configured || !lan.running || lan.unavailableReason != null,
      discoveryAvailable: ports.v4 > 0 || ports.v6 > 0,
      onCellular: onCellular,
      powerSaveActive: powerSaveActive,
    );
    return SyncUiState(
      enabled: _controlPlane.enabled,
      syncing: _engine.syncing,
      deviceId: _controlPlane.deviceId,
      deviceName: _controlPlane.deviceName,
      categories: Map<SyncCategory, bool>.unmodifiable(
        _controlPlane.categories,
      ),
      enabledTransports: Set<SyncTransportId>.unmodifiable({
        for (final entry in transportStates.entries)
          if (entry.value.enabled) entry.key,
      }),
      transports: Map<SyncTransportId, SyncTransportUiState>.unmodifiable(
        transportStates,
      ),
      webdav: _controlPlane.webdav,
      log: List<SyncLogEntry>.unmodifiable(_controlPlane.log),
      peers: List<SyncPeerState>.unmodifiable(peers),
      manualPeers: List<ManualPeer>.unmodifiable(manualPeers),
      peerView: SyncPeerView.from(
        peers: peers,
        manualPeers: manualPeers,
        lastReport: lastReport,
        nowMs: nowMs,
      ),
      lanDiscoveryPorts: ports,
      lanHttpPort: _controlPlane.lanHttpPort,
      nearbyAvailability: nearbyAvailability,
      nearbyDevices:
          _pairing?.nearbyDevices ??
          const Stream<List<SyncNearbyDevice>>.empty(),
      incomingPairingRequests:
          _pairing?.incomingRequests ??
          const Stream<SyncPairingRequest>.empty(),
      pairingAttempts:
          _pairing?.attempts ?? const Stream<SyncPairingAttempt>.empty(),
      peerConnectedNotices: _engine.peerConnectedNotices,
      scanningNearby: _pairing?.scanning ?? false,
      hasGroup: _controlPlane.hasEstablishedGroup,
      nowMs: nowMs,
      lastReport: lastReport,
      lanPermissionNeeded: _lanPermission?.needsPermission ?? false,
      lanPermissionPermanentlyDenied:
          _lanPermission?.permanentlyDenied ?? false,
      lanPermissionNeedsAttention: permissionNeedsAttention,
      canCheckNow: _scheduler?.canRunAutomatically ?? false,
      syncLevel: _scheduler?.level,
      activity24h: SyncActivitySummary.fromEntries(
        _controlPlane.activity,
        nowMs: nowMs,
      ),
      onCellular: onCellular,
      powerSaveActive: powerSaveActive,
      cellularPolicy: _controlPlane.cellularPolicy,
      passphrase: _controlPlane.passphrase,
      maskedPassphrase: _controlPlane.maskedPassphrase,
    );
  }

  /// 用户动作面；UI 只经这里改状态。
  SyncCommands get commands => this;

  @override
  SyncPairingCommands get pairing => this;

  @override
  SyncNearbyCommands get nearby => this;

  @override
  SyncBackupCommands get backup => this;

  @override
  SyncLocalEndpointsCommands get endpoints => this;

  SyncTransportUiState _transportState(SyncTransportId id) {
    final status = _controlPlane.transportStatus(id.kind);
    return SyncTransportUiState(
      id: id,
      configured: status != null,
      enabled: status?.enabled ?? false,
      running: status?.running ?? false,
      unavailableReason: status?.unavailableReason,
      error: status?.error,
      lastSuccessAt: _controlPlane.transportLastSuccessAt(id.kind),
    );
  }

  /// 局域网权限需要用户处理：设置页据此显示常驻警告行（桌面歌词同款）。
  ///
  /// 除了权限门自己的状态，还兼容「状态尚未复查、但传输已因权限不可用」：
  /// 启动时局域网已开启的路径由后台传输过门，页面等一次状态刷新即可看到。
  bool _lanPermissionNeedsAttention(SyncTransportUiState lan) {
    final permission = _lanPermission;
    if (permission == null || !permission.needsPermission) return false;
    if (permission.needsUserAction) return true;
    return lan.enabled &&
        lan.unavailableReason == SyncUnavailableReason.permissionDenied;
  }

  /// 开 / 关一路传输（开关即总闸：两路都关 = 同步完全停）。
  ///
  /// 开传输即启用同步：口令在这里兜一层（正常已由 [init] 生成；init 异常降级
  /// 的路径也能补上），保证「开传输 → 附近设备配对」的链路不缺口令。
  ///
  /// 返回 false 只表示本次「打开」被局域网权限拦下（开关应保持关闭）；
  /// 权限已授予但传输启动失败仍返回 true，失败由开关副文案与日志呈现。
  @override
  Future<bool> setTransportEnabled(SyncTransportId id, bool value) async {
    final kind = id.kind;
    if (value && kind == SyncTransportKind.lan) {
      final permission = _lanPermission;
      if (permission != null && permission.needsPermission) {
        var granted = false;
        try {
          granted = await permission.ensure(retry: true);
        } catch (e) {
          debugPrint('[Molia] 申请局域网权限失败: $e');
        }
        if (!granted) {
          // 未授权不假装开启：立刻回到关闭，UI 用底栏 + 常驻警告行引导授权。
          await _applyTransportEnabled(kind, false);
          return false;
        }
      }
    }
    await _applyTransportEnabled(kind, value);
    return true;
  }

  /// 控制面写入 + 口令兜底（不经过权限门，供授权成功后的启用路径复用）。
  ///
  /// 打开传输成功后立刻排一次 check 轮：用户刚打开局域网 / WebDAV 时最关心
  /// 「现在能不能连上」，不必等下一次空闲唤醒；仍走调度器，省电 / 移动数据
  /// 暂停 / 同步关闭时由调度器自己拦住。关闭传输不触发。
  ///
  /// WebDAV 未配置时不检查：打开开关后紧接着会进配置弹层，此时跑一轮必然
  /// 以 `not_configured` 失败，没有信息量。
  Future<void> _applyTransportEnabled(String kind, bool value) async {
    if (value) await _controlPlane.ensurePassphrase();
    await _controlPlane.setTransportEnabled(kind, value);
    if (!value) return;
    final shouldCheck =
        kind == SyncTransportKind.lan ||
        (kind == SyncTransportKind.webdav && _controlPlane.webdav.isConfigured);
    if (shouldCheck) unawaited(_scheduler?.checkNow());
  }

  /// 显式申请局域网权限（用户点「去授权」）；授予后启用局域网传输。
  @override
  Future<bool> requestLanPermission() async {
    final permission = _lanPermission;
    if (permission == null) return true;
    var granted = false;
    try {
      granted = await permission.ensure(retry: true);
    } catch (e) {
      debugPrint('[Molia] 申请局域网权限失败: $e');
    }
    if (granted) await _applyTransportEnabled(SyncTransportKind.lan, true);
    notifyListeners();
    return granted;
  }

  /// 跳系统设置（权限被永久拒绝时的唯一出路）。
  @override
  Future<void> openSystemSettings() async {
    await _lanPermission?.openSystemSettings();
  }

  /// 一次写入 WebDAV 配置与密码（配置弹层的唯一保存入口）。
  ///
  /// 分两步写时，配置先落地会让已启用的 WebDAV 用「新地址 + 旧密码」跑一轮
  /// 必然失败的检查；保存完成后才排一次 check 轮。未启用 / 未配置不触发。
  @override
  Future<void> saveWebdavConfig(WebDavConfig config, String password) async {
    await _controlPlane.setWebdavConfig(config);
    await _controlPlane.writeWebdavPassword(password);
    if (_controlPlane.enabledTransports.contains(SyncTransportKind.webdav) &&
        _controlPlane.webdav.isConfigured) {
      unawaited(_scheduler?.checkNow());
    }
  }

  @override
  Future<String?> readWebdavPassword() => _controlPlane.readWebdavPassword();

  @override
  Future<void> setCategory(SyncCategory category, bool value) async {
    await _controlPlane.setCategory(category, value);
    // 打开类别立即排一轮：已有本地数据（尤其自定义封面）不必等空闲退避。
    if (value) {
      final triggers = _triggers;
      if (triggers != null) {
        triggers.localChange(categories: {category});
      } else {
        _scheduler?.notifyLocalChange(categories: {category});
      }
    }
  }

  @override
  Future<void> setCellularPolicy(SyncCellularPolicy value) =>
      _controlPlane.setCellularPolicy(value);

  @override
  Future<void> setDeviceName(String value) =>
      _controlPlane.setDeviceName(value);

  /// 重置口令：所有设备需重新输入新口令。
  @override
  Future<String> resetPassphrase() => _controlPlane.resetPassphrase();

  /// 手动地址表单的唯一命令：地址入簿 → 附近设备探测 → 立即接触。
  ///
  /// 编排（地址归一 / 配对探测 / 增移 / 报告解读）已收进
  /// [ManualPeerService]；这里只保留 UI 命令入口。
  @override
  Future<SyncManualPeerOutcome> saveManualPeer({
    required String host,
    int probePort = 0,
    String name = '',
    ManualPeer? editing,
  }) => _manualPeerService.save(
    host: host,
    probePort: probePort,
    name: name,
    editing: editing,
  );

  /// 供恢复动作 / 测试直接核对某地址；UI 不直接调用（表单走 [saveManualPeer]）。
  Future<bool?> contactManualPeer(String host) =>
      _manualPeerService.contact(host);

  /// 移除手动对端。
  @override
  Future<void> removeManualPeer(String host) =>
      _controlPlane.removeManualPeer(host);

  /// 从本机列表移除一台设备（名册 + 地址簿条目）。
  ///
  /// 只清理本机观测，不撤销同步授权：对方仍持有口令并在线时会被下一轮
  /// 探测重新发现。真正停止与它同步需要更换口令。
  @override
  Future<void> removePeer(String deviceId) async {
    // 先清引擎内存名册，再落状态：避免正在收尾的一轮从旧名册写回。
    _engine.forgetPeer(deviceId);
    await _controlPlane.removePeer(deviceId);
  }

  /// 显式清理某台设备的远端文件（不做自动删除）。
  @override
  Future<({bool removed, SyncIssue? error})> cleanupRemote(String deviceId) =>
      _controlPlane.cleanupRemote(deviceId);

  /// 跑一轮手动同步。
  ///
  /// 首屏没有手动主操作；这里只服务恢复动作（添加手动对端、日志失败弹层的
  /// 重试、配对成功后立即收敛）。手动请求始终直接走引擎：注入调度器时也不
  /// 经它，避免同一个用户动作有时等补跑轮、有时立刻拿到 null。
  ///
  /// 手动轮是**全量比对轮**：显式请求允许 anti-entropy，对端指纹分歧时取一次
  /// 全量快照修复静默分歧。返回**本次请求所加入的那一轮**报告：在途轮次上的
  /// 请求并入补跑轮并等该轮结束。null 只表示同步关闭 / 没有传输（没有一轮真正
  /// 跑），不表示另有轮次在跑。
  @override
  Future<SyncRoundReport?> syncNow() async {
    return await _engine.syncNow(
      trigger: SyncTrigger.manual,
      antiEntropy: true,
    );
  }

  /// 打开同步页时检查连接状态：经调度器（省电 / 蜂窝暂停 / 同步关闭时不跑）。
  @override
  Future<void> checkConnections() async {
    await _scheduler?.checkNow();
  }

  @override
  Future<bool> start() async => await _pairing?.startScan() ?? false;

  @override
  void stop() => _pairing?.stopScan();

  @override
  Future<SyncPairingResult> request(SyncNearbyDevice device) async {
    final pairing = _pairing;
    if (pairing == null) {
      return const SyncPairingResult(outcome: SyncPairingOutcome.unavailable);
    }
    return pairing.requestPairing(device);
  }

  @override
  Future<SyncPairingOutcome> respond(
    String requestId, {
    required bool accept,
  }) async {
    final pairing = _pairing;
    if (pairing == null) return SyncPairingOutcome.unavailable;
    return pairing.respond(requestId, accept: accept);
  }

  @override
  Future<void> cancel(String requestId) async {
    await _pairing?.cancelPairing(requestId);
  }

  /// 导出完整备份 JSON（数据与存储页使用；默认含全部凭证，保证换机一致）。
  @override
  Future<String> exportJson({bool includeCredentials = true}) =>
      _backup.exportBackupJson(includeCredentials: includeCredentials);

  @override
  Future<String> exportPlaylistJson({
    required String playlistSyncId,
    String? coverKey,
  }) => _backup.exportPlaylistJson(
    playlistSyncId: playlistSyncId,
    coverKey: coverKey,
  );

  /// 导入完整备份（与本地数据逐键 LWW 合并）。
  ///
  /// 备份模块不持有 listener：导入落地后由 provider 统一通知 UI。
  @override
  Future<SyncApplyOutcome> importJson(
    String json, {
    bool includeCredentials = true,
  }) async {
    final outcome = await _backup.importBackupJson(
      json,
      includeCredentials: includeCredentials,
    );
    notifyListeners();
    return outcome;
  }

  @override
  Future<List<LocalEndpoint>> list() => _endpoints.list();

  @override
  void refresh() => _endpoints.invalidate();

  // 应用生命周期（组合根 / 首帧收尾调用，不属于 UI 动作）。

  Future<void> init() async {
    await _controlPlane.init();
    await _engine.init();
    // 口令即设备身份：初始化就绪，附近设备配对随时可用。生成口令没有网络
    // 副作用，也不依赖任何传输开关——既然没有总开关，就不能等「首次开启
    // 同步」才生成（否则配对请求会指向一个不存在的口令）。
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

  /// 用户交互（界面操作）：续期调度器活跃窗口。
  void notifyInteraction() => _scheduler?.notifyInteraction();

  /// 回到前台：先让已启用的局域网传输恢复（重绑 / 公告），复查权限，
  /// 再拉一次（有本地变更时一并推送）。
  Future<void> onAppResumed() async {
    await _controlPlane.onAppResumed();
    await _refreshLanPermissionIfKnown();
    _scheduler?.onAppVisible();
  }

  /// 回前台复查权限（不弹窗）。
  ///
  /// 只在局域网已开启或本会话已申请过时查询：避免首次启动就把「未申请」
  /// 误判成「被拒」并常驻警告行。授权后立刻启动已启用的局域网传输；
  /// 警告行 / 权限状态由 [notifyListeners] 更新。
  Future<void> _refreshLanPermissionIfKnown() async {
    final permission = _lanPermission;
    if (permission == null || !permission.needsPermission) return;
    final lanEnabled = _controlPlane.enabledTransports.contains(
      SyncTransportKind.lan,
    );
    if (!lanEnabled && !permission.needsUserAction) return;
    try {
      await permission.refresh();
    } catch (e) {
      debugPrint('[Molia] 复查局域网权限失败: $e');
      return;
    }
    if (permission.granted && lanEnabled) {
      try {
        await startTransports();
      } catch (e) {
        debugPrint('[Molia] 授权后启动局域网传输失败: $e');
      }
      // 这里不单独排 check 轮：onAppResumed 随后调用 onAppVisible()，resume
      // 轮会覆盖这次启用；再排一个 check 会和它争 `_roundRunning`，并丢掉
      // 零对端时 resume 轮 arm 的重连阶梯。
    }
    notifyListeners();
  }

  /// 退后台 / 锁屏：先让传输停止发现（公告 / 重连计时器），再取消调度器
  /// 定时器并尽力推一次——pause 轮只走已知端点 HTTP，不再广播。
  void onAppHidden() {
    _controlPlane.onAppHidden();
    _scheduler?.onAppHidden();
  }

  @override
  void dispose() {
    // 先摘掉监听再释放被监听对象：调度器 / 引擎在销毁路径里仍可能通知，
    // 已 dispose 的 provider 不应再把通知转发给 UI。
    _engine.removeListener(notifyListeners);
    _controlPlane.removeListener(notifyListeners);
    // 触发桥先于调度器释放：取消流订阅 / 恢复设置与回调钩子。
    _triggers?.dispose();
    _scheduler?.dispose();
    // 配对服务随 provider 释放：清 pending 临时密钥并关闭流。
    unawaited(_pairing?.dispose() ?? Future<void>.value());
    // worker isolate 随 provider 释放（进程退出前不留常驻 isolate）。
    unawaited(_codec?.dispose() ?? Future<void>.value());
    super.dispose();
  }
}
