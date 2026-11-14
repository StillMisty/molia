import '../domain/models/device_sync.dart';
import '../domain/models/sync_peer_status.dart';
import '../utils/device_id.dart';

/// 对端展示名：用户命名优先，对端自报名仅兜底，都没有用短设备 id。
///
/// 放在纯投影模块里（不依赖 UI）：设置页名册、设备详情与底部提示必须用
/// 同一个称谓；散落在页面里会让同一台设备出现多个名字。
String syncPeerDisplayName(SyncPeerState peer, ManualPeer? manual) {
  final userNamed = manual?.name.trim() ?? '';
  if (userNamed.isNotEmpty) return userNamed;
  return peer.name.isEmpty ? shortDeviceId(peer.deviceId) : peer.name;
}

/// 名册里的一行：对端观测 + 匹配到的手动地址 + 本轮连接结论。
///
/// 连接结论在构造 [SyncPeerView] 时算一次，页面不再逐处调用
/// `resolveSyncPeerConnection`（否则同一行在名册、footer 与重检条件里可能
/// 拿到不同时刻的结论）。
class SyncPeerRow {
  const SyncPeerRow({
    required this.peer,
    required this.manual,
    required this.connection,
  });

  final SyncPeerState peer;

  /// 该设备在手动地址簿里的条目（未手动添加 / 尚未认领时为 null）。
  final ManualPeer? manual;

  final SyncPeerConnectionStatus connection;

  String get displayName => syncPeerDisplayName(peer, manual);

  bool get isConnected => connection == SyncPeerConnectionStatus.connected;

  bool get isLost => connection == SyncPeerConnectionStatus.lost;
}

/// 同步设置页设备区的不可变投影：名册顺序、连接状态与手动命名一次算好。
///
/// 纯值对象（不是 ChangeNotifier）：provider 通知后页面重新构建一份，
/// 页面只读 [rows] / [connected] / [lost]，不再各自循环名册推导状态。
class SyncPeerView {
  SyncPeerView._({
    required this.rows,
    required this.connected,
    required this.lost,
    required this.hasReport,
  });

  /// 从当前控制面快照构建投影（纯函数，不读时钟也不发通知）。
  factory SyncPeerView.from({
    required List<SyncPeerState> peers,
    required List<ManualPeer> manualPeers,
    required SyncRoundReport? lastReport,
    required int nowMs,
  }) {
    // 以 deviceId 关联地址簿条目；未认领（deviceId 为空）的地址没有名册行，
    // 不参与命名。
    final manualByDevice = <String, ManualPeer>{
      for (final entry in manualPeers)
        if (entry.deviceId.isNotEmpty) entry.deviceId: entry,
    };
    final rows = <SyncPeerRow>[
      for (final peer in peers)
        SyncPeerRow(
          peer: peer,
          manual: manualByDevice[peer.deviceId],
          connection: resolveSyncPeerConnection(
            peer,
            report: lastReport,
            nowMs: nowMs,
          ),
        ),
    ];
    return SyncPeerView._(
      rows: List.unmodifiable(rows),
      connected: List.unmodifiable(rows.where((row) => row.isConnected)),
      lost: List.unmodifiable(rows.where((row) => row.isLost)),
      hasReport: lastReport != null,
    );
  }

  /// 名册行，顺序与 [peers] 一致。
  final List<SyncPeerRow> rows;

  /// 最近一轮真正接触成功的行（设备区 footer / 重检条件用）。
  final List<SyncPeerRow> connected;

  /// 超过失联阈值的行（连接状态 [SyncPeerConnectionStatus.lost]）。
  final List<SyncPeerRow> lost;

  /// 本次进程内是否已经跑过一轮；false 时页面不能断言「本轮没连上」。
  final bool hasReport;

  bool get hasConnected => connected.isNotEmpty;
}
