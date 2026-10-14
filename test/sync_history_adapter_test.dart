import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/library_repository.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/sync/adapters/history_sync_adapter.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/models/library.dart';

import 'support/memory_database.dart';

/// 播放历史适配器测试：两库互导、playedAt 取新、删除墓碑与复活。
void main() {
  late MoliaDatabase dbA;
  late MoliaDatabase dbB;
  late LibraryRepository repoA;
  late LibraryRepository repoB;
  late HistorySyncAdapter adapterA;
  late HistorySyncAdapter adapterB;

  PlayHistoryEntry entry(
    String songId, {
    required int playedAt,
    String title = '',
  }) =>
      PlayHistoryEntry(
        sourceKey: 'wy',
        songId: songId,
        title: title.isEmpty ? 'Song $songId' : title,
        artist: 'Artist',
        album: 'Album',
        raw: {'songId': songId},
        playedAt: playedAt,
      );

  setUp(() async {
    dbA = openMemoryDatabase();
    dbB = openMemoryDatabase();
    repoA = LibraryRepository(
      databaseProvider: () => dbA,
      deviceIdProvider: () => 'devA',
    );
    repoB = LibraryRepository(
      databaseProvider: () => dbB,
      deviceIdProvider: () => 'devB',
    );
    adapterA = HistorySyncAdapter(repository: repoA);
    adapterB = HistorySyncAdapter(repository: repoB);
  });

  tearDown(() async {
    await repoA.dispose();
    await repoB.dispose();
    await dbA.close();
    await dbB.close();
  });

  test('A → B：历史整体同步；重复应用幂等', () async {
    await repoA.addHistoryEntry(entry('s1', playedAt: 1000));
    await repoA.addHistoryEntry(entry('s2', playedAt: 2000));

    final result = await adapterB.apply(await adapterA.collect());
    expect(result.applied, 2);
    final listB = await repoB.listHistory();
    expect(listB.map((e) => e.songId), ['s2', 's1']);

    final again = await adapterB.apply(await adapterA.collect());
    expect(again.applied, 0);
    expect(again.skipped, 2);
  });

  test('playedAt 取新：B 的同曲目更新记录回流 A', () async {
    await repoA.addHistoryEntry(entry('s1', playedAt: 1000, title: '旧标题'));
    await adapterB.apply(await adapterA.collect());

    await repoB.addHistoryEntry(entry('s1', playedAt: 5000, title: '新标题'));
    final result = await adapterA.apply(await adapterB.collect());
    expect(result.applied, 1);
    final listA = await repoA.listHistory();
    expect(listA.single.title, '新标题');
    expect(listA.single.playedAt, 5000);
  });

  test('删除经墓碑传播；晚于删除的播放复活条目', () async {
    await repoA.addHistoryEntry(entry('s1', playedAt: 1000));
    await repoA.addHistoryEntry(entry('s2', playedAt: 2000));
    await adapterB.apply(await adapterA.collect());

    // B 删除 s1 → A 删除。
    await repoB.deleteHistoryEntry('wy', 's1');
    await adapterA.apply(await adapterB.collect());
    expect((await repoA.listHistory()).map((e) => e.songId), ['s2']);

    // A 重新播放 s1（更晚）→ 墓碑被清除并回流 B。
    final now = DateTime.now().millisecondsSinceEpoch;
    await repoA.addHistoryEntry(entry('s1', playedAt: now + 10000));
    final result = await adapterB.apply(await adapterA.collect());
    expect(result.applied, greaterThanOrEqualTo(1));
    expect((await repoB.listHistory()).map((e) => e.songId), contains('s1'));
  });

  test('清空历史传播删除', () async {
    await repoA.addHistoryEntry(entry('s1', playedAt: 1000));
    await adapterB.apply(await adapterA.collect());

    await repoA.clearHistory();
    final result = await adapterB.apply(await adapterA.collect());
    expect(result.applied, 1);
    expect(await repoB.listHistory(), isEmpty);
  });

  test('历史键编解码', () {
    final key = SyncRecordKeys.history('wy', 'mid:1');
    final parsed = SyncRecordKeys.parseHistory(key)!;
    expect(parsed.sourceKey, 'wy');
    expect(parsed.songId, 'mid:1');
    expect(SyncRecordKeys.parseHistory('broken'), isNull);
  });

  test('本地下载曲目（local）不同步：条目与墓碑都过滤', () async {
    await repoA.addHistoryEntry(entry('s1', playedAt: 1000));
    await repoA.addHistoryEntry(PlayHistoryEntry(
      sourceKey: 'local',
      songId: 'wy:9',
      title: '本地下载',
      playedAt: 2000,
    ));
    await repoA.deleteHistoryEntry('local', 'wy:8'); // 无对应行 → 不产生墓碑

    final collected = await adapterA.collect();
    expect(
      collected[SyncCategory.history]!.map((record) => record.key),
      [SyncRecordKeys.history('wy', 's1')],
    );

    // 对端收到 local 条目 / 墓碑也忽略（防御：旧版本或异常数据）。
    final result = await adapterB.apply({
      SyncCategory.history: [
        SyncRecord(
          key: SyncRecordKeys.history('local', 'wy:9'),
          updatedAt: 3000,
          updatedBy: 'devA',
          data: const {
            'sourceKey': 'local',
            'songId': 'wy:9',
            'title': '本地下载',
            'playedAt': 3000,
          },
        ),
        SyncRecord.tombstone(
          key: SyncRecordKeys.history('local', 'wy:8'),
          updatedAt: 4000,
          updatedBy: 'devA',
        ),
      ],
    });
    expect(result.applied, 0);
    expect(await repoB.listHistory(), isEmpty);
  });
}
