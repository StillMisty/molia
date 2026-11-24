import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/library_repository.dart';
import 'package:molia/data/local_cache_index_repository.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/domain/models/local_cache_index.dart';
import 'package:molia/domain/ports/local_cache_index.dart';
import 'package:molia/providers/local_songs_collection.dart';
import 'package:molia/services/audio_cache_store.dart';
import 'package:molia/services/local_cache_index_store.dart';
import 'package:molia/sources/source_track.dart';

import 'support/memory_database.dart';
import 'support/sync_test_support.dart';

/// 假持久化：记录每次 upsert / remove，便于断言「只在完成时写」「重复对账
/// 不重复写」与上限裁剪。
class _FakePersistence implements LocalCacheIndexPersistence {
  _FakePersistence({Iterable<LocalCacheIndexEntry> rows = const []})
    : rows = {for (final row in rows) row.key: row};

  final Map<String, LocalCacheIndexEntry> rows;
  final List<LocalCacheIndexEntry> upserts = [];
  final List<LocalCacheIndexKey> removals = [];
  bool failLoad = false;

  @override
  Future<List<LocalCacheIndexEntry>> loadAll() async {
    if (failLoad) throw StateError('load failed');
    return rows.values.toList();
  }

  @override
  Future<void> upsertAll(List<LocalCacheIndexEntry> entries) async {
    upserts.addAll(entries);
    for (final entry in entries) {
      rows[entry.key] = entry;
    }
  }

  @override
  Future<void> removeAll(Iterable<LocalCacheIndexKey> keys) async {
    for (final key in keys) {
      removals.add(key);
      rows.remove('${key.sourceKey}:${key.songId}');
    }
  }
}

