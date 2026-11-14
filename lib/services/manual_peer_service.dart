import '../domain/models/device_sync.dart';
import '../utils/peer_address.dart';

/// 手动地址表单的保存结果（地址入簿 → 探测 → 立即接触）。
///
/// [probeSent] = 未配对设备已发出附近设备探测，后续在「附近设备」里点选配对；
/// 其余状态与设置页文案一一对应；[unreachable] 只表示本轮明确没连上。
enum SyncManualPeerOutcome {
  probeSent,
  contactQueued,
  added,
  updated,
  unreachable,
}

/// 手动对端地址簿、单播探测与「立即接触」的窄端口。
///
/// 只依赖读写地址簿、发探测与跑一轮三个动作；不持有 `SyncEngine` /
/// `SyncStateStore`，测试用内存假实现即可覆盖编排语义。
class ManualPeerService {
  ManualPeerService({
    required this._manualPeers,
    required this._addManualPeer,
    required this._moveManualPeer,
    required this._probeAddress,
    required this._syncNow,
  });

  final List<ManualPeer> Function() _manualPeers;
  final Future<bool> Function(ManualPeer peer) _addManualPeer;
  final ManualPeerMove _moveManualPeer;
  final ManualPeerProbe _probeAddress;
  final ManualPeerSyncNow _syncNow;

  /// 手动地址表单的唯一命令：地址入簿 → 附近设备探测 → 立即接触。
  ///
  /// 已认领身份的地址（编辑态自身或地址簿同址条目）跳过「探测后即关闭」，
  /// 直接进入接触；未配对地址探测成功时只提示「已发出附近设备探测」。
  /// 接触返回 null = 同步关闭 / 没有传输（没有一轮真正跑），按「稍后」处理；
  /// false 才表示本轮明确没连上。
  Future<SyncManualPeerOutcome> save({
    required String host,
    int probePort = 0,
    String name = '',
    ManualPeer? editing,
  }) async {
    final normalized = normalizePeerHost(host);
    final trimmedName = name.trim();
    // 编辑态自身已认领身份，或地址簿里同一地址已有 deviceId（重复添加
    // 已配对设备）。
    final paired =
        (editing?.deviceId.isNotEmpty ?? false) ||
        _manualPeers().any(
          (entry) => entry.host == normalized && entry.deviceId.isNotEmpty,
        );
    final added = editing == null
        ? await _addManualPeer(
            ManualPeer(
              host: normalized,
              name: trimmedName,
              probePort: probePort,
            ),
          )
        : false;
    if (editing != null) {
      await _moveManualPeer(
        normalizePeerHost(editing.host),
        toHost: normalized,
        probePort: probePort,
        name: trimmedName,
      );
    }
    final probed = await _probeAddress(normalized, probePort: probePort);
    if (!paired && probed) return SyncManualPeerOutcome.probeSent;
    final contacted = await contact(normalized);
    if (contacted == null) return SyncManualPeerOutcome.contactQueued;
    if (contacted) {
      return editing == null && added
          ? SyncManualPeerOutcome.added
          : SyncManualPeerOutcome.updated;
    }
    return SyncManualPeerOutcome.unreachable;
  }

  /// 立刻跑一轮并判断该手动地址是否接触成功。
  ///
  /// 判据：地址簿条目在本轮学到了设备身份，且名册里该设备是本轮接触的
  /// （`lastSeenAt` 不早于**本轮**开始）——只有本轮真正握手过才算成功。
  ///
  /// 结果直接取自 [syncNow] 返回的本轮报告：在途轮次上的请求会排队等补跑
  /// 轮，报告就是补跑轮的，不使用「对象是否相同 / 时间戳是否更早」猜有没有
  /// 真正跑。返回 null = 没有一轮真正跑（同步关闭 / 没有传输）：此时不下
  /// 结论，调用方按「稍后」处理，等后续轮次给出结果。
  Future<bool?> contact(String host) async {
    final report = await _syncNow();
    if (report == null) return null;
    ManualPeer? entry;
    for (final peer in _manualPeers()) {
      if (peer.host == host) {
        entry = peer;
        break;
      }
    }
    final deviceId = entry?.deviceId ?? '';
    if (deviceId.isEmpty) return false;
    return report.peers.any(
      (peer) =>
          peer.deviceId == deviceId && peer.lastSeenAt >= report.startedAt,
    );
  }
}

/// 更新一条手动地址（保留身份与已学端口，只改「设备在哪」）。
typedef ManualPeerMove = Future<void> Function(
  String fromHost, {
  required String toHost,
  int? probePort,
  String? name,
});

/// 向一个手动地址单播配对探测；false = 配对端口未注入或发送失败。
typedef ManualPeerProbe = Future<bool> Function(String host, {int probePort});

/// 「立即接触」：跑一轮并返回本轮报告；null = 没有一轮真正跑。
typedef ManualPeerSyncNow = Future<SyncRoundReport?> Function();
