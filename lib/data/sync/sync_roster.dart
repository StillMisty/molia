/// 同步名册：对端观测、已验证局域网端点、手动地址簿与一次性提示。
///
/// 为什么单独一层：这些状态都在回答「本机对谁有观测」，增删规则互相牵连
/// （移除设备要同时清名册 / 端点 / 首连提示；换口令要清空整组观测但保留
/// 用户配置的地址簿），持久化时机也一致（轮内接触只标脏，用户命令由状态
/// 存储立即提交）。收进这里后，`SyncStateStore` 只负责拼装持久化快照与
/// 提交，名册行为可以直接构造实例测试，不必经过 SharedPreferences。
///
/// 落盘形状仍由 `sync_state_codec.dart` 定义：本模块只产出 / 接受四个字段的
/// 不可变切片，不维护 JSON 键名或容错规则。
library;

import '../../domain/models/device_sync.dart';
import '../../utils/peer_address.dart';
import 'sync_state_codec.dart';

/// 名册类字段的持久化切片（对应 `SyncPersistedState` 的同名字段）。
///
/// 构造时复制集合：调用方可以把切片交给异步编码，之后的轮次观测不会改到
/// 正在落盘的内容。
class SyncRosterSnapshot {
  SyncRosterSnapshot({
    List<ManualPeer> manualPeers = const [],
    Set<String> notifiedPeers = const {},
    List<SyncPeerState> peers = const [],
    List<LanPeerEndpoint> lanEndpoints = const [],
  })  : manualPeers = List.unmodifiable(manualPeers),
        notifiedPeers = Set.unmodifiable(notifiedPeers),
        peers = List.unmodifiable(peers),
        lanEndpoints = List.unmodifiable(lanEndpoints);

  /// 手动地址簿（顺序即探测与展示的优先序）。
  final List<ManualPeer> manualPeers;

  /// 已提示过「首次连通」的设备 id。
  final Set<String> notifiedPeers;

  /// 设备名册（deviceId → 最近一次接触的观测值）。
  final List<SyncPeerState> peers;

  /// 已验证的局域网端点。
  final List<LanPeerEndpoint> lanEndpoints;
}

/// 对端名册与地址簿（内存状态；不做持久化）。
class SyncRoster {
  SyncRoster({
    required void Function() onChanged,
    int peerLimit = SyncStateCodec.peerLimit,
    int lanEndpointLimit = SyncStateCodec.lanEndpointLimit,
    int lanEndpointRetentionMs = defaultLanEndpointRetentionMs,
  })  : _onChanged = onChanged,
        _peerLimit = peerLimit,
        _lanEndpointLimit = lanEndpointLimit,
        _lanEndpointRetentionMs = lanEndpointRetentionMs;

  /// 已验证局域网端点的保留期：超过该时长没再验证过随名册淘汰。
  ///
  /// 换网 / DHCP 变更后旧地址多半已失效，留着只会让每轮多试几个连不通的
  /// 地址；180 天是「长期离线但可能回来」的折中，持久化层不再单独维护一份。
  static const int defaultLanEndpointRetentionMs = 180 * 24 * 60 * 60 * 1000;

  /// 有内存变更（由状态存储标脏；轮内不改磁盘）。
  final void Function() _onChanged;

  final int _peerLimit;
  final int _lanEndpointLimit;
  final int _lanEndpointRetentionMs;

  /// 手动添加的对端地址（局域网发现失败时的兜底）。
  final List<ManualPeer> _manualPeers = [];

  /// 已提示过「首次连通」的设备 id（一次性 UI 提示）。
  final Set<String> _notifiedPeers = {};

  /// 刚被用户从本机移除的设备 id：只压住下一次 `recordRound`，防止正在
  /// 收尾的一轮把已删除的行写回。**不是持久化屏蔽**——设备如果仍在线且
  /// 持有同步口令，下一轮探测会重新发现它。
  final Set<String> _forgottenPeers = {};

  /// 设备名册（deviceId → 最近一次接触的观测值）。
  final Map<String, SyncPeerState> _peers = {};

