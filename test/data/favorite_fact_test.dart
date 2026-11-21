import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/library/favorite_fact.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/domain/models/library_browse.dart';

import '../support/fake_library_repository.dart';

/// 允许把收藏键 / 收藏列表读取挂在闸门上，制造「读取在途时又发生切换」。
class _GatedLibraryRepository extends FakeLibraryRepository {
  Completer<Set<String>>? nextKeys;
  Completer<List<PlaylistTrack>>? nextTracks;
  int keysCalls = 0;
  int tracksCalls = 0;

  @override
  Future<Set<String>> favoriteKeys() {
    keysCalls++;
    final gate = nextKeys;
    if (gate != null) {
      nextKeys = null;
      return gate.future;
    }
    return super.favoriteKeys();
  }

  @override
  Future<List<PlaylistTrack>> listPlaylistTracks(int playlistId, {int? limit}) {
    tracksCalls++;
    final gate = nextTracks;
    if (gate != null) {
      nextTracks = null;
      return gate.future;
    }
    return super.listPlaylistTracks(playlistId, limit: limit);
  }
}

PlaylistTrack track(
  String id, {
  int sortOrder = 0,
  int addedAt = 0,
  String sourceKey = 'wy',
}) => PlaylistTrack(
  playlistId: 0,
  sourceKey: sourceKey,
  songId: id,
  title: 'Song $id',
  addedAt: addedAt,
  sortOrder: sortOrder,
);

FavoriteToggle addToggle(PlaylistTrack row) => FavoriteToggle.add(row);

FavoriteToggle removeToggle(String id, {String sourceKey = 'wy'}) =>
    FavoriteToggle.remove(sourceKey: sourceKey, songId: id);

