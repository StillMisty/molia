import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_adapter.dart';
import 'package:molia/data/sync/sync_known_store.dart';
import 'package:molia/data/sync/sync_round.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/data/sync/sync_transport_runtime.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/ports/sync_transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/sync_test_support.dart';

/// 轮次阶段单测：不跑完整 syncNow，只调用 collect / pull / consume / apply，
/// 验证阶段之间的契约与「应用成功才推进游标」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late MemorySyncSecretStore secrets;
  late SyncStateStore state;
  late FakeSyncTransport transport;
  late SyncTransportRuntime runtime;
  late _RecordingAdapter adapter;
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
    transport = FakeSyncTransport();
    runtime =
        SyncTransportRuntime(state: state, transports: {'lan': transport});
    adapter = _RecordingAdapter();
    runner = SyncRoundRunner(
      state: state,
      adapters: [adapter],
      transports: {'lan': transport},
      stamps: state.stampIssuer,
      known: InMemorySyncKnownStore(),
      runtime: runtime,
      clock: () => DateTime.fromMillisecondsSinceEpoch(7000),
    );
  });

  SyncRoundContext context({
    SyncTrigger trigger = SyncTrigger.manual,
    bool push = true,
    bool antiEntropy = false,
    Set<SyncCategory>? onlyCategories,
  }) =>
      SyncRoundContext(
        trigger: trigger,
        push: push,
        antiEntropy: antiEntropy,
        onlyCategories: onlyCategories,
        startedAt: 7000,
        window: const SyncRoundWindow(startedAt: 7000),
      );

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

  test('collect → pull：计划带名册游标，拉取结果进入上下文', () async {
    state.recordRound(SyncRoundReport(
      trigger: SyncTrigger.timer,
      startedAt: 0,
      finishedAt: 1,
      outcome: SyncOutcome.ok,
      peers: const [SyncPeerState(deviceId: 'devB', cursorSeq: 2)],
    ));
    transport.available.add(remote());

    final round = context();
    await runner.collectStage(round);
    expect(transport.isRunning, isTrue, reason: '运行时在 collect 阶段 ensure');
    expect(round.localChanged, isTrue);
    expect(
      round.accumulators['lan']!.enabled,
      isTrue,
    );

    await runner.pullStage(round);
    expect(transport.lastRequest!.plan.cursorFor('devB'), 2);
    expect(transport.lastRequest!.plan.forceDiscovery, isTrue);
    expect(round.pulledEntries, hasLength(1));
    expect(round.pulledEntries.single.$1, 'lan');
    expect(round.inboundOnly, isFalse);
  });

  test('consume → apply：远端胜出后应用，成功才推进游标', () async {
    transport.available.add(remote());
    final round = context();
    await runner.collectStage(round);
    await runner.pullStage(round);
    await runner.consumeStage(round);

    expect(round.remoteRecords[SyncCategory.settings], hasLength(1));
    expect(round.pendingCursors['devB'], 3);

    await runner.applyStage(round);
    expect(adapter.appliedKeys, ['theme_mode']);
    expect(round.applied, 1);
    expect(round.applyFailures, 0);
    expect(
      runner.peerOf('devB').cursorSeq,
      3,
      reason: '应用成功后游标才落进名册',
    );
  });

  test('apply 失败：游标不推进，记录计入失败', () async {
    adapter.failNext = true;
    transport.available.add(remote());
    final round = context();
    await runner.collectStage(round);
    await runner.pullStage(round);
    await runner.consumeStage(round);

    await runner.applyStage(round);
    expect(round.applyFailures, 1);
    expect(round.applied, 0);
    expect(
      runner.peerOf('devB').cursorSeq,
      SyncPullRequest.noCursor,
      reason: '未落地的载荷不能推进游标',
    );
  });

  test('入站轮：不主动拉取，只消费队列里的快照', () async {
    runner.enqueueInbound(remote());
    final round = context(trigger: SyncTrigger.incoming, push: false);
    await runner.collectStage(round);
    await runner.pullStage(round);

    expect(transport.pullCount, 0, reason: '入站轮不联系任何对端');
    expect(round.pulledEntries, hasLength(1));
    expect(round.pulledEntries.single.$1, '', reason: '入站载荷没有传输归属');
  });
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
