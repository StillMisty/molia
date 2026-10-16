import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/library_repository.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/sync/adapters/history_sync_adapter.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/models/library.dart';
import 'support/sync_test_support.dart';

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
      clock: () => nowA,
      stamps: testStampIssuer(clock: () => nowA, deviceId: 'devA'),
    );
    repoB = LibraryRepository(
      databaseProvider: () => dbB,
      clock: () => nowB,
      stamps: testStampIssuer(clock: () => nowB, deviceId: 'devB'),
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
    // A 随后的播放（真实时间）仍被压制——删除 vs 播放只看内容时间。
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

  test('换源更新版本：历史替换后的条目可同步到对端', () async {
    await repoA.addHistoryEntry(entry('s1', playedAt: 1000, title: '旧标题'));
    final before = (await repoA.syncExportHistory()).single.version;

    nowA = 2000;
    await repoA.replaceHistoryEntry(
      (sourceKey: 'wy', songId: 's1'),
      PlayHistoryEntry(
        sourceKey: 'kw',
        songId: 's1',
        title: '换源标题',
        artist: 'Artist',
        album: 'Album',
        raw: const {'id': 'kw-s1'},
        playedAt: 1000,
      ),
    );
    final after = (await repoA.syncExportHistory()).single.version;
    expect(
      after.isNewerThan(before),
      isTrue,
      reason: '换源是本地修改：版本必须前进（否则永不传播）',
    );

    final result = await adapterB.apply(await adapterA.collect());
    expect(result.applied, 1);
    final listB = await repoB.listHistory();
    expect(listB.single.sourceKey, 'kw');
    expect(listB.single.title, '换源标题');
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

  group('墓碑的删除 vs 播放按实际生效的删除时间判定', () {
    /// 直接落库：本地墓碑与/或本地播放行（模拟历史遗留状态）。
    Future<void> seedTombstone({
      required SyncVersion version,
      required int deletedAt,
    }) async {
      await dbB.into(dbB.syncTombstones).insert(SyncTombstonesCompanion.insert(
            category: 'history',
            key: SyncRecordKeys.history('wy', 's1'),
            versionPhysical: version.physical,
            versionCounter: Value(version.counter),
            deviceId: Value(version.deviceId),
            deletedAt: Value(deletedAt),
          ));
    }

    Future<void> seedRow({
      required int playedAt,
      required SyncVersion version,
    }) async {
      await dbB.into(dbB.playHistory).insert(PlayHistoryCompanion.insert(
            sourceKey: 'wy',
            songId: 's1',
            title: '本地行',
            playedAt: playedAt,
            versionPhysical: Value(version.physical),
            versionCounter: Value(version.counter),
            deviceId: Value(version.deviceId),
          ));
    }

    test('入站墓碑版本更旧（未被采用）：不按它的删除时间删行，也不撤本地墓碑', () async {
      await seedTombstone(
        version: const SyncVersion(physical: 9000, deviceId: 'devB'),
        deletedAt: 9000,
      );
      await seedRow(
        playedAt: 10000,
        version: const SyncVersion(physical: 8000, deviceId: 'devB'),
      );

      // 入站墓碑版本 1000（更旧）但删除时间 12000（更晚）：不应被采用。
      final result = await adapterB.apply({
        SyncCategory.history: [
          SyncRecord.tombstone(
            key: SyncRecordKeys.history('wy', 's1'),
            version: const SyncVersion(physical: 1000, deviceId: 'devA'),
            deletedAt: 12000,
          ),
        ],
      });

      expect(result.applied, 0, reason: '不按旧墓碑的删除时间误删');
      expect(
        (await repoB.listHistory()).map((e) => e.songId),
        contains('s1'),
        reason: '本地行保留',
      );
      final tombstones = await repoB.syncExportTombstones(['history']);
      expect(tombstones, hasLength(1), reason: '比入站更新的本地墓碑不被撤下');
      expect(tombstones.single.version.physical, 9000);
      expect(tombstones.single.deletedAt, 9000);
    });

    test('入站墓碑版本更新（被采用）：按它自己的删除时间删行并覆盖本地墓碑', () async {
      await seedTombstone(
        version: const SyncVersion(physical: 1000, deviceId: 'devB'),
        deletedAt: 1000,
      );
      await seedRow(
        playedAt: 5000,
        version: const SyncVersion(physical: 7000, deviceId: 'devB'),
      );

      final result = await adapterB.apply({
        SyncCategory.history: [
          SyncRecord.tombstone(
            key: SyncRecordKeys.history('wy', 's1'),
            version: const SyncVersion(physical: 9000, deviceId: 'devA'),
            deletedAt: 6000,
          ),
        ],
      });

      expect(result.applied, 1);
      expect(await repoB.listHistory(), isEmpty);
      final tombstones = await repoB.syncExportTombstones(['history']);
      expect(tombstones.single.version.physical, 9000);
      expect(tombstones.single.deletedAt, 6000);
    });

    test('旧备份的播放记录晚于删除时间：本机复活但不顶掉更新的本地墓碑', () async {
      await seedTombstone(
        version: const SyncVersion(physical: 9000, deviceId: 'devB'),
        deletedAt: 9000,
      );

      // 入站条目版本 1000（更旧）playedAt 12000（晚于删除）。
      final result = await adapterB.apply({
        SyncCategory.history: [
          SyncRecord(
            key: SyncRecordKeys.history('wy', 's1'),
            version: const SyncVersion(physical: 1000, deviceId: 'devA'),
            data: const {
              'sourceKey': 'wy',
              'songId': 's1',
              'title': '旧备份',
              'playedAt': 12000,
            },
          ),
        ],
      });

      expect(result.applied, 1, reason: '播放晚于删除：本机复活');
      expect((await repoB.listHistory()).map((e) => e.songId), contains('s1'));
      final tombstones = await repoB.syncExportTombstones(['history']);
      expect(tombstones, hasLength(1), reason: '更新的本地墓碑保留');
      expect(tombstones.single.version.physical, 9000);
    });
  });
}
