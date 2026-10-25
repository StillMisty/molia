import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_peer_candidate.dart';

/// 局域网对端候选的纯决策：观测合并（新鲜度优先）与地址尝试顺序。
void main() {
  SyncPeerCandidate candidate({
    String deviceId = 'devA',
    String host = '192.168.1.10',
    int port = 8080,
    List<String> addresses = const [],
    List<String> alternateHosts = const [],
    String snapshotId = '',
    int? journalHead,
    bool fresh = false,
    bool expected = true,
  }) =>
      SyncPeerCandidate(
        deviceId: deviceId,
        name: '',
        host: host,
        port: port,
        addresses: addresses,
        alternateHosts: alternateHosts,
        snapshotId: snapshotId,
        journalHead: journalHead,
        snapshotFresh: fresh,
        expected: expected,
      );

  test('合并：本轮观测的指纹优先于上一轮记忆', () {
    final stale = candidate(snapshotId: 'old', journalHead: 3);
    final fresh = candidate(snapshotId: 'new', journalHead: 5, fresh: true);

    final merged = stale.merge(fresh);
    expect(merged.snapshotId, 'new');
    expect(merged.journalHead, 5);
    expect(merged.snapshotFresh, isTrue);

    final reverse = fresh.merge(stale);
    expect(reverse.snapshotId, 'new');
    expect(reverse.journalHead, 5);
  });

  test('合并：两侧都新鲜时字段级取非空值；都不新鲜只保留缓存标记', () {
    final a = candidate(snapshotId: 'a', journalHead: 2, fresh: true);
    final b = candidate(snapshotId: '', journalHead: 4, fresh: true);
    final merged = a.merge(b);
    expect(merged.snapshotId, 'a');
    expect(merged.journalHead, 4);

    final staleA = candidate(snapshotId: 'x', journalHead: 1);
    final staleB = candidate(snapshotId: '', journalHead: 2);
    final staleMerged = staleA.merge(staleB);
    expect(staleMerged.snapshotId, 'x');
    expect(staleMerged.journalHead, 1);
    expect(staleMerged.snapshotFresh, isFalse);
  });

  test('合并：地址 / 备用地址并集、身份字段取非空、预期状态取或', () {
    final manual = candidate(
      deviceId: '',
      host: '192.168.1.10',
      port: 0,
      expected: true,
    );
    final presence = candidate(
      deviceId: 'devA',
      host: '192.168.1.11',
      port: 8080,
      addresses: const ['192.168.1.11'],
      alternateHosts: const ['10.0.0.2'],
      expected: false,
    );

    final merged = manual.merge(presence);
    expect(merged.deviceId, 'devA');
    expect(merged.port, 8080);
    expect(merged.host, '192.168.1.10', reason: '已有首选地址不被覆盖');
    expect(merged.addresses, ['192.168.1.11']);
    expect(merged.alternateHosts, contains('192.168.1.11'));
    expect(merged.alternateHosts, contains('10.0.0.2'));
    expect(merged.expected, isTrue);
  });

  test('地址排序：IPv4 → 全局 / ULA IPv6 → 观测源地址 → link-local，去重且限 3 个', () {
    final hosts = orderPeerHosts(
      addresses: const [
        'fe80::1%eth0',
        '2409:8a55::1',
        '192.168.1.10',
        '192.168.1.10',
      ],
      primary: '10.0.0.2',
      alternates: const ['2409:8a55::2', 'fe80::2'],
    );

    expect(hosts, [
      '192.168.1.10',
      '10.0.0.2',
      '2409:8a55::1',
    ]);
  });

  test('地址排序：非 IP 字面量排最后，仍可作为兜底', () {
    final hosts = orderPeerHosts(
      addresses: const ['peer.local'],
      primary: '192.168.1.10',
    );
    expect(hosts, ['192.168.1.10', 'peer.local']);
  });

  test('去重键与展示名：认领 id 后按 id，未认领按端点', () {
    expect(candidate(deviceId: 'devA').key, 'devA');
    final unresolved = candidate(deviceId: '', host: '10.0.0.9', port: 9000);
    expect(unresolved.key, 'host:10.0.0.9:9000');
    expect(unresolved.label, '10.0.0.9');

    final named = candidate(deviceId: 'devA').merge(
      SyncPeerCandidate(
        deviceId: 'devA',
        name: '书房',
        host: '192.168.1.10',
        port: 8080,
        expected: true,
      ),
    );
    expect(named.label, '书房');
  });
}
