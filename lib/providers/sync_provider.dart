import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/sync/sync_engine.dart';
import '../data/sync/sync_passphrase.dart';
import '../data/sync/sync_scheduler.dart';
import '../data/sync/sync_state_store.dart';
import '../data/sync/transport/local_network_permission.dart';
import '../domain/models/device_sync.dart';
import '../domain/ports/sync_transport.dart';

/// 跨设备同步的 UI 门面：引擎状态 + 口令管理 + 手动同步 + 触发策略转发。
///
/// 口令即信任根：显示/复制/重置都在这里管理；UI 不直接接触引擎。
/// 「什么时候自动同步」由 [SyncScheduler] 决定，本类只做转发（不再自带
/// 去抖定时器）。
class SyncProvider extends ChangeNotifier {
  SyncProvider({
    required SyncEngine engine,
    SyncScheduler? scheduler,
    LocalNetworkPermission? lanPermission,
  })  : _engine = engine,
        _scheduler = scheduler,
        _lanPermission = lanPermission {
    _engine.addListener(notifyListeners);
  }

  final SyncEngine _engine;
  final SyncScheduler? _scheduler;
  final LocalNetworkPermission? _lanPermission;

  String? _passphrase;
  bool _busy = false;

  SyncEngine get engine => _engine;

  /// 同步调度器（未注入时为 null：UI 只做手动同步）。
  SyncScheduler? get scheduler => _scheduler;

  bool get enabled => _engine.state.enabled;
  bool get syncing => _busy || _engine.syncing;
  String get deviceId => _engine.state.deviceId;
  String get deviceName => _engine.state.deviceName;
  Map<SyncCategory, bool> get categories => _engine.state.categories;
  Set<String> get enabledTransports => _engine.state.enabledTransports;
  WebDavConfig get webdav => _engine.state.webdav;
  int get lastSyncAt => _engine.state.lastSyncAt;
  List<SyncLogEntry> get log => _engine.state.log;

  /// 设备名册（不含本机；按最近接触时间倒序）。
  List<SyncPeerState> get peers => _engine.state.peers;

  /// 手动对端地址簿（发现失败时的兜底）。
  List<ManualPeer> get manualPeers => _engine.state.manualPeers;

  /// 添加手动对端（非空地址；UI 已做格式校验，这里再兜一层）。
  ///
  /// 返回 false 表示该地址已存在（UI 据此提示「已更新」）。
  Future<bool> addManualPeer(
    String host, {
    String name = '',
    int probePort = 0,
  }) async {
    final trimmed = host.trim();
    if (trimmed.isEmpty) return false;
    return _engine.addManualPeer(ManualPeer(
      host: trimmed,
      name: name.trim(),
      probePort: probePort,
    ));
  }

  /// 移除手动对端。
  Future<void> removeManualPeer(String host) =>
      _engine.removeManualPeer(host);

  /// 立刻跑一轮并判断该手动地址是否接触成功。
  ///
  /// 判据：地址簿条目在本轮学到了设备身份，且名册里该设备是本轮接触的
  /// （`lastSeenAt` 不早于本轮开始）——只有本轮真正握手过才算成功。
  Future<bool> contactManualPeer(String host) async {
    final startedAt = _engine.state.nowMs();
    await syncNow(manual: true);
    final report = _engine.lastReport;
    if (report == null) return false;
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
    if (granted) await _engine.setTransportEnabled(SyncTransportKind.lan, true);
    notifyListeners();
    return granted;
  }

  /// 跳系统设置（权限被永久拒绝时的唯一出路）。
  Future<void> openSystemSettings() async {
    await _lanPermission?.openSystemSettings();
  }

  /// 最近一轮完整结果；null = 本次进程内还没跑过。
  SyncRoundReport? get lastReport => _engine.lastReport;

  /// 最近一轮的结论（UI 状态用语）。
  SyncOutcome? get lastOutcome => _engine.lastReport?.outcome;

  /// 传输状态（开关开着但不可用时给出原因）；未知 kind 返回 null。
  SyncTransportReport? transportStatus(String kind) =>
      _engine.transportStatus(kind);

  /// 传输最近一次成功接触对端的时间（0 = 尚未成功过）。
  int transportLastSuccessAt(String kind) =>
      _engine.state.transportLastSuccessAt(kind);

