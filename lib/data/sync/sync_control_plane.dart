import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../domain/models/device_sync.dart';
import '../../domain/ports/sync_transport.dart';
import 'sync_activity.dart';
import 'sync_passphrase.dart';
import 'sync_state_store.dart';

/// 同步控制面：设备身份 / 配对口令 / 传输开关与运行状态 / 观测快照的
/// **唯一 UI 写入点**：UI 只经这里的 getter 与 mutator 工作，不再接触
/// `SyncStateStore`，引擎也不再暴露状态存储。
///
/// 为什么单独拆出来：引擎的实现是「跑一轮」，UI 需要的是「谁、怎么连、
/// 现在是什么状态」。两者的生命周期不同（控制面在引擎空闲时也要响应设置页
/// 的读写），接口宽度也不同（引擎报告一轮结果，控制面提供身份与开关）。
/// 分开后引擎不再暴露状态存储与一打一行式 mutator，控制面则把「改状态 +
/// 重启传输 + 通知 UI」这一组必须同进同退的动作收在一处。
///
/// 组合根契约：控制面与引擎必须拿到**同一个** [SyncStateStore] 与同一份
/// 传输实例；控制面的写入就是引擎下一轮读到的状态，不存在第二份内存副本。
class SyncControlPlane extends ChangeNotifier {
  SyncControlPlane({
    required SyncStateStore state,
    required Map<String, SyncTransport> transports,
  })  : _state = state,
        _transports = transports;

  final SyncStateStore _state;
  final Map<String, SyncTransport> _transports;
  final Logger _logger = Logger('molia.sync');

  /// 口令缓存：设置页 / 配对码要同步读取，不能每次都碰安全存储。写入路径
  /// 与安全存储保持一致（[readPassphrase] 是唯一的重新加载入口）。
  String? _passphrase;

  bool _initialized = false;

  // ---- 只读观测面（UI 只经这些 getter，不接触状态存储） ----

  bool get enabled => _state.enabled;
  String get deviceId => _state.deviceId;
  String get deviceName => _state.deviceName;
  Map<SyncCategory, bool> get categories => _state.categories;
  Set<String> get enabledTransports => _state.enabledTransports;
  WebDavConfig get webdav => _state.webdav;
  int get lastSyncAt => _state.lastSyncAt;
  List<SyncLogEntry> get log => _state.log;
  List<SyncPeerState> get peers => _state.peers;
  List<ManualPeer> get manualPeers => _state.manualPeers;
  int get lanHttpPort => _state.lanHttpPort;
  List<SyncActivityEntry> get activity => _state.activity;
  SyncCellularPolicy get cellularPolicy => _state.cellularPolicy;

  /// 本机时钟（设置页的相对时间 / 失联判定）。
  int nowMs() => _state.nowMs();

  /// 传输最近一次成功接触对端的时间（0 = 尚未成功过）。
  int transportLastSuccessAt(String kind) =>
      _state.transportLastSuccessAt(kind);

  /// 局域网传输本机实际绑定的 UDP 探测端口（分族；0 = 该族未运行 /
  /// 不可用）。命名映射：传输层是 `SyncTransport.discoveryPorts`（传输不限
  /// 局域网），控制面 / UI 层带 `lan` 前缀限定。
  ({int v4, int v6}) get lanDiscoveryPorts =>
      _transports[SyncTransportKind.lan]?.discoveryPorts ?? (v4: 0, v6: 0);

  /// 传输当前状态（UI 呈现「开关开着但没在工作」）；未知 kind 返回 null。
  ///
  /// 与一轮报告同一类型（[SyncTransportReport]）：计数为零、`error` 为启动类
  /// 失败原因，避免「状态视图」与「报告」两套字段各自漂移。
  SyncTransportReport? transportStatus(String kind) {
    final transport = _transports[kind];
    if (transport == null) return null;
    final running = transport.isRunning;
    final reason = transport.unavailableReason;
    return SyncTransportReport(
      kind: kind,
      enabled: _state.enabledTransports.contains(kind),
      running: running,
      unavailableReason: reason,
      error: running || reason == null
          ? null
          : SyncIssue(code: reason, detail: transport.unavailableDetail),
    );
  }

