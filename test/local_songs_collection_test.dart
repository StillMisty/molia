import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/models/library.dart';
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

/// 假资料库：历史条目与同下标的领域曲目。
class _FakeLibrary {
  _FakeLibrary(this.history, this.tracks);

  final List<PlayHistoryEntry> history;
  final List<Track> tracks;
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
  LocalSongsInput inputFor(
    _FakeLibrary library,
    _FakeDownloads downloads, {
    int recordsRevision = 0,
    int cacheRevision = 0,
  }) => LocalSongsInput(
    history: library.history,
    historyTracks: () => library.tracks,
    downloads: downloads.records,
    supported: downloads.supported,
    initialized: downloads.initialized,
    recordsRevision: recordsRevision,
    cacheRevision: cacheRevision,
  );

  PlayHistoryEntry historyOf(String id) => PlayHistoryEntry(
    sourceKey: 'wy',
    songId: id,
    title: 'Song $id',
    artist: 'Artist $id',
    raw: {'songId': id},
    playedAt: 1,
  );

  Track trackOf(String id) => Track(
    id: TrackId('wy', id),
    title: 'Song $id',
    origin: TrackOrigin.builtin,
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

  test('缓存命中：历史曲目命中完整音频缓存时进入本地歌曲行', () async {
    final library = _FakeLibrary([historyOf('1')], [trackOf('1')]);
    final localData = _FakeTrackLocalData(
      (tracks) async => {for (final track in tracks) track.id},
    );
    final collection = LocalSongsCollection(
      loadCachedAudioTrackIds: localData.cachedAudioTrackIds,
    );
    addTearDown(collection.dispose);

    await collection.sync(inputFor(library, _FakeDownloads()));

    expect(localData.requests, hasLength(1));
    expect(collection.rows, hasLength(1));
    expect(collection.rows.single.isCached, isTrue);
    expect(collection.rows.single.title, 'Song 1');
    expect(collection.count, 1);
    expect(collection.loading, isFalse);
  });

  test('下载优先：同一曲目有下载记录时不再列缓存行', () async {
    final library = _FakeLibrary([historyOf('1')], [trackOf('1')]);
    final downloads = _FakeDownloads(records: [downloadOf('1')]);
    final localData = _FakeTrackLocalData(
      (tracks) async => {for (final track in tracks) track.id},
    );
    final collection = LocalSongsCollection(
      loadCachedAudioTrackIds: localData.cachedAudioTrackIds,
    );
    addTearDown(collection.dispose);

    await collection.sync(inputFor(library, downloads));

    expect(collection.rows, hasLength(1), reason: '下载行 + 缓存行同名只留一行');
    expect(collection.rows.single.isCached, isFalse);
    expect(collection.rows.single.key, 'wy:1');
    expect(collection.rows.single.title, '下载 1');
  });

  test('下载优先：仅歌词记录（无音频文件）也抑制同曲缓存行', () async {
    final library = _FakeLibrary([historyOf('1')], [trackOf('1')]);
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

    await collection.sync(inputFor(library, downloads));

    // 记录没有音频（filePath == null）也按下载优先占位：缓存行不再重复出现。
    expect(downloads.records.single.hasAudio, isFalse);
    expect(collection.rows, hasLength(1));
    expect(collection.rows.single.isCached, isFalse);
    expect(collection.rows.single.key, 'wy:1');
    expect(collection.rows.single.title, '只有歌词');
  });

  test('下载能力不可用：不查缓存索引，行为空且不显示加载态', () async {
    final library = _FakeLibrary([historyOf('1')], [trackOf('1')]);
    final localData = _FakeTrackLocalData(
      (tracks) async => fail('能力不可用时不应查询缓存索引'),
    );
    final collection = LocalSongsCollection(
      loadCachedAudioTrackIds: localData.cachedAudioTrackIds,
    );
    addTearDown(collection.dispose);

    await collection.sync(
      inputFor(
        library,
        _FakeDownloads(records: [downloadOf('1')], supported: false),
      ),
    );

    expect(localData.requests, isEmpty);
    expect(collection.rows, isEmpty);
    expect(collection.count, 0);
    expect(collection.loading, isFalse);
  });

  test('下载记录未初始化：加载态优先于空态', () async {
    final collection = LocalSongsCollection(
      loadCachedAudioTrackIds: (tracks) async => const <TrackId>{},
    );
    addTearDown(collection.dispose);

    await collection.sync(
      inputFor(
        _FakeLibrary(const [], const []),
        _FakeDownloads(initialized: false),
      ),
    );

    expect(collection.rows, isEmpty);
    expect(collection.loading, isTrue);
  });

  test('缓存 revision 失效：同一历史 / 下载记录也会重算缓存行', () async {
    final library = _FakeLibrary([historyOf('1')], [trackOf('1')]);
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
      inputFor(library, downloads, cacheRevision: revision),
    );
    expect(collection.rows, hasLength(1));

    revision = 1;
    await collection.sync(
      inputFor(library, downloads, cacheRevision: revision),
    );

    expect(localData.requests, hasLength(2), reason: 'revision 变了要重算');
    expect(collection.rows, isEmpty);
    expect(collection.count, 0);
  });

