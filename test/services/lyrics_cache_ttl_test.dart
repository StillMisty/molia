import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/cache_service.dart';
import 'package:molia/services/cache_storage_stub.dart';
import 'package:molia/services/lyrics/lyric_provider.dart';
import 'package:molia/services/lyrics_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 计数假 Provider：验证缓存命中时不会发起网络请求。
class _CountingProvider extends LyricProvider {
  int searchCalls = 0;

  @override
  String get name => 'counting';

  @override
  Future<String?> fetchLyric(String songId) async => '[00:00]fresh lyric';

  @override
  Future<SongMatch?> search(String title, String artist) async {
    searchCalls++;
    return SongMatch(songId: 'id', title: title, artist: artist);
  }

  @override
  Future<List<SongMatch>> searchMultiple(String title, String artist,
          {int limit = 3}) async =>
      [SongMatch(songId: 'id', title: title, artist: artist)];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late CacheService cacheService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    cacheService = CacheService(
      prefs: prefs,
      storage: MemoryCacheStorage(),
    );
  });

  String cacheEntry(String lyric, int timestamp) => jsonEncode({
        'provider': 'seeded',
        'lyric': lyric,
        'ts': timestamp,
      });

  int nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  test('默认 TTL 30 天：新鲜缓存直接命中，不访问 Provider', () async {
    await prefs.setString(
      'lyrics_cache_track1',
      cacheEntry('[00:00]cached', nowSeconds() - 60),
    );
    final provider = _CountingProvider();
    final service = LyricsService(
      providers: [provider],
      prefs: prefs,
      cacheService: cacheService,
    );

    final result = await service.getLyrics('t', 'a', 'track1');
    expect(result!.lyric, '[00:00]cached');
    expect(result.provider, 'seeded');
    expect(provider.searchCalls, 0);
  });

  test('TTL=0（永不过期）：1970 年的时间戳也命中', () async {
    await cacheService.setLyricsTtlDays(0);
    await prefs.setString('lyrics_cache_track2', cacheEntry('[00:00]old', 1));
    final provider = _CountingProvider();
    final service = LyricsService(
      providers: [provider],
      prefs: prefs,
      cacheService: cacheService,
    );

    final result = await service.getLyrics('t', 'a', 'track2');
    expect(result!.lyric, '[00:00]old');
    expect(provider.searchCalls, 0);
  });

  test('TTL=1 天：过期条目重新获取并回写缓存', () async {
    await cacheService.setLyricsTtlDays(1);
    await prefs.setString(
      'lyrics_cache_track3',
      cacheEntry('[00:00]stale', nowSeconds() - 3 * 24 * 60 * 60),
    );
    final provider = _CountingProvider();
    final service = LyricsService(
      providers: [provider],
      prefs: prefs,
      cacheService: cacheService,
    );

    final result = await service.getLyrics('t', 'a', 'track3');
    expect(result!.lyric, '[00:00]fresh lyric');
    expect(result.provider, 'counting');
    expect(provider.searchCalls, 1);

    // 回写后再次获取命中新缓存，不再请求。
    final again = await service.getLyrics('t', 'a', 'track3');
    expect(again!.lyric, '[00:00]fresh lyric');
    expect(provider.searchCalls, 1);
  });

  test('缩短 TTL 立即生效：29 天前条目在 TTL=7 时视为过期', () async {
    await prefs.setString(
      'lyrics_cache_track4',
      cacheEntry('[00:00]month old', nowSeconds() - 29 * 24 * 60 * 60),
    );
    final provider = _CountingProvider();
    final service = LyricsService(
      providers: [provider],
      prefs: prefs,
      cacheService: cacheService,
    );

    // 默认 30 天：命中。
    expect((await service.getLyrics('t', 'a', 'track4'))!.lyric,
        '[00:00]month old');
    expect(provider.searchCalls, 0);

    // 改为 7 天后同一条目立即过期。
    await cacheService.setLyricsTtlDays(7);
    final refreshed = await service.getLyrics('t', 'a', 'track4');
    expect(refreshed!.lyric, '[00:00]fresh lyric');
    expect(provider.searchCalls, 1);
  });
}