  /// 已验证的局域网端点（deviceId → 最近一次成功连通的地址 / 端口）。
  ///
  /// 广播 / 组播被 AP 隔离或 iOS entitlement 挡住时，靠这里的单播兜底；
  /// 只在 MAC 验证 + HTTP 解密成功后写入（见 `LanSyncTransport`）。
  final Map<String, LanPeerEndpoint> _lanEndpoints = {};

  /// 手动对端地址簿（去重后不可变）。
  List<ManualPeer> get manualPeers => List.unmodifiable(_manualPeers);

  /// 名册（按最近接触时间倒序；本机不在其中）。
  List<SyncPeerState> get peers =>
      List.unmodifiable(trimPeers(_peers.values, _peerLimit));

  /// 已验证的局域网端点（不可变；上限由构造参数给定）。
  List<LanPeerEndpoint> get lanEndpoints =>
      List.unmodifiable(_lanEndpoints.values);

  /// 添加手动对端（同一 host 覆盖：地址簿以地址为身份，学到的信息合并保留）。
  ///
  /// 返回 false 表示该地址已存在（本次按用户输入更新名称与端口）。
  bool addManualPeer(ManualPeer peer) =>
      _upsertManualPeer(peer, overwriteName: true);

  /// 移除手动对端（按地址；仅移除地址簿条目，不影响已发现的对端）。
  ///
  /// 返回是否命中条目：未命中时状态存储不落盘（与旧行为一致）。
  bool removeManualPeer(String host) {
    final index = _manualPeers.indexWhere((entry) => entry.host == host);
    if (index < 0) return false;
    _manualPeers.removeAt(index);
    _onChanged();
    return true;
  }

  /// 更新某条手动地址的 host / 探测端口 / 命名（设备详情里的「更新地址」）。
  ///
  /// 身份（deviceId）与已学到的端点端口保留：改的是「设备在哪」，不是「是谁」。
  /// 目标地址已有条目时并入该条目并移除旧条目（同一地址不重复入簿）。
  /// 返回是否发生移动（无效输入 / 地址未变时不落盘）。
  bool moveManualPeer(
    String fromHost, {
    required String toHost,
    int? probePort,
    String? name,
  }) {
    final index = _manualPeers.indexWhere((entry) => entry.host == fromHost);
    if (index < 0 || toHost.isEmpty || toHost == fromHost) return false;
    final moved = _manualPeers.removeAt(index).copyWith(
          host: toHost,
          probePort: probePort,
          name: name,
        );
    final existing = _manualPeers.indexWhere((entry) => entry.host == toHost);
    if (existing >= 0) {
      _manualPeers[existing] = _manualPeers[existing].mergeLearned(
        httpPort: moved.httpPort > 0 ? moved.httpPort : null,
        deviceId: moved.deviceId.isNotEmpty ? moved.deviceId : null,
        name: moved.name.isNotEmpty ? moved.name : null,
      );
    } else {
      // 刚配置的地址排前面：地址簿顺序即探测与展示的优先序。
      _manualPeers.insert(0, moved);
    }
    _onChanged();
    return true;
  }

  /// 回写首次接触学到的信息（deviceId / 端口 / 名称）。
  ///
  /// 学到的对端名只在条目尚未命名时填入：手动条目优先保留用户命名。
  /// 这是轮内接触的副产物：只改内存 + 标脏，随轮末提交落盘。
  void learnManualPeer(ManualPeer learned) {
    _upsertManualPeer(learned, overwriteName: false, promote: true);
  }

  /// 从本机列表移除一台设备：名册 + 该设备的地址簿条目 + 首次连通提示。
  ///
  /// **只做本机记录清理，不撤销同步授权**：对方如果仍持有同步口令并在线，
  /// 下一轮探测会重新发现它。真正停止与它同步的唯一方式是更换口令（对
  /// 所有设备生效）。因此这里不写任何屏蔽 / 忽略标记。
  void removePeer(String deviceId) {
    if (deviceId.isEmpty) return;
    _peers.remove(deviceId);
    _manualPeers.removeWhere((entry) => entry.deviceId == deviceId);
    _notifiedPeers.remove(deviceId);
    _lanEndpoints.remove(deviceId);
    // 正在收尾的一轮可能带着旧名册快照，压住它一次；下一轮重新发现即恢复。
    _forgottenPeers.add(deviceId);
    _onChanged();
  }

