import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_pull_plan.dart';

/// 拉取计划与「跳过」判定：不碰 socket / HTTP，只钉住证据 → 动作的规则。
///
/// 关键不变量：只有**本轮新鲜**的证据能跳过；计划要求全量时证据再新也不能
/// 跳过；局域网（snapshotId）与 WebDAV（etag）共用同一份判定。
void main() {
  SyncPeerPullEvidence lanEvidence({
    String token = 'snap-1',
    String? cached = 'snap-1',
    bool fresh = true,
    int? head = 5,
    bool trusted = true,
  }) =>
      SyncPeerPullEvidence(
        token: token,
        cachedToken: cached,
        fresh: fresh,
        journalHead: head,
        headTrusted: trusted,
      );

  test('计划携带逐对端游标 / 全量名单 / 发现策略', () {
    final plan = SyncPullPlan.fromIntents(
      discovery: SyncPullDiscovery.full,
      intents: const [
        SyncPeerPullIntent(deviceId: 'devA', cursor: 3),
        SyncPeerPullIntent(deviceId: 'devB', cursor: -1, forceFull: true),
      ],
    );

    expect(plan.forceDiscovery, isTrue);
    expect(plan.cursorFor('devA'), 3);
    expect(plan.cursorFor('devB'), -1);
    expect(plan.cursorFor('unknown'), -1);
    expect(plan.forcesFull('devB'), isTrue);
    expect(plan.forcesFull('devA'), isFalse);
  });

  test('本轮新鲜且指纹一致 + 已到头部 → 跳过', () {
    final decision = decideSyncPull(
      intent: const SyncPeerPullIntent(deviceId: 'devA', cursor: 5),
      evidence: lanEvidence(),
    );
    expect(decision.action, SyncPullAction.skip);
    expect(decision.upToDate, isTrue);
    expect(decision.sameEvidence, isTrue);
  });

  test('上一轮指纹命中缓存但本轮不新鲜 → 不能跳过（必须重取）', () {
    final decision = decideSyncPull(
      intent: const SyncPeerPullIntent(deviceId: 'devA', cursor: 5),
      evidence: lanEvidence(fresh: false, trusted: false),
    );
    expect(decision.action, SyncPullAction.delta);
    expect(decision.sameEvidence, isFalse);
  });

  test('本轮新鲜但指纹变化 → 增量', () {
    final decision = decideSyncPull(
      intent: const SyncPeerPullIntent(deviceId: 'devA', cursor: 5),
      evidence: lanEvidence(token: 'snap-2', cached: 'snap-1'),
    );
    expect(decision.action, SyncPullAction.delta);
    expect(decision.sameEvidence, isFalse);
  });

  test('游标落后对端头部 → 增量（即使指纹一致）', () {
    final decision = decideSyncPull(
      intent: const SyncPeerPullIntent(deviceId: 'devA', cursor: 3),
      evidence: lanEvidence(head: 5),
    );
    expect(decision.action, SyncPullAction.delta);
    expect(decision.upToDate, isFalse);
  });

  test('计划强制全量：证据一致也要取全量', () {
    final decision = decideSyncPull(
      intent: const SyncPeerPullIntent(
        deviceId: 'devA',
        cursor: 5,
        forceFull: true,
      ),
      evidence: lanEvidence(),
    );
    expect(decision.action, SyncPullAction.full);
  });

  test('没有版本令牌但头部可信且已到头部 → 跳过（WebDAV 无 etag 场景）', () {
    final decision = decideSyncPull(
      intent: const SyncPeerPullIntent(deviceId: 'devA', cursor: 4),
      evidence: lanEvidence(token: '', cached: null, head: 4, trusted: true),
    );
    expect(decision.action, SyncPullAction.skip);
    expect(decision.sameEvidence, isFalse);
  });

  test('没有版本令牌且头部不可信 → 增量（局域网旧 presence 场景）', () {
    final decision = decideSyncPull(
      intent: const SyncPeerPullIntent(deviceId: 'devA', cursor: 4),
      evidence: lanEvidence(
        token: '',
        cached: null,
        head: 4,
        fresh: false,
        trusted: false,
      ),
    );
    expect(decision.action, SyncPullAction.delta);
  });

  test('对端头部未知：协议判定为已到头部，但只有可信证据才跳过', () {
    final trusted = decideSyncPull(
      intent: const SyncPeerPullIntent(deviceId: 'devA', cursor: 0),
      evidence: lanEvidence(head: null, trusted: true),
    );
    expect(trusted.action, SyncPullAction.skip);

    final untrusted = decideSyncPull(
      intent: const SyncPeerPullIntent(deviceId: 'devA', cursor: 0),
      evidence: lanEvidence(head: null, fresh: false, trusted: false),
    );
    expect(untrusted.action, SyncPullAction.delta);
  });

  test('计划里没有的对端按无游标处理', () {
    const plan = SyncPullPlan.none;
    final intent = plan.intentFor('new-peer');
    expect(intent.cursor, SyncPullRequestCursor.none);
    expect(intent.forceFull, isFalse);
    expect(
      decideSyncPull(
        intent: intent,
        evidence: lanEvidence(head: 0, token: '', cached: null),
      ).action,
      SyncPullAction.delta,
      reason: '无游标的对端不能因为头部可信就跳过',
    );
  });
}