  test('记录 revision 失效：记录键不变也会重算缓存行', () async {
    final library = _FakeLibrary([historyOf('1')], [trackOf('1')]);
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
      inputFor(library, downloads, recordsRevision: recordsRevision),
    );
    expect(collection.rows, hasLength(1));
    expect(collection.rows.single.isCached, isFalse);

    recordsRevision = 1;
    await collection.sync(
      inputFor(library, downloads, recordsRevision: recordsRevision),
    );

    expect(localData.requests, hasLength(2), reason: 'revision 变了要重算');
    expect(collection.rows.single.key, 'wy:1');
  });

  test('过期结果丢弃：旧输入晚到的缓存行不能覆盖新输入', () async {
    final libraryA = _FakeLibrary([historyOf('1')], [trackOf('1')]);
    final libraryB = _FakeLibrary([historyOf('2')], [trackOf('2')]);
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

    final loadA = collection.sync(inputFor(libraryA, _FakeDownloads()));
    final loadB = collection.sync(inputFor(libraryB, _FakeDownloads()));

    second.complete({trackOf('2').id});
    await loadB;
    expect(collection.rows.single.title, 'Song 2');
    expect(collection.loading, isFalse);

    // 旧输入这时才返回：令牌已变，必须整轮丢弃。
    first.complete({trackOf('1').id});
    await loadA;
    expect(collection.rows.single.title, 'Song 2');
    expect(collection.count, 1);
    expect(collection.loading, isFalse);
  });

  test('弹层计数不变量：计数 = 下载 / 导入记录 + 去重后的缓存行', () async {
    final library = _FakeLibrary(
      [historyOf('1'), historyOf('2')],
      [trackOf('1'), trackOf('2')],
    );
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

    await collection.sync(inputFor(library, downloads));

    // 下载 2 条（wy:1 / local:x）+ 缓存 1 条（wy:2；wy:1 被下载抑制）。
    expect(collection.rows, hasLength(3));
    expect(collection.count, collection.rows.length);
    expect(collection.rows.map((row) => row.key), ['wy:1', 'local:x', 'wy:2']);
  });

  test('签名相同：不重复列举缓存索引', () async {
    final library = _FakeLibrary([historyOf('1')], [trackOf('1')]);
    final downloads = _FakeDownloads();
    final localData = _FakeTrackLocalData((tracks) async => {tracks.single.id});
    final collection = LocalSongsCollection(
      loadCachedAudioTrackIds: localData.cachedAudioTrackIds,
    );
    addTearDown(collection.dispose);

    final input = inputFor(library, downloads);
    await collection.sync(input);
    await collection.sync(input);

    expect(localData.requests, hasLength(1));
  });

  group('行列表缓存', () {
    test('输入不变：rows 返回同一列表，count 与 rows 同源', () async {
      final library = _FakeLibrary([historyOf('1')], [trackOf('1')]);
      final downloads = _FakeDownloads(records: [downloadOf('1')]);
      final localData = _FakeTrackLocalData(
        (tracks) async => {for (final track in tracks) track.id},
      );
      final collection = LocalSongsCollection(
        loadCachedAudioTrackIds: localData.cachedAudioTrackIds,
      );
      addTearDown(collection.dispose);

      await collection.sync(inputFor(library, downloads));

      final first = collection.rows;
      final revision = collection.rowsRevision;
      expect(identical(collection.rows, first), isTrue);

      // 每帧都会构造新的 LocalSongsInput：对象换了但内容没变，仍复用。
      await collection.sync(inputFor(library, downloads));
      expect(identical(collection.rows, first), isTrue);
      expect(collection.rowsRevision, revision);
      expect(collection.count, first.length);
    });

    test('recordsRevision / 下载列表换引用：替换行列表', () async {
      final library = _FakeLibrary(const [], const []);
      final downloads = _FakeDownloads(records: [downloadOf('1')]);
      final localData = _FakeTrackLocalData(
        (tracks) async => const <TrackId>{},
      );
      final collection = LocalSongsCollection(
        loadCachedAudioTrackIds: localData.cachedAudioTrackIds,
      );
      addTearDown(collection.dispose);

      await collection.sync(inputFor(library, downloads));
      var previous = collection.rows;
      var revision = collection.rowsRevision;

      await collection.sync(
        inputFor(library, downloads, recordsRevision: 1),
      );
      var current = collection.rows;
      expect(identical(current, previous), isFalse, reason: 'revision 变要重算');
      expect(collection.rowsRevision, greaterThan(revision));

      // 记录键 / revision 都没变，但下载列表换了引用（标题 / 路径等快照
      // 替换不一定改 revision）：行列表同样要重算。
      previous = current;
      revision = collection.rowsRevision;
      await collection.sync(
        inputFor(
          library,
          _FakeDownloads(records: [downloadOf('1')]),
          recordsRevision: 1,
        ),
      );
      current = collection.rows;
      expect(identical(current, previous), isFalse);
      expect(collection.rowsRevision, greaterThan(revision));
      expect(collection.count, current.length);
    });

    test('历史列表换引用（键不变）：替换行列表', () async {
      final downloads = _FakeDownloads();
      final firstLibrary = _FakeLibrary([historyOf('1')], [trackOf('1')]);
      final secondLibrary = _FakeLibrary([historyOf('1')], [trackOf('1')]);
      final localData = _FakeTrackLocalData(
        (tracks) async => {for (final track in tracks) track.id},
      );
      final collection = LocalSongsCollection(
        loadCachedAudioTrackIds: localData.cachedAudioTrackIds,
      );
      addTearDown(collection.dispose);

      await collection.sync(inputFor(firstLibrary, downloads));
      final first = collection.rows;
      final revision = collection.rowsRevision;

      await collection.sync(inputFor(secondLibrary, downloads));
      final second = collection.rows;
      expect(identical(second, first), isFalse);
      expect(collection.rowsRevision, greaterThan(revision));
      expect(
        second.map((row) => row.key),
        first.map((row) => row.key),
        reason: '键一样，但历史列表是新引用，行列表不能复用',
      );
    });

    test('缓存行异步落定：替换行列表', () async {
      final library = _FakeLibrary([historyOf('1')], [trackOf('1')]);
      final completer = Completer<Set<TrackId>>();
      final localData = _FakeTrackLocalData((_) => completer.future);
      final collection = LocalSongsCollection(
        loadCachedAudioTrackIds: localData.cachedAudioTrackIds,
      );
      addTearDown(collection.dispose);

      final load = collection.sync(inputFor(library, _FakeDownloads()));
      final before = collection.rows;
      final revision = collection.rowsRevision;
      expect(before, isEmpty, reason: '缓存索引还在途');

      completer.complete({trackOf('1').id});
      await load;

      final after = collection.rows;
      expect(identical(after, before), isFalse);
      expect(after.single.title, 'Song 1');
      expect(collection.rowsRevision, greaterThan(revision));
      expect(collection.count, after.length);
    });
  });
}
