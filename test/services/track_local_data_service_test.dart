import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/data/mapping/track_mapper.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/music_source.dart';
import 'package:molia/managers/artwork_cache.dart';
import 'package:molia/services/audio_cache_store.dart';
import 'package:molia/services/cache_service.dart';
import 'package:molia/services/cache_storage_io.dart';

import '../support/memory_cache_storage.dart';

import 'package:molia/services/download/download_records.dart';
import 'package:molia/services/track_local_data_service.dart';
import 'package:molia/sources/source_track.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_music_source.dart';

/// 可解析的假音源：用于把取链缓存灌进 CatalogService。
class _ResolvableSource extends FakeMusicSource {
  _ResolvableSource(super.key);

  @override
  Future<PlayableStream> resolve(
    Track track, {
    AudioQuality? preferredQuality,
  }) async => PlayableStream(Uri.parse('https://cdn.example/${track.id.id}'));
}

/// 假封面缓存：只记录「有哪些 URL 被命中/删除」，不碰 flutter_cache_manager。
class _FakeArtworkCache extends ArtworkCache {
  _FakeArtworkCache()
    : super(cacheService: CacheService(storage: MemoryCacheStorage()));

  final Map<String, int> files = {};
  final List<String> removed = [];

  @override
  Future<CacheUsage> usageOf(String url) async => files.containsKey(url)
      ? CacheUsage(bytes: files[url]!, count: 1)
      : CacheUsage.zero;