void main() {
  late _GatedLibraryRepository repository;
  late FavoriteFact fact;

  setUp(() {
    repository = _GatedLibraryRepository();
    fact = FavoriteFact(repository: repository);
  });

  tearDown(() {
    fact.dispose();
  });

  Future<int> seedFavorites(List<PlaylistTrack> rows) async {
    await repository.addFavorites(rows);
    final playlist = await repository.findPlaylistByName('__favorites__');
    fact.bindPlaylist(playlist!.id);
    return playlist.id;
  }

  test('整表读取：键与计数落地，行保持未加载', () async {
    await seedFavorites([track('1'), track('2')]);
    final revision = fact.revision;

    await fact.ensureLoaded(force: true);

    expect(fact.contains('wy', '1'), isTrue);
    expect(fact.contains('wy', '3'), isFalse);
    expect(fact.rows, isNull, reason: '整表读取只读键，不顺手把整表曲目读进内存');
    expect(fact.count, 2);
    expect(fact.revision, greaterThan(revision));
    expect(fact.snapshot.keys, {'wy:1', 'wy:2'});
  });

  test('已加载且非 force：重复 ensure 不再查库', () async {
    await seedFavorites([track('1')]);
    await fact.ensureLoaded(force: true);
    repository.keysCalls = 0;

    await fact.ensureLoaded();

    expect(repository.keysCalls, 0);
  });

  test('单曲切换：键 / 行 / 计数一次更新，重复补丁不递增版本', () async {
    await seedFavorites([track('1', sortOrder: 0, addedAt: 1)]);
    await fact.ensureLoaded(force: true);
    fact.adoptRows([track('1', sortOrder: 0, addedAt: 1)]);

    final before = fact.revision;
    fact.applyChange(addToggle(track('2', sortOrder: 1, addedAt: 2)));

    expect(fact.contains('wy', '2'), isTrue);
    expect(fact.count, 2);
    expect(fact.rows!.map((row) => row.songId), ['1', '2']);
    expect(fact.revision, before + 1);

    // 事件与写入口各补一次：第二次没有键变化，不应重复递增版本。
    fact.applyChange(addToggle(track('2', sortOrder: 1, addedAt: 2)));
    expect(fact.revision, before + 1);

    fact.applyChange(removeToggle('1'));
    expect(fact.contains('wy', '1'), isFalse);
    expect(fact.count, 1);
    expect(fact.rows!.map((row) => row.songId), ['2']);
    expect(fact.revision, before + 2);
  });

  test('行顺序：sortOrder 优先，同序按 addedAt', () async {
    fact.adoptRows([
      track('b', sortOrder: 1, addedAt: 20),
      track('d', sortOrder: 3, addedAt: 1),
    ]);

    fact.applyChange(addToggle(track('a', sortOrder: 1, addedAt: 10)));
    fact.applyChange(addToggle(track('c', sortOrder: 2, addedAt: 0)));
    fact.applyChange(addToggle(track('e', sortOrder: 4, addedAt: 0)));

    expect(fact.rows!.map((row) => row.songId), ['a', 'b', 'c', 'd', 'e']);
  });

  test('读取在途时切换：旧快照落地后键与行都被重放', () async {
    await seedFavorites([track('1', sortOrder: 0, addedAt: 1)]);
    fact.adoptRows([track('1', sortOrder: 0, addedAt: 1)]);

    final gate = Completer<Set<String>>();
    repository.nextKeys = gate;
    final reading = fact.ensureLoaded(force: true);
    await Future<void>.delayed(Duration.zero);

    fact.applyChange(addToggle(track('2', sortOrder: 1, addedAt: 2)));
    expect(fact.contains('wy', '2'), isTrue);

    // 旧快照不含 2：落地后必须重放，不能把刚写入的收藏覆盖掉。
    gate.complete({'wy:1'});
    await reading;

    expect(fact.contains('wy', '2'), isTrue);
    expect(fact.count, 2);
    expect(fact.rows!.map((row) => row.songId), ['1', '2']);
  });

  test('批量校准在途时切换：旧键 / 旧行快照都不会覆盖新收藏', () async {
    await seedFavorites([track('1', sortOrder: 0, addedAt: 1)]);
    await fact.ensureLoaded(force: true);
    fact.adoptRows([track('1', sortOrder: 0, addedAt: 1)]);

    final keysGate = Completer<Set<String>>();
    final tracksGate = Completer<List<PlaylistTrack>>();
    repository.nextKeys = keysGate;
    repository.nextTracks = tracksGate;
    final reloading = fact.reload(readRows: true);
    await Future<void>.delayed(Duration.zero);

    fact.applyChange(addToggle(track('2', sortOrder: 1, addedAt: 2)));

    keysGate.complete({'wy:1'});
    tracksGate.complete([track('1', sortOrder: 0, addedAt: 1)]);
    await reloading;

    expect(fact.contains('wy', '2'), isTrue);
    expect(fact.count, 2);
    expect(fact.rows!.map((row) => row.songId), ['1', '2']);
  });

  test('后发起的整表读取优先，旧快照不能回滚新快照', () async {
    final staleGate = Completer<Set<String>>();
    repository.nextKeys = staleGate;
    final stale = fact.ensureLoaded(force: true);
    await Future<void>.delayed(Duration.zero);

    final freshGate = Completer<Set<String>>();
    repository.nextKeys = freshGate;
    final fresh = fact.ensureLoaded(force: true);
    await Future<void>.delayed(Duration.zero);

    freshGate.complete({'wy:fresh'});
    await fresh;
    staleGate.complete({'wy:stale'});
    await stale;

    expect(fact.contains('wy', 'fresh'), isTrue);
    expect(fact.contains('wy', 'stale'), isFalse);
  });

  test('批量收藏 / 取消：返回实际变化数，键与计数同步', () async {
    final added = await fact.addAll([track('1'), track('2')]);
    expect(added, 2);
    expect(fact.count, 2);
    expect(fact.contains('wy', '1'), isTrue);

    // 重复收藏跳过，不改变计数。
    expect(await fact.addAll([track('1')]), 0);
    expect(fact.count, 2);

    final removed = await fact.removeAll([
      (sourceKey: 'wy', songId: '1'),
      (sourceKey: 'wy', songId: 'missing'),
    ]);
    expect(removed, 1);
    expect(fact.count, 1);
    expect(fact.contains('wy', '1'), isFalse);
  });

  test('写失败向上抛，事实保持原样', () async {
    await fact.addAll([track('1')]);
    final revision = fact.revision;
    repository.failFavoriteWrites = true;

    await expectLater(
      fact.toggle(sourceKey: 'wy', songId: '2', title: 'Song 2'),
      throwsStateError,
    );
    await expectLater(fact.addAll([track('3')]), throwsStateError);
    await expectLater(
      fact.removeAll([(sourceKey: 'wy', songId: '1')]),
      throwsStateError,
    );

    expect(fact.contains('wy', '1'), isTrue);
    expect(fact.contains('wy', '2'), isFalse);
    expect(fact.revision, revision);
  });

  test('计数优先级：整表键 > 已加载行 > 清单计数 ± 净变化', () async {
    fact.seedCount(7);
    expect(fact.count, 7, reason: '没有更可信依据时采用清单计数');

    fact.applyChange(addToggle(track('1')));
    expect(fact.count, 8, reason: '无整表键 / 无行时按单步增减');
    fact.applyChange(removeToggle('1'));
    expect(fact.count, 7);

    fact.adoptRows([track('1'), track('2')]);
    expect(fact.count, 2, reason: '已加载行优先于清单计数');
    fact.seedCount(9);
    expect(fact.count, 2);

    await fact.ensureLoaded(force: true);
    expect(fact.count, 0, reason: '整表收藏键是最高优先级（仓库里还没有收藏）');
    await fact.addAll([track('3')]);
    expect(fact.count, 1);
  });

  test('releaseRows：保留键与计数，行等页面重新读取', () async {
    await fact.addAll([track('1')]);
    fact.adoptRows([track('1')]);
    expect(fact.rows, isNotNull);

    fact.releaseRows();

    expect(fact.rows, isNull);
    expect(fact.contains('wy', '1'), isTrue);
    expect(fact.count, 1);
  });

  test('外部行投影：与事实同一插入顺序，无变化返回原引用', () {
    BrowseTrack browse(String id, {int sortOrder = 0, int addedAt = 0}) =>
        BrowseTrack(
          sourceKey: 'wy',
          songId: id,
          title: 'Song $id',
          sortOrder: sortOrder,
          addedAt: addedAt,
        );

    final rows = [browse('a', sortOrder: 0, addedAt: 1)];
    final added = fact.applyToggleToProjection(
      rows: rows,
      toggle: addToggle(track('b', sortOrder: 1, addedAt: 2)),
      wrap: BrowseTrack.fromPlaylistTrack,
    );
    expect(added.map((row) => row.songId), ['a', 'b']);

    final duplicate = fact.applyToggleToProjection(
      rows: added,
      toggle: addToggle(track('b', sortOrder: 1, addedAt: 2)),
      wrap: BrowseTrack.fromPlaylistTrack,
    );
    expect(identical(duplicate, added), isTrue, reason: '重复收藏不重建投影');

    final removed = fact.applyToggleToProjection(
      rows: added,
      toggle: removeToggle('a'),
      wrap: BrowseTrack.fromPlaylistTrack,
    );
    expect(removed.map((row) => row.songId), ['b']);

    final missing = fact.applyToggleToProjection(
      rows: removed,
      toggle: removeToggle('missing'),
      wrap: BrowseTrack.fromPlaylistTrack,
    );
    expect(identical(missing, removed), isTrue, reason: '取消不存在的收藏不重建');
  });
}