  /// 清空本机对**旧同步组**的全部观测（换口令时调用）。
  ///
  /// 名册、已验证局域网端点、首次连通提示与「刚移除」暂存都只描述旧组；
  /// 口令即信任根，换口令后这些设备已不再被授权。留着会让
  /// `SyncControlPlane.hasEstablishedGroup` 继续声称「已有组」，把新设备误判
  /// 成邀请方 / 冲突，旧端点也仍会被当作可信的单播目标。手动地址簿
  /// （host / 端口）是用户配置而非组观察，保留。
  void resetGroupObservations() {
    _peers.clear();
    _lanEndpoints.clear();
    _notifiedPeers.clear();
    _forgottenPeers.clear();
    _onChanged();
  }

  /// 该设备是否已提示过「首次连通」。
  bool isPeerConnectNotified(String deviceId) =>
      _notifiedPeers.contains(deviceId);

  /// 登记「首次连通」已提示：设备第一次真正交换过数据时只提示一次，
  /// 持久化后重启不重复。返回是否新增（重复登记不标脏）。
  bool markPeerConnectNotified(String deviceId) {
    if (deviceId.isEmpty || !_notifiedPeers.add(deviceId)) return false;
    _onChanged();
    return true;
  }

  /// 记住一个已验证的局域网端点（MAC 验证 + HTTP 解密成功后回写）。
  ///
  /// 只更新内存 + 标脏：每轮每对端成功都会回写一次，这里若自己落盘会让
  /// 多对端一轮写多次大状态 JSON。持久化由状态存储的 `commit()` 统一完成。
  ///
  /// 返回是否产生变化（非法端点 / 完全相同的重复观测不标脏）。
  bool rememberLanEndpoint(LanPeerEndpoint endpoint) {
    if (!SyncStateCodec.isValidLanEndpoint(endpoint)) return false;
    final existing = _lanEndpoints[endpoint.deviceId];
    final next = LanPeerEndpoint(
      deviceId: endpoint.deviceId,
      host: normalizePeerHost(endpoint.host),
      httpPort: endpoint.httpPort,
      // 新观测没带探测端口时保留已有值：来源端口可能因 NAT / 重启变化，
      // 旧的持久化端口仍是有效的单播目标。
      probePort: endpoint.probePort > 0
          ? endpoint.probePort
          : (existing?.probePort ?? 0),
      verifiedAt: endpoint.verifiedAt,
    );
    final identityChanged = existing == null ||
        existing.host != next.host ||
        existing.httpPort != next.httpPort ||
        existing.probePort != next.probePort;
    if (!identityChanged && existing.verifiedAt == next.verifiedAt) {
      return false;
    }
    _lanEndpoints[next.deviceId] = next;
    _trimLanEndpoints();
    // 端点身份变化会改变名册淘汰 / 单播目标，仅验证时间前进也要跨重启保留：
    // 都只标脏，等轮末提交（每轮每对端都会回写，绝不能在这里落盘）。
    _onChanged();
    return true;
  }

  /// 记录一轮同步涉及的名册观测。
  ///
  /// 名册由引擎合并后传入（每条都是完整状态），这里只负责内存更新与按最近
  /// 接触时间淘汰，避免长期运行后无界增长；落盘由引擎在轮末提交一次。
  void recordRound(SyncRoundReport report) {
    _onChanged();
    // 用户刚移除的设备：压住本轮的在途快照，避免删除动作被收尾中的一轮
    // 立刻写回。只影响这一次落库；下一轮重新发现（设备仍在线）会照常写入。
    final forgotten = Set<String>.of(_forgottenPeers);
    _forgottenPeers.clear();
    for (final peer in report.peers) {
      if (forgotten.contains(peer.deviceId)) continue;
      _peers[peer.deviceId] = peer;
    }
    final recent = trimPeers(_peers.values, _peerLimit);
    _peers
      ..clear()
      ..addEntries(recent.map((peer) => MapEntry(peer.deviceId, peer)));
    // 180 天没再验证过的端点随名册一起淘汰：换网 / DHCP 变更后旧地址多半
    // 已失效，留着只会让每轮多试几个连不通的地址（保留期可注入，见构造）。
    final now = report.finishedAt;
    _lanEndpoints.removeWhere(
      (_, endpoint) =>
          endpoint.verifiedAt > 0 &&
          now - endpoint.verifiedAt > _lanEndpointRetentionMs,
    );
  }