  // ---- 初始化与传输运行时 ----

  /// 状态存储初始化（幂等）。首次成功后通知一次：设置页在首帧后打开时
  /// 才能看到设备 id / 口令。
  Future<void> init() async {
    if (_initialized) return;
    await _state.init();
    _initialized = true;
    notifyListeners();
  }

  /// 启动已启用且未运行的传输（幂等）。
  ///
  /// 组合根在**首帧之后**调用它：局域网传输启动要过权限门（Android 17 起是
  /// 系统对话框）并绑套接字 / 枚举网卡，放在 `runApp` 之前会让首帧等一个
  /// 用户看不见的对话框。装配期只初始化状态，传输留给首帧收尾或首个轮次。
  Future<void> startTransports() async {
    if (!_state.enabled) return;
    await _ensureTransportsRunning();
  }

  /// 回前台：通知已启用的局域网传输（隐藏过久时重绑 UDP / 探活 HTTP）。
  ///
  /// 只对实现了 [SyncLanLifecycle] 的传输调用；WebDAV 没有生命周期动作。
  /// 失败只记日志：回前台不能因为发现层异常打断调度器拉一轮。
  Future<void> onAppResumed() async {
    for (final entry in _transports.entries) {
      if (!_state.enabledTransports.contains(entry.key)) continue;
      final transport = entry.value;
      if (transport is! SyncLanLifecycle) continue;
      final lifecycle = transport as SyncLanLifecycle;
      try {
        await lifecycle.onAppResumed();
      } catch (e) {
        _logger.warning('回前台：传输 ${entry.key} 恢复失败', e);
      }
    }
  }

  /// 退后台：通知已启用的局域网传输取消公告 / 重连计时器。
  void onAppHidden() {
    for (final entry in _transports.entries) {
      if (!_state.enabledTransports.contains(entry.key)) continue;
      final transport = entry.value;
      if (transport is! SyncLanLifecycle) continue;
      final lifecycle = transport as SyncLanLifecycle;
      try {
        lifecycle.onAppHidden();
      } catch (e) {
        _logger.warning('退后台：传输 ${entry.key} 暂停失败', e);
      }
    }
  }

  // ---- 设置写入（改状态 + 通知 UI；传输开关额外负责起停） ----

  Future<void> setCategory(SyncCategory category, bool value) async {
    await _state.setCategory(category, value);
    notifyListeners();
  }

  /// 开 / 关一路传输（= 总开关：两路都关时 [enabled] 为假，一切停摆）。
  ///
  /// 打开时启动**全部**已启用传输（幂等）：与引擎轮次开始前的启动路径一致，
  /// 避免「刚打开的这一路起了、另一路仍停着」的半开状态。
  Future<void> setTransportEnabled(String kind, bool value) async {
    await _state.setTransportEnabled(kind, value);
    final transport = _transports[kind];
    if (transport != null) {
      if (value) {
        await _ensureTransportsRunning();
      } else if (transport.isRunning) {
        await transport.stop();
      }
    }
    notifyListeners();
  }

  Future<void> setDeviceName(String value) async {
    await _state.setDeviceName(value);
    notifyListeners();
  }

  Future<void> setWebdavConfig(WebDavConfig config) async {
    await _state.setWebdavConfig(config);
    notifyListeners();
  }

  Future<void> setCellularPolicy(SyncCellularPolicy value) async {
    await _state.setCellularPolicy(value);
    notifyListeners();
  }

  // ---- 手动对端地址簿（局域网发现失败时的兜底） ----

  /// 添加手动对端（地址 + 可选名称）；重复地址按地址合并。
  ///
  /// 返回 false 表示该地址已存在（UI 据此提示「已更新」而不是「已添加」）。
  Future<bool> addManualPeer(ManualPeer peer) async {
    final added = await _state.addManualPeer(peer);
    notifyListeners();
    return added;
  }

  Future<void> removeManualPeer(String host) async {
    await _state.removeManualPeer(host);
    notifyListeners();
  }

