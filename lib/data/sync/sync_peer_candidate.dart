/// 局域网对端候选：观测合并与地址尝试顺序（纯数据，不碰 socket / HTTP）。
///
/// 为什么单独成模块：候选合并的字段级新鲜度（本轮 presence 优先于旧记忆）
/// 与地址排序（IPv4 → 全局 / ULA IPv6 → 观测源地址 → link-local 兜底）
/// 原先只存在于传输私有类里，只能靠真实 UDP + HTTP 测试触达；其中任何一处
/// 判错，表现都是「对端在线却连不上」或「旧地址拖慢整轮」，很难定位。
library;

import 'dart:io';

import '../../utils/device_id.dart';

/// 一台对端的候选观测（可能来自手动地址 / presence / 持久化端点）。
///
/// 同一台设备可能有多条候选：`merge` 按字段合并，[snapshotFresh] 决定
/// 「本轮观测」优先于「上一轮记忆」——旧指纹永远不能覆盖新指纹。
class SyncPeerCandidate {
  const SyncPeerCandidate({
    required this.deviceId,
    required this.name,
    required this.host,
    required this.port,
    this.probePort = 0,
    this.addresses = const [],
    this.alternateHosts = const [],
    this.snapshotId = '',
    this.journalHead,
    this.snapshotFresh = false,
    required this.expected,
  });

  /// 单个对端最多尝试的 HTTP 地址数（候选地址可能有多个，全试没必要）。
  static const int maxHosts = 3;

  final String deviceId;
  final String name;

  /// 首选主机（presence 的观测源地址 / 手动地址 / 持久化端点）。
  final String host;

  /// HTTP 端口。
  final int port;
  final int probePort;
  final List<String> addresses;
  final List<String> alternateHosts;
  final String snapshotId;
  final int? journalHead;

  /// snap/head 是否来自**本轮**探测（presence.lastHeardAt >= 本轮起点）。
  /// 只有新鲜的指纹才能作为「未变跳过 GET」的依据。
  final bool snapshotFresh;

  /// 预期对端（manual / presence）失败要计数；试探性对端失败不计数。
  final bool expected;

  /// 合并两条候选观测（同设备或同端点）。
  ///
  /// 指纹 / 头部按新鲜度取：单侧新鲜用新鲜侧，两侧都新鲜按字段取非空，
  /// 都不新鲜只保留非空值做缓存标记（不用于跳过 GET）。
  SyncPeerCandidate merge(SyncPeerCandidate other) {
    final String mergedSnapshotId;
    final int? mergedJournalHead;
    if (snapshotFresh && !other.snapshotFresh) {
      mergedSnapshotId = snapshotId;
      mergedJournalHead = journalHead;
    } else if (!snapshotFresh && other.snapshotFresh) {
      mergedSnapshotId = other.snapshotId;
      mergedJournalHead = other.journalHead;
    } else if (snapshotFresh && other.snapshotFresh) {
      mergedSnapshotId =
          other.snapshotId.isNotEmpty ? other.snapshotId : snapshotId;
      mergedJournalHead = other.journalHead ?? journalHead;
    } else {
      mergedSnapshotId = snapshotId.isNotEmpty ? snapshotId : other.snapshotId;
      mergedJournalHead = journalHead ?? other.journalHead;
    }
    return SyncPeerCandidate(
      deviceId: deviceId.isNotEmpty ? deviceId : other.deviceId,
      name: name.isNotEmpty ? name : other.name,
      host: host.isNotEmpty ? host : other.host,
      port: port > 0 ? port : other.port,
      probePort: probePort > 0 ? probePort : other.probePort,
      addresses: _union(addresses, other.addresses),
      alternateHosts: _union(
        alternateHosts,
        [
          if (other.host.isNotEmpty && other.host != host) other.host,
          ...other.alternateHosts,
        ],
      ),
      snapshotId: mergedSnapshotId,
      journalHead: mergedJournalHead,
      snapshotFresh: snapshotFresh || other.snapshotFresh,
      expected: expected || other.expected,
    );
  }

  /// HTTP 主机尝试顺序：候选地址（IPv4 → 全局 / ULA IPv6）→ 观测源地址
  /// → 其它已学到的地址；单对端最多 [maxHosts] 个，避免长时间离线设备拖慢
  /// 整轮。
  List<String> get hosts => orderPeerHosts(
        addresses: addresses,
        primary: host,
        alternates: alternateHosts,
      );

  /// 去重键：认领到设备 id 后按 id，未认领（手动地址首轮）按端点。
  String get key => deviceId.isNotEmpty ? deviceId : 'host:$host:$port';

  /// 日志 / 错误文案用的人类可读标识（设备名 > 设备 id 短号 > 主机）。
  String get label {
    if (name.isNotEmpty) return name;
    if (deviceId.isNotEmpty) return shortDeviceId(deviceId);
    return host;
  }

  static List<String> _union(List<String> a, List<String> b) {
    final values = <String>[...a];
    for (final value in b) {
      if (!values.contains(value)) values.add(value);
    }
    return values;
  }
}

/// 地址尝试顺序（纯函数，测试可直接钉住排序与上限）。
///
/// 稳定性：同 rank 保持候选原顺序（观测源地址作为兜底排在候选之后）。
List<String> orderPeerHosts({
  required Iterable<String> addresses,
  required String primary,
  Iterable<String> alternates = const [],
  int maxHosts = SyncPeerCandidate.maxHosts,
}) {
  final ordered = <String>[];
  void add(String value) {
    final normalized =
        InternetAddress.tryParse(value.trim())?.address ?? value.trim();
    if (normalized.isEmpty || ordered.contains(normalized)) return;
    ordered.add(normalized);
  }

  for (final address in addresses) {
    add(address);
  }
  add(primary);
  for (final alternate in alternates) {
    add(alternate);
  }
  final indexed = ordered.indexed.toList()
    ..sort((a, b) {
      final byRank = peerHostRank(a.$2).compareTo(peerHostRank(b.$2));
      return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
    });
  return [
    for (final (_, value) in indexed.take(maxHosts)) value,
  ];
}

/// 地址可达性排序：IPv4 = 0，全局 / ULA IPv6 = 1，其它地址（link-local /
/// 带 zone / 非 IP 字面量）最后。
int peerHostRank(String host) {
  final address = InternetAddress.tryParse(host);
  if (address == null) return 3;
  if (address.type == InternetAddressType.IPv4) return 0;
  if (address.isLinkLocal || address.isLoopback || host.contains('%')) {
    return 3;
  }
  return 1;
}