void main() {
  LocalCacheIndexEntry entry(
    String id, {
    int cachedAt = 1,
    String title = '',
    String sourceKey = 'wy',
  }) => LocalCacheIndexEntry(
    sourceKey: sourceKey,
    songId: id,
    title: title.isEmpty ? 'Song $id' : title,
    artist: 'Artist',
    album: 'Album',
    raw: {'songId': id},
    cachedAt: cachedAt,
  );

  SourceTrack sourceTrack(String id, {String title = ''}) => SourceTrack(
    sourceKey: 'wy',
    origin: 'builtin',
    title: title.isEmpty ? 'Song $id' : title,
    artist: 'Artist',
    album: 'Album',
    duration: const Duration(seconds: 200),
    raw: {'songId': id},
  );

  Map<String, int> cacheFiles(Iterable<String> ids) => {
    for (final id in ids)
      AudioCacheStore.key(sourceKey: 'wy', songId: id): 1024,
  };

  group('LocalCacheIndexStore', () {
    test('初始化装载持久化行；初始化完成才通知', () async {
      final persistence = _FakePersistence(
        rows: [entry('1', cachedAt: 10), entry('2', cachedAt: 20)],
      );
      final store = LocalCacheIndexStore(persistence: persistence);
      addTearDown(store.dispose);
      var notifications = 0;
      store.changes.addListener(() => notifications++);

      expect(store.initialized, isFalse);
      await store.init();

      expect(store.initialized, isTrue);
      expect(store.entries.map((row) => row.songId), ['2', '1']);
      expect(notifications, 1);
      expect(store.revision, 1);
    });

    test('缓存完成才写：记录完成后内存与持久化同时更新并通知', () async {
      final persistence = _FakePersistence();
      final store = LocalCacheIndexStore(persistence: persistence);
      addTearDown(store.dispose);
      await store.init();
      var notifications = 0;
      store.changes.addListener(() => notifications++);

      await store.recordCompleted(sourceTrack('1'));

      expect(store.entries, hasLength(1));
      expect(store.entries.single.title, 'Song 1');
      expect(store.entries.single.durationMs, 200000);
      expect(persistence.rows.keys, ['wy:1']);
      expect(notifications, 1);
    });

    test('同曲目重复完成：按键幂等 upsert，不产生第二行', () async {
      final persistence = _FakePersistence();
      final store = LocalCacheIndexStore(
        persistence: persistence,
        clock: () => DateTime.fromMillisecondsSinceEpoch(100),
      );
      addTearDown(store.dispose);
      await store.init();

      await store.recordCompleted(sourceTrack('1', title: '旧标题'));
      await store.recordCompleted(sourceTrack('1', title: '新标题'));

      expect(store.entries, hasLength(1));
      expect(store.entries.single.title, '新标题');
      expect(store.entries.single.cachedAt, 100);
      expect(persistence.rows, hasLength(1));
      expect(persistence.upserts, hasLength(2));
    });

    test('上限裁剪：按缓存完成时间倒序只保留最新 N 行', () async {
      final persistence = _FakePersistence();
      final store = LocalCacheIndexStore(
        persistence: persistence,
        maxEntries: 2,
      );
      addTearDown(store.dispose);
      await store.init();

      await store.recordCompletedEntry(entry('1', cachedAt: 10));
      await store.recordCompletedEntry(entry('2', cachedAt: 20));
      await store.recordCompletedEntry(entry('3', cachedAt: 30));

      expect(store.entries.map((row) => row.songId), ['3', '2']);
      expect(persistence.rows.keys.toSet(), {'wy:2', 'wy:3'});
      expect(persistence.removals, [(sourceKey: 'wy', songId: '1')]);
    });

    test('按键移除：只删指定行并通知', () async {
      final persistence = _FakePersistence();
      final store = LocalCacheIndexStore(persistence: persistence);
      addTearDown(store.dispose);
      await store.init();
      await store.recordCompletedEntry(entry('1'));
      await store.recordCompletedEntry(entry('2'));
      var notifications = 0;
      store.changes.addListener(() => notifications++);

      await store.remove('wy', '1');

      expect(store.entries.map((row) => row.songId), ['2']);
      expect(persistence.rows.keys, ['wy:2']);
      expect(notifications, 1);

      await store.remove('wy', 'missing');
      expect(notifications, 1, reason: '不存在的键不通知、不写库');
    });

    test('初始化失败：保留已有行、按已尝试处理、不永久加载', () async {
      final persistence = _FakePersistence(rows: [entry('1')]);
      final store = LocalCacheIndexStore(persistence: persistence);
      addTearDown(store.dispose);
      await store.init();
      expect(store.entries, hasLength(1));

      persistence.failLoad = true;
      await store.init(force: true);

      expect(store.initialized, isTrue);
      expect(store.entries, hasLength(1), reason: '读取失败不能清空已有索引');
    });

    test('对账：只补缓存确认命中的候选，移除已无缓存文件的行', () async {
      final persistence = _FakePersistence(rows: [entry('old', cachedAt: 5)]);
      final store = LocalCacheIndexStore(persistence: persistence);
      addTearDown(store.dispose);
      await store.init();

      await store.reconcile(
        candidates: [entry('1', cachedAt: 10), entry('2', cachedAt: 20)],
        scanCache: () async => cacheFiles(['1']),
      );

      expect(store.entries.map((row) => row.songId), ['1']);
      expect(persistence.rows.keys, ['wy:1']);
      expect(persistence.removals, [(sourceKey: 'wy', songId: 'old')]);
    });

    test('候选为空：只清理已无缓存文件的行，保留仍命中的行', () async {
      final persistence = _FakePersistence(
        rows: [entry('keep', cachedAt: 10), entry('stale', cachedAt: 20)],
      );
      final store = LocalCacheIndexStore(persistence: persistence);
      addTearDown(store.dispose);
      await store.init();

      await store.reconcile(
        candidates: const [],
        scanCache: () async => cacheFiles(['keep']),
      );

      expect(store.entries.map((row) => row.songId), ['keep']);
      expect(persistence.rows.keys, ['wy:keep']);
      expect(persistence.removals, [(sourceKey: 'wy', songId: 'stale')]);
    });

    test('对账：目录列举失败完全不动索引', () async {
      final persistence = _FakePersistence(rows: [entry('old')]);
      final store = LocalCacheIndexStore(persistence: persistence);
      addTearDown(store.dispose);
      await store.init();
      final revision = store.revision;

      await store.reconcile(
        candidates: [entry('1')],
        scanCache: () async => null,
      );

      expect(store.entries.map((row) => row.songId), ['old']);
      expect(store.revision, revision);
      expect(persistence.upserts, isEmpty);
      expect(persistence.removals, isEmpty);
    });

    test('对账期间新完成的行不会被旧扫描结果删除', () async {
      final persistence = _FakePersistence(rows: [entry('old', cachedAt: 5)]);
      final store = LocalCacheIndexStore(persistence: persistence);
      addTearDown(store.dispose);
      await store.init();
      final scan = Completer<Map<String, int>?>();
      final reconcile = store.reconcile(
        candidates: const [],
        scanCache: () => scan.future,
      );

      // 扫描还没返回时完成一条新缓存：它不在旧扫描结果里，但绝不能被删。
      await store.recordCompleted(sourceTrack('fresh'));
      scan.complete(const {});
      await reconcile;

      expect(store.entries.map((row) => row.songId), ['fresh']);
      expect(persistence.rows.keys, ['wy:fresh']);
    });

    test('对账幂等：重复执行不重复写库、不重复通知', () async {
      final persistence = _FakePersistence();
      final store = LocalCacheIndexStore(persistence: persistence);
      addTearDown(store.dispose);
      await store.init();
      final candidates = [entry('1')];
      Future<Map<String, int>?> scan() async => cacheFiles(['1']);

      await store.reconcile(candidates: candidates, scanCache: scan);
      final revision = store.revision;
      final upserts = persistence.upserts.length;

      await store.reconcile(candidates: candidates, scanCache: scan);

      expect(store.entries, hasLength(1));
      expect(store.revision, revision);
      expect(persistence.upserts, hasLength(upserts));
    });

    test('并发完成事件串行落库，不丢行', () async {
      final persistence = _FakePersistence();
      final store = LocalCacheIndexStore(persistence: persistence);
      addTearDown(store.dispose);
      await store.init();

      await Future.wait([
        store.recordCompleted(sourceTrack('1')),
        store.recordCompleted(sourceTrack('2')),
        store.recordCompleted(sourceTrack('3')),
      ]);

      expect(store.entries, hasLength(3));
      expect(persistence.rows, hasLength(3));
    });
  });

  group('LocalCacheIndexRepository', () {
    test('写入 / 读取 / 删除与 raw 往返保真', () async {
      final db = openMemoryDatabase();
      addTearDown(db.close);
      final repository = LocalCacheIndexRepository(databaseProvider: () => db);

      await repository.upsertAll([
        entry('1', cachedAt: 10, title: '标题'),
        entry('2', cachedAt: 20),
      ]);
      final rows = await repository.loadAll();
      expect(rows.map((row) => row.songId), ['2', '1']);
      expect(rows.last.title, '标题');
      expect(rows.last.raw['songId'], '1');

      await repository.removeAll([(sourceKey: 'wy', songId: '1')]);
      final after = await repository.loadAll();
      expect(after.map((row) => row.songId), ['2']);
    });

    test('播放历史写入不产生索引行', () async {
      final db = openMemoryDatabase();
      addTearDown(db.close);
      final indexRepository = LocalCacheIndexRepository(
        databaseProvider: () => db,
      );
      final store = LocalCacheIndexStore(persistence: indexRepository);
      addTearDown(store.dispose);
      final library = LibraryRepository(
        databaseProvider: () => db,
        stamps: testStampIssuer(deviceId: 'devA'),
      );
      addTearDown(library.dispose);
      await store.init();

      await library.addHistoryEntry(
        PlayHistoryEntry(
          sourceKey: 'wy',
          songId: '1',
          title: 'Song 1',
          raw: const {'songId': '1'},
          playedAt: 1,
        ),
      );

      expect(store.entries, isEmpty);
      expect(await indexRepository.loadAll(), isEmpty);
    });

    test('清空 / 单条 / 批量 / 同步墓碑删除历史后索引与本地歌曲行保留', () async {
      final db = openMemoryDatabase();
      addTearDown(db.close);
      final indexRepository = LocalCacheIndexRepository(
        databaseProvider: () => db,
      );
      final store = LocalCacheIndexStore(persistence: indexRepository);
      addTearDown(store.dispose);
      final library = LibraryRepository(
        databaseProvider: () => db,
        stamps: testStampIssuer(deviceId: 'devA'),
      );
      addTearDown(library.dispose);
      await store.init();

      PlayHistoryEntry history(String id) => PlayHistoryEntry(
        sourceKey: 'wy',
        songId: id,
        title: 'Song $id',
        artist: 'Artist',
        album: 'Album',
        raw: {'songId': id},
        playedAt: 1,
      );

      for (final id in ['1', '2']) {
        await library.addHistoryEntry(history(id));
        await store.recordCompletedEntry(entry(id));
      }

      Future<void> expectIndexIntact() async {
        expect(
          (await indexRepository.loadAll()).map((row) => row.songId).toSet(),
          {'1', '2'},
        );
      }

      Future<void> expectLocalSongsIntact() async {
        final index = await indexRepository.loadAll();
        final collection = LocalSongsCollection(
          loadCachedAudioTrackIds: (tracks) async => {
            for (final track in tracks) track.id,
          },
        );
        addTearDown(collection.dispose);
        await collection.sync(
          LocalSongsInput(
            indexEntries: index,
            indexInitialized: true,
            downloads: const [],
            supported: true,
            initialized: true,
            recordsRevision: 0,
            cacheRevision: 0,
          ),
        );
        expect(collection.rows.map((row) => row.key).toSet(), {'wy:1', 'wy:2'});
      }

      await library.deleteHistoryEntry('wy', '1');
      await expectIndexIntact();
      await expectLocalSongsIntact();

      await library.deleteHistoryEntries([(sourceKey: 'wy', songId: '2')]);
      await expectIndexIntact();

      await library.addHistoryEntry(history('1'));
      await library.addHistoryEntry(history('2'));
      await library.syncApplyHistory(
        tombstones: [
          SyncTombstoneRecord(
            category: SyncCategory.history.name,
            key: SyncRecordKeys.history('wy', '1'),
            version: const SyncVersion(
              physical: 999,
              counter: 0,
              deviceId: 'devB',
            ),
            deletedAt: 999999,
          ),
        ],
      );
      await expectIndexIntact();
      expect(
        (await library.listHistory()).map((row) => row.songId),
        isNot(contains('1')),
      );

      await library.addHistoryEntry(history('1'));
      await library.addHistoryEntry(history('2'));
      await library.clearHistory();
      await expectIndexIntact();
      expect(await library.listHistory(), isEmpty);
      await expectLocalSongsIntact();
    });
  });
}
