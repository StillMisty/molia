import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_journal.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/domain/ports/sync_transport.dart';

import 'support/sync_network.dart';

/// 增量协议与多设备（N≥3）验收：
/// - 一次变更只产生 1 份 journal 增量，其余设备各拉 1 次增量，解密次数与
///   字节数恒定（不随库大小变化）；
/// - 落后超出日志窗口 → 走 bootstrap 全量快照，数据完整（含墓碑语义）；
/// - 名册落后量（behindBy / behindBytes）随对端 ack 更新。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const passphrase = 'ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789';

  late SyncNetwork network;

  setUp(() {
    network = SyncNetwork(passphrase: passphrase);
  });

  tearDown(() => network.dispose());

  /// 三方首次接触：各自跑一轮，互相引导（首次是全量快照）。
  Future<(SyncDevice, SyncDevice, SyncDevice)> settleThree() async {
    final a = await network.addDevice('devA');
    final b = await network.addDevice('devB');
    final c = await network.addDevice('devC');
    for (var i = 0; i < 2; i++) {
      await a.engine.syncNow();
      await b.engine.syncNow();
      await c.engine.syncNow();
    }
    return (a, b, c);
  }

  test('N=3：一次变更只产生 1 份增量，其余两台各拉 1 次（字节数不随库大小变化）', () async {
    final (a, b, c) = await settleThree();
    // 存量数据：直接入库（不进日志），只影响全量快照体积。
    await seedHistoryRows(a.db, 400);
    await a.engine.syncNow();
    // 先量一次全量快照体积（对端 D 首次引导会走 bootstrap）。
    final d = await network.addDevice('devD');
    network.resetCounters();
    await d.engine.syncNow();
    final bootstrapBytes = network.bytesTransferred;
    expect(network.bootstrapServed, greaterThan(0));
    expect(bootstrapBytes, greaterThan(1000));

    // A 的一次本地变更：设置键变化 → 1 条日志 + 1 份增量。
    await a.setSetting('theme_mode', 'dark');
    network.resetCounters();
    await a.engine.syncNow();

    expect(await a.journal.headSeq(), 1);
    expect(await a.journal.window(), hasLength(1));

    // 其余两台各拉 1 次增量：从 A 拉到 1 份解密、1 份小载荷（不随库大小变化）。
    for (final device in [b, c]) {
      network.resetCounters();
      await device.engine.syncNow();
      expect(device.prefs.getString('theme_mode'), 'dark');
      expect(network.deltaServed, greaterThan(0));
      expect(network.pullDecryptionsByPeer['devA'], 1);
      expect(network.pullBytesByPeer['devA'], lessThan(1024));
      // 与 400 行存量数据的全量快照相比：增量小一个数量级以上。
      expect(network.pullBytesByPeer['devA'], lessThan(bootstrapBytes ~/ 8));
    }
  });

  test('落后超出日志窗口：改走 bootstrap 全量快照，数据完整（含墓碑语义）', () async {
    // A 的日志上限压到 2 条：写第 3 条时超限 → 只保留最新两条、覆盖推进到头部。
    final a = await network.addDevice(
      'devA',
      deviceLimits: const SyncJournalLimits(maxEntries: 2),
    );
    final b = await network.addDevice('devB');
    final c = await network.addDevice('devC');

    // 首次引导：B / C 从 A 拿到初始状态。
    await a.engine.syncNow();
    await b.engine.syncNow();
    await c.engine.syncNow();

    // A 连续三次变更（B / C 都不在线，游标停在 0）。
    await a.setSetting('theme_mode', 'dark');
    await a.engine.syncNow();
    await a.setSetting('theme_mode', 'light');
    await a.engine.syncNow();
    await a.setSetting('theme_mode', 'system');
    await a.engine.syncNow();
    expect(await a.journal.headSeq(), 3);
    // 超硬上限：只保留最新 2 条，最旧一条被裁剪（覆盖推进到头部）。
    expect(await a.journal.baseSeq(), 1);
    expect(await a.journal.snapshotSeq(), 3);

    // B 的游标（0）落后于窗口起点（baseSeq = 1）→ 必须 bootstrap。
    network.resetCounters();
    await b.engine.syncNow();
    expect(network.bootstrapServed, greaterThan(0));
    expect(b.prefs.getString('theme_mode'), 'system');
    expect(peerOf(b, 'devA').cursorSeq, 3);

    // 墓碑语义：A 删掉一条历史（删除也取新，写墓碑），再写两条把窗口推超上限；
    // C 落后于窗口起点 → bootstrap，落地后条目同样消失。
    await a.library.addHistoryEntry(const PlayHistoryEntry(
      sourceKey: 'kuwo',
      songId: 'song-1',
      title: '要删的歌',
      playedAt: 10,
    ));
    await a.engine.syncNow();
    await a.library.deleteHistoryEntry('kuwo', 'song-1');
    await a.engine.syncNow();
    await a.setSetting('theme_mode', 'dark');
    await a.engine.syncNow();
    await a.setSetting('theme_mode', 'system');
    await a.engine.syncNow();

    expect(peerOf(c, 'devA').cursorSeq, 0);
    network.resetCounters();
    await c.engine.syncNow();
    expect(network.bootstrapServed, greaterThan(0));
    expect(c.prefs.getString('theme_mode'), 'system');
    // 数据完整：删除的条目在对端也不存在，且墓碑已落地（防止旧快照复活）。
    expect(await c.library.listHistory(), isEmpty);
    expect(
      await c.library.syncExportTombstones(['history']),
      hasLength(1),
    );
    expect(peerOf(c, 'devA').cursorSeq, await a.journal.headSeq());
  });

  test('compact 不丢未 ack 的条目：落后对端仍能拿到全部增量', () async {
    final a = await network.addDevice('devA');
    final b = await network.addDevice('devB');
    await a.engine.syncNow();
    await b.engine.syncNow();

    // A 写两条变更；B 只拉到第一条（游标 1）并回传 ack。
    await a.setSetting('theme_mode', 'dark');
    await a.engine.syncNow();
    await b.engine.syncNow();
    expect(b.state.peers.single.cursorSeq, 1);

    await a.setSetting('theme_mode', 'light');
    await a.engine.syncNow();
    // A 拉一次 B 的载荷：学到 B 的 ack = 1。
    await a.engine.syncNow();
    expect(a.state.peers.single.ackedSeq, 1);

    // A compact：快照覆盖 = 2（首次构建即头部），minAck = 1 → 只裁到 1。
    expect(await a.journal.baseSeq(), 1);
    expect([for (final entry in await a.journal.window()) entry.seq], [2]);

    // B 的游标 1 ≥ baseSeq 1：不用 bootstrap，直接拉第 2 条增量。
    network.resetCounters();
    await b.engine.syncNow();
    expect(network.bootstrapServed, 0);
    expect(b.prefs.getString('theme_mode'), 'light');
    expect(b.state.peers.single.cursorSeq, 2);
  });

  test('名册落后量：behindBy / behindBytes 随对端 ack 更新，补齐后清空', () async {
    final a = await network.addDevice('devA');
    final b = await network.addDevice('devB');
    await a.engine.syncNow();
    await b.engine.syncNow();

    await a.setSetting('theme_mode', 'dark');
    await a.engine.syncNow();
    await b.engine.syncNow();
    // A 学 B 的 ack = 1。
    await a.engine.syncNow();
    final upToDate = a.state.peers.single;
    expect(upToDate.behindBy, isNull);

    // A 再写两条，B 不拉：A 的名册里 B 落后 2 条。
    await a.setSetting('theme_mode', 'light');
    await a.engine.syncNow();
    await a.setSetting('theme_mode', 'system');
    await a.engine.syncNow();
    final behind = a.state.peers.single;
    expect(behind.behindBy, 2);
    expect(behind.behindBytes, greaterThan(0));
    expect(behind.isLostAt(a.state.nowMs()), isFalse);

    // B 补齐：落后量清空。
    await b.engine.syncNow();
    await a.engine.syncNow();
    expect(a.state.peers.single.behindBy, isNull);
  });

  test('anti-entropy：发现并修复人为篡改的本地数据（静默分歧）', () async {
    // 可控时钟：越过 anti-entropy 的兜底节流间隔。
    var now = DateTime.now().millisecondsSinceEpoch;
    int clock() => now;
    final a = await network.addDevice('devA', clock: clock);
    final b = await network.addDevice('devB', clock: clock);
    await a.library.addHistoryEntry(const PlayHistoryEntry(
      sourceKey: 'kuwo',
      songId: 'song-1',
      title: '要被篡改的歌',
      playedAt: 10,
    ));
    await a.engine.syncNow();
    await b.engine.syncNow();
    expect(await b.library.listHistory(), hasLength(1));

    // 人为篡改：绕过同步层直接删库内行（日志与登记都没有变化）。
    await (b.db.delete(b.db.playHistory)).go();
    expect(await b.library.listHistory(), isEmpty);

    // 普通轮次发现不了：对端没有新条目，本机也没有日志缺口。
    await b.engine.syncNow();
    expect(await b.library.listHistory(), isEmpty);

    // anti-entropy 轮：指纹不一致 → 全量兜底 → 数据修复。
    now += 11 * 60 * 1000;
    network.resetCounters();
    await b.engine.syncNow(antiEntropy: true);
    expect(network.bootstrapServed, greaterThan(0));
    expect(await b.library.listHistory(), hasLength(1));
    expect((await b.library.listHistory()).single.title, '要被篡改的歌');

    // 修复后指纹一致：再跑 anti-entropy 轮不再重复全量拉取。
    now += 11 * 60 * 1000;
    network.resetCounters();
    await b.engine.syncNow(antiEntropy: true);
    expect(network.bootstrapServed, 0);
  });

  test('首次引导：对端还没跑过轮次也能拿到完整快照（不是空快照）', () async {
    final a = await network.addDevice('devA');
    final b = await network.addDevice('devB');
    // A 有数据但还没跑过轮次（快照按需就地构建）。
    await a.library.addHistoryEntry(const PlayHistoryEntry(
      sourceKey: 'kuwo',
      songId: 'song-1',
      title: '存量歌曲',
      playedAt: 10,
    ));

    await b.engine.syncNow();
    expect(await b.library.listHistory(), hasLength(1));
    // 游标推进到 A 的日志头部（快照覆盖位置），后续只拉增量。
    expect(peerOf(b, 'devA').cursorSeq, await a.journal.headSeq());

    // A 之后的新变更照常以增量送达，且不会覆盖掉首次拿到的存量数据。
    await a.setSetting('theme_mode', 'dark');
    await a.engine.syncNow();
    await b.engine.syncNow();
    expect(b.prefs.getString('theme_mode'), 'dark');
    expect(await b.library.listHistory(), hasLength(1));
  });

  test('anti-entropy：直改内容（版本不变）也能修回远端值', () async {
    var now = DateTime.now().millisecondsSinceEpoch;
    int clock() => now;
    final a = await network.addDevice('devA', clock: clock);
    final b = await network.addDevice('devB', clock: clock);
    await a.library.addHistoryEntry(const PlayHistoryEntry(
      sourceKey: 'kuwo',
      songId: 'song-1',
      title: '远端标题',
      playedAt: 10,
    ));
    await a.engine.syncNow();
    await b.engine.syncNow();
    expect((await b.library.listHistory()).single.title, '远端标题');

    // 直改标题（版本三列不动）：LWW 判不出差异，只有全量兜底能修。
    await (b.db.update(b.db.playHistory)
          ..where((t) => t.songId.equals('song-1')))
        .write(const PlayHistoryCompanion(title: Value('被篡改的标题')));

    now += 11 * 60 * 1000;
    network.resetCounters();
    await b.engine.syncNow(antiEntropy: true);

    expect(network.bootstrapServed, greaterThan(0));
    expect((await b.library.listHistory()).single.title, '远端标题');
  });

  test('失联设备不拖住日志裁剪：compact 的 minAck 跳过失联对端', () async {
    final a = await network.addDevice(
      'devA',
      deviceLimits: const SyncJournalLimits(maxEntries: 2),
    );
    final ghost = await network.addDevice('devGhost');
    await a.engine.syncNow();
    await ghost.engine.syncNow();
    // ghost 只 ack 到 0；随后离线（不再参与网络）。
    network.devices.remove('devGhost');
    final ancient = DateTime.now().millisecondsSinceEpoch -
        SyncPeerState.lostThresholdMs -
        1000;
    a.state.recordRound(SyncRoundReport(
      trigger: SyncTrigger.timer,
      startedAt: 0,
      finishedAt: 1,
      outcome: SyncOutcome.ok,
      peers: [
        SyncPeerState(
          deviceId: 'devGhost',
          lastSeenAt: ancient,
          cursorSeq: 0,
          ackedSeq: 0,
        ),
      ],
    ));

    // 三次变更超过条数上限：失联设备的旧 ack 不参与 minAck → 正常裁剪。
    await a.setSetting('theme_mode', 'dark');
    await a.engine.syncNow();
    await a.setSetting('theme_mode', 'light');
    await a.engine.syncNow();
    await a.setSetting('theme_mode', 'system');
    await a.engine.syncNow();

    expect(await a.journal.baseSeq(), greaterThan(0));
    expect(await a.journal.snapshotSeq(), await a.journal.headSeq());
  });

  test('失联对端不钉住日志窗口（minAck 跳过它）', () async {
    final a = await network.addDevice(
      'devA',
      deviceLimits: const SyncJournalLimits(maxEntries: 2),
    );
    final b = await network.addDevice('devB');
    await a.engine.syncNow();
    await b.engine.syncNow();
    // B 只 ack 到 0；随后失联（超过 180 天无接触）。
    a.state.recordRound(SyncRoundReport(
      trigger: SyncTrigger.timer,
      startedAt: 0,
      finishedAt: 1,
      outcome: SyncOutcome.ok,
      peers: [
        SyncPeerState(
          deviceId: 'devB',
          lastSeenAt: a.state.nowMs() - SyncPeerState.lostThresholdMs - 1000,
          cursorSeq: 0,
          ackedSeq: 0,
        ),
      ],
    ));
    network.devices.remove('devB');

    // 三次变更超过条数上限：失联对端的旧 ack 不参与 minAck → 正常裁剪。
    await a.setSetting('theme_mode', 'dark');
    await a.engine.syncNow();
    await a.setSetting('theme_mode', 'light');
    await a.engine.syncNow();
    await a.setSetting('theme_mode', 'system');
    await a.engine.syncNow();

    expect(await a.journal.baseSeq(), greaterThan(0));
    expect(await a.journal.snapshotSeq(), await a.journal.headSeq());
  });

  test('不支持实时快照的传输：日志裁剪钉在已发布覆盖上（bootstrap 不丢）', () async {
    // A 的传输按 WebDAV 语义（kind = webdav、servesLiveSnapshot = false）：
    // 全量快照是异步读取的远端文件，日志窗口不能越过已发布覆盖——否则
    // 游标落后 / 新加入的对端取到的快照不含窗口起点。
    final a = await network.addDevice(
      'devA',
      kind: SyncTransportKind.webdav,
      servesLiveSnapshot: false,
      deviceLimits: const SyncJournalLimits(maxEntries: 2),
    );
    final b = await network.addDevice('devB');

    // 首次接触：A 发布首份全量快照（首次构建即头部），B 按它引导。
    await a.engine.syncNow();
    await b.engine.syncNow();
    await a.engine.syncNow();
    final published = a.state.snapshotPushSeq(SyncTransportKind.webdav);
    expect(published, await a.journal.snapshotSeq());

    // 一次本地变更，B 拉到并回传 ack：A 的窗口里对端 ack 已到头部。
    await a.setSetting('theme_mode', 'dark');
    await a.engine.syncNow();
    await b.engine.syncNow();
    await a.engine.syncNow();
    final head = await a.journal.headSeq();
    expect(a.state.peers.single.ackedSeq, head);
    expect(head, greaterThan(published));

    // 对端 ack 到头部但快照覆盖没推进：裁剪停在已发布覆盖（对端按需给实时
    // 快照的传输才允许裁到 ack）。
    expect(await a.journal.baseSeq(), lessThanOrEqualTo(published));
    expect(await a.journal.window(), isNotEmpty);

    // 硬上限把快照覆盖推到头部 → 引擎重发快照文件 → 覆盖推进后裁剪跟上。
    await a.setSetting('theme_mode', 'light');
    await a.engine.syncNow();
    await a.setSetting('theme_mode', 'system');
    await a.engine.syncNow();

    final republished = a.state.snapshotPushSeq(SyncTransportKind.webdav);
    expect(republished, greaterThan(published));
    expect(republished, await a.journal.snapshotSeq());
    expect(await a.journal.baseSeq(), lessThanOrEqualTo(republished));
  });

  test('名册：超过失联阈值的对端标记「已失联」（只提示，不自动清理）', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    final peer = SyncPeerState(
      deviceId: 'ghost',
      lastSeenAt: now - SyncPeerState.lostThresholdMs - 1,
      cursorSeq: 3,
      ackedSeq: 3,
    );
    expect(peer.isLostAt(now), isTrue);
    // 名册不丢条目：失联设备仍可见（用户可从本机移除 / 清理远端文件）。
    expect(trimPeers([peer], 20), hasLength(1));
  });
}
