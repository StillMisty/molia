import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/database_helper.dart';
import 'package:molia/data/play_statistics_repository.dart';
import 'package:molia/data/sync/adapters/statistics_sync_adapter.dart';
import 'package:molia/domain/models/play_statistics.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 听歌统计适配器测试：导出 / 去重合并 / 收尾事件覆盖 / 存量键回填。
void main() {
  sqfliteFfiInit();

  late Directory tempDir;
  late Database dbA;
  late Database dbB;
  late PlayStatisticsRepository repoA;
  late PlayStatisticsRepository repoB;
  late StatisticsSyncAdapter adapterA;
  late StatisticsSyncAdapter adapterB;

  Future<Database> openDb(String name) => databaseFactoryFfi.openDatabase(
        '${tempDir.path}/$name.db',
        options: OpenDatabaseOptions(
          version: DatabaseHelper.dbVersion,
          onCreate: (database, version) => DatabaseHelper.createSchema(database),
        ),
      );

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
    tempDir = Directory.systemTemp.createTempSync('molia_sync_stats');
    dbA = await openDb('a');
    dbB = await openDb('b');
    repoA = PlayStatisticsRepository(
      databaseProvider: () async => dbA,
      deviceIdProvider: () => 'devA',
    );
    repoB = PlayStatisticsRepository(
      databaseProvider: () async => dbB,
      deviceIdProvider: () => 'devB',
    );
    adapterA = StatisticsSyncAdapter(repository: repoA);
    adapterB = StatisticsSyncAdapter(repository: repoB);
  });

  tearDown(() async {
    await repoA.dispose();
    await repoB.dispose();
    await dbA.close();
    await dbB.close();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {
      // 清理失败不影响测试结果。
    }
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
    final rows = await dbA.query('play_events',
        columns: ['originDeviceId'], where: 'songId = ?', whereArgs: ['s9']);
    expect(rows.single['originDeviceId'], 'devB');
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
      await db.insert('play_events', {
        'sourceKey': 'wy',
        'songId': 'legacy',
        'title': 'Legacy',
        'artist': '',
        'album': '',
        'raw': '{}',
        'startedAt': 100,
        'endedAt': 200,
        'listenedMs': 100,
        'maxPositionMs': 100,
        'endReason': 'completed',
        'originDeviceId': '',
      });
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
}
