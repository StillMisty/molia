import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_roster.dart';
import 'package:molia/domain/models/device_sync.dart';

/// 名册模块测试：单轮移除抑制、换口令清空观测、端点校验 / 淘汰 / 保留上限。
///
/// 这些规则原先埋在 `SyncStateStore` 里，只能经 SharedPreferences 验证；
/// 直接构造名册后，边界条件（保留条数 / 保留期）可以用小参数跑，不必造
/// 几十轮真实状态。
void main() {
  SyncRoster roster({
    int peerLimit = 20,
    int lanEndpointLimit = 32,
    int lanEndpointRetentionMs = SyncRoster.defaultLanEndpointRetentionMs,
    void Function()? onChanged,
  }) =>
      SyncRoster(
        onChanged: onChanged ?? () {},
        peerLimit: peerLimit,
        lanEndpointLimit: lanEndpointLimit,
        lanEndpointRetentionMs: lanEndpointRetentionMs,
      );

  SyncRoundReport round({
    required int finishedAt,
    List<SyncPeerState> peers = const [],
  }) =>
      SyncRoundReport(
        trigger: SyncTrigger.timer,
        startedAt: finishedAt - 1,
        finishedAt: finishedAt,
        outcome: SyncOutcome.ok,
        peers: peers,
      );

  test('移除设备只压住下一轮：在途快照不写回，再下一轮重新发现入册', () {
    final state = roster();
    const devB = SyncPeerState(deviceId: 'devB', name: 'B', lastSeenAt: 1);
    state.recordRound(round(finishedAt: 1, peers: const [devB]));
    expect(state.peers.single.deviceId, 'devB');

    state.removePeer('devB');
    expect(state.peers, isEmpty);
    expect(state.isPeerConnectNotified('devB'), isFalse);

    // 收尾中的一轮带着旧名册回来：被压住（否则删除动作被立刻写回）。
    state.recordRound(round(finishedAt: 2, peers: const [devB]));
    expect(state.peers, isEmpty);

    // 只压一轮：设备仍在线时下一轮重新发现即恢复。
    state.recordRound(round(
      finishedAt: 3,
      peers: const [SyncPeerState(deviceId: 'devB', lastSeenAt: 3)],
    ));
    expect(state.peers.single.deviceId, 'devB');
  });

  test('移除设备：地址簿 / 已验证端点 / 首连提示一并清理，其它设备不受影响', () {
    final state = roster();
    state.recordRound(round(
      finishedAt: 10,
      peers: const [
        SyncPeerState(deviceId: 'devB', lastSeenAt: 10),
        SyncPeerState(deviceId: 'devC', lastSeenAt: 10),
      ],
    ));
    state.addManualPeer(
        const ManualPeer(host: '192.168.1.23', deviceId: 'devB'));
    state.addManualPeer(
        const ManualPeer(host: '192.168.1.24', deviceId: 'devC'));
    state.markPeerConnectNotified('devB');
    state.markPeerConnectNotified('devC');
    state.rememberLanEndpoint(const LanPeerEndpoint(
      deviceId: 'devB',
      host: '192.168.1.23',
      httpPort: 40000,
      verifiedAt: 10,
    ));

    state.removePeer('devB');

    expect(state.peers.map((peer) => peer.deviceId), ['devC']);
    expect(state.manualPeers.map((peer) => peer.host), ['192.168.1.24']);
    expect(state.isPeerConnectNotified('devB'), isFalse);
    expect(state.isPeerConnectNotified('devC'), isTrue);
    expect(state.lanEndpoints, isEmpty);
  });

  test('换口令清空旧组观测：地址簿保留，移除抑制随旧组过期', () {
    final state = roster();
    state.recordRound(round(
      finishedAt: 1,
      peers: const [SyncPeerState(deviceId: 'devB', lastSeenAt: 1)],
    ));
    state.addManualPeer(
        const ManualPeer(host: '192.168.1.23', deviceId: 'devB'));
    state.markPeerConnectNotified('devB');
    state.rememberLanEndpoint(const LanPeerEndpoint(
      deviceId: 'devB',
      host: '192.168.1.23',
      httpPort: 40000,
      verifiedAt: 1,
    ));
    state.removePeer('devX');

    state.resetGroupObservations();

    expect(state.peers, isEmpty);
    expect(state.lanEndpoints, isEmpty);
    expect(state.isPeerConnectNotified('devB'), isFalse);
    expect(state.manualPeers.single.host, '192.168.1.23',
        reason: '地址簿是用户配置，不是旧组观测');

    // 旧组留下的「刚移除」抑制也一起清掉：重新发现立即入册。
    state.recordRound(round(
      finishedAt: 2,
      peers: const [SyncPeerState(deviceId: 'devX')],
    ));
    expect(state.peers.single.deviceId, 'devX');
  });

  test('已验证端点：不可路由地址 / 非法端口 / 空 id / 无验证时间都丢弃', () {
    final state = roster();
    for (final endpoint in const [
      LanPeerEndpoint(
        deviceId: 'loopback',
        host: '127.0.0.1',
        httpPort: 40000,
        verifiedAt: 1,
      ),
      LanPeerEndpoint(
        deviceId: 'linkLocal',
        host: 'fe80::1',
        httpPort: 40000,
        verifiedAt: 1,
      ),
      LanPeerEndpoint(
        deviceId: 'hostname',
        host: 'example.com',
        httpPort: 40000,
        verifiedAt: 1,
      ),
      LanPeerEndpoint(
        deviceId: 'noPort',
        host: '192.168.1.23',
        httpPort: 0,
        verifiedAt: 1,
      ),
      LanPeerEndpoint(
        deviceId: 'badProbe',
        host: '192.168.1.23',
        httpPort: 40000,
        probePort: 70000,
        verifiedAt: 1,
      ),
      LanPeerEndpoint(
        deviceId: '',
        host: '192.168.1.23',
        httpPort: 40000,
        verifiedAt: 1,
      ),
      LanPeerEndpoint(
        deviceId: 'noVerifiedAt',
        host: '192.168.1.23',
        httpPort: 40000,
        verifiedAt: 0,
      ),
    ]) {
      expect(state.rememberLanEndpoint(endpoint), isFalse);
    }
    expect(state.lanEndpoints, isEmpty);
  });

  test('已验证端点：地址归一；新观测没带探测端口时保留旧值', () {
    final state = roster();
    expect(
      state.rememberLanEndpoint(const LanPeerEndpoint(
        deviceId: 'devB',
        host: '[2409:8a55::9]',
        httpPort: 40000,
        probePort: 47825,
        verifiedAt: 1,
      )),
      isTrue,
    );
    expect(state.lanEndpoints.single.host, '2409:8a55::9');

    expect(
      state.rememberLanEndpoint(const LanPeerEndpoint(
        deviceId: 'devB',
        host: '2409:8a55::9',
        httpPort: 40001,
        verifiedAt: 2,
      )),
      isTrue,
    );
    final endpoint = state.lanEndpoints.single;
    expect(endpoint.httpPort, 40001);
    expect(endpoint.probePort, 47825, reason: '来源端口可能变化，旧探测端口仍有效');
    expect(endpoint.verifiedAt, 2);
  });

  test('已验证端点：重复观测不标脏；仅验证时间前进要标脏（等轮末提交）', () {
    var changes = 0;
    final state = roster(onChanged: () => changes++);
    const endpoint = LanPeerEndpoint(
      deviceId: 'devB',
      host: '192.168.1.23',
      httpPort: 40000,
      verifiedAt: 1,
    );
    expect(state.rememberLanEndpoint(endpoint), isTrue);
    expect(changes, 1);

    expect(state.rememberLanEndpoint(endpoint), isFalse);
    expect(changes, 1, reason: '完全相同的观测不产生变更');

    expect(state.rememberLanEndpoint(endpoint.copyWith(verifiedAt: 2)), isTrue);
    expect(changes, 2, reason: '验证时间前进也要跨重启保留');
  });

  test('已验证端点：超过上限按 verifiedAt 淘汰最旧', () {
    final state = roster(lanEndpointLimit: 3);
    for (var i = 0; i < 5; i++) {
      state.rememberLanEndpoint(LanPeerEndpoint(
        deviceId: 'dev$i',
        host: '192.168.1.${i + 1}',
        httpPort: 40000,
        verifiedAt: i + 1,
      ));
    }

    expect(state.lanEndpoints.map((endpoint) => endpoint.deviceId),
        ['dev2', 'dev3', 'dev4']);
  });

  test('已验证端点：超过保留期随轮次淘汰，近期验证保留', () {
    final state = roster(lanEndpointRetentionMs: 1000);
    state.rememberLanEndpoint(const LanPeerEndpoint(
      deviceId: 'old',
      host: '192.168.1.23',
      httpPort: 40000,
      verifiedAt: 500,
    ));
    state.rememberLanEndpoint(const LanPeerEndpoint(
      deviceId: 'fresh',
      host: '192.168.1.24',
      httpPort: 40000,
      verifiedAt: 1500,
    ));

    state.recordRound(round(finishedAt: 1501));

    expect(state.lanEndpoints.map((endpoint) => endpoint.deviceId), ['fresh']);
  });

  test('名册：按最近接触时间倒序并截断', () {
    final state = roster(peerLimit: 2);
    state.recordRound(round(
      finishedAt: 10,
      peers: const [
        SyncPeerState(deviceId: 'old', lastSeenAt: 1),
        SyncPeerState(deviceId: 'new', lastSeenAt: 3),
        SyncPeerState(deviceId: 'mid', lastSeenAt: 2),
      ],
    ));

    expect(state.peers.map((peer) => peer.deviceId), ['new', 'mid']);
  });

  test('地址簿：学习不覆盖用户命名，用户提交同址显式改名并保留已学信息', () {
    final state = roster();
    state.addManualPeer(const ManualPeer(host: ' 192.168.1.23 ', name: '书房'));

    state.learnManualPeer(const ManualPeer(
      host: '192.168.1.23',
      deviceId: 'devB',
      httpPort: 40000,
      name: '对端广播名',
    ));
    final learned = state.manualPeers.single;
    expect(learned.host, '192.168.1.23');
    expect(learned.name, '书房', reason: '手动命名优先');
    expect(learned.deviceId, 'devB');
    expect(learned.httpPort, 40000);

    state.addManualPeer(const ManualPeer(host: '192.168.1.23', name: '新名字'));
    expect(state.manualPeers.single.name, '新名字');
    expect(state.manualPeers.single.deviceId, 'devB', reason: '改的是名字，不是身份');
  });

  test('地址簿：更新地址保留身份与已学端口，目标已有条目时并入', () {
    final state = roster();
    state.addManualPeer(const ManualPeer(
      host: '192.168.1.23',
      deviceId: 'devB',
      httpPort: 40000,
      probePort: 47825,
    ));

    expect(
      state.moveManualPeer('192.168.1.23', toHost: '192.168.1.100'),
      isTrue,
    );
    final moved = state.manualPeers.single;
    expect(moved.host, '192.168.1.100');
    expect(moved.deviceId, 'devB', reason: '改的是「设备在哪」，不是「是谁」');
    expect(moved.httpPort, 40000, reason: '已学到的端点端口保留');
    expect(moved.probePort, 47825);

    state.addManualPeer(const ManualPeer(host: '192.168.1.99'));
    expect(
      state.moveManualPeer('192.168.1.100', toHost: '192.168.1.99'),
      isTrue,
    );
    expect(state.manualPeers, hasLength(1), reason: '同一地址不重复入簿');
    final merged = state.manualPeers.single;
    expect(merged.host, '192.168.1.99');
    expect(merged.deviceId, 'devB');
    expect(merged.httpPort, 40000);
    expect(merged.probePort, 0, reason: '并入时保留目标条目自己的探测端口配置');
  });

  test('快照往返：四个字段整体替换，进程内移除抑制不来自持久化', () {
    final source = roster();
    source.recordRound(round(
      finishedAt: 1,
      peers: const [SyncPeerState(deviceId: 'devB', lastSeenAt: 1)],
    ));
    source.addManualPeer(
        const ManualPeer(host: '192.168.1.23', deviceId: 'devB'));
    source.markPeerConnectNotified('devB');
    source.rememberLanEndpoint(const LanPeerEndpoint(
      deviceId: 'devB',
      host: '192.168.1.23',
      httpPort: 40000,
      verifiedAt: 1,
    ));

    final target = roster()..applySnapshot(source.snapshot());

    expect(target.peers.single.deviceId, 'devB');
    expect(target.manualPeers.single.host, '192.168.1.23');
    expect(target.isPeerConnectNotified('devB'), isTrue);
    expect(target.lanEndpoints.single.host, '192.168.1.23');

    target.applySnapshot(SyncRosterSnapshot());
    expect(target.peers, isEmpty);
    expect(target.manualPeers, isEmpty);
    expect(target.isPeerConnectNotified('devB'), isFalse);
    expect(target.lanEndpoints, isEmpty);
  });
}
