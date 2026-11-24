import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/models/local_cache_index.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/local_songs_collection.dart';

/// 假下载服务：只提供本地歌曲合集消费的三项（能力 / 初始化 / 记录）。
class _FakeDownloads {
  _FakeDownloads({
    this.records = const [],
    this.supported = true,
    this.initialized = true,
  });

  final List<DownloadedTrack> records;
  final bool supported;
  final bool initialized;
}

/// 假本地数据服务：缓存索引查询由测试逐轮给结果 / Completer。
class _FakeTrackLocalData {
  _FakeTrackLocalData(this.lookup);

  final Future<Set<TrackId>> Function(List<Track> tracks) lookup;
  final List<List<Track>> requests = [];

  Future<Set<TrackId>> cachedAudioTrackIds(List<Track> tracks) {
    requests.add(tracks);
    return lookup(tracks);
  }
}

void main() {
  LocalCacheIndexEntry indexOf(
    String id, {
    int cachedAt = 1,
    String? title,
    String sourceKey = 'wy',
  }) => LocalCacheIndexEntry(
    sourceKey: sourceKey,
    songId: id,
    title: title ?? 'Song $id',
    artist: 'Artist $id',
    raw: {'songId': id},
    cachedAt: cachedAt,
  );

  LocalSongsInput inputFor(
    _FakeDownloads downloads, {
    List<LocalCacheIndexEntry> index = const [],
    bool indexInitialized = true,
    int indexRevision = 0,
    int recordsRevision = 0,
    int cacheRevision = 0,
  }) => LocalSongsInput(
    indexEntries: index,
    indexInitialized: indexInitialized,
    downloads: downloads.records,
    supported: downloads.supported,
    initialized: downloads.initialized,
    recordsRevision: recordsRevision,
    indexRevision: indexRevision,
    cacheRevision: cacheRevision,
  );

  DownloadedTrack downloadOf(String id, {bool imported = false}) =>
      DownloadedTrack(
        originSourceKey: imported ? kLocalSourceKey : 'wy',
        originSongId: id,
        title: imported ? '导入 $id' : '下载 $id',
        filePath: '/downloads/$id.mp3',
        imported: imported,
        downloadedAt: 1,
      );

  test('索引为空：历史非空也不产生缓存行', () async {
    // 历史只属于「播放历史」合集；本地歌曲输入里没有它。
    final localData = _FakeTrackLocalData(
      (tracks) async => {for (final track in tracks) track.id},
    );
    final collection = LocalSongsCollection(
      loadCachedAudioTrackIds: localData.cachedAudioTrackIds,
    );
    addTearDown(collection.dispose);

    await collection.sync(inputFor(_FakeDownloads()));

    expect(localData.requests, isEmpty);
    expect(collection.rows, isEmpty);
    expect(collection.count, 0);
    expect(collection.loading, isFalse);
  });

  test('行列表是零拷贝只读视图：重复读取保持同一引用', () async {
    final localData = _FakeTrackLocalData(
      (tracks) async => {for (final track in tracks) track.id},
    );
    final collection = LocalSongsCollection(
      loadCachedAudioTrackIds: localData.cachedAudioTrackIds,
    );
    addTearDown(collection.dispose);

    await collection.sync(inputFor(_FakeDownloads()));

    final rows = collection.rows;
    expect(identical(rows, collection.rows), isTrue);
    expect(rows.clear, throwsUnsupportedError);
  });

  test('索引行命中完整音频缓存时进入本地歌曲行', () async {
    final localData = _FakeTrackLocalData(
      (tracks) async => {for (final track in tracks) track.id},
    );
    final collection = LocalSongsCollection(
      loadCachedAudioTrackIds: localData.cachedAudioTrackIds,
    );
    addTearDown(collection.dispose);

    await collection.sync(
      inputFor(_FakeDownloads(), index: [indexOf('1', title: '缓存标题')]),
    );

    expect(localData.requests, hasLength(1));
    expect(localData.requests.single.single.title, '缓存标题');
    expect(collection.rows, hasLength(1));
    expect(collection.rows.single.isCached, isTrue);
    expect(collection.rows.single.title, '缓存标题');
    expect(collection.rows.single.favoriteKey, (sourceKey: 'wy', songId: '1'));
    expect(collection.count, 1);
    expect(collection.loading, isFalse);
  });

  test('索引行缓存未命中：不产生行', () async {
    final localData = _FakeTrackLocalData((_) async => const <TrackId>{});
    final collection = LocalSongsCollection(
      loadCachedAudioTrackIds: localData.cachedAudioTrackIds,
    );
    addTearDown(collection.dispose);

    await collection.sync(inputFor(_FakeDownloads(), index: [indexOf('1')]));

    expect(localData.requests, hasLength(1));
    expect(collection.rows, isEmpty);
    expect(collection.loading, isFalse);
  });

  test('下载优先：同一曲目有下载记录时不再列缓存行', () async {
    final downloads = _FakeDownloads(records: [downloadOf('1')]);
    final localData = _FakeTrackLocalData(
      (tracks) async => {for (final track in tracks) track.id},
    );
    final collection = LocalSongsCollection(
      loadCachedAudioTrackIds: localData.cachedAudioTrackIds,
    );
    addTearDown(collection.dispose);

    await collection.sync(inputFor(downloads, index: [indexOf('1')]));

    expect(collection.rows, hasLength(1), reason: '下载行 + 缓存行同名只留一行');
    expect(collection.rows.single.isCached, isFalse);
    expect(collection.rows.single.key, 'wy:1');
    expect(collection.rows.single.title, '下载 1');
  });

  test('下载优先：仅歌词记录（无音频文件）也抑制同曲缓存行', () async {
    final downloads = _FakeDownloads(
      records: [
        const DownloadedTrack(
          originSourceKey: 'wy',
          originSongId: '1',
          title: '只有歌词',
          lyricPath: '/downloads/1.lrc',
          downloadedAt: 1,
        ),
      ],
    );
    final localData = _FakeTrackLocalData(
      (tracks) async => {for (final track in tracks) track.id},
    );
    final collection = LocalSongsCollection(
      loadCachedAudioTrackIds: localData.cachedAudioTrackIds,
    );
    addTearDown(collection.dispose);

    await collection.sync(inputFor(downloads, index: [indexOf('1')]));

    expect(downloads.records.single.hasAudio, isFalse);
    expect(collection.rows, hasLength(1));
    expect(collection.rows.single.isCached, isFalse);
    expect(collection.rows.single.key, 'wy:1');
    expect(collection.rows.single.title, '只有歌词');
  });

  test('重复键去重：索引快照重复也只产生一行', () async {
    final localData = _FakeTrackLocalData(
      (tracks) async => {for (final track in tracks) track.id},
    );
    final collection = LocalSongsCollection(
      loadCachedAudioTrackIds: localData.cachedAudioTrackIds,
    );
    addTearDown(collection.dispose);

    await collection.sync(
      inputFor(
        _FakeDownloads(),
        index: [
          indexOf('1', cachedAt: 2, title: '新快照'),
          indexOf('1'),
        ],
      ),
    );

    expect(collection.rows, hasLength(1));
    expect(collection.rows.single.title, '新快照');
  });

  test('下载能力不可用：不查缓存索引，行为空且不显示加载态', () async {
    final localData = _FakeTrackLocalData((_) async => fail('能力不可用时不应查询缓存索引'));
    final collection = LocalSongsCollection(
      loadCachedAudioTrackIds: localData.cachedAudioTrackIds,
    );
    addTearDown(collection.dispose);

    await collection.sync(
      inputFor(
        _FakeDownloads(records: [downloadOf('1')], supported: false),
        index: [indexOf('1')],
      ),
    );

    expect(localData.requests, isEmpty);
    expect(collection.rows, isEmpty);
    expect(collection.count, 0);
    expect(collection.loading, isFalse);
  });

  test('下载记录未初始化：加载态优先于空态', () async {
    final collection = LocalSongsCollection(
      loadCachedAudioTrackIds: (_) async => const <TrackId>{},
    );
    addTearDown(collection.dispose);

    await collection.sync(inputFor(_FakeDownloads(initialized: false)));

    expect(collection.rows, isEmpty);
    expect(collection.loading, isTrue);
  });

  test('缓存索引未初始化：首次进入显示加载态，避免空态闪烁', () async {
    final collection = LocalSongsCollection(
      loadCachedAudioTrackIds: (_) async => const <TrackId>{},
    );
    addTearDown(collection.dispose);

    await collection.sync(inputFor(_FakeDownloads(), indexInitialized: false));

    expect(collection.rows, isEmpty);
    expect(collection.loading, isTrue);
  });

  test('索引读取失败：下载 / 导入行仍显示，不回到加载态', () async {
    final downloads = _FakeDownloads(records: [downloadOf('1')]);
    final collection = LocalSongsCollection(
      loadCachedAudioTrackIds: (_) async =>
          throw StateError('cache read failed'),
    );
    addTearDown(collection.dispose);

    await collection.sync(inputFor(downloads, index: [indexOf('2')]));

    expect(collection.rows, hasLength(1));
    expect(collection.rows.single.key, 'wy:1');
    expect(collection.loading, isFalse);
  });

  test('缓存 revision 失效：同一索引 / 下载记录也会重算缓存行', () async {
    final downloads = _FakeDownloads();
    var revision = 0;
    final localData = _FakeTrackLocalData(
      (tracks) async => revision == 0 ? {tracks.single.id} : const <TrackId>{},
    );
    final collection = LocalSongsCollection(
      loadCachedAudioTrackIds: localData.cachedAudioTrackIds,
    );
    addTearDown(collection.dispose);

    await collection.sync(
      inputFor(downloads, index: [indexOf('1')], cacheRevision: revision),
    );
    expect(collection.rows, hasLength(1));

    revision = 1;
    await collection.sync(
      inputFor(downloads, index: [indexOf('1')], cacheRevision: revision),
    );

    expect(localData.requests, hasLength(2), reason: 'revision 变了要重算');
    expect(collection.rows, isEmpty);
    expect(collection.count, 0);
  });

  test('记录 revision 失效：记录键不变也会重算缓存行', () async {
    final downloads = _FakeDownloads(records: [downloadOf('1')]);
    var recordsRevision = 0;
    final localData = _FakeTrackLocalData(
      (tracks) async => {for (final track in tracks) track.id},
    );
    final collection = LocalSongsCollection(
      loadCachedAudioTrackIds: localData.cachedAudioTrackIds,
    );
    addTearDown(collection.dispose);

    await collection.sync(
      inputFor(
        downloads,
        index: [indexOf('1')],
        recordsRevision: recordsRevision,
      ),
    );
    expect(collection.rows, hasLength(1));
    expect(collection.rows.single.isCached, isFalse);

    recordsRevision = 1;
    await collection.sync(
      inputFor(
        downloads,
        index: [indexOf('1')],
        recordsRevision: recordsRevision,
      ),
    );

    expect(localData.requests, hasLength(2), reason: 'revision 变了要重算');
    expect(collection.rows.single.key, 'wy:1');
  });

  test('索引 revision 失效：同键换元数据快照也会重算行', () async {
    var revision = 0;
    final localData = _FakeTrackLocalData(
      (tracks) async => {for (final track in tracks) track.id},
    );
    final collection = LocalSongsCollection(
      loadCachedAudioTrackIds: localData.cachedAudioTrackIds,
    );
    addTearDown(collection.dispose);

    await collection.sync(
      inputFor(
        _FakeDownloads(),
        index: [indexOf('1', title: '旧标题')],
        indexRevision: revision,
      ),
    );
    expect(collection.rows.single.title, '旧标题');

    revision = 1;
    await collection.sync(
      inputFor(
        _FakeDownloads(),
        index: [indexOf('1', title: '新标题')],
        indexRevision: revision,
      ),
    );

    expect(localData.requests, hasLength(2));
    expect(collection.rows.single.title, '新标题');
  });

  test('过期结果丢弃：旧输入晚到的缓存行不能覆盖新输入', () async {
    final first = Completer<Set<TrackId>>();
    final second = Completer<Set<TrackId>>();
    final pending = <Completer<Set<TrackId>>>[first, second];
    final localData = _FakeTrackLocalData(
      (tracks) => pending.removeAt(0).future,
    );
    final collection = LocalSongsCollection(
      loadCachedAudioTrackIds: localData.cachedAudioTrackIds,
    );
    addTearDown(collection.dispose);

    final loadA = collection.sync(
      inputFor(_FakeDownloads(), index: [indexOf('1')]),
    );
    final loadB = collection.sync(
      inputFor(_FakeDownloads(), index: [indexOf('2')]),
    );

    second.complete({const TrackId('wy', '2')});
    await loadB;
    expect(collection.rows.single.title, 'Song 2');
    expect(collection.loading, isFalse);

    // 旧输入这时才返回：令牌已变，必须整轮丢弃。
    first.complete({const TrackId('wy', '1')});
    await loadA;
    expect(collection.rows.single.title, 'Song 2');
    expect(collection.count, 1);
    expect(collection.loading, isFalse);
  });

  test('弹层计数不变量：计数 = 下载 / 导入记录 + 去重后的缓存行', () async {
    final downloads = _FakeDownloads(
      records: [downloadOf('1'), downloadOf('x', imported: true)],
    );
    final localData = _FakeTrackLocalData(
      (tracks) async => {for (final track in tracks) track.id},
    );
    final collection = LocalSongsCollection(
      loadCachedAudioTrackIds: localData.cachedAudioTrackIds,
    );
    addTearDown(collection.dispose);

    await collection.sync(
      inputFor(downloads, index: [indexOf('1'), indexOf('2')]),
    );

    // 下载 2 条（wy:1 / local:x）+ 缓存 1 条（wy:2；wy:1 被下载抑制）。
    expect(collection.rows, hasLength(3));
    expect(collection.count, collection.rows.length);
    expect(collection.rows.map((row) => row.key), ['wy:1', 'local:x', 'wy:2']);
  });

  test('签名相同：不重复列举缓存索引', () async {
    final localData = _FakeTrackLocalData(
      (tracks) async => {for (final track in tracks) track.id},
    );
    final collection = LocalSongsCollection(
      loadCachedAudioTrackIds: localData.cachedAudioTrackIds,
    );
    addTearDown(collection.dispose);

    final input = inputFor(_FakeDownloads(), index: [indexOf('1')]);
    await collection.sync(input);
    await collection.sync(input);

    expect(localData.requests, hasLength(1));
  });

  test('快照暴露行 / 计数 / 加载态，异步落定后通知 changes', () async {
    final completer = Completer<Set<TrackId>>();
    final collection = LocalSongsCollection(
      loadCachedAudioTrackIds: (_) => completer.future,
    );
    addTearDown(collection.dispose);
    var notifications = 0;
    collection.changes.addListener(() => notifications++);

    final load = collection.sync(
      inputFor(_FakeDownloads(), index: [indexOf('1')]),
    );

    expect(collection.state.rows, isEmpty);
    expect(collection.state.count, 0);
    expect(collection.state.loading, isTrue, reason: '缓存索引还在途');
    expect(collection.state.rowsRevision, collection.rowsRevision);

    completer.complete({const TrackId('wy', '1')});
    await load;

    expect(notifications, 1);
    expect(collection.state.rows.single.title, 'Song 1');
    expect(collection.state.count, 1);
    expect(collection.state.loading, isFalse);
    expect(collection.state.rowsRevision, collection.rowsRevision);
  });

  group('行列表缓存', () {
    test('输入不变：rows 返回同一列表，count 与 rows 同源', () async {
      final downloads = _FakeDownloads(records: [downloadOf('1')]);
      final index = [indexOf('2')];
      final localData = _FakeTrackLocalData(
        (tracks) async => {for (final track in tracks) track.id},
      );
      final collection = LocalSongsCollection(
        loadCachedAudioTrackIds: localData.cachedAudioTrackIds,
      );
      addTearDown(collection.dispose);

      await collection.sync(inputFor(downloads, index: index));

      final first = collection.rows;
      final revision = collection.rowsRevision;
      expect(identical(collection.rows, first), isTrue);

      // 每帧都会构造新的 LocalSongsInput：对象换了但内容没变，仍复用。
      await collection.sync(inputFor(downloads, index: index));
      expect(identical(collection.rows, first), isTrue);
      expect(collection.rowsRevision, revision);
      expect(collection.count, first.length);
    });

    test('recordsRevision / 下载列表换引用：替换行列表', () async {
      final downloads = _FakeDownloads(records: [downloadOf('1')]);
      final localData = _FakeTrackLocalData((_) async => const <TrackId>{});
      final collection = LocalSongsCollection(
        loadCachedAudioTrackIds: localData.cachedAudioTrackIds,
      );
      addTearDown(collection.dispose);

      await collection.sync(inputFor(downloads));
      var previous = collection.rows;
      var revision = collection.rowsRevision;

      await collection.sync(inputFor(downloads, recordsRevision: 1));
      var current = collection.rows;
      expect(identical(current, previous), isFalse, reason: 'revision 变要重算');
      expect(collection.rowsRevision, greaterThan(revision));

      // 记录键 / revision 都没变，但下载列表换了引用（标题 / 路径等快照
      // 替换不一定改 revision）：行列表同样要重算。
      previous = current;
      revision = collection.rowsRevision;
      await collection.sync(
        inputFor(
          _FakeDownloads(records: [downloadOf('1')]),
          recordsRevision: 1,
        ),
      );
      current = collection.rows;
      expect(identical(current, previous), isFalse);
      expect(collection.rowsRevision, greaterThan(revision));
      expect(collection.count, current.length);
    });

    test('索引列表换引用（键不变）：替换行列表', () async {
      final localData = _FakeTrackLocalData(
        (tracks) async => {for (final track in tracks) track.id},
      );
      final collection = LocalSongsCollection(
        loadCachedAudioTrackIds: localData.cachedAudioTrackIds,
      );
      addTearDown(collection.dispose);

      await collection.sync(inputFor(_FakeDownloads(), index: [indexOf('1')]));
      final first = collection.rows;
      final revision = collection.rowsRevision;

      await collection.sync(inputFor(_FakeDownloads(), index: [indexOf('1')]));
      final second = collection.rows;
      expect(identical(second, first), isFalse);
      expect(collection.rowsRevision, greaterThan(revision));
      expect(
        second.map((row) => row.key),
        first.map((row) => row.key),
        reason: '键一样，但索引列表是新引用，行列表不能复用',
      );
    });

    test('缓存行异步落定：替换行列表', () async {
      final completer = Completer<Set<TrackId>>();
      final localData = _FakeTrackLocalData((_) => completer.future);
      final collection = LocalSongsCollection(
        loadCachedAudioTrackIds: localData.cachedAudioTrackIds,
      );
      addTearDown(collection.dispose);

      final load = collection.sync(
        inputFor(_FakeDownloads(), index: [indexOf('1')]),
      );
      final before = collection.rows;
      final revision = collection.rowsRevision;
      expect(before, isEmpty, reason: '缓存索引还在途');

      completer.complete({const TrackId('wy', '1')});
      await load;

      final after = collection.rows;
      expect(identical(after, before), isFalse);
      expect(after.single.title, 'Song 1');
      expect(collection.rowsRevision, greaterThan(revision));
      expect(collection.count, after.length);
    });
  });
}
