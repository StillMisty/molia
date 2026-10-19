import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/peer_journal_protocol.dart';
import 'package:molia/domain/models/device_sync.dart';

/// 对端增量日志协议的边界条件：一次写错就会让对端白做 bootstrap 或永久
/// 跳过条目，因此窗口取舍、游标消费、分块衔接与文件命名都在这里钉住。
void main() {
  SyncJournalEntry entry(int seq) => SyncJournalEntry(
        seq: seq,
        category: SyncCategory.settings,
        record: SyncRecord(
          key: 'key-$seq',
          version: SyncVersion(physical: seq, deviceId: 'devB'),
          data: {'v': '$seq'},
        ),
      );

  List<int> seqs(JournalDeltaConsumption result) =>
      [for (final entry in result.accepted) entry.seq];

  group('窗口选择', () {
    test('游标 -1 的全新对端：回全量快照', () {
      expect(
        chooseJournalServeMode(since: -1, baseSeq: 0, headSeq: 5),
        JournalServeMode.fullSnapshot,
      );
    });

    test('游标 0 落在窗口内：回增量', () {
      expect(
        chooseJournalServeMode(since: 0, baseSeq: 0, headSeq: 5),
        JournalServeMode.delta,
      );
    });

    test('游标等于头部：回空增量（不是全量）', () {
      expect(
        chooseJournalServeMode(since: 5, baseSeq: 0, headSeq: 5),
        JournalServeMode.delta,
      );
    });

    test('游标落后于窗口起点（条目已裁剪）：回全量', () {
      expect(
        chooseJournalServeMode(since: 2, baseSeq: 4, headSeq: 9),
        JournalServeMode.fullSnapshot,
      );
    });

    test('游标超前头部（本机日志被重置）：回全量重新引导', () {
      expect(
        chooseJournalServeMode(since: 9, baseSeq: 0, headSeq: 5),
        JournalServeMode.fullSnapshot,
      );
    });
  });

  group('增量消费', () {
    test('游标 -1：从 seq 1 起连续接受，游标推进到末条', () {
      final result = consumeJournalDelta(
        cursor: -1,
        baseSeq: 0,
        windowEnd: 3,
        entries: [entry(1), entry(2), entry(3)],
      );

      expect(seqs(result), [1, 2, 3]);
      expect(result.nextCursor, 3);
      expect(result.gap, isFalse);
      expect(result.truncated, isFalse);
    });

    test('游标 0：seq <= 游标的条目被忽略，其余连续接受', () {
      final result = consumeJournalDelta(
        cursor: 0,
        baseSeq: 0,
        windowEnd: 2,
        entries: [entry(0), entry(1), entry(2)],
      );

      expect(seqs(result), [1, 2]);
      expect(result.nextCursor, 2);
      expect(result.gap, isFalse);
    });

    test('游标等于头部 + 空窗口：空增量，游标不动', () {
      final result = consumeJournalDelta(
        cursor: 5,
        baseSeq: 0,
        windowEnd: 0,
        entries: const [],
      );

      expect(result.accepted, isEmpty);
      expect(result.nextCursor, 5);
      expect(result.gap, isFalse);
      expect(result.truncated, isFalse);
    });

    test('游标 -1 + 空窗口（回执类载荷）：不算缺口，游标夹到 0', () {
      final result = consumeJournalDelta(
        cursor: -1,
        baseSeq: 0,
        windowEnd: 0,
        entries: const [],
      );

      // 旧实现的基线夹取：-1 表示「还没消费」，空窗口不推进到任何真实 seq，
      // 但游标从 -1 走到 0，下次仍从 seq 1 开始。
      expect(result.accepted, isEmpty);
      expect(result.nextCursor, 0);
      expect(result.gap, isFalse);
      expect(result.truncated, isFalse);
    });

    test('游标落后窗口起点：整窗不应用，游标不动并标缺口', () {
      final result = consumeJournalDelta(
        cursor: 1,
        baseSeq: 4,
        windowEnd: 5,
        entries: [entry(5)],
      );

      expect(result.accepted, isEmpty);
      expect(result.nextCursor, 1);
      expect(result.gap, isTrue);
      expect(result.truncated, isFalse);
    });

    test('非连续条目：只接受空洞之前，游标停在已接受位置', () {
      final result = consumeJournalDelta(
        cursor: 0,
        baseSeq: 0,
        windowEnd: 3,
        entries: [entry(1), entry(3)],
      );

      expect(seqs(result), [1]);
      expect(result.nextCursor, 1);
      expect(result.gap, isTrue);
    });

    test('窗口声明被截断：接受实到条目，但不把游标推到 windowEnd', () {
      final result = consumeJournalDelta(
        cursor: 0,
        baseSeq: 0,
        windowEnd: 3,
        entries: [entry(1)],
      );

      expect(seqs(result), [1]);
      expect(result.nextCursor, 1);
      expect(result.gap, isTrue);
      expect(result.truncated, isTrue);
    });

    test('窗口从游标之前开始：旧条目忽略，不在游标后制造空洞', () {
      final result = consumeJournalDelta(
        cursor: 2,
        baseSeq: 0,
        windowEnd: 3,
        entries: [entry(1), entry(2), entry(3)],
      );

      expect(seqs(result), [3]);
      expect(result.nextCursor, 3);
      expect(result.gap, isFalse);
    });
  });

  group('窗口边界', () {
    test('空窗口编码为 0 / 0，非空取首尾 seq', () {
      final empty = journalWindowBounds(const []);
      expect(empty.windowStart, 0);
      expect(empty.windowEnd, 0);

      final bounds = journalWindowBounds([entry(2), entry(5)]);
      expect(bounds.windowStart, 2);
      expect(bounds.windowEnd, 5);
    });
  });

  group('WebDAV 分块衔接', () {
    test('游标 -1：首块从 1 开始视为连续', () {
      final selection = selectJournalChunks(
        cursor: -1,
        chunks: const [
          JournalSeqRange(startSeq: 1, endSeq: 2),
          JournalSeqRange(startSeq: 3, endSeq: 4),
        ],
      );

      expect(selection.contiguous, isTrue);
      expect(selection.needed, const [
        JournalSeqRange(startSeq: 1, endSeq: 2),
        JournalSeqRange(startSeq: 3, endSeq: 4),
      ]);
    });

    test('游标 0：首块从 1 开始同样视为连续', () {
      final selection = selectJournalChunks(
        cursor: 0,
        chunks: const [JournalSeqRange(startSeq: 1, endSeq: 3)],
      );

      expect(selection.contiguous, isTrue);
      expect(selection.needed, const [
        JournalSeqRange(startSeq: 1, endSeq: 3),
      ]);
    });

    test('首块晚于游标 + 1：不连续（中间缺条目）', () {
      final selection = selectJournalChunks(
        cursor: 2,
        chunks: const [JournalSeqRange(startSeq: 4, endSeq: 5)],
      );

      expect(selection.contiguous, isFalse);
      expect(selection.needed, const [
        JournalSeqRange(startSeq: 4, endSeq: 5),
      ]);
    });

    test('块之间有空隙：不连续', () {
      final selection = selectJournalChunks(
        cursor: 0,
        chunks: const [
          JournalSeqRange(startSeq: 1, endSeq: 2),
          JournalSeqRange(startSeq: 4, endSeq: 5),
        ],
      );

      expect(selection.contiguous, isFalse);
    });

    test('游标之前的块不参与选择；重叠块可以接上', () {
      final selection = selectJournalChunks(
        cursor: 2,
        chunks: const [
          JournalSeqRange(startSeq: 1, endSeq: 2),
          JournalSeqRange(startSeq: 2, endSeq: 4),
        ],
      );

      expect(selection.needed, const [
        JournalSeqRange(startSeq: 2, endSeq: 4),
      ]);
      expect(selection.contiguous, isTrue);
    });

    test('没有可读块：不算连续（头部已知且落后时只能 bootstrap）', () {
      final selection = selectJournalChunks(
        cursor: 3,
        chunks: const <JournalSeqRange>[],
      );

      expect(selection.needed, isEmpty);
      expect(selection.contiguous, isFalse);
    });
  });

  group('WebDAV 文件命名', () {
    test('块名编码 / 解析往返（seq 区间由名字承载）', () {
      const range = JournalSeqRange(startSeq: 7, endSeq: 9);
      final name = PeerJournalNames.chunk('devA', range);

      expect(name, 'devA.7-9.chunk.msync');
      final parsed = PeerJournalNames.parse(name);
      expect(parsed, isNotNull);
      expect(parsed!.deviceId, 'devA');
      expect(parsed.kind, PeerJournalFileKind.chunk);
      expect(parsed.range, range);
    });

    test('非法区间 / 幽灵命名不参与协议', () {
      expect(PeerJournalNames.parse('devA.9-7.chunk.msync'), isNull);
      expect(PeerJournalNames.parse('devA.1-x.chunk.msync'), isNull);
      expect(PeerJournalNames.parse('ghost.msync'), isNull);
      expect(PeerJournalNames.parse('devA.1-2.journal.msync'), isNull);
    });

    test('回执 / 快照命名仍按原规则解析', () {
      final acks = PeerJournalNames.parse(PeerJournalNames.acks('devA'));
      expect(acks?.kind, PeerJournalFileKind.acks);
      expect(acks?.deviceId, 'devA');

      final snapshot =
          PeerJournalNames.parse(PeerJournalNames.snapshot('devA', 12));
      expect(snapshot?.kind, PeerJournalFileKind.snapshot);
      expect(snapshot?.coverage, 12);

      // v3 之前的命名（`<deviceId>.snapshot.msync`）不是合法协议文件：
      // 旧实现同样返回 null（固定名残留由清理逻辑按名字显式删）。
      expect(PeerJournalNames.parse('devA.snapshot.msync'), isNull);
    });
  });

  group('对端进度', () {
    test('游标到头部即视为跟上（含头部未知）', () {
      expect(isPeerUpToDate(cursor: 5, headSeq: 5), isTrue);
      expect(isPeerUpToDate(cursor: 6, headSeq: 5), isTrue);
      expect(isPeerUpToDate(cursor: 4, headSeq: 5), isFalse);
      expect(isPeerUpToDate(cursor: 0, headSeq: null), isTrue);
    });
  });
}
