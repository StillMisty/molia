import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_adapter.dart';
import 'package:molia/data/sync/sync_journal.dart';
import 'package:molia/data/sync/sync_known_store.dart';
import 'package:molia/data/sync/sync_round.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/data/sync/sync_transport_runtime.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/models/sync_peer_status.dart';
import 'package:molia/domain/ports/sync_transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/sync_test_support.dart';

/// 轮次整轮测试：阶段与轮次上下文都是私有实现，这里只经 `runRound` 驱动
/// （假传输 / 假适配器 / 假日志），覆盖「应用成功才推进游标」、入站失败
/// 恢复与发布 / 裁剪顺序。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late MemorySyncSecretStore secrets;
  late SyncStateStore state;
  late _RecordingAdapter adapter;
  late _RecordingJournal journal;
  late _OrderedTransport orderedTransport;
  late SyncRoundRunner runner;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    secrets = MemorySyncSecretStore();
    state = SyncStateStore(
      preferences: prefs,
      secrets: secrets,
      clock: () => 7000,
      deviceId: 'devA',
    );
    await state.init();
    await state.writePassphrase('ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789');
    await state.setTransportEnabled(SyncTransportKind.lan, true);
    adapter = _RecordingAdapter();
    journal = _RecordingJournal();
    orderedTransport = _OrderedTransport(journal.events);
    runner = SyncRoundRunner(
      state: state,
      adapters: [adapter],
      transports: {'lan': orderedTransport},
      stamps: state.stampIssuer,
      known: InMemorySyncKnownStore(),
      journal: journal,
      runtime: SyncTransportRuntime(
        state: state,
        transports: {'lan': orderedTransport},
      ),
      clock: () => DateTime.fromMillisecondsSinceEpoch(7000),
    );
  });

  SyncEnvelope remote() => SyncEnvelope(
        deviceId: 'devB',
        deviceName: 'B',
        producedAt: 6000,
        journalHead: 3,
        records: {
          SyncCategory.settings: [
            SyncRecord(
              key: 'theme_mode',
              version: const SyncVersion(physical: 9000, deviceId: 'devB'),
              data: const {'v': 'dark'},
            ),
          ],
        },
      );

  Future<SyncRoundReport> run({
    SyncTrigger trigger = SyncTrigger.manual,
    bool push = true,
    bool antiEntropy = false,
    Set<SyncCategory>? onlyCategories,
  }) =>
      runner.runRound(
        trigger: trigger,
        push: push,
        antiEntropy: antiEntropy,
        onlyCategories: onlyCategories,
      );

  test('类别受限适配器：collect 收到本轮请求的类别集合', () async {
    final scoped = _ScopedAdapter();
    final scopedRunner = SyncRoundRunner(
      state: state,
      adapters: [scoped],
      transports: const {},
      stamps: state.stampIssuer,
      known: InMemorySyncKnownStore(),
      runtime: SyncTransportRuntime(state: state, transports: const {}),
      clock: () => DateTime.fromMillisecondsSinceEpoch(7000),
    );
    addTearDown(scopedRunner.dispose);

    await scopedRunner.collect({SyncCategory.settings, SyncCategory.covers});
    expect(scoped.lastCategories, {SyncCategory.settings, SyncCategory.covers});

    // 未请求封面时仍经过 scoped 方法（适配器据此立即返回空）。
    await scopedRunner.collect({SyncCategory.settings});
    expect(scoped.lastCategories, {SyncCategory.settings});
  });

  test('collect → pull：计划带名册游标，拉取结果进入本轮', () async {
    state.recordRound(const SyncRoundReport(
      trigger: SyncTrigger.timer,
      startedAt: 0,
      finishedAt: 1,
      outcome: SyncOutcome.ok,
      peers: [SyncPeerState(deviceId: 'devB', cursorSeq: 2)],
    ));
    orderedTransport.available.add(remote());

    await run(push: false);

    expect(orderedTransport.isRunning, isTrue, reason: 'collect 阶段 ensure 运行时');
    expect(orderedTransport.lastRequest!.plan.cursorFor('devB'), 2);
    expect(orderedTransport.lastRequest!.plan.forceDiscovery, isTrue);
    expect(orderedTransport.pullCount, 1);
    expect(adapter.appliedKeys, ['theme_mode']);
    expect(orderedTransport.pushed, isEmpty, reason: '只拉不推的轮次');
  });

  test('consume → apply：远端胜出后应用，成功才推进游标', () async {
    orderedTransport.available.add(remote());

    final report = await run(push: false);

    expect(adapter.appliedKeys, ['theme_mode']);
    expect(report.applied, 1);
    expect(report.applyFailures, 0);
    expect(
      runner.peerOf('devB').cursorSeq,
      3,
      reason: '应用成功后游标才落进名册',
    );
  });

  test('apply 失败：游标不推进，记录计入失败', () async {
    adapter.failNext = true;
    orderedTransport.available.add(remote());

    final report = await run(push: false);

    expect(report.applyFailures, 1);
    expect(report.applied, 0);
    expect(
      runner.peerOf('devB').cursorSeq,
      SyncPullRequest.noCursor,
      reason: '未落地的载荷不能推进游标',
    );
  });

  test('入站轮应用失败：快照放回队列，游标不推进', () async {
    adapter.failNext = true;
    runner.enqueueInbound(remote());

    final report = await run(trigger: SyncTrigger.incoming, push: false);

    expect(orderedTransport.pullCount, 0, reason: '入站轮不联系任何对端');
    expect(report.applyFailures, 1);
    expect(
      runner.peerOf('devB').cursorSeq,
      SyncPullRequest.noCursor,
      reason: '未落地的入站载荷不能推进游标',
    );
    expect(runner.inbound, hasLength(1), reason: '对端推来的快照不能丢');
  });

  test('入站轮：不主动拉取，只消费队列里的快照', () async {
    runner.enqueueInbound(remote());

    await run(trigger: SyncTrigger.incoming, push: false);

    expect(orderedTransport.pullCount, 0, reason: '入站轮不联系任何对端');
    expect(adapter.appliedKeys, ['theme_mode']);
    expect(runner.inbound, isEmpty, reason: '本轮已消费');
  });

  test('publish：先 compact + 记录快照覆盖，再推送快照与增量', () async {
    journal.head = 5;
    journal.base = 0;
    orderedTransport.available.add(remote());

    await run();

    // compact 必须发生在构建 / 推送之前：裁剪下限读到的是本轮头部。
    expect(
      journal.events.take(2),
      ['compact:5', 'snapshot:5'],
      reason: '先裁日志、再标记本轮快照覆盖',
    );
    expect(orderedTransport.events, contains('push'));
    expect(
      journal.events.indexOf('compact:5'),
      lessThan(orderedTransport.events.indexOf('push')),
      reason: 'compact 不能被推到推送之后',
    );
    expect(
      journal.events.indexOf('snapshot:5'),
      lessThan(orderedTransport.events.indexOf('push')),
      reason: '快照覆盖先于外发，落后对端才能 bootstrap',
    );
  });

  test('同一轮拉取失败 + 推送成功：保留失败原因，不冒充成功接触', () async {
    state.recordRound(const SyncRoundReport(
      trigger: SyncTrigger.timer,
      startedAt: 0,
      finishedAt: 1,
      outcome: SyncOutcome.ok,
      peers: [SyncPeerState(deviceId: 'devB')],
    ));
    orderedTransport
      ..pullFailures = 1
      ..peersSeenOverride = 1
      ..seenIdsOverride = const []
      ..pullFailedIssues = const {
        'devB': SyncIssue(code: SyncIssueCode.peerReadFailed),
      }
      ..pushSucceededIds = const ['devB'];

    await run();

    expect(orderedTransport.pushed, isNotEmpty, reason: '本轮确实推送成功');
    final peer = runner.peerOf('devB');
    expect(peer.lastError?.code, SyncIssueCode.peerReadFailed,
        reason: '推送成功不能清掉同一轮的拉取失败');
    expect(peer.lastSuccessAt, 0, reason: '拉取失败不算成功接触');
    expect(peer.lastPushAt, 0, reason: '本轮只带回执，失败轮不推进 lastPushAt');
    expect(peer.lastSeenAt, 7000, reason: '本轮尝试时间仍应刷新');
    expect(
      resolveSyncPeerConnection(
        peer,
        report: SyncRoundReport(
          trigger: SyncTrigger.manual,
          startedAt: 7000,
          finishedAt: 7000,
          outcome: SyncOutcome.partial,
        ),
        nowMs: 7000,
      ),
      SyncPeerConnectionStatus.unreachable,
    );
  });
}

