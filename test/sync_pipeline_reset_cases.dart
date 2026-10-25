import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:molia/data/sync/sync_engine.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/ports/sync_transport.dart';

import 'support/sync_test_support.dart';

/// 「管线重置」语义（派生状态随版本重建 / 日志被清）：
/// 对端游标超前本机头部 → 回全量让对端重新引导；接收方游标回落到快照覆盖位置。
/// 不做这条，重置后之后 seq 更小的变更会被永久跳过（静默分歧）。
void main() {
  const passphrase = 'ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789';
  late SyncStateStore state;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    state = SyncStateStore(
      preferences: await SharedPreferences.getInstance(),
      secrets: MemorySyncSecretStore(),
      clock: () => 7000,
    );
    await state.init();
    await state.writePassphrase(passphrase);
    await state.setTransportEnabled(SyncTransportKind.lan, true);
  });

  test('serveJournal：对端游标超前本机头部（日志已重置）→ 回全量快照', () async {
    final journal = FakeJournalStore(head: 0);
    final engine = SyncEngine(
      state: state,
      stamps: state.stampIssuer,
      adapters: const [],
      transports: const {},
      journal: journal,
      clock: () => DateTime.fromMillisecondsSinceEpoch(7000),
    );
    addTearDown(engine.dispose);

    // 正常窗口：游标 0..head 走增量。
    journal.head = 5;
    final delta = await engine.serveJournal(since: 2);
    expect(delta.isDelta, isTrue);
    expect(delta.journalHead, 5);

    // 重置后头部归零、对端游标仍是旧的 → 必须回全量（不是空窗口）。
    journal.head = 0;
    final bootstrap = await engine.serveJournal(since: 5);
    expect(bootstrap.isDelta, isFalse);
  });

  test('接收侧：全量快照让游标回落到快照覆盖位置（不悬空）', () async {
    final transport = ResetTransport();
    final engine = SyncEngine(
      state: state,
      stamps: state.stampIssuer,
      adapters: const [],
      transports: {SyncTransportKind.lan: transport},
      journal: FakeJournalStore(head: 0),
      clock: () => DateTime.fromMillisecondsSinceEpoch(7000),
    );
    addTearDown(engine.dispose);
    await engine.init();

    // 先按「对端头部 9」推进游标。
    transport.snapshot = _snapshot(deviceId: 'dev-b', journalHead: 9);
    await engine.syncNow(trigger: SyncTrigger.timer, push: false);
    expect(_cursorOf(state, 'dev-b'), 9);

    // 对端日志重置：全量快照声明头部 0 → 游标回落，后续变更才能被取到。
    transport.snapshot = _snapshot(deviceId: 'dev-b', journalHead: 0);
    await engine.syncNow(trigger: SyncTrigger.timer, push: false);
    expect(_cursorOf(state, 'dev-b'), 0);
  });
}

int _cursorOf(SyncStateStore state, String deviceId) {
  for (final peer in state.peers) {
    if (peer.deviceId == deviceId) return peer.cursorSeq;
  }
  return -1;
}

SyncEnvelope _snapshot({required String deviceId, required int journalHead}) =>
    SyncEnvelope(
      deviceId: deviceId,
      deviceName: deviceId,
      producedAt: 6000,
      journalHead: journalHead,
      records: const {},
    );

/// 只回一份全量快照的传输（重置场景：对端头部变小）。
class ResetTransport implements SyncTransport {
  SyncEnvelope snapshot = _snapshot(deviceId: 'dev-b', journalHead: 0);

  @override
  String get kind => SyncTransportKind.lan;

  @override
  bool get isRunning => true;

  @override
  String? get unavailableReason => null;

  @override
  String? get unavailableDetail => null;

  @override
  bool get servesLiveSnapshot => true;

  @override
  ({int v4, int v6}) get discoveryPorts => (v4: 0, v6: 0);

  @override
  Stream<SyncEnvelope> get incoming => const Stream.empty();

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<SyncPullResult> pull(
          [SyncPullRequest request = SyncPullRequest.none]) async =>
      SyncPullResult(envelopes: [snapshot], peersSeen: 1, contacted: true);

  @override
  Future<SyncPushResult> push(
    SyncEnvelope envelope, {
    SyncRoundWindow? window,
  }) async =>
      const SyncPushResult(succeededPeers: 1);

  @override
  Future<bool> deleteRemote(String deviceId) async => false;
}
