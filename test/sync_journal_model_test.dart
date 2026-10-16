import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/ports/sync_transport.dart';

/// 增量协议领域模型：日志条目 / 增量窗口载荷 / 对端游标与失联判定。
void main() {
  SyncRecord themeRecord(String value, int physical) => SyncRecord(
        key: 'theme_mode',
        version: SyncVersion(physical: physical, deviceId: 'devA'),
        data: {'v': value},
      );

  test('日志条目 JSON 往返保留序号 / 类别 / 记录', () {
    final entry = SyncJournalEntry(
      seq: 7,
      category: SyncCategory.settings,
      record: themeRecord('dark', 100),
    );

    final parsed = SyncJournalEntry.fromJson(entry.toJson());

    expect(parsed, isNotNull);
    expect(parsed!.seq, 7);
    expect(parsed.category, SyncCategory.settings);
    expect(parsed.record.key, 'theme_mode');
    expect(parsed.record.version.physical, 100);
    expect(parsed.record.data, {'v': 'dark'});
  });

  test('日志条目：序号非法 / 类别未知的坏条目跳过', () {
    expect(SyncJournalEntry.fromJson(null), isNull);
    expect(SyncJournalEntry.fromJson({'seq': 0, 'category': 'settings'}), isNull);
    expect(
      SyncJournalEntry.fromJson({
        'seq': 1,
        'category': 'not_a_category',
        'record': themeRecord('dark', 1).toJson(),
      }),
      isNull,
    );
  });

  test('增量载荷：isDelta / payloadRecords 从窗口条目提取记录', () {
    final envelope = SyncEnvelope(
      deviceId: 'devA',
      producedAt: 200,
      journalHead: 9,
      baseSeq: 4,
      windowStart: 5,
      windowEnd: 9,
      journal: [
        SyncJournalEntry(
          seq: 5,
          category: SyncCategory.settings,
          record: themeRecord('dark', 100),
        ),
        SyncJournalEntry(
          seq: 9,
          category: SyncCategory.history,
          record: SyncRecord.tombstone(
            key: 'kuwo\u0001song-1',
            version: SyncVersion(physical: 110, deviceId: 'devA'),
            deletedAt: 105,
          ),
        ),
      ],
      acks: const {'devB': 3},
    );

    expect(envelope.isDelta, isTrue);
    final records = envelope.payloadRecords;
    expect(records[SyncCategory.settings], hasLength(1));
    expect(records[SyncCategory.history]!.single.deleted, isTrue);

    final parsed = SyncEnvelope.fromJson(envelope.toJson());
    expect(parsed, isNotNull);
    expect(parsed!.isDelta, isTrue);
    expect(parsed.journalHead, 9);
    expect(parsed.baseSeq, 4);
    expect(parsed.windowStart, 5);
    expect(parsed.windowEnd, 9);
    expect(parsed.journal, hasLength(2));
    expect(parsed.journal!.first.seq, 5);
    expect(parsed.acks, {'devB': 3});
    expect(parsed.payloadRecords[SyncCategory.history], hasLength(1));
  });

  test('空增量窗口与全量快照的区分（journal 字段存在与否）', () {
    final emptyWindow = SyncEnvelope.fromJson(SyncEnvelope(
      deviceId: 'devA',
      producedAt: 1,
      journalHead: 9,
      journal: const [],
    ).toJson());
    expect(emptyWindow!.isDelta, isTrue);
    expect(emptyWindow.journal, isEmpty);

    final snapshot = SyncEnvelope.fromJson(SyncEnvelope(
      deviceId: 'devA',
      producedAt: 1,
      journalHead: 9,
      records: {
        SyncCategory.settings: [themeRecord('dark', 100)],
      },
    ).toJson());
    expect(snapshot!.isDelta, isFalse);
    expect(snapshot.records[SyncCategory.settings], hasLength(1));
    expect(snapshot.payloadRecords[SyncCategory.settings], hasLength(1));
  });

  test('全量快照复制（裁剪墓碑 / 替换指纹）保留 journal 元信息与 ack', () {
    final envelope = SyncEnvelope(
      deviceId: 'devA',
      producedAt: 1,
      journalHead: 12,
      baseSeq: 3,
      acks: const {'devB': 11},
      records: {
        SyncCategory.settings: [themeRecord('dark', 100)],
      },
    );

    final pruned = envelope.pruneTombstones(now: 1000, tombstoneRetentionMs: 1);
    expect(pruned.journalHead, 12);
    expect(pruned.baseSeq, 3);
    expect(pruned.acks, {'devB': 11});
    expect(pruned.withSnapshotId('abc').snapshotId, 'abc');
    expect(pruned.withSnapshotId('abc').acks, {'devB': 11});
  });

  test('对端名册：游标 / ack / 落后字节与失联判定', () {
    const peer = SyncPeerState(
      deviceId: 'devB',
      cursorSeq: 5,
      ackedSeq: 3,
      headSeq: 8,
      behindBy: 4,
      behindBytes: 512,
      snapshotId: 'hash-b',
      categories: ['settings', 'history'],
      fullPulledAt: 900,
      lastSeenAt: 1000,
    );

    final parsed = SyncPeerState.fromJson(peer.toJson())!;
    expect(parsed.cursorSeq, 5);
    expect(parsed.ackedSeq, 3);
    expect(parsed.headSeq, 8);
    expect(parsed.behindBy, 4);
    expect(parsed.behindBytes, 512);
    expect(parsed.snapshotId, 'hash-b');
    expect(parsed.categories, ['settings', 'history']);
    expect(parsed.fullPulledAt, 900);

    expect(parsed.isLostAt(1000 + SyncPeerState.lostThresholdMs), isFalse);
    expect(parsed.isLostAt(1001 + SyncPeerState.lostThresholdMs), isTrue);
    // 从未接触过（lastSeenAt = 0）不按失联标记。
    expect(const SyncPeerState(deviceId: 'devC').isLostAt(1 << 40), isFalse);

    // 缺省游标 = 尚未消费任何条目；ack 未知。
    final fresh = SyncPeerState.fromJson({'deviceId': 'devC'})!;
    expect(fresh.cursorSeq, -1);
    expect(fresh.ackedSeq, -1);
    expect(fresh.behindBy, isNull);
  });

  test('拉取请求：游标查询与未记录对端的缺省值', () {
    const request = SyncPullRequest(
      cursors: {'devB': 7},
      fullPeers: {'devC'},
    );
    expect(request.cursorFor('devB'), 7);
    expect(request.cursorFor('devC'), SyncPullRequest.noCursor);
    expect(request.fullPeers, contains('devC'));
  });
}
