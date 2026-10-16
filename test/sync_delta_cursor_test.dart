import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_adapter.dart';
import 'package:molia/data/sync/sync_engine.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/sync_test_support.dart';

/// 游标与 ack 只在**落地成功**后推进：应用失败不推进、不 ack（对端据此不会
/// 裁掉未落地的条目），窗口内的空洞（坏条目 / 未知类别）标缺口改走 bootstrap。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const passphrase = 'ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789';

  late SyncStateStore state;
  late FakeSyncTransport transport;
  late RecordingAdapter adapter;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    state = SyncStateStore(
      preferences: prefs,
      secrets: MemorySyncSecretStore(),
      clock: () => 7000,
      deviceId: 'devA',
    );
    await state.init();
    await state.writePassphrase(passphrase);
    await state.setEnabled(true);
    transport = FakeSyncTransport();
    adapter = RecordingAdapter();
  });

  SyncEnvelope delta({
    required List<SyncJournalEntry> entries,
    int baseSeq = 0,
    int windowStart = 1,
    int? windowEnd,
    String deviceId = 'devB',
  }) =>
      SyncEnvelope(
        deviceId: deviceId,
        deviceName: deviceId,
        producedAt: 5000,
        snapshotId: 'hash-${windowEnd ?? entries.length}',
        journalHead: windowEnd ?? entries.last.seq,
        baseSeq: baseSeq,
        windowStart: windowStart,
        windowEnd: windowEnd ?? entries.last.seq,
        journal: entries,
      );

  SyncJournalEntry entry(int seq, String key) => SyncJournalEntry(
        seq: seq,
        category: SyncCategory.settings,
        record: SyncRecord(
          key: key,
          version: SyncVersion(physical: 1000 + seq, deviceId: 'devB'),
          data: {'v': 'x'},
        ),
      );

  /// 全量快照（建立初始游标：对端的既有数据只能靠它引导）。
  SyncEnvelope fullSnapshot({int journalHead = 0}) => SyncEnvelope(
        deviceId: 'devB',
        deviceName: 'devB',
        producedAt: 5000,
        snapshotId: 'hash-full',
        journalHead: journalHead,
      );

  /// 建立对端游标（先引导一次全量快照）。
  Future<void> bootstrapPeer(SyncEngine sync) async {
    transport.available.add(fullSnapshot());
    await sync.syncNow();
    transport.available.clear();
  }

  SyncEngine engine() => SyncEngine(
        state: state,
        stamps: state.stampIssuer,
        adapters: [adapter],
        transports: {'lan': transport},
        // 入站合流窗口缩短：单测不用等默认的 1.5s。
        inboundWindow: const Duration(milliseconds: 10),
      );

  test('应用失败：游标不推进、ack 不前进，下一轮重取同一批条目', () async {
    final sync = engine();
    addTearDown(sync.dispose);
    await sync.syncNow();
    await bootstrapPeer(sync);
    expect(state.peers.single.cursorSeq, 0);

    transport.available.add(delta(entries: [entry(1, 'k1'), entry(2, 'k2')]));
    adapter.failNext = true;
    final failed = await sync.syncNow();
    expect(failed!.applyFailures, 1);
    expect(state.peers.single.cursorSeq, 0, reason: '未落地不推进游标');
    // 我们外发的 ack 停在已落地位置（对端不会按 minAck 裁掉这两条）。
    expect(sync.lastEnvelope?.acks['devB'], 0);

    // 下一轮成功：同一批条目重新交付并推进游标。
    adapter.reset();
    final retried = await sync.syncNow();
    expect(retried!.applied, 2);
    expect(adapter.lastKeys, ['k1', 'k2']);
    expect(state.peers.single.cursorSeq, 2);
    expect(sync.lastEnvelope?.acks['devB'], 2);
  });

  test('窗口内空洞（坏条目被丢弃）：标缺口改走 bootstrap，不静默推 windowEnd', () async {
    final sync = engine();
    addTearDown(sync.dispose);
    await sync.syncNow();
    await bootstrapPeer(sync);

    // 窗口声称覆盖 1..3，但只带 1 与 3（2 被解析层丢弃 / 对端漏发）。
    transport.available.add(delta(
      entries: [entry(1, 'k1'), entry(3, 'k3')],
      windowEnd: 3,
    ));
    final report = await sync.syncNow();

    // 缺口 → 本轮内改取全量快照（第二次 pull 带 fullPeers）。
    expect(transport.lastRequest?.fullPeers, contains('devB'));
    // 空洞之前的条目照常应用；游标不推进到 windowEnd（不跳过 seq 2），
    // 其余条目由 bootstrap 的全量快照补齐。
    expect(adapter.lastKeys, ['k1']);
    expect(state.peers.single.cursorSeq, lessThan(3));
    expect(report!.failedCount, 0);
  });

  test('入站轮发现窗口缺口：本轮内定向补 bootstrap（不再整包丢弃）', () async {
    final sync = engine();
    addTearDown(sync.dispose);
    await sync.syncNow();
    await bootstrapPeer(sync);

    final pullsBefore = transport.pullCount;
    // 对端主动推来一个起点超本机游标的增量窗口（条目已被对端裁剪）。
    await sync.onIncomingEnvelope(delta(
      entries: [entry(5, 'k5')],
      baseSeq: 4,
      windowStart: 5,
      windowEnd: 5,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 40));

    // 入站轮不再只消费：发现缺口后本轮内发起全量兜底（带 fullPeers）。
    expect(transport.pullCount, pullsBefore + 1);
    expect(transport.lastRequest?.fullPeers, contains('devB'));
  });

  test('窗口起点超出本机游标：不应用该窗口，本轮改取全量快照', () async {
    final sync = engine();
    addTearDown(sync.dispose);
    await sync.syncNow();
    await bootstrapPeer(sync);

    transport.available.add(delta(
      entries: [entry(5, 'k5')],
      baseSeq: 4,
      windowStart: 5,
      windowEnd: 5,
    ));
    await sync.syncNow();

    expect(transport.lastRequest?.fullPeers, contains('devB'));
    expect(adapter.lastKeys, isEmpty, reason: '缺口窗口不应用（不完整）');
    expect(state.peers.single.cursorSeq, 0, reason: '游标停在已消费位置（不跳到 5）');
  });
}

/// 记录交付内容的适配器（可注入一次失败）。
class RecordingAdapter implements SyncAdapter {
  int applyCalls = 0;
  List<String> lastKeys = [];
  bool failNext = false;

  void reset() {
    applyCalls = 0;
    lastKeys = [];
  }

  @override
  Set<SyncCategory> get categories => const {SyncCategory.settings};

  @override
  bool get ready => true;

  @override
  Future<Map<SyncCategory, List<SyncRecord>>> collect() async => const {};

  @override
  Future<SyncApplyOutcome> apply(
    Map<SyncCategory, List<SyncRecord>> records, {
    bool force = false,
  }) async {
    applyCalls++;
    if (failNext) {
      failNext = false;
      throw StateError('应用失败（测试注入）');
    }
    final all = [for (final list in records.values) ...list];
    lastKeys = [for (final record in all) record.key];
    return SyncApplyOutcome(applied: all.length);
  }
}