  /// 用配对码里的地址集合收敛该设备的条目（码外旧地址退役）。
  Future<void> adoptPeerAddresses(
    String deviceId,
    List<ManualPeer> addresses,
  ) async {
    await _state.adoptPeerAddresses(deviceId, addresses);
    notifyListeners();
  }

  /// 更新某条手动地址（身份与已学到的端点端口保留）。
  Future<void> moveManualPeer(
    String fromHost, {
    required String toHost,
    int? probePort,
    String? name,
  }) async {
    await _state.moveManualPeer(
      fromHost,
      toHost: toHost,
      probePort: probePort,
      name: name,
    );
    notifyListeners();
  }

  /// 从本机列表移除一台设备（名册 + 地址簿条目）。
  ///
  /// 只做本机记录清理，不撤销同步授权：对方仍持有口令并在线时会被下一次
  /// 探测重新发现。真正停止与它同步需要更换口令（对所有设备生效）。
  Future<void> removePeer(String deviceId) async {
    if (deviceId.isEmpty) return;
    await _state.removePeer(deviceId);
    notifyListeners();
  }

  /// 显式清理某台设备的远端文件（用户动作；**不做自动删除**）。
  ///
  /// 返回每个传输的结果；没有可清理内容的传输返回 false（局域网直连无远端
  /// 存储）。失败原因进日志与返回值，UI 据此提示。
  Future<({bool removed, SyncIssue? error})> cleanupRemote(
    String deviceId,
  ) async {
    if (deviceId.isEmpty) return (removed: false, error: null);
    var removed = false;
    SyncIssue? firstError;
    for (final entry in _transports.entries) {
      if (!_state.enabledTransports.contains(entry.key)) continue;
      try {
        if (await entry.value.deleteRemote(deviceId)) removed = true;
      } catch (e) {
        firstError ??= SyncIssue(
          code: SyncIssueCode.deleteRemoteFailed,
          args: {'peer': deviceId},
          detail: '$e',
        );
        _logger.warning('清理远端文件失败（${entry.key}/$deviceId）', e);
      }
    }
    return (removed: removed, error: firstError);
  }

  // ---- 敏感配置与口令（口令即信任根，生命周期只在这里） ----

  Future<String?> readWebdavPassword() => _state.readWebdavPassword();

  Future<void> writeWebdavPassword(String password) async {
    await _state.writeWebdavPassword(password);
    notifyListeners();
  }

  /// 当前口令缓存；null = 尚未加载 / 未设置。
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

  /// 从安全存储重新加载口令缓存（初始化 / 外部写入后调用）。
  Future<String?> readPassphrase() async {
    _passphrase = await _state.readPassphrase();
    return _passphrase;
  }

  /// 读取现有口令；不存在时生成并持久化（开启同步的入口）。
  Future<String> ensurePassphrase() async {
    final existing = await _state.readPassphrase();
    if (existing != null && existing.trim().isNotEmpty) {
      _passphrase = existing;
      return existing;
    }
    final generated = SyncPassphrase.generate();
    await _state.writePassphrase(generated);
    _passphrase = generated;
    notifyListeners();
    return generated;
  }

  /// 保存调用方已归一化的口令（加入已有同步组）。
  Future<void> setPassphrase(String passphrase) async {
    await _state.writePassphrase(passphrase);
    _passphrase = passphrase;
    notifyListeners();
  }

  /// 重置口令：全部设备需重新输入（口令即信任根）。
  Future<String> resetPassphrase() async {
    final generated = SyncPassphrase.generate();
    await _state.writePassphrase(generated);
    _passphrase = generated;
    notifyListeners();
    return generated;
  }

  Future<void> _ensureTransportsRunning() async {
    for (final entry in _transports.entries) {
      if (!_state.enabledTransports.contains(entry.key)) continue;
      if (entry.value.isRunning) continue;
      // 启动失败由传输自己记录（`unavailableReason`）并进入状态 / 本轮报告：
      // 「开关打开但没在工作」必须能被用户看到，不能只留在日志里。
      await entry.value.start();
    }
  }
}
