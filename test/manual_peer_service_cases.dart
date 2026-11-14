import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/services/manual_peer_service.dart';

/// 手动地址表单的编排：地址入簿 → 附近设备探测 → 立即接触。
///
/// 只断言 [ManualPeerService] 的顺序与结果映射；地址簿 / 探测 / 轮次都是
/// 内存假实现，用例不必搭真 `SyncEngine` + `SyncStateStore`。
void main() {
  test('新增 + 探测成功：只提示已发出探测，不再跑接触轮', () async {
    final harness = _buildHarness()..probe.result = true;

    final outcome = await harness.service.save(
      host: '[192.168.1.7]',
      probePort: 47825,
      name: '  书房 ',
    );

    expect(outcome, SyncManualPeerOutcome.probeSent);
    expect(harness.probe.probes, [(host: '192.168.1.7', probePort: 47825)]);
    expect(harness.sync.calls, 0, reason: '探测路径不进入接触轮');
    final entry = harness.book.peers.single;
    expect(entry.host, '192.168.1.7', reason: '地址先归一（去方括号）');
    expect(entry.name, '书房', reason: '名称统一 trim');
    expect(entry.probePort, 47825);
  });

  test('新增 + 同步关闭：地址已入簿，接触按「稍后」返回', () async {
    final harness = _buildHarness()..sync.report = null;

    final outcome = await harness.service.save(
      host: '192.168.1.8',
      probePort: 47825,
    );

    expect(outcome, SyncManualPeerOutcome.contactQueued);
    expect(harness.book.peers.single.host, '192.168.1.8');
    expect(harness.sync.calls, 1, reason: '接触轮请求了，但本轮没有真正跑');
  });

  test('编辑地址 + 接触成功：保留身份与已学端口，返回 updated', () async {
    final harness = _buildHarness(
      seed: const [
        ManualPeer(
          host: '10.0.0.9',
          name: '旧名',
          probePort: 47825,
          httpPort: 51234,
          deviceId: 'devB',
        ),
      ],
    );
    final editing = harness.book.peers.single;
    harness.sync.report = _report(deviceId: 'devB', lastSeenAt: 150);

    final outcome = await harness.service.save(
      host: '10.0.0.10',
      probePort: 50000,
      name: ' 新名 ',
      editing: editing,
    );

    expect(outcome, SyncManualPeerOutcome.updated);
    final moved = harness.book.peers.single;
    expect(moved.host, '10.0.0.10');
    expect(moved.name, '新名');
    expect(moved.probePort, 50000);
    expect(moved.deviceId, 'devB', reason: '改地址不改身份');
    expect(moved.httpPort, 51234, reason: '已学到的端点端口保留');
  });

  test('本轮明确没连上：返回 unreachable，地址仍留在簿里', () async {
    final harness = _buildHarness()
      ..sync.report = _report(deviceId: 'devB', lastSeenAt: 0);

    final outcome = await harness.service.save(
      host: '10.0.0.11',
      probePort: 47825,
    );

    expect(outcome, SyncManualPeerOutcome.unreachable);
    expect(harness.book.peers.single.host, '10.0.0.11');
    expect(harness.sync.calls, 1, reason: '已跑接触轮');
  });

  test('重复添加已配对地址：接触成功返回 updated，不新增第二条', () async {
    final harness = _buildHarness(
      seed: const [ManualPeer(host: '10.0.0.12', name: '旧名', deviceId: 'devB')],
    );
    harness.probe.result = true;
    harness.sync.report = _report(deviceId: 'devB', lastSeenAt: 150);

    final outcome = await harness.service.save(
      host: '10.0.0.12',
      probePort: 47825,
      name: '新名',
    );

    expect(outcome, SyncManualPeerOutcome.updated);
    expect(harness.book.peers, hasLength(1));
    expect(harness.book.peers.single.name, '新名');
    expect(harness.probe.probes, [
      (host: '10.0.0.12', probePort: 47825),
    ], reason: '已配对地址仍发探测，只是不按「已发出探测」收口');
    expect(harness.sync.calls, 1);
  });

  test('接触成功只认本轮的 lastSeenAt（早于本轮开始 = 没连上）', () async {
    final harness = _buildHarness(
      seed: const [ManualPeer(host: '10.0.0.13', deviceId: 'devB')],
    );
    harness.sync.report = _report(deviceId: 'devB', lastSeenAt: 50);

    expect(await harness.service.contact('10.0.0.13'), isFalse);
  });

  test('地址簿尚无身份 / 本轮没跑：contact 分别返回 false / null', () async {
    final harness = _buildHarness(seed: const [ManualPeer(host: '10.0.0.14')]);

    expect(await harness.service.contact('10.0.0.14'), isFalse);

    harness.sync.report = null;
    expect(await harness.service.contact('10.0.0.14'), isNull);
  });
}

SyncRoundReport _report({required String deviceId, required int lastSeenAt}) =>
    SyncRoundReport(
      trigger: SyncTrigger.manual,
      startedAt: 100,
      finishedAt: 200,
      outcome: SyncOutcome.ok,
      peers: [SyncPeerState(deviceId: deviceId, lastSeenAt: lastSeenAt)],
    );

({ManualPeerService service, _Book book, _Probe probe, _Sync sync})
_buildHarness({List<ManualPeer> seed = const []}) {
  final book = _Book(seed);
  final probe = _Probe();
  final sync = _Sync();
  final service = ManualPeerService(
    manualPeers: () => book.peers,
    addManualPeer: book.add,
    moveManualPeer: book.move,
    probeAddress: probe.probe,
    syncNow: sync.run,
  );
  return (service: service, book: book, probe: probe, sync: sync);
}

class _Book {
  _Book(Iterable<ManualPeer> seed) : peers = [...seed];

  final List<ManualPeer> peers;

  Future<bool> add(ManualPeer peer) async {
    final index = peers.indexWhere((entry) => entry.host == peer.host);
    if (index >= 0) {
      peers[index] = peers[index].copyWith(
        name: peer.name,
        probePort: peer.probePort,
      );
      return false;
    }
    peers.add(peer);
    return true;
  }

  Future<void> move(
    String fromHost, {
    required String toHost,
    int? probePort,
    String? name,
  }) async {
    final index = peers.indexWhere((entry) => entry.host == fromHost);
    peers[index] = peers[index].copyWith(
      host: toHost,
      probePort: probePort,
      name: name,
    );
  }
}

class _Probe {
  bool result = false;
  final List<({String host, int probePort})> probes = [];

  Future<bool> probe(String host, {int probePort = 0}) async {
    probes.add((host: host, probePort: probePort));
    return result;
  }
}

class _Sync {
  SyncRoundReport? report = SyncRoundReport(
    trigger: SyncTrigger.manual,
    startedAt: 100,
    finishedAt: 200,
    outcome: SyncOutcome.ok,
    peers: const [],
  );
  int calls = 0;

  Future<SyncRoundReport?> run() async {
    calls++;
    return report;
  }
}
