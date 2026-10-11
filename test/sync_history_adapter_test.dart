import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/database_helper.dart';
import 'package:molia/data/library_repository.dart';
import 'package:molia/data/sync/adapters/history_sync_adapter.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/models/library.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 播放历史适配器测试：两库互导、playedAt 取新、删除墓碑与复活。
void main() {
  sqfliteFfiInit();

  late Directory tempDir;
  late Database dbA;
  late Database dbB;
  late LibraryRepository repoA;
  late LibraryRepository repoB;
  late HistorySyncAdapter adapterA;
  late HistorySyncAdapter adapterB;

  Future<Database> openDb(String name) => databaseFactoryFfi.openDatabase(
        '${tempDir.path}/$name.db',
        options: OpenDatabaseOptions(
          version: DatabaseHelper.dbVersion,
          onCreate: (database, version) => DatabaseHelper.createSchema(database),
        ),
      );

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
    tempDir = Directory.systemTemp.createTempSync('molia_sync_history');
    dbA = await openDb('a');
    dbB = await openDb('b');
    repoA = LibraryRepository(
      databaseProvider: () async => dbA,
      deviceIdProvider: () => 'devA',
    );
    repoB = LibraryRepository(
      databaseProvider: () async => dbB,
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
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {
      // 清理失败不影响测试结果。
    }
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
}
