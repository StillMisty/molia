import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/library_repository.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/sync/adapters/history_sync_adapter.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/models/library.dart';

import 'support/memory_database.dart';

/// 播放历史适配器测试：两库互导、版本取新、删除墓碑与复活，
/// 以及时钟偏移下「删除 vs 播放」按真实时间判定（ADR-0003 v2 §2）。
void main() {
  late MoliaDatabase dbA;
  late MoliaDatabase dbB;
  late LibraryRepository repoA;
  late LibraryRepository repoB;
  late HistorySyncAdapter adapterA;
  late HistorySyncAdapter adapterB;

  /// 两台设备的时钟：默认正常；偏移用例里单独抬高（版本戳会跟着超前）。
  var nowA = 1000;
  var nowB = 1000;

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
    nowA = 1000;
    nowB = 1000;
    dbA = openMemoryDatabase();
    dbB = openMemoryDatabase();
    repoA = LibraryRepository(
      databaseProvider: () => dbA,
      deviceIdProvider: () => 'devA',
      clock: () => nowA,
    );
    repoB = LibraryRepository(
      databaseProvider: () => dbB,
      deviceIdProvider: () => 'devB',
      clock: () => nowB,
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
    nowA = 1100;
    await repoA.addHistoryEntry(entry('s2', playedAt: 2000));

    final result = await adapterB.apply(await adapterA.collect());
    expect(result.applied, 2);
    final listB = await repoB.listHistory();
    expect(listB.map((e) => e.songId), ['s2', 's1']);

    final again = await adapterB.apply(await adapterA.collect());
    expect(again.applied, 0);
    expect(again.skipped, 2);
  });

  test('版本取新：B 的同曲目更新记录回流 A', () async {
    await repoA.addHistoryEntry(entry('s1', playedAt: 1000, title: '旧标题'));
    await adapterB.apply(await adapterA.collect());

    nowB = 5000;
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

    // B 删除 s1（真实删除时间 2000）→ A 删除。
    nowB = 2000;
    await repoB.deleteHistoryEntry('wy', 's1');
    await adapterA.apply(await adapterB.collect());
    expect((await repoA.listHistory()).map((e) => e.songId), ['s2']);

    // A 重新播放 s1（真实时间 20000，晚于删除）→ 墓碑被清除并回流 B。
    nowA = 20000;
    await repoA.addHistoryEntry(entry('s1', playedAt: 20000));
    final result = await adapterB.apply(await adapterA.collect());
    expect(result.applied, greaterThanOrEqualTo(1));
    expect((await repoB.listHistory()).map((e) => e.songId), contains('s1'));
  });

  test('时钟偏移（删除）：删除是否生效只看真实时间，不看版本戳大小', () async {
    // A 的时钟快 1 年：A 的版本戳（100000）远大于 B 的删除版本（5000）。
    nowA = 100000;
    await repoA.addHistoryEntry(entry('s1', playedAt: 1000));
    await adapterB.apply(await adapterA.collect());

    // B 在真实时间 5000 删除（版本戳更小），但删除时刻晚于 A 的最后播放。
    nowB = 5000;
    await repoB.deleteHistoryEntry('wy', 's1');

    // A 应用墓碑：playedAt(1000) <= deletedAt(5000) → 删除生效
    // （若拿版本戳比较，B 的 5000 < A 的 100000，会错误地保留条目）。
    final result = await adapterA.apply(await adapterB.collect());
    expect(result.applied, 1);
    expect(await repoA.listHistory(), isEmpty);
  });

  test('时钟偏移（播放）：晚于删除的播放按真实时间复活', () async {
    nowA = 100000;
    await repoA.addHistoryEntry(entry('s1', playedAt: 1000));
    await adapterB.apply(await adapterA.collect());

    nowB = 5000;
    await repoB.deleteHistoryEntry('wy', 's1');
    await adapterA.apply(await adapterB.collect());
    expect(await repoA.listHistory(), isEmpty);

    // A 在真实时间 20000（playedAt）重新播放：晚于 B 的删除时间 5000 → 复活。
    nowA = 200000;
    await repoA.addHistoryEntry(entry('s1', playedAt: 20000));
    final result = await adapterB.apply(await adapterA.collect());
    expect(result.applied, greaterThanOrEqualTo(1));
    expect((await repoB.listHistory()).map((e) => e.songId), contains('s1'));
  });

  test('时钟超前设备的删除压制随后的播放（内容时间的残余代价）', () async {
    // B 的时钟快 1 年：删除时间 = B 的墙上时钟（超前），
    // A 随后的播放（真实时间）仍被压制——与首版同级，不因基线吸收放大。
    nowB = 100000;
    await repoA.addHistoryEntry(entry('s1', playedAt: 1000));
    await adapterB.apply(await adapterA.collect());
    await repoB.deleteHistoryEntry('wy', 's1');

    nowA = 10000;
    await repoA.addHistoryEntry(entry('s1', playedAt: 10000));
    final result = await adapterA.apply(await adapterB.collect());
    // 删除生效（playedAt 10000 <= deletedAt 100000），播放被压制。
    expect(result.applied, 1);
    expect(await repoA.listHistory(), isEmpty);
  });

  test('清空历史传播删除', () async {
    await repoA.addHistoryEntry(entry('s1', playedAt: 1000));
    await adapterB.apply(await adapterA.collect());

    nowA = 2000;
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
          version: const SyncVersion(physical: 3000, deviceId: 'devA'),
          data: const {
            'sourceKey': 'local',
            'songId': 'wy:9',
            'title': '本地下载',
            'playedAt': 3000,
          },
        ),
        SyncRecord.tombstone(
          key: SyncRecordKeys.history('local', 'wy:8'),
          version: const SyncVersion(physical: 4000, deviceId: 'devA'),
          deletedAt: 4000,
        ),
      ],
    });
    expect(result.applied, 0);
    expect(await repoB.listHistory(), isEmpty);
  });
}
