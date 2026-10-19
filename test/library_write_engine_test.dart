/// 资料库写入网关：五步仪式（发号 → 写行 → journal 记录 → 墓碑 → 变更事件）
/// 的产物与顺序钉死。
///
/// 真 drift in-memory 库 + 真日志仓库：只经公开意图方法观察行 / 日志窗口 /
/// 变更广播，不读私有字段。网关是 data 层内部模块，直接单测——以前这些口径
/// 只能经 1968 行的仓库整体验证。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/library_write_engine.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/sync/sync_journal.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/models/library.dart';

import 'support/memory_database.dart';
import 'support/sync_test_support.dart';

void main() {
  late MoliaDatabase db;
  late SyncJournalRepository journal;
  late LibraryWriteEngine engine;
  late List<LibraryChange> events;
  late StreamSubscription<LibraryChange> subscription;

  /// 内容时间（`createdAt` / `addedAt` / 墓碑的真实删除时间）的注入值。
  const clockMs = 5000;

  setUp(() {
    db = openMemoryDatabase();
    journal = SyncJournalRepository(
      databaseProvider: () => db,
      clock: () => 9000,
    );
    engine = LibraryWriteEngine(
      databaseProvider: () => db,
      clock: () => clockMs,
      stamps: testStampIssuer(clock: () => 1000, deviceId: 'devA'),
      journal: journal,
    );
    events = [];
    subscription = engine.changes.listen(events.add);
  });

  tearDown(() async {
    await subscription.cancel();
    await engine.dispose();
    await db.close();
  });

  /// 变更广播是异步投递（非 sync 控制器）：断言前先让微任务队列排空。
  Future<void> flush() => Future<void>.delayed(Duration.zero);

  PlayHistoryEntry history(String songId, {int playedAt = 100}) =>
      PlayHistoryEntry(
        sourceKey: 'wy',
        songId: songId,
        title: 'Song $songId',
        artist: 'Artist',
        album: 'Album',
        coverUrl: 'https://img.example/$songId.jpg',
        durationMs: 180000,
        raw: {'songId': songId},
        playedAt: playedAt,
      );

  /// 建一个列表并丢掉它自己的广播（后续断言只看被测意图）。
  Future<int> createPlaylist() async {
    final id = await engine.createPlaylist('L');
    await flush();
    events.clear();
    return id;
  }

  PlaylistTrack track(String songId, {int addedAt = 10}) => PlaylistTrack(
        playlistId: 0,
        sourceKey: 'wy',
        songId: songId,
        title: 'T$songId',
        artist: 'A$songId',
        album: 'B$songId',
        raw: {'songId': songId},
        addedAt: addedAt,
      );

  /// 列表内曲目按 `sortOrder` 升序（展示顺序）的键序列。
  Future<List<String>> orderedIds(int playlistId) async {
    final rows = await (db.select(db.playlistTracks)
          ..where((t) => t.playlistId.equals(playlistId)))
        .get();
    rows.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return [for (final row in rows) '${row.sourceKey}:${row.songId}'];
  }

  /// 独立位置偏好的网关实例（与 setUp 的默认实例共用同一库 / 日志）。
  LibraryWriteEngine engineWithPosition(bool Function() addToTop) {
    final scoped = LibraryWriteEngine(
      databaseProvider: () => db,
      clock: () => clockMs,
      stamps: testStampIssuer(clock: () => 1000, deviceId: 'devA'),
      journal: journal,
      addToTop: addToTop,
    );
    addTearDown(scoped.dispose);
    return scoped;
  }

  test('历史写入 / 删除：行版本 = 日志版本，墓碑按注入时钟，各广播一次', () async {
    await engine.addHistoryEntry(history('1', playedAt: 100));
    await flush();
    expect(events, [const LibraryHistoryChange()]);

    final row = (await db.select(db.playHistory).get()).single;
    expect(row.playedAt, 100);
    final entry = (await journal.window()).single;
    expect(entry.category, SyncCategory.history);
    expect(entry.record.key, SyncRecordKeys.history('wy', '1'));
    expect(entry.record.deleted, isFalse);
    // 行与日志共用同一个号（同一版本在日志与全量快照里必须一致）。
    expect(entry.record.version, row.syncVersion);
    expect(entry.record.data?['playedAt'], 100);
    expect(entry.record.data?['title'], 'Song 1');

    events.clear();
    await engine.deleteHistoryEntry('wy', '1');
    await flush();
    expect(await db.select(db.playHistory).get(), isEmpty);
    expect(events, [const LibraryHistoryChange()]);
    final tombstone = (await db.select(db.syncTombstones).get()).single;
    expect(tombstone.category, SyncCategory.history.name);
    expect(tombstone.key, SyncRecordKeys.history('wy', '1'));
    // 真实删除时间是内容时间：取注入时钟，不进版本戳。
    expect(tombstone.deletedAt, clockMs);
    final removal = (await journal.window(since: 1)).single;
    expect(removal.record.deleted, isTrue);
    expect(removal.record.version, tombstone.syncVersion);
  });

  test('批量历史：每行一个新号，行版本与日志一一对应且严格递增', () async {
    await engine.addHistoryEntries([
      history('1', playedAt: 1),
      history('2', playedAt: 2),
    ]);

    final rows = await db.select(db.playHistory).get();
    final window = await journal.window();
    expect(rows, hasLength(2));
    expect(window, hasLength(2));

    final versions = [for (final entry in window) entry.record.version];
    expect(versions.toSet(), hasLength(2), reason: '发号唯一');
    expect(versions[1].isNewerThan(versions[0]), isTrue, reason: '发号严格单调');
    for (final row in rows) {
      final entry = window.singleWhere(
        (e) => e.record.key == SyncRecordKeys.history(row.sourceKey, row.songId),
      );
      expect(entry.record.version, row.syncVersion);
    }
  });

  test('重播复活：再次写入清除该曲目的历史墓碑', () async {
    await engine.addHistoryEntry(history('1'));
    await engine.deleteHistoryEntry('wy', '1');
    expect(await db.select(db.syncTombstones).get(), hasLength(1));

    await engine.addHistoryEntry(history('1', playedAt: 200));
    expect(await db.select(db.syncTombstones).get(), isEmpty);
    expect((await db.select(db.playHistory).get()).single.playedAt, 200);
  });

  test('列表曲目加入：排序位 + 日志载荷带列表 syncId；重复加入不写不广播', () async {
    final playlistId = await createPlaylist();
    final syncId = (await db.select(db.playlists).get()).single.syncId!;
    final head = await journal.headSeq();

    expect(await engine.addTrackToPlaylist(playlistId, track('1')), isTrue);
    await flush();

    final row = (await db.select(db.playlistTracks).get()).single;
    expect(row.sortOrder, 0);
    expect(row.addedAt, 10);
    expect(row.syncVersion, (await journal.window(since: head)).single.record.version);
    expect((events.single as LibraryPlaylistTracksChange).playlistId, playlistId);

    final record = (await journal.window(since: head)).single.record;
    expect(record.key, SyncRecordKeys.playlistTrack(syncId, 'wy', '1'));
    expect(record.data?['sortOrder'], 0);
    expect(record.data?['title'], 'T1');

    // 重复加入：不发号、不写日志、不广播。
    events.clear();
    expect(await engine.addTrackToPlaylist(playlistId, track('1')), isFalse);
    await flush();
    expect(events, isEmpty);
    expect(await journal.window(since: head), hasLength(1));
  });

  group('加入列表位置偏好', () {
    test('偏好顶部：单条与批次都插到列表开头，批内保持传入顺序', () async {
      final top = engineWithPosition(() => true);
      final playlistId = await top.createPlaylist('L');

      await top.addTrackToPlaylist(playlistId, track('1'));
      final head = await journal.headSeq();
      await top.addTracksToPlaylist(playlistId, [track('2'), track('3')]);

      expect(await orderedIds(playlistId), ['wy:2', 'wy:3', 'wy:1']);
      // 日志的 sortOrder 与实际行一致（顶部插入是连续区间）。
      expect(
        [for (final entry in await journal.window(since: head))
          entry.record.data?['sortOrder']],
        [-2, -1],
      );

      // 再插一批：新批次整体仍在最前，既有条目顺序不动。
      await top.addTrackToPlaylist(playlistId, track('4'));
      expect(await orderedIds(playlistId), ['wy:4', 'wy:2', 'wy:3', 'wy:1']);
    });

    test('偏好顶部：去重后再取排序位（批内不使用被跳过的名额）', () async {
      final top = engineWithPosition(() => true);
      final playlistId = await top.createPlaylist('L');
      await top.addTrackToPlaylist(playlistId, track('1'));

      final added = await top.addTracksToPlaylist(playlistId, [
        track('2'),
        track('2'), // 批内重复
        track('1'), // 已在列表
        track('3'),
      ]);

      expect(added, 2);
      expect(await orderedIds(playlistId), ['wy:2', 'wy:3', 'wy:1']);
    });

    test('空列表顶部插入仍从 0 开始（首行排序位口径不变）', () async {
      final top = engineWithPosition(() => true);
      final playlistId = await top.createPlaylist('L');

      await top.addTrackToPlaylist(playlistId, track('1'));

      final row = (await db.select(db.playlistTracks).get()).single;
      expect(row.sortOrder, 0);
    });

    test('偏好底部：与旧口径一致追加；显式覆盖（表内导入）不受偏好影响', () async {
      final top = engineWithPosition(() => true);
      final playlistId = await top.createPlaylist('L');
      await top.addTracksToPlaylist(playlistId, [track('1'), track('2')]);

      // 显式 false = 导入路径：追加到末尾。
      await top.addTracksToPlaylist(playlistId, [track('3')], addToTop: false);
      expect(await orderedIds(playlistId), ['wy:1', 'wy:2', 'wy:3']);

      // 偏好底部的实例与未接线实例都追加。
      final bottom = engineWithPosition(() => false);
      final other = await bottom.createPlaylist('L2');
      await bottom.addTracksToPlaylist(other, [track('1')]);
      await bottom.addTracksToPlaylist(other, [track('2')]);
      expect(await orderedIds(other), ['wy:1', 'wy:2']);
    });
  });

  test('批量移除：墓碑与日志一次追加，只广播一次', () async {
    final playlistId = await createPlaylist();
    for (final songId in ['1', '2', '3']) {
      await engine.addTrackToPlaylist(playlistId, track(songId));
    }
    await flush();
    events.clear();
    final head = await journal.headSeq();

    final removed = await engine.removeTracksFromPlaylist(playlistId, [
      (sourceKey: 'wy', songId: '1'),
      (sourceKey: 'wy', songId: '3'),
      (sourceKey: 'wy', songId: '404'),
    ]);
    await flush();

    expect(removed, 2);
    expect(events.single, isA<LibraryPlaylistTracksChange>());
    final tombstones = await db.select(db.syncTombstones).get();
    expect(tombstones, hasLength(2), reason: '不存在的键不留墓碑');
    expect(tombstones.map((t) => t.deletedAt), everyElement(clockMs));
    final removals = await journal.window(since: head);
    expect(removals, hasLength(2), reason: '批量墓碑只追加一次日志');
    for (final entry in removals) {
      expect(entry.record.deleted, isTrue);
      final row = tombstones.singleWhere((t) => t.key == entry.record.key);
      expect(entry.record.version, row.syncVersion);
    }
  });

  test('列表换源：目标缺失不写不广播；命中时保位置并取新号进日志', () async {
    final playlistId = await createPlaylist();
    await engine.addTrackToPlaylist(playlistId, track('1'));
    await engine.addTrackToPlaylist(playlistId, track('2'));
    await flush();
    events.clear();
    final head = await journal.headSeq();
    final before = (await db.select(db.playlistTracks).get())
        .firstWhere((row) => row.songId == '1');

    expect(
      await engine.replacePlaylistTrack(
        playlistId,
        (sourceKey: 'wy', songId: '404'),
        track('900'),
      ),
      isFalse,
    );
    await flush();
    expect(events, isEmpty);
    expect(await journal.window(since: head), isEmpty);

    expect(
      await engine.replacePlaylistTrack(
        playlistId,
        (sourceKey: 'wy', songId: '1'),
        track('900'),
      ),
      isTrue,
    );
    await flush();
    final swapped = (await db.select(db.playlistTracks).get())
        .firstWhere((row) => row.songId == '900');
    expect(swapped.sortOrder, before.sortOrder);
    expect(swapped.addedAt, before.addedAt, reason: '换源不改变加入时间');
    expect(swapped.syncVersion, (await journal.window(since: head)).single.record.version);
    expect(events.single, isA<LibraryPlaylistTracksChange>());
  });

  test('收藏切换：加入时间走注入时钟，固定 syncId，广播与墓碑齐全', () async {
    expect(
      await engine.toggleFavorite(sourceKey: 'wy', songId: '1', title: 'A'),
      isTrue,
    );
    await flush();

    final favorites = (await db.select(db.playlists).get()).single;
    expect(favorites.name, favoritesPlaylistRowName);
    expect(favorites.syncId, SyncRecordKeys.favoritesPlaylistSyncId);
    expect(events.last, isA<LibraryFavoritesChange>());
    // 加入时间是内容时间：经注入时钟（曾经走 DateTime.now()，无法钉住）。
    expect((await db.select(db.playlistTracks).get()).single.addedAt, clockMs);

    events.clear();
    expect(
      await engine.toggleFavorite(sourceKey: 'wy', songId: '1', title: 'A'),
      isFalse,
    );
    await flush();
    expect(events.single, isA<LibraryFavoritesChange>());
    expect(await db.select(db.playlistTracks).get(), isEmpty);
    final tombstone = (await db.select(db.syncTombstones).get()).single;
    expect(tombstone.category, SyncCategory.playlistTracks.name);
    expect(tombstone.deletedAt, clockMs);
  });

  test('导入：addedAt 由调用方给、不追 journal、0 新增也广播 import', () async {
    final playlistId = await createPlaylist();
    final head = await journal.headSeq();

    expect(
      await engine.importPlaylistTracks(
        playlistId,
        [track('1', addedAt: 777), track('2', addedAt: 777)],
      ),
      2,
    );
    await flush();
    expect(events.single, isA<LibraryImportChange>());
    final rows = await db.select(db.playlistTracks).get();
    expect(rows.map((row) => row.addedAt), everyElement(777));
    expect(rows.map((row) => row.sortOrder), [0, 1]);
    // 导入路径不追加日志（既有口径：整批落库，见网关内说明）。
    expect(await journal.headSeq(), head);

    // 全部重复：0 新增也广播（复用的列表要刷新）。
    events.clear();
    expect(await engine.importPlaylistTracks(playlistId, [track('1')]), 0);
    await flush();
    expect(events.single, isA<LibraryImportChange>());
  });

  test('空输入：不发号、不写、不广播', () async {
    final playlistId = await createPlaylist();
    final head = await journal.headSeq();

    expect(await engine.addHistoryEntries(const []), 0);
    expect(await engine.removeTracksFromPlaylist(playlistId, const []), 0);
    expect(await engine.addTracksToPlaylist(playlistId, const []), 0);
    await engine.reorderPlaylistTracks(playlistId, const []);
    await flush();

    expect(events, isEmpty);
    expect(await journal.headSeq(), head);
  });
}
