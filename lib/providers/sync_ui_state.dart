import 'package:flutter/foundation.dart';

import '../data/sync/sync_activity.dart';
import '../data/sync/sync_state_codec.dart';
import '../domain/models/device_sync.dart';
import '../domain/models/sync_nearby_pairing.dart';
import '../domain/ports/sync_transport.dart';
import 'sync_nearby_availability.dart';
import 'sync_peer_view.dart';

/// 传输的类型化标识：UI 投影与用户动作只认枚举，不再传裸 `String kind`。
///
/// 持久化 / 协议层仍是字符串（[kind]），转换只在投影边界发生。
enum SyncTransportId {
  lan(SyncTransportKind.lan),
  webdav(SyncTransportKind.webdav);

  const SyncTransportId(this.kind);

  /// 持久化键 / 传输报告里的 kind 字符串。
  final String kind;

  /// 已知 kind → 枚举；未知值返回 null（旧持久化 / 未来传输不崩 UI）。
  static SyncTransportId? tryParse(String kind) {
    for (final id in values) {
      if (id.kind == kind) return id;
    }
    return null;
  }
}

/// 单路传输的 UI 事实：开关、运行状态、不可用原因与最近成功时间。
@immutable
class SyncTransportUiState {
  const SyncTransportUiState({
    required this.id,
    required this.configured,
    required this.enabled,
    required this.running,
    this.unavailableReason,
    this.error,
    this.lastSuccessAt = 0,
  });

  final SyncTransportId id;

  /// 该传输是否已装配（false = 当前版本没有这路传输）。
  final bool configured;

  final bool enabled;
  final bool running;

  /// 机器可读不可用原因（[SyncUnavailableReason]）；null = 可用。
  final String? unavailableReason;

  /// 启动类失败原因（详情在日志子页的失败弹层里）。
  final SyncIssue? error;

  /// 最近一次成功接触对端的时间（0 = 尚未成功过）。
  final int lastSuccessAt;

  /// 开关已开且实际可用：状态色 / 附近设备可用性共用这一判据。
  bool get available => running && unavailableReason == null;
}

/// 跨设备同步的不可变 UI 投影。
///
/// 页面只读这一份快照，不再分别接触控制面 / 引擎 / 调度器 / 权限门。
/// 每份投影里的集合都已复制为不可变视图，调用方不能反向修改同步状态。
@immutable
class SyncUiState {
  const SyncUiState({
    required this.enabled,
    required this.syncing,
    required this.deviceId,
    required this.deviceName,
    required this.categories,
    required this.enabledTransports,
    required this.transports,
    required this.webdav,
    required this.log,
    required this.peers,
    required this.manualPeers,
    required this.peerView,
    required this.lanDiscoveryPorts,
    required this.lanHttpPort,
    required this.nearbyAvailability,
    required this.nearbyDevices,
    required this.incomingPairingRequests,
    required this.pairingAttempts,
    required this.peerConnectedNotices,
    required this.scanningNearby,
    required this.hasGroup,
    required this.nowMs,
    required this.lastReport,
    required this.lanPermissionNeeded,
    required this.lanPermissionPermanentlyDenied,
    required this.lanPermissionNeedsAttention,
    required this.canCheckNow,
    required this.syncLevel,
    required this.activity24h,
    required this.onCellular,
    required this.powerSaveActive,
    required this.cellularPolicy,
    required this.passphrase,
    required this.maskedPassphrase,
  });

  /// 是否已有任一传输开启（传输开关即总闸）。
  final bool enabled;

  /// 是否有一轮同步正在跑。
  final bool syncing;

  final String deviceId;
  final String deviceName;

  /// 各类别开关（不可变副本）。
  final Map<SyncCategory, bool> categories;

  /// 已开启的传输（类型化）。
  final Set<SyncTransportId> enabledTransports;

  /// 两路传输的当前事实（未知传输不会出现在这里）。
  final Map<SyncTransportId, SyncTransportUiState> transports;

  final WebDavConfig webdav;

  /// 展示日志（最多 20 条；不可变副本）。
  final List<SyncLogEntry> log;

  /// 已配对设备名册（不可变副本）。
  final List<SyncPeerState> peers;

  /// 手动对端地址簿（不可变副本）。
  final List<ManualPeer> manualPeers;

  /// 设备区的一次性只读投影（名册顺序 / 手动命名 / 连接状态）。
  final SyncPeerView peerView;

  final ({int v4, int v6}) lanDiscoveryPorts;
  final int lanHttpPort;
  final SyncNearbyAvailability nearbyAvailability;

  final Stream<List<SyncNearbyDevice>> nearbyDevices;
  final Stream<SyncPairingRequest> incomingPairingRequests;
  final Stream<SyncPairingAttempt> pairingAttempts;
  final Stream<SyncPeerState> peerConnectedNotices;

  final bool scanningNearby;
  final bool hasGroup;

  /// 设置页相对时间 / 失联判定用的本机时钟（投影时取一次）。
  final int nowMs;

  final SyncRoundReport? lastReport;
  SyncOutcome? get lastOutcome => lastReport?.outcome;

  final bool lanPermissionNeeded;
  final bool lanPermissionPermanentlyDenied;
  final bool lanPermissionNeedsAttention;

  final bool canCheckNow;
  final SyncLevel? syncLevel;
  final SyncActivitySummary activity24h;
  final bool onCellular;
  final bool powerSaveActive;
  final SyncCellularPolicy cellularPolicy;

  final String? passphrase;
  final String maskedPassphrase;
}
