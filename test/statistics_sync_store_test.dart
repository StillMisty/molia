import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/play_statistics_repository.dart';
import 'package:molia/data/sync/statistics_sync_store.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/models/play_statistics.dart';
import 'package:molia/domain/ports/statistics_sync_store.dart';

import 'support/sync_test_support.dart';

import 'support/memory_database.dart';

/// 听歌统计同步存储测试：首次导出 / 本地曲目过滤 /
/// 版本与内容时间分离 / 应用幂等 / 导出缓存。
void main() {
  late MoliaDatabase db;
  late SqliteStatisticsSyncStore store;
  late PlayStatisticsRepository repository;
  var clock = 1000;

  setUp(() {
    clock = 1000;
    db = openMemoryDatabase();
    store = testStatisticsSyncStore(
      () => db,
      clock: () => clock,
      deviceId: 'devA',
    );
    repository = PlayStatisticsRepository(
      databaseProvider: () => db,
      clock: () => clock,
      statisticsSync: store,
    );
  });

  tearDown(() async {
    await repository.dispose();
    await db.close();
  });

  Future<int> play({
    String sourceKey = 'wy',
    String songId = 's1',
    String title = 'Song',
    Map<String, dynamic> raw = const {},
    int startedAt = 1000,
    int endedAt = 61000,
    int listenedMs = 60000,
  }) async {
    final id = await repository.startEvent(
      sourceKey: sourceKey,
      songId: songId,
      title: title,
      raw: raw,
      startedAt: startedAt,
    );
    await repository.finishEvent(
      id,
      reason: PlayEventEndReason.completed,
      listenedMs: listenedMs,
      maxPositionMs: listenedMs,
      endedAt: endedAt,
    );
    return id;
  }

  test('首次收尾：导出带 syncKey / 设备戳 / 自包含内容，指纹随收尾推进', () async {
    final id = await repository.startEvent(
      sourceKey: 'wy',
      songId: 's1',
      title: '歌曲一',
      raw: const {'id': 's1'},
      startedAt: 1000,
    );
    final beforeFinish = await store.syncFingerprint();
    await repository.touchEvent(id, listenedMs: 5000, maxPositionMs: 5000);
    expect(
      await store.syncFingerprint(),
      beforeFinish,
      reason: '进行中事件不导出，不影响指纹',
    );

    await repository.finishEvent(
      id,
      reason: PlayEventEndReason.completed,
      listenedMs: 60000,
      maxPositionMs: 60000,
      endedAt: 61000,
    );
    expect(await store.syncFingerprint(), isNot(beforeFinish));

    final exported = await store.syncExportEvents();
    expect(exported, hasLength(1));
    final event = exported.single;
    expect(event.syncKey, isNotEmpty);
    expect(event.version.deviceId, 'devA');
    expect(event.version.physical, 1000);
    expect(event.sourceKey, 'wy');
    expect(event.songId, 's1');
    expect(event.endedAt, 61000);
    expect(event.raw, '{"id":"s1"}');
    expect(event.toData().containsKey('id'), isFalse, reason: '本机行 id 不出本机');
    expect(event.toData()['syncKey'], event.syncKey);

    // 事件行的同步列由写入点落库（仓库不再自己拼 syncKey / 来源设备）。
    final row = (await tableRows(db, 'play_events')).single;
    expect(row['syncKey'], event.syncKey);
    expect(row['originDeviceId'], 'devA');

    // 指纹未变时导出复用同一列表实例（缓存命中不读全表）。
    expect(identical(await store.syncExportEvents(), exported), isTrue);
  });

  test('本地下载曲目：导出与应用两侧都过滤', () async {
    await play(sourceKey: 'local', songId: 'wy:9', title: '本地下载');
    await play(sourceKey: 'wy', songId: 's1', title: '在线歌曲');

    final exported = await store.syncExportEvents();
    expect(exported, hasLength(1));
    expect(exported.single.sourceKey, 'wy');

    // 对端收到 local 事件也忽略（防御：异常或外来数据）。
    final result = await store.syncApplyEvents([
      const StatisticsSyncEvent(
        syncKey: 'remote-local',
        version: SyncVersion(physical: 9000, deviceId: 'devB'),
        sourceKey: 'local',
        songId: 'wy:9',
        title: '本地下载',
        startedAt: 1000,
        endedAt: 2000,
      ),
    ]);
    expect(result.applied, 0);
    expect(result.skipped, 1);
    expect(
      await tableRows(db, 'play_events'),
      hasLength(2),
      reason: '本地事件仍在，但远端 local 记录不落地',
    );
  });

  test('版本与内容时间分离：endedAt 更大但版本更旧的事件不覆盖', () async {
    final id = await play(songId: 'same', title: '本机', listenedMs: 60000);
    final localKey = (await db.customSelect(
      'SELECT syncKey FROM play_events WHERE id = ?',
      variables: [Variable.withInt(id)],
    ).getSingle())
        .data['syncKey'] as String;

    // 更旧版本 + 更大的内容时间：按版本应跳过。
    final older = await store.syncApplyEvents([
      StatisticsSyncEvent(
        syncKey: localKey,
        version: const SyncVersion(physical: 1, deviceId: 'devB'),
        sourceKey: 'wy',
        songId: 'same',
        title: '远端旧版本',
        startedAt: 9000,
        endedAt: 999999,
        listenedMs: 1,
      ),
    ]);
    expect(older, (applied: 0, skipped: 1));
    var row = (await db.customSelect(
      'SELECT endedAt, listenedMs, versionPhysical FROM play_events '
      'WHERE syncKey = ?',
      variables: [Variable.withString(localKey)],
    ).getSingle())
        .data;
    expect(row['endedAt'], 61000);
    expect(row['listenedMs'], 60000);

    // 更新版本 + 更小的内容时间：版本胜出，内容时间只是字段。
    final newer = await store.syncApplyEvents([
      StatisticsSyncEvent(
        syncKey: localKey,
        version: const SyncVersion(physical: 2000, deviceId: 'devB'),
        sourceKey: 'wy',
        songId: 'same',
        title: '远端新版本',
        startedAt: 9000,
        endedAt: 5000,
        listenedMs: 123,
      ),
    ]);
    expect(newer, (applied: 1, skipped: 0));
    row = (await db.customSelect(
      'SELECT endedAt, listenedMs, versionPhysical FROM play_events '
      'WHERE syncKey = ?',
      variables: [Variable.withString(localKey)],
    ).getSingle())
        .data;
    expect(row['endedAt'], 5000);
    expect(row['listenedMs'], 123);
    expect(row['versionPhysical'], 2000);
  });

  test('应用同一远端事件两次：第二次幂等跳过，行数不增', () async {
    const event = StatisticsSyncEvent(
      syncKey: 'remote-1',
      version: SyncVersion(physical: 9000, deviceId: 'devB'),
      sourceKey: 'wy',
      songId: 'remote',
      title: '远端歌曲',
      raw: '{"v":1}',
      startedAt: 100,
      endedAt: 200,
      listenedMs: 100,
      maxPositionMs: 100,
      endReason: 'completed',
    );

    final first = await store.syncApplyEvents([event]);
    expect(first, (applied: 1, skipped: 0));
    final second = await store.syncApplyEvents([event]);
    expect(second, (applied: 0, skipped: 1));
    expect(await tableRows(db, 'play_events'), hasLength(1));
    expect(await tableRows(db, 'play_tracks'), hasLength(1));

    final exported = await store.syncExportEvents();
    expect(exported.single.syncKey, 'remote-1');
  });
}
