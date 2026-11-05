import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/models/sync_peer_status.dart';
import 'package:molia/providers/sync_peer_view.dart';

/// 设备连接状态解析：五种状态。
void main() {
  const now = 2000000000;
  const startedAt = now - 1000;

  SyncRoundReport report({int started = startedAt}) => SyncRoundReport(
    trigger: SyncTrigger.manual,
    startedAt: started,
    finishedAt: started + 500,
    outcome: SyncOutcome.ok,
  );

  test('connected：最近一轮有成功接触', () {
    final peer = SyncPeerState(
      deviceId: 'devB',
      lastSeenAt: startedAt + 100,
      lastSuccessAt: startedAt + 100,
    );
    expect(
      resolveSyncPeerConnection(peer, report: report(), nowMs: now),
      SyncPeerConnectionStatus.connected,
    );
  });

  test('unreachable：最近一轮尝试过但没有成功', () {
    final peer = SyncPeerState(
      deviceId: 'devB',
      lastSeenAt: startedAt + 100,
      lastSuccessAt: startedAt - 5000,
      lastError: const SyncIssue(code: SyncIssueCode.peerReadFailed),
    );
    expect(
      resolveSyncPeerConnection(peer, report: report(), nowMs: now),
      SyncPeerConnectionStatus.unreachable,
    );
  });

  test('idle：有历史证据，但最近一轮没有尝试', () {
    final peer = SyncPeerState(
      deviceId: 'devB',
      lastSeenAt: startedAt - 5000,
      lastSuccessAt: startedAt - 5000,
      lastPullAt: startedAt - 5000,
    );
    expect(
      resolveSyncPeerConnection(peer, report: report(), nowMs: now),
      SyncPeerConnectionStatus.idle,
    );
  });

  test('never：没有任何接触证据', () {
    expect(
      resolveSyncPeerConnection(
        const SyncPeerState(deviceId: 'devB'),
        report: report(),
        nowMs: now,
      ),
      SyncPeerConnectionStatus.never,
    );
  });

  test('lost：有旧成功 + 最近失败尝试，仍按旧成功判失联', () {
    const now = 2 * SyncPeerState.lostThresholdMs;
    final peer = SyncPeerState(
      deviceId: 'devB',
      lastSeenAt: now - 1000,
      lastSuccessAt: now - SyncPeerState.lostThresholdMs - 1,
      lastError: const SyncIssue(code: SyncIssueCode.peerReadFailed),
    );
    expect(peer.isLostAt(now), isTrue);
    expect(
      resolveSyncPeerConnection(peer, report: report(), nowMs: now),
      SyncPeerConnectionStatus.lost,
    );
  });

  test('从未成功 + 反复失败：不是已失联，而是未连接', () {
    const now = 2 * SyncPeerState.lostThresholdMs;
    final peer = SyncPeerState(
      deviceId: 'devB',
      lastSeenAt: now - 1000,
      lastError: const SyncIssue(code: SyncIssueCode.peerReadFailed),
    );
    expect(peer.lastSuccessAt, 0);
    expect(peer.isLostAt(now), isFalse);
    expect(
      resolveSyncPeerConnection(peer, report: report(), nowMs: now),
      SyncPeerConnectionStatus.unreachable,
    );
  });

  test('没有最新报告时：失败原因按未连接，否则按上次同步', () {
    const failed = SyncPeerState(
      deviceId: 'devB',
      lastSeenAt: startedAt,
      lastError: SyncIssue(code: SyncIssueCode.peerReadFailed),
    );
    expect(
      resolveSyncPeerConnection(failed, nowMs: now),
      SyncPeerConnectionStatus.unreachable,
    );

    final idle = SyncPeerState(
      deviceId: 'devC',
      lastSeenAt: startedAt,
      lastSuccessAt: startedAt,
    );
    expect(
      resolveSyncPeerConnection(idle, nowMs: now),
      SyncPeerConnectionStatus.idle,
    );
  });

  group('SyncPeerView', () {
    // 失联阈值约 155 亿毫秒，now 要显著大于它才能构造「有旧成功」的失联行。
    const viewNow = 2 * SyncPeerState.lostThresholdMs;
    const reportStartedAt = viewNow - 1000;
    final report = SyncRoundReport(
      trigger: SyncTrigger.manual,
      startedAt: reportStartedAt,
      finishedAt: viewNow,
      outcome: SyncOutcome.ok,
    );

    test('空名册：没有行 / 已连接 / 失联，也没有本轮结论', () {
      final view = SyncPeerView.from(
        peers: const [],
        manualPeers: const [],
        lastReport: null,
        nowMs: viewNow,
      );

      expect(view.rows, isEmpty);
      expect(view.connected, isEmpty);
      expect(view.lost, isEmpty);
      expect(view.hasConnected, isFalse);
      expect(view.hasReport, isFalse);
    });

    test('行顺序与名册一致，connected / lost 从同一份行派生', () {
      final peers = [
        SyncPeerState(
          deviceId: 'devA',
          name: 'A',
          lastSuccessAt: reportStartedAt + 100,
          lastSeenAt: reportStartedAt + 100,
        ),
        SyncPeerState(
          deviceId: 'devB',
          name: 'B',
          lastSuccessAt: viewNow - SyncPeerState.lostThresholdMs - 1,
          lastSeenAt: viewNow - 1000,
          lastError: const SyncIssue(code: SyncIssueCode.peerReadFailed),
        ),
        SyncPeerState(
          deviceId: 'devC',
          name: 'C',
          lastSuccessAt: reportStartedAt - 5000,
          lastSeenAt: reportStartedAt - 5000,
        ),
      ];
      final view = SyncPeerView.from(
        peers: peers,
        manualPeers: const [
          ManualPeer(host: '192.168.1.2', deviceId: 'devA', name: '书房'),
          ManualPeer(host: '192.168.1.3', deviceId: 'devB', name: '  '),
          ManualPeer(host: '192.168.1.4', deviceId: 'devC', name: '客厅'),
        ],
        lastReport: report,
        nowMs: viewNow,
      );

      expect(view.rows.map((row) => row.peer.deviceId), [
        'devA',
        'devB',
        'devC',
      ], reason: '投影不重排名册');
      expect(view.rows[0].connection, SyncPeerConnectionStatus.connected);
      expect(view.rows[0].displayName, '书房', reason: '用户命名优先');
      expect(view.rows[1].connection, SyncPeerConnectionStatus.lost);
      expect(view.rows[1].displayName, 'B', reason: '手动命名为空时回退对端自报名');
      expect(view.rows[2].connection, SyncPeerConnectionStatus.idle);
      expect(view.rows[2].displayName, '客厅');
      expect(view.connected.map((row) => row.peer.deviceId), ['devA']);
      expect(view.lost.map((row) => row.peer.deviceId), ['devB']);
      expect(view.hasConnected, isTrue);
      expect(view.hasReport, isTrue);
    });

    test('没有手动命名 / 自报名：用短设备 id 兜底', () {
      const peer = SyncPeerState(deviceId: 'abcdef123456');
      final view = SyncPeerView.from(
        peers: const [peer],
        manualPeers: const [],
        lastReport: null,
        nowMs: viewNow,
      );

      expect(view.rows.single.manual, isNull);
      expect(view.rows.single.displayName, '123456');
      expect(view.rows.single.connection, SyncPeerConnectionStatus.never);
      expect(view.hasConnected, isFalse);
      expect(view.hasReport, isFalse);
    });

    test('没有最新报告：失败按未连接、有历史证据按上次同步', () {
      final view = SyncPeerView.from(
        peers: [
          const SyncPeerState(
            deviceId: 'devB',
            lastSeenAt: reportStartedAt,
            lastError: SyncIssue(code: SyncIssueCode.peerReadFailed),
          ),
          SyncPeerState(
            deviceId: 'devC',
            lastSeenAt: reportStartedAt,
            lastSuccessAt: reportStartedAt,
          ),
        ],
        manualPeers: const [],
        lastReport: null,
        nowMs: viewNow,
      );

      expect(view.rows[0].connection, SyncPeerConnectionStatus.unreachable);
      expect(view.rows[1].connection, SyncPeerConnectionStatus.idle);
      expect(view.connected, isEmpty);
      expect(view.lost, isEmpty);
      expect(view.hasReport, isFalse);
    });
  });
}