  @override
  Future<bool> remove(String url) async {
    removed.add(url);
    return files.remove(url) != null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late SharedPreferences prefs;
  late CacheService cacheService;
  late _FakeArtworkCache artworkCache;
  late DownloadRecords downloadRecords;
  late _ResolvableSource source;
  late CatalogService catalogService;
  late TrackLocalDataService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    tempRoot = await Directory.systemTemp.createTemp('track_local_data_test_');
    cacheService = CacheService(
      prefs: prefs,
      storage: IoCacheStorage(
        audioDirOverride: '${tempRoot.path}/audio_cache',
        artworkDirOverride: '${tempRoot.path}/artwork_cache',
      ),
      audioProtectAge: Duration.zero, // 测试文件视为“非活动”
    );
    artworkCache = _FakeArtworkCache();
    downloadRecords = DownloadRecords();
    source = _ResolvableSource('kw');
    catalogService = CatalogService(
      registry: FakeSourceRegistry({'kw': source}),
    );
    service = TrackLocalDataService(
      cacheService: cacheService,
      artworkCache: artworkCache,
      catalogService: catalogService,
      downloadRecords: downloadRecords,
    );
  });

  tearDown(() async {
    downloadRecords.dispose();
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  Track track({String id = 'a'}) => Track(
    id: TrackId('kw', id),
    title: 'Title $id',
    origin: TrackOrigin.lx,
    artwork: Artwork(
      uri: Uri.parse('https://cdn.example/$id.jpg'),
      fallbacks: [Uri.parse('https://cdn.example/$id-fallback.jpg')],
    ),
    qualities: const [
      AudioQuality(type: '320k'),
      AudioQuality(type: 'flac'),
    ],
    payload: {'id': id},
  );

  Future<void> writeAudio(String name, int size) async {
    final file = File('${tempRoot.path}/audio_cache/$name');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List<int>.filled(size, 0));
  }

  test('load：下载记录 + 四项占用一次读出（音频多音质合并）', () async {
    final t = track();
    await writeAudio(
      AudioCacheStore.key(sourceKey: 'kw', songId: 'a', quality: '320k'),
      100,
    );
    await writeAudio(
      AudioCacheStore.key(sourceKey: 'kw', songId: 'a', quality: 'flac'),
      200,
    );
    await prefs.setString(
      '${CacheService.lyricsCacheKeyPrefix}kw:a',
      '{"provider":"qq","lyric":"x","timestamp":1}',
    );
    artworkCache.files['https://cdn.example/a.jpg'] = 300;
    await catalogService.resolve(t, quality: const AudioQuality(type: '320k'));
    await catalogService.resolve(t);

    final data = await service.load(t);
    expect(data.audioCache, const CacheUsage(bytes: 300, count: 2));
    expect(data.lyricsCache.count, 1);
    expect(data.artworkCache, const CacheUsage(bytes: 300, count: 1));
    expect(data.resolveEntries, 2);
    // 命中缓存的音质（音质列表标记 / 预选）。
    expect(data.cachedQualities, ['320k', 'flac']);
  });

  test('loadMany：一次列举批量出状态，半成品计入写入中不入缓存', () async {
    final a = track();
    final b = track(id: 'b');
    await writeAudio(
      AudioCacheStore.key(sourceKey: 'kw', songId: 'a', quality: '320k'),
      100,
    );
    await writeAudio(
      '${AudioCacheStore.key(sourceKey: 'kw', songId: 'a', quality: '320k')}'
      '$audioCachePartSuffix',
      50,
    );

    final data = await service.loadMany([a, b]);

    expect(data['kw:a']!.audioState, LocalPartState.cached);
    expect(data['kw:a']!.audioCache, const CacheUsage(bytes: 100, count: 1));
    expect(data['kw:a']!.audioWriting.count, 1);
    expect(data['kw:a']!.cachedQualities, ['320k']);
    expect(data['kw:b']!.audioState, LocalPartState.none);
  });

  test('loadMany：下载记录附着为 downloaded 口径；空表不触存储', () async {
    final a = track();
    downloadRecords.replaceAll([
      DownloadedTrack(
        originSourceKey: 'kw',
        originSongId: 'a',
        title: a.title,
        artist: 'Artist',
        album: '',
        filePath: '/downloads/Title a.mp3',
        downloadedAt: 1,
      ),
    ]);

    final data = await service.loadMany([a]);

    expect(data['kw:a']!.audioState, LocalPartState.downloaded);
    expect(await service.loadMany(const []), isEmpty);
  });

  test('cachedAudioTrackIds：只认完整音频缓存；已有音频下载的曲目不算', () async {
    final a = track();
    final b = track(id: 'b');
    await writeAudio(
      AudioCacheStore.key(sourceKey: 'kw', songId: 'a', quality: '320k'),
      100,
    );
    // 半成品（.part）不是可播放缓存，不算命中。
    await writeAudio(
      '${AudioCacheStore.key(sourceKey: 'kw', songId: 'a', quality: '320k')}'
      '$audioCachePartSuffix',
      50,
    );
    expect(await service.cachedAudioTrackIds([a, b]), {
      const TrackId('kw', 'a'),
    });

    // 有音频下载就归下载档（下载优先）：缓存文件还在也不算「已缓存」。
    downloadRecords.replaceAll([
      DownloadedTrack(
        originSourceKey: 'kw',
        originSongId: 'a',
        title: a.title,
        artist: 'Artist',
        album: '',
        filePath: '/downloads/Title a.mp3',
        downloadedAt: 1,
      ),
    ]);
    expect(
      await service.cachedAudioTrackIds([a, b]),
      isEmpty,
      reason: '下载优先：下载行的曲目不进缓存行',
    );
    expect(await service.cachedAudioTrackIds(const []), isEmpty);
  });

  test('两档状态：无 → 已缓存 → 已下载（下载 > 缓存）', () async {
    final t = track();
    expect((await service.load(t)).audioState, LocalPartState.none);

    await writeAudio(
      AudioCacheStore.key(sourceKey: 'kw', songId: 'a', quality: '320k'),
      100,
    );
    expect((await service.load(t)).audioState, LocalPartState.cached);

    downloadRecords.replaceAll([
      DownloadedTrack(
        originSourceKey: 'kw',
        originSongId: 'a',
        title: t.title,
        artist: 'Artist',
        album: '',
        filePath: '/downloads/Title a.mp3',
        quality: '320k',
        sizeBytes: 1024,
        downloadedAt: 1,
      ),
    ]);
    final data = await service.load(t);
    expect(data.audioState, LocalPartState.downloaded);
    expect(data.hasAudioDownload, isTrue);
  });

  test('lyrics / artwork 分项状态：缓存与下载分别成立', () async {
    final t = track();
    await prefs.setString(
      '${CacheService.lyricsCacheKeyPrefix}kw:a',
      '{"provider":"qq","lyric":"x","timestamp":1}',
    );
    artworkCache.files['https://cdn.example/a-fallback.jpg'] = 120;

    final cached = await service.load(t);
    expect(cached.lyricsState, LocalPartState.cached);
    expect(cached.artworkState, LocalPartState.cached);
    expect(cached.audioState, LocalPartState.none);

    downloadRecords.replaceAll([
      DownloadedTrack(
        originSourceKey: 'kw',
        originSongId: 'a',
        title: t.title,
        artist: 'Artist',
        album: '',
        lyricPath: '/downloads/lyrics/Title a.lrc',
        coverPath: '/downloads/covers/Title a.jpg',
        downloadedAt: 1,
      ),
    ]);
    final downloaded = await service.load(t);
    expect(downloaded.lyricsState, LocalPartState.downloaded);
    expect(downloaded.artworkState, LocalPartState.downloaded);
  });

  test('downloadState：同步种子只带下载档，缓存占用为零', () {
    final t = track();
    downloadRecords.replaceAll([
      DownloadedTrack(
        originSourceKey: 'kw',
        originSongId: 'a',
        title: t.title,
        artist: 'Artist',
        album: '',
        filePath: '/downloads/Title a.mp3',
        sizeBytes: 2048,
        downloadedAt: 1,
      ),
    ]);
    final seed = service.downloadState(t);
    expect(seed.audioState, LocalPartState.downloaded);
    expect(seed.audioCache, CacheUsage.zero);
  });

  test('clear audio：删除全部音质变体并返回释放量', () async {
    final t = track();
    final key320 = AudioCacheStore.keyForTrack(t, quality: '320k');
    final keyFlac = AudioCacheStore.keyForTrack(t, quality: 'flac');
    await writeAudio(key320, 100);
    await writeAudio(keyFlac, 200);

    final result = await service.clear(t, LocalCachePart.audio);
    expect(result.part, LocalCachePart.audio);
    expect(result.cleared, isTrue);
    expect(result.freed, const CacheUsage(bytes: 300, count: 2));
    expect(result.skipped, 0);
    expect(File('${tempRoot.path}/audio_cache/$key320').existsSync(), isFalse);
    expect(File('${tempRoot.path}/audio_cache/$keyFlac').existsSync(), isFalse);
    expect((await service.load(t)).audioCache, CacheUsage.zero);
  });

  test('clear audio：正在写入（protectAge 内）→ skipped 且未清掉', () async {
    final guarded = TrackLocalDataService(
      cacheService: CacheService(
        prefs: prefs,
        storage: IoCacheStorage(
          audioDirOverride: '${tempRoot.path}/audio_cache',
          artworkDirOverride: '${tempRoot.path}/artwork_cache',
        ),
        audioProtectAge: const Duration(hours: 1),
      ),
      artworkCache: artworkCache,
      catalogService: catalogService,
    );
    final t = track();
    await writeAudio(AudioCacheStore.keyForTrack(t, quality: '320k'), 100);

    final result = await guarded.clear(t, LocalCachePart.audio);
    expect(result.cleared, isFalse);
    expect(result.skipped, 1);
  });

  test('clear lyrics / artwork / resolve：各自释放量与状态正确', () async {
    final t = track();
    await prefs.setString(
      '${CacheService.lyricsCacheKeyPrefix}kw:a',
      '{"provider":"qq","lyric":"x","timestamp":1}',
    );
    artworkCache.files['https://cdn.example/a.jpg'] = 300;
    artworkCache.files['https://cdn.example/a-fallback.jpg'] = 120;
    await catalogService.resolve(t, quality: const AudioQuality(type: '320k'));
    await catalogService.resolve(t, quality: const AudioQuality(type: '128k'));

    final lyrics = await service.clear(t, LocalCachePart.lyrics);
    expect(lyrics.cleared, isTrue);
    expect(lyrics.freed.count, 1);
    expect(prefs.getString('${CacheService.lyricsCacheKeyPrefix}kw:a'), isNull);

    final artwork = await service.clear(t, LocalCachePart.artwork);
    expect(artwork.cleared, isTrue);
    expect(artwork.freed, const CacheUsage(bytes: 420, count: 2));
    expect(
      artworkCache.removed,
      containsAll([
        'https://cdn.example/a.jpg',
        'https://cdn.example/a-fallback.jpg',
      ]),
    );

    final resolve = await service.clear(t, LocalCachePart.resolveUrl);
    expect(resolve.part, LocalCachePart.resolveUrl);
    expect(resolve.freed.count, 2);
    expect(catalogService.resolveCacheCountForTrack(t), 0);

    // 清完后再查：四项全空。
    expect((await service.load(t)).hasAnyCache, isFalse);
  });

  test('音频缓存写入侧 key 与读取侧同源（复合曲目 id 回归）', () async {
    // 播放侧只拿得到 SourceTrack；页面侧只有领域 Track。两边必须落在同一文件名上。
    final sourceTrack = SourceTrack(
      sourceKey: 'kw',
      origin: 'builtin',
      title: 'Song',
      artist: 'Singer',
      album: 'Album',
      qualities: const [SourceQuality(type: '320k')],
      raw: const {'songmid': 'a'},
    );
    final t = trackFromSourceTrack(sourceTrack);

    final written = AudioCacheStore.keyForSource(sourceTrack, quality: '320k');
    await writeAudio(written, 1234);

    expect(AudioCacheStore.keyForTrack(t, quality: '320k'), written);
    final data = await service.load(t);
    expect(data.audioCache, const CacheUsage(bytes: 1234, count: 1));
    expect(data.audioState, LocalPartState.cached);
  });

  test('无封面 / 无缓存：占用为零，清理不报错', () async {
    final noArtwork = Track(
      id: const TrackId('kw', 'plain'),
      title: 'plain',
      origin: TrackOrigin.lx,
      payload: const {'id': 'plain'},
    );
    final data = await service.load(noArtwork);
    expect(data.hasAnyCache, isFalse);
    expect(data.cachedQualities, isEmpty);
    for (final part in LocalCachePart.values) {
      final result = await service.clear(noArtwork, part);
      expect(result.cleared, isFalse);
      expect(result.skipped, 0);
    }
  });
}