  /// 当前内存状态的持久化切片（不可变；字段由 `sync_state_codec.dart` 编码）。
  SyncRosterSnapshot snapshot() => SyncRosterSnapshot(
        manualPeers: _manualPeers,
        notifiedPeers: _notifiedPeers,
        peers: _peers.values.toList(),
        lanEndpoints: _lanEndpoints.values.toList(),
      );

  /// 把解码出的切片写回内存（整体替换：状态 JSON 是完整视图，不是增量）。
  ///
  /// 只做观测替换：`_forgottenPeers` 是进程内的单轮抑制，不来自持久化。
  void applySnapshot(SyncRosterSnapshot snapshot) {
    _manualPeers
      ..clear()
      ..addAll(snapshot.manualPeers);
    _notifiedPeers
      ..clear()
      ..addAll(snapshot.notifiedPeers);
    _peers
      ..clear()
      ..addEntries(snapshot.peers.map((peer) => MapEntry(peer.deviceId, peer)));
    _lanEndpoints
      ..clear()
      ..addEntries(snapshot.lanEndpoints
          .map((endpoint) => MapEntry(endpoint.deviceId, endpoint)));
  }

  /// 地址簿写入的唯一入口：按 host 查找合并（重复地址不新增条目）。
  ///
  /// [overwriteName] 是命名策略开关：用户提交同一地址是显式改名，学习路径
  /// 不覆盖已有命名（对端广播的设备名只填空名）。[promote] 把刚更新过的条目
  /// 提到最前（地址簿顺序即探测与展示的优先序；仅学习路径需要）。
  /// 返回 false = 地址已存在（或 host 为空，不入簿）。
  bool _upsertManualPeer(
    ManualPeer peer, {
    required bool overwriteName,
    bool promote = false,
  }) {
    final host = peer.host.trim();
    if (host.isEmpty) return false;
    final index = _manualPeers.indexWhere((entry) => entry.host == host);
    if (index >= 0) {
      final name = peer.name.trim();
      var merged = _manualPeers[index].mergeLearned(
        httpPort: peer.httpPort > 0 ? peer.httpPort : null,
        deviceId: peer.deviceId.isNotEmpty ? peer.deviceId : null,
        // 学习路径才把对端名填进空名；用户提交走下面的显式改名。
        name: !overwriteName && peer.name.isNotEmpty ? peer.name : null,
      );
      if (overwriteName && name.isNotEmpty) {
        merged = merged.copyWith(name: name);
      }
      if (promote) {
        _manualPeers.removeAt(index);
        _manualPeers.insert(0, merged);
      } else {
        _manualPeers[index] = merged;
      }
      _onChanged();
      return false;
    }
    _manualPeers.add(peer.copyWith(host: host));
    _onChanged();
    return true;
  }

  /// 超过 [_lanEndpointLimit] 时按 `verifiedAt` 淘汰最旧的端点。
  void _trimLanEndpoints() {
    while (_lanEndpoints.length > _lanEndpointLimit) {
      String? oldestId;
      var oldestAt = 1 << 62;
      for (final entry in _lanEndpoints.entries) {
        if (entry.value.verifiedAt < oldestAt) {
          oldestAt = entry.value.verifiedAt;
          oldestId = entry.key;
        }
      }
      if (oldestId == null) return;
      _lanEndpoints.remove(oldestId);
    }
  }
}