/// 共享事件序列的传输：把 push 与日志动作排在同一条时间线上，验证发布顺序。
class _OrderedTransport extends FakeSyncTransport {
  _OrderedTransport(this.events);

  final List<String> events;

  @override
  Future<SyncPushResult> push(
    SyncEnvelope envelope, {
    SyncRoundWindow? window,
  }) {
    events.add('push');
    return super.push(envelope, window: window);
  }
}

/// 可记录调用顺序的日志替身：head 可调，窗口返回空（本轮无增量）。
class _RecordingJournal implements SyncJournalStore {
  int head = 0;
  int base = 0;
  int snapshot = -1;
  final List<String> events = [];

  @override
  Future<int> headSeq() async => head;

  @override
  Future<int> baseSeq() async => base;

  @override
  Future<int> snapshotSeq() async => snapshot;

  @override
  Future<SyncJournalStats> stats() async => SyncJournalStats(
        headSeq: head,
        baseSeq: base,
        snapshotSeq: snapshot,
        entries: 0,
        bytes: 0,
        oldestAt: 0,
      );

  @override
  Future<List<SyncJournalEntry>> window(
          {int since = -1, int limit = 0}) async =>
      const [];

  @override
  Future<int> windowBytes({int since = -1}) async => 0;

  @override
  Future<void> markSnapshotBuilt(int seq) async {
    events.add('snapshot:$seq');
    snapshot = seq;
  }

