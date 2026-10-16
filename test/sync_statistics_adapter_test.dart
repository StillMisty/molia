import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/play_statistics_repository.dart';
import 'package:molia/data/sync/adapters/statistics_sync_adapter.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/models/play_statistics.dart';
import 'support/sync_test_support.dart';

import 'support/memory_database.dart';

/// 听歌统计适配器测试：导出 / 去重合并 / 收尾事件覆盖 / 存量键回填。
void main() {
  late MoliaDatabase dbA;
  late MoliaDatabase dbB;
  late PlayStatisticsRepository repoA;
  late PlayStatisticsRepository repoB;
  late StatisticsSyncAdapter adapterA;
  late StatisticsSyncAdapter adapterB;
  var clockA = 1000;
  var clockB = 1000;

  Future<int> play(
    PlayStatisticsRepository repo, {
    required String songId,
    required int startedAt,
    required int endedAt,
    int listenedMs = 60000,
  }) async {
    final id = await repo.startEvent(
      sourceKey: 'wy',
      songId: songId,
      title: 'Song $songId',
      artist: 'Artist',
      startedAt: startedAt,
    );
    await repo.finishEvent(
      id,
      reason: PlayEventEndReason.completed,
      listenedMs: listenedMs,
      maxPositionMs: listenedMs,
      endedAt: endedAt,
    );
    return id;
  }

  setUp(() async {
    clockA = 1000;
    clockB = 1000;
    dbA = openMemoryDatabase();
    dbB = openMemoryDatabase();
    repoA = PlayStatisticsRepository(
      databaseProvider: () => dbA,
      clock: () => clockA,
      stamps: testStampIssuer(clock: () => clockA, deviceId: 'devA'),
    );
    repoB = PlayStatisticsRepository(
      databaseProvider: () => dbB,
      clock: () => clockB,
      stamps: testStampIssuer(clock: () => clockB, deviceId: 'devB'),
    );
    adapterA = StatisticsSyncAdapter(repository: repoA);
    adapterB = StatisticsSyncAdapter(repository: repoB);
  });

  tearDown(() async {
    await repoA.dispose();
    await repoB.dispose();
    await dbA.close();
    await dbB.close();
  });

  test('A → B：事件合并后汇总口径一致；重复应用幂等', () async {
    await play(repoA, songId: 's1', startedAt: 1000, endedAt: 61000);
    await play(repoA, songId: 's2', startedAt: 2000, endedAt: 62000);

    final collected = await adapterA.collect();
    expect(collected.length, 1);
    final result = await adapterB.apply(collected);
    expect(result.applied, 2);

    final summaryA = await repoA.summary();
    final summaryB = await repoB.summary();
    expect(summaryB.playCount, summaryA.playCount);
    expect(summaryB.totalListenedMs, summaryA.totalListenedMs);

    final again = await adapterB.apply(await adapterA.collect());
    expect(again.applied, 0);
    expect(again.skipped, 2);
  });

  test('事件来源设备随记录保留；B 新增事件回流 A', () async {
    await play(repoA, songId: 's1', startedAt: 1000, endedAt: 61000);
    await adapterB.apply(await adapterA.collect());
    await play(repoB, songId: 's9', startedAt: 5000, endedAt: 65000);

    final result = await adapterA.apply(await adapterB.collect());
    expect(result.applied, 1);
    final rows = await dbA.customSelect(
      'SELECT originDeviceId FROM play_events WHERE songId = ?',
      variables: [Variable.withString('s9')],
    ).get();
    expect(rows.single.data['originDeviceId'], 'devB');
  });

  test('进行中事件不导出；收尾后的事件随下一轮同步', () async {
    await repoA.startEvent(
      sourceKey: 'kw',
      songId: 'live',
      title: 'Live',
      startedAt: 1000,
    );
    final before = await adapterA.collect();
    expect(before.values.single, isEmpty);

    await repoA.closeStaleEvents();
    final after = await adapterA.collect();
    expect(after.values.single.length, 1);

    final result = await adapterB.apply(after);
    expect(result.applied, 1);
    // interrupted 计入事件数但不计入有效播放。
    expect((await repoB.summary()).playCount, 1);
    expect((await repoB.summary()).qualifiedPlayCount, 0);
  });

  test('存量事件（无 syncKey）导出时按内容哈希回填且跨库一致', () async {
    // 模拟 v5 前旧行：直接插入不带 syncKey。
    for (final db in [dbA, dbB]) {
      await db.into(db.playEvents).insert(PlayEventsCompanion.insert(
            sourceKey: 'wy',
            songId: 'legacy',
            title: const Value('Legacy'),
            artist: const Value(''),
            album: const Value(''),
            raw: const Value('{}'),
            startedAt: 100,
            endedAt: const Value(200),
            listenedMs: const Value(100),
            maxPositionMs: const Value(100),
            endReason: const Value('completed'),
            originDeviceId: const Value(''),
          ));
    }
    final a = await adapterA.collect();
    final keyA = a.values.single.single.key;
    expect(keyA, startsWith('legacy_'));

    // 同一个事件在 B 上回填出相同键：应用后不产生重复。
    await adapterB.collect();
    final result = await adapterB.apply(a);
    expect(result.applied, 0);
    expect((await repoB.summary()).playCount, 1);
  });

  test('本地下载曲目（local）事件不同步：导出与应用两侧过滤', () async {
    final localId = await repoA.startEvent(
      sourceKey: 'local',
      songId: 'wy:9',
      title: '本地下载',
      artist: '歌手',
      startedAt: 1000,
    );
    await repoA.finishEvent(
      localId,
      reason: PlayEventEndReason.completed,
      listenedMs: 60000,
      maxPositionMs: 60000,
      endedAt: 61000,
    );
    await play(repoA, songId: 's1', startedAt: 2000, endedAt: 62000);

    final collected = await adapterA.collect();
    final keys = collected[SyncCategory.statistics]!;
    expect(keys, hasLength(1));
    expect(keys.single.data!['sourceKey'], 'wy');

    // 对端收到 local 事件也忽略（防御：异常或外来数据）。
    final result = await adapterB.apply({
      SyncCategory.statistics: [
        SyncRecord(
          key: 'legacy_local_key',
          version: const SyncVersion(physical: 61000, deviceId: 'devA'),
          data: const {
            'sourceKey': 'local',
            'songId': 'wy:9',
            'title': '本地下载',
            'startedAt': 1000,
            'endedAt': 61000,
            'listenedMs': 60000,
            'maxPositionMs': 60000,
            'endReason': 'completed',
          },
        ),
      ],
    });
    expect(result.applied, 0);
    expect((await repoB.summary()).playCount, 0);
  });
}