  /// 完整同步口令（显示与复制用；调用方负责提示妥善保管）。
  String? get passphrase => _passphrase;

  /// 打码口令（设置行副标题用；保留首组便于用户核对自己输入的是哪台）。
  String get maskedPassphrase {
    final value = _passphrase;
    if (value == null || value.isEmpty) return '';
    final chars = value.split('');
    for (var i = 0; i < chars.length; i++) {
      if (chars[i] == '-') continue;
      if (i < 4) continue;
      chars[i] = '*';
    }
    return chars.join();
  }

  Future<void> init() async {
    await _engine.init();
    _passphrase = await _engine.readPassphrase();
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (value) await _engine.ensurePassphrase();
    await _engine.setEnabled(value);
    _passphrase = await _engine.readPassphrase();
    notifyListeners();
  }

  Future<void> setCategory(SyncCategory category, bool value) =>
      _engine.setCategory(category, value);

  Future<void> setTransportEnabled(String kind, bool value) =>
      _engine.setTransportEnabled(kind, value);

  Future<void> setDeviceName(String value) => _engine.setDeviceName(value);

  Future<void> setWebdavConfig(WebDavConfig config) =>
      _engine.setWebdavConfig(config);

  Future<void> setWebdavPassword(String password) async {
    await _engine.state.writeWebdavPassword(password);
    notifyListeners();
  }

  Future<String?> readWebdavPassword() => _engine.state.readWebdavPassword();

  /// 输入已有口令加入同步（归一化后保存；无效输入抛 [ArgumentError]）。
  Future<void> joinWithPassphrase(String raw) async {
    final normalized = SyncPassphrase.normalize(raw);
    if (normalized.length < 16) {
      throw ArgumentError('口令过短');
    }
    await _engine.setPassphrase(normalized);
    _passphrase = normalized;
    notifyListeners();
  }

  /// 重置口令：所有设备需重新输入新口令。
  Future<String> resetPassphrase() async {
    final generated = await _engine.resetPassphrase();
    _passphrase = generated;
    notifyListeners();
    return generated;
  }

  Future<SyncRoundReport?> syncNow({bool manual = false}) async {
    _busy = true;
    notifyListeners();
    try {
      // 引擎自带排队：进行中的轮次结束后会补跑，这里不做早退（否则
      // 连点两次只有一次生效且无提示）。手动触发经调度器（不受省电 /
      // 蜂窝暂停策略限制）；未注入调度器时直接走引擎。
      final scheduler = _scheduler;
      if (manual && scheduler != null) {
        await scheduler.syncNow();
        return _engine.lastReport;
      }
      return await _engine.syncNow(
        trigger: manual ? SyncTrigger.manual : SyncTrigger.timer,
      );
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 数据变更通知（资料库 / 统计 / 音源配置的 changes 事件）。
  ///
  /// 活跃等级去抖 3–5s 后跑一轮；空闲 / 后台 / 省电等级只标记待外发，
  /// 等下次唤醒或回前台（无本地变更不广播、不发 PROPFIND）。
  void notifyLocalChange() => _scheduler?.notifyLocalChange();

  /// 用户交互（界面操作）。
  void notifyInteraction() => _scheduler?.notifyInteraction();

  /// 回到前台：拉一次（有本地变更时一并推送）。
  void onAppResumed() => _scheduler?.onAppVisible();

  /// 退后台 / 锁屏：零定时唤醒，有本地变更时尽力推一次。
  void onAppHidden() => _scheduler?.onAppHidden();

  /// 当前同步等级（未注入调度器时为 null）。
  SyncLevel? get syncLevel => _scheduler?.level;

  /// 蜂窝网络下的自动同步策略。
  SyncCellularPolicy get cellularPolicy => _engine.state.cellularPolicy;

  Future<void> setCellularPolicy(SyncCellularPolicy value) async {
    await _engine.state.setCellularPolicy(value);
    notifyListeners();
  }

  /// 重新探测电量与网络类型（设置页进入 / 前台恢复时刷新观测面）。
  Future<void> refreshEnvironment() async =>
      _scheduler?.refreshEnvironment();

  @override
  void dispose() {
    _scheduler?.dispose();
    _engine.removeListener(notifyListeners);
    super.dispose();
  }
}