  @override
  Future<int> compact({
    required int minAck,
    required int coverage,
    int? nowMs,
  }) async {
    events.add('compact:$coverage');
    return base;
  }

  @override
  Future<void> reset() async {
    head = 0;
    base = 0;
    snapshot = -1;
  }
}

/// 类别受限适配器：记录引擎实际传进来的类别集合。
class _ScopedAdapter implements CategoryScopedSyncAdapter {
  Set<SyncCategory> lastCategories = const {};

  @override
  Set<SyncCategory> get categories => const {SyncCategory.covers};

  @override
  bool get ready => true;

  @override
  Future<Map<SyncCategory, List<SyncRecord>>> collect(
          {bool fresh = false}) async =>
      const {};

  @override
  Future<Map<SyncCategory, List<SyncRecord>>> collectForCategories(
    Set<SyncCategory> categories, {
    bool fresh = false,
  }) async {
    lastCategories = {...categories};
    return const {};
  }

  @override
  Future<SyncApplyOutcome> apply(
    Map<SyncCategory, List<SyncRecord>> records,
  ) async =>
      SyncApplyOutcome.none;
}

class _RecordingAdapter implements SyncAdapter {
  bool failNext = false;
  final List<String> appliedKeys = [];

  @override
  Set<SyncCategory> get categories => const {SyncCategory.settings};

  @override
  bool get ready => true;

  @override
  Future<Map<SyncCategory, List<SyncRecord>>> collect({
    bool fresh = false,
  }) async =>
      const {
        SyncCategory.settings: [
          SyncRecord(
            key: 'theme_mode',
            version: SyncVersion(physical: 1000, deviceId: 'devA'),
            data: {'v': 'light'},
          ),
        ],
      };

  @override
  Future<SyncApplyOutcome> apply(
    Map<SyncCategory, List<SyncRecord>> records,
  ) async {
    if (failNext) {
      failNext = false;
      throw StateError('应用失败（测试注入）');
    }
    var applied = 0;
    for (final record
        in records[SyncCategory.settings] ?? const <SyncRecord>[]) {
      appliedKeys.add(record.key);
      applied++;
    }
    return SyncApplyOutcome(applied: applied);
  }
}
