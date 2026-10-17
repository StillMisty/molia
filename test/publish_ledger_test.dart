/// 发布台账：plan 的四类门控结果（快照·覆盖够到 / 快照·内容指纹未变 /
/// 快照·需要发布 / 增量·窗口与 ack 未变）、mark 的记账（成功才记，零对端与
/// 失败都遗忘，快照成功推进持久覆盖）与 compact 覆盖下限的推导。
///
/// 真 `SyncStateStore`（SharedPreferences mock）+ 可假替的能力位：断言只经
/// 台账的公开动作、状态存储的键值与 `journalCoverage`，不读私有字段。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/publish_ledger.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/ports/sync_transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/sync_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const webdav = SyncTransportKind.webdav;

  late SharedPreferences prefs;
  late SyncStateStore state;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    state = SyncStateStore(
      preferences: prefs,
      secrets: MemorySyncSecretStore(),
      deviceId: 'devA',
    );
    await state.init();
  });

  /// 全量快照载荷（身份 = 内容指纹）。
  SyncEnvelope snapshot(String snapshotId) => SyncEnvelope(
        deviceId: 'devA',
        producedAt: 1000,
        snapshotId: snapshotId,
      );

  /// 增量窗口载荷（身份 = 窗口边界 + ack 集合）。
  SyncEnvelope delta(
    int windowStart,
    int windowEnd, {
    Map<String, int> acks = const {},
  }) =>
      SyncEnvelope(
        deviceId: 'devA',
        producedAt: 1000,
        windowStart: windowStart,
        windowEnd: windowEnd,
        journal: const [],
        acks: acks,
      );

  PublishLedger ledger({
    String kind = SyncTransportKind.lan,
    bool live = true,
  }) =>
      PublishLedger(kind: kind, state: state, servesLiveSnapshot: () => live);

  /// 确实有对端收下且没有失败。
  const delivered = SyncPushResult(succeededPeers: 1);

  /// 零对端（局域网开关开着但无人在线）：不算推送成功。
  const noPeers = SyncPushResult.none;

  const failed = SyncPushResult(failedPeers: 1);

  test('全量快照：内容指纹未变 → 跳过加密与上传', () async {
    // 未注入增量日志（snapshotSeq = null）：没有覆盖可依，每轮都外发。
    final lan = ledger();
    expect(lan.plan(snapshot('s1')), isTrue);
    await lan.mark(delivered);
    expect(lan.plan(snapshot('s1')), isFalse);
    expect(lan.plan(snapshot('s2')), isTrue);
    await lan.mark(delivered);
    expect(lan.plan(snapshot('s2')), isFalse);
  });

  test('全量快照：已发布覆盖够到本轮构建位置 → 跳过（不重写文件）', () async {
    final file = ledger(kind: webdav, live: false);
    expect(file.plan(snapshot('s1'), snapshotSeq: 5), isTrue);
    await file.mark(delivered);
    expect(state.snapshotPushSeq(webdav), 5);

    // 覆盖够到：内容指纹变了也不重发（对端拿到的那份已覆盖窗口起点）。
    expect(file.plan(snapshot('s2'), snapshotSeq: 5), isFalse);
    // 覆盖推进（超硬上限重写）：重发。
    expect(file.plan(snapshot('s2'), snapshotSeq: 6), isTrue);
  });

  test('全量快照：内容指纹为空时无法比对，保守外发', () async {
    final lan = ledger();
    expect(lan.plan(snapshot('')), isTrue);
    await lan.mark(delivered);
    expect(lan.plan(snapshot('')), isTrue);
  });

  test('增量窗口：窗口边界 + ack 集合未变 → 跳过；任一变化 → 外发', () async {
    final lan = ledger();
    expect(lan.plan(delta(1, 3)), isTrue);
    await lan.mark(delivered);
    expect(lan.plan(delta(1, 3)), isFalse);
    expect(lan.plan(delta(1, 4)), isTrue, reason: '窗口变');
    expect(lan.plan(delta(2, 3)), isTrue, reason: '起点变');
    // ack 推进：窗口没变也要外发一次（对端据此裁自己的日志）。
    expect(lan.plan(delta(1, 3, acks: {'devB': 2})), isTrue);
    await lan.mark(delivered);
    // 身份与 map 插入顺序无关。
    expect(lan.plan(delta(1, 3, acks: {'devC': 5, 'devB': 2})), isTrue);
    await lan.mark(delivered);
    expect(lan.plan(delta(1, 3, acks: {'devB': 2, 'devC': 5})), isFalse);
  });

  test('mark：零对端与失败都不算推送成功，遗忘指纹下轮重试', () async {
    final lan = ledger();
    expect(lan.plan(snapshot('s1')), isTrue);
    await lan.mark(noPeers);
    expect(lan.plan(snapshot('s1')), isTrue, reason: '零对端不算推过');

    await lan.mark(delivered);
    expect(lan.plan(snapshot('s1')), isFalse);

    // 失败显式遗忘：已经成功过的旧指纹同样作废，下一轮重发。
    expect(lan.plan(snapshot('s2')), isTrue);
    await lan.mark(failed);
    expect(lan.plan(snapshot('s2')), isTrue);
    expect(lan.plan(snapshot('s1')), isTrue);

    // 失败也不推进持久覆盖。
    final file = ledger(kind: webdav, live: false);
    expect(file.plan(snapshot('s1'), snapshotSeq: 3), isTrue);
    await file.mark(failed);
    expect(state.snapshotPushSeq(webdav), -1);
  });

  test('mark：没有配对 plan 的调用是空操作', () async {
    final lan = ledger();
    await lan.mark(delivered);
    expect(lan.plan(snapshot('s1')), isTrue);
  });

  test('全量快照的持久覆盖跨重启不回退（新存储 + 新台账）', () async {
    final file = ledger(kind: webdav, live: false);
    expect(file.plan(snapshot('s1'), snapshotSeq: 7), isTrue);
    await file.mark(delivered);

    final reloaded = SyncStateStore(
      preferences: prefs,
      secrets: MemorySyncSecretStore(),
      deviceId: 'devA',
    );
    await reloaded.init();
    expect(reloaded.snapshotPushSeq(webdav), 7);

    // 内存指纹随进程消失，但覆盖还在：够到即跳过。
    final restarted = PublishLedger(
      kind: webdav,
      state: reloaded,
      servesLiveSnapshot: () => false,
    );
    expect(restarted.plan(snapshot('s1'), snapshotSeq: 7), isFalse);
    expect(restarted.plan(snapshot('s1'), snapshotSeq: 8), isTrue);
  });

  test('publishedCoverage：实时快照的传输不约束；文件型传输未发布 → 0', () async {
    expect(ledger().publishedCoverage, isNull);

    final file = ledger(kind: webdav, live: false);
    expect(file.publishedCoverage, 0, reason: '从未发布过：不能裁到任何位置');
    expect(file.plan(snapshot('s1'), snapshotSeq: 4), isTrue);
    await file.mark(delivered);
    expect(file.publishedCoverage, 4);
  });

  test('能力位在判定时读取：假替成文件型传输后开始约束裁剪', () async {
    var live = true;
    final lan = PublishLedger(
      kind: SyncTransportKind.lan,
      state: state,
      servesLiveSnapshot: () => live,
    );
    expect(lan.publishedCoverage, isNull);
    live = false;
    expect(lan.publishedCoverage, 0);
  });

  test('journalCoverage：只统计启用且需要发布快照文件的传输，取最小值', () async {
    final lan = ledger();
    final fileA = ledger(kind: webdav, live: false);
    final fileB = ledger(kind: 'backup', live: false);
    expect(fileA.plan(snapshot('s1'), snapshotSeq: 4), isTrue);
    await fileA.mark(delivered);
    expect(fileB.plan(snapshot('s1'), snapshotSeq: 6), isTrue);
    await fileB.mark(delivered);

    final ledgers = [lan, fileA, fileB];
    // 只有实时快照的传输：没有约束（返回头部）。
    expect(
      journalCoverage(ledgers: ledgers, enabledKinds: {'lan'}, journalHead: 9),
      9,
    );
    // 未启用的文件型传输不参与。
    expect(
      journalCoverage(
        ledgers: ledgers,
        enabledKinds: {'lan', webdav},
        journalHead: 9,
      ),
      4,
    );
    // 多个文件型传输：取最小值。
    expect(
      journalCoverage(
        ledgers: ledgers,
        enabledKinds: {'lan', webdav, 'backup'},
        journalHead: 9,
      ),
      4,
    );
    // 覆盖够到头部：下限就是头部本身。
    expect(
      journalCoverage(
        ledgers: [fileB],
        enabledKinds: {'backup'},
        journalHead: 6,
      ),
      6,
    );
    // 从未发布过的文件型传输把下限钉在 0。
    expect(
      journalCoverage(
        ledgers: [lan, fileB, ledger(kind: 'webdav-2', live: false)],
        enabledKinds: {'lan', 'backup', 'webdav-2'},
        journalHead: 9,
      ),
      0,
    );
  });
}
