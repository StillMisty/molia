import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/sync/sync_journal.dart';
import 'package:molia/domain/models/device_sync.dart';

import 'support/memory_database.dart';

/// 增量日志仓库：追加的单调序号 / 窗口读取 / 与数据写入同事务 / compact
/// 边界（不丢未 ack 的条目，超硬上限才整体裁剪）。
void main() {
  late MoliaDatabase db;
  late SyncJournalRepository journal;

  SyncJournalChange change(String key, int physical, {bool deleted = false}) => (
        category: SyncCategory.settings,
        record: SyncRecord(
          key: key,
          version: SyncVersion(physical: physical, deviceId: 'devA'),
          deleted: deleted,
          data: deleted ? null : {'v': key},
        ),
      );

  setUp(() {
    db = openMemoryDatabase();
    journal = SyncJournalRepository(
      databaseProvider: () => db,
      clock: () => 1000,
    );
  });

  tearDown(() => db.close());

  test('追加：序号从 1 起单调递增，窗口只取游标之后的条目', () async {
    await journal.append(db, [change('a', 1), change('b', 2)]);
    await journal.append(db, [change('c', 3)]);

    expect(await journal.headSeq(), 3);
    expect(await journal.baseSeq(), 0);

    final all = await journal.window();
    expect([for (final entry in all) entry.seq], [1, 2, 3]);
    expect(all.first.record.key, 'a');
    expect(all.first.record.data, {'v': 'a'});
    expect(all.first.category, SyncCategory.settings);

    final tail = await journal.window(since: 1);
    expect([for (final entry in tail) entry.record.key], ['b', 'c']);
    expect(await journal.window(since: 3), isEmpty);

    // 墓碑条目原样往返（删除也取新）。
    await journal.append(db, [change('a', 4, deleted: true)]);
    final tombstone = (await journal.window(since: 3)).single;
    expect(tombstone.record.deleted, isTrue);
    expect(tombstone.record.version.physical, 4);
  });

  test('追加与数据写入同事务：事务回滚后日志与数据都不落', () async {
    try {
      await db.transaction(() async {
        await db.into(db.playHistory).insert(
              PlayHistoryCompanion.insert(
                sourceKey: 'kuwo',
                songId: 'song-1',
                title: '测试',
                playedAt: 1,
              ),
            );
        await journal.append(db, [change('a', 1)]);
        throw StateError('回滚（测试注入）');
      });
    } catch (_) {
      // 预期回滚。
    }

    expect(await db.select(db.playHistory).get(), isEmpty);
    expect(await journal.headSeq(), 0);
  });

  test('窗口字节量按条目累计（compact 体积上限的判据）', () async {
    await journal.append(db, [change('a', 1)]);
    final single = await journal.windowBytes();
    await journal.append(db, [change('b', 2)]);
    final doubled = await journal.windowBytes();

    expect(single, greaterThan(96));
    expect(doubled, greaterThan(single));
    expect(await journal.windowBytes(since: 1), doubled - single);
  });

  test('compact 边界：只裁到 min(minAck, 快照覆盖)，未 ack 的条目保留', () async {
    await journal.append(db, [change('a', 1), change('b', 2), change('c', 3), change('d', 4)]);
    // 快照覆盖到 4：允许裁到 4；对端只 ack 到 2。
    await journal.markSnapshotBuilt(4);

    expect(await journal.compact(minAck: 2), 2);
    expect(await journal.baseSeq(), 2);
    expect([for (final entry in await journal.window()) entry.seq], [3, 4]);

    // 对端推进到 3：再裁一格，仍是「未 ack 的不动」。
    expect(await journal.compact(minAck: 3), 3);
    expect([for (final entry in await journal.window()) entry.seq], [4]);
    // 已裁到快照覆盖位置：ack 再大也不会裁掉快照未覆盖的部分。
    expect(await journal.compact(minAck: 4), 4);
    expect(await journal.window(), isEmpty);
    expect(await journal.headSeq(), 4);
  });

  test('compact：快照尚未覆盖的位置不裁（保证新对端能 bootstrap）', () async {
    await journal.append(db, [change('a', 1), change('b', 2)]);
    // 尚未构建过全量快照（snapshotSeq = -1）：即使对端都 ack 了也不裁。
    expect(await journal.snapshotSeq(), -1);
    expect(await journal.compact(minAck: 2), 0);
    expect([for (final entry in await journal.window()) entry.seq], [1, 2]);

    await journal.markSnapshotBuilt(1);
    expect(await journal.compact(minAck: 2), 1);
    expect([for (final entry in await journal.window()) entry.seq], [2]);
  });

  test('compact：超过条数硬上限时快照覆盖推进到头部并整体裁剪', () async {
    final capped = SyncJournalRepository(
      databaseProvider: () => db,
      clock: () => 1000,
      limits: const SyncJournalLimits(maxEntries: 3),
    );
    await capped.append(db, [
      change('a', 1),
      change('b', 2),
      change('c', 3),
      change('d', 4),
    ]);

    final base = await capped.compact(minAck: 0, nowMs: 1000);

    expect(base, 4);
    expect(await capped.baseSeq(), 4);
    expect(await capped.snapshotSeq(), 4);
    expect(await capped.window(), isEmpty);
  });

  test('compact：超过时间硬上限时同样整体裁剪（落后对端降级 bootstrap）', () async {
    final aged = SyncJournalRepository(
      databaseProvider: () => db,
      clock: () => 1000,
      limits: const SyncJournalLimits(maxAge: Duration(hours: 1)),
    );
    await aged.append(db, [change('a', 1)]);

    expect(
      await aged.compact(minAck: 0, nowMs: 1000 + 2 * 60 * 60 * 1000),
      1,
    );
    expect(await aged.window(), isEmpty);
  });

  test('快照覆盖只前进：markSnapshotBuilt 不接受回退', () async {
    await journal.append(db, [change('a', 1), change('b', 2)]);
    await journal.markSnapshotBuilt(2);
    await journal.markSnapshotBuilt(1);
    expect(await journal.snapshotSeq(), 2);
  });
}
