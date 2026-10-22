import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/pages/sync_peer_status.dart';

/// 设备连接状态解析：五种状态 + 旧名册兜底。
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

  test('lost：超过 180 天没有成功接触（失败尝试不续命）', () {
    const now = 2 * SyncPeerState.lostThresholdMs;
    final peer = SyncPeerState(
      deviceId: 'devB',
      lastSeenAt: now - 1000,
      lastSuccessAt: now - SyncPeerState.lostThresholdMs - 1,
    );
    expect(
      resolveSyncPeerConnection(peer, report: report(), nowMs: now),
      SyncPeerConnectionStatus.lost,
    );
  });

  test('旧名册没有 lastSuccessAt：用最近数据流转兜底为 connected', () {
    final peer = SyncPeerState(
      deviceId: 'devB',
      lastSeenAt: startedAt + 100,
      lastPullAt: startedAt + 100,
    );
    expect(peer.lastSuccessAt, 0);
    expect(
      resolveSyncPeerConnection(peer, report: report(), nowMs: now),
      SyncPeerConnectionStatus.connected,
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
}
