import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/music_source.dart';
import 'package:molia/managers/artwork_cache.dart';
import 'package:molia/services/cache_service.dart';
import 'package:molia/services/cache_storage_io.dart';
import 'package:molia/services/cache_storage_stub.dart';
import 'package:molia/services/track_cache_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_music_source.dart';

/// 可解析的假音源：用于把取链缓存灌进 CatalogService。
class _ResolvableSource extends FakeMusicSource {
  _ResolvableSource(super.key);

  @override
  Future<PlayableStream> resolve(
    Track track, {
    AudioQuality? preferredQuality,
  }) async =>
      PlayableStream(Uri.parse('https://cdn.example/${track.id.id}'));
}

/// 假封面缓存：只记录「有哪些 URL 被命中/删除」，不碰 flutter_cache_manager。
class _FakeArtworkCache extends ArtworkCache {
  _FakeArtworkCache() : super(cacheService: CacheService(storage: MemoryCacheStorage()));

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
  late _ResolvableSource source;
  late CatalogService catalogService;
  late TrackCacheService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    tempRoot = await Directory.systemTemp.createTemp('track_cache_test_');
    cacheService = CacheService(
      prefs: prefs,
      storage: IoCacheStorage(
        audioDirOverride: '${tempRoot.path}/audio_cache',
        artworkDirOverride: '${tempRoot.path}/artwork_cache',
      ),
      audioProtectAge: Duration.zero, // 测试文件视为“非活动”
    );
    artworkCache = _FakeArtworkCache();
    source = _ResolvableSource('kw');
    catalogService = CatalogService(
      registry: FakeSourceRegistry({'kw': source}),
    );
    service = TrackCacheService(
      cacheService: cacheService,
      artworkCache: artworkCache,
      catalogService: catalogService,
    );
  });

  tearDown(() async {
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
        payload: {'id': id},
      );

  Future<void> writeAudio(String name, int size) async {
    final file = File('${tempRoot.path}/audio_cache/$name');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List<int>.filled(size, 0));
  }

  test('usage：四项占用一次读出（音频多音质合并 / 歌词 / 封面 / 取链）', () async {
    final t = track();
    await writeAudio(
      CacheService.audioCacheKey(sourceKey: 'kw', songId: 'a', quality: '320k'),
      100,
    );
    await writeAudio(
      CacheService.audioCacheKey(sourceKey: 'kw', songId: 'a', quality: 'flac'),
      200,
    );
    await prefs.setString(
      '${CacheService.lyricsCacheKeyPrefix}kw:a',
      '{"provider":"qq","lyric":"x","timestamp":1}',
    );
    artworkCache.files['https://cdn.example/a.jpg'] = 300;
    await catalogService.resolve(t, quality: const AudioQuality(type: '320k'));
    await catalogService.resolve(t);

    final usage = await service.usage(t);
    expect(usage.audio, const CacheUsage(bytes: 300, count: 2));
    expect(usage.lyrics.count, 1);
    expect(usage.artwork, const CacheUsage(bytes: 300, count: 1));
    expect(usage.resolveEntries, 2);
  });

  test('clear audio：删除全部音质变体并返回释放量', () async {
    final t = track();
    final key320 = CacheService.audioCacheKey(
        sourceKey: 'kw', songId: 'a', quality: '320k');
    final keyFlac = CacheService.audioCacheKey(
        sourceKey: 'kw', songId: 'a', quality: 'flac');
    await writeAudio(key320, 100);
    await writeAudio(keyFlac, 200);

    final result = await service.clear(t, TrackCachePart.audio);
    expect(result.part, TrackCachePart.audio);
    expect(result.cleared, isTrue);
    expect(result.freed, const CacheUsage(bytes: 300, count: 2));
    expect(result.skipped, 0);
    expect(File('${tempRoot.path}/audio_cache/$key320').existsSync(), isFalse);
    expect(File('${tempRoot.path}/audio_cache/$keyFlac').existsSync(), isFalse);
    expect((await service.usage(t)).audio, CacheUsage.zero);
  });

  test('clear audio：正在写入（protectAge 内）→ skipped 且未清掉', () async {
    final guarded = TrackCacheService(
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
    await writeAudio(
      CacheService.audioCacheKey(sourceKey: 'kw', songId: 'a', quality: '320k'),
      100,
    );

    final result = await guarded.clear(t, TrackCachePart.audio);
    expect(result.cleared, isFalse);
    expect(result.skipped, 1);
  });

  test('clear lyrics / artwork / resolve：各自释放量与状态正确', () async {
    final t = track();
    await prefs.setString(
      '${CacheService.lyricsCacheKeyPrefix}kw:a',
      '{"provider":"qq","lyric":"x","timestamp":1}',
    );
    await prefs.setString('manual_lyrics_cache_kw:a', '{}');
    artworkCache.files['https://cdn.example/a.jpg'] = 300;
    artworkCache.files['https://cdn.example/a-fallback.jpg'] = 120;
    await catalogService.resolve(t, quality: const AudioQuality(type: '320k'));
    await catalogService.resolve(t, quality: const AudioQuality(type: '128k'));

    final lyrics = await service.clear(t, TrackCachePart.lyrics);
    expect(lyrics.cleared, isTrue);
    expect(lyrics.freed.count, 1);
    expect(prefs.getString('${CacheService.lyricsCacheKeyPrefix}kw:a'), isNull);
    expect(prefs.getString('manual_lyrics_cache_kw:a'), isNull);

    final artwork = await service.clear(t, TrackCachePart.artwork);
    expect(artwork.cleared, isTrue);
    expect(artwork.freed, const CacheUsage(bytes: 420, count: 2));
    expect(
      artworkCache.removed,
      containsAll([
        'https://cdn.example/a.jpg',
        'https://cdn.example/a-fallback.jpg',
      ]),
    );

    final resolve = await service.clear(t, TrackCachePart.resolveUrl);
    expect(resolve.part, TrackCachePart.resolveUrl);
    expect(resolve.freed.count, 2);
    expect(catalogService.resolveCacheCountForTrack(t), 0);

    // 清完后再查：四项全空。
    final usage = await service.usage(t);
    expect(usage.hasAny, isFalse);
  });

  test('无封面 / 无缓存：占用为零，清理不报错', () async {
    final noArtwork = Track(
      id: const TrackId('kw', 'plain'),
      title: 'plain',
      origin: TrackOrigin.lx,
      payload: const {'id': 'plain'},
    );
    final usage = await service.usage(noArtwork);
    expect(usage.hasAny, isFalse);
    for (final part in TrackCachePart.values) {
      final result = await service.clear(noArtwork, part);
      expect(result.cleared, isFalse);
      expect(result.skipped, 0);
    }
  });
}
