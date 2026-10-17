import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/cache_service.dart';
import 'package:molia/services/lyrics/lyric_provider.dart';
import 'package:molia/services/lyrics_cache.dart';
import 'package:molia/services/lyrics_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/memory_cache_storage.dart';

/// 计数假 Provider：验证缓存命中时不会发起网络请求。
class _CountingProvider extends LyricProvider {
  int searchCalls = 0;

  @override
  String get name => 'counting';

  @override
  Future<String?> fetchLyric(String songId) async => '[00:00]fresh lyric';

  @override
  Future<SongMatch?> search(String title, String artist) async =>
      SongMatch(songId: 'id', title: title, artist: artist);

  @override
  Future<List<SongMatch>> searchMultiple(String title, String artist,
      {int limit = 3}) async {
    searchCalls++;
    return [SongMatch(songId: 'id', title: title, artist: artist)];
  }
}

/// 歌词缓存测试面：基础读写（规范键 / 损坏条目 / usage / clear / remove）、
/// 翻译与罗马音扩展及旧版 JSON 兼容、TTL 过期重取与回写。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // 基础：规范键读写、损坏条目、用量统计与清理的键范围。
  test('write/read 往返（规范键）', () async {
    final cache = LyricsCache();
    await cache.write(
      'kw:1',
      LyricCacheData(provider: 'netease', lyric: '[00:01]hi', timestamp: 123),
    );
    final entry = await cache.read('kw:1');
    expect(entry, isNotNull);
    expect(entry!.provider, 'netease');
    expect(entry.lyric, '[00:01]hi');
    expect(entry.timestamp, 123);
  });

  test('损坏条目按未命中处理', () async {
    SharedPreferences.setMockInitialValues({'lyrics_cache_x': 'not-json'});
    expect(await LyricsCache().read('x'), isNull);
  });

  test('usage 只统计规范键（历史 manual 键不算用量）', () async {
    SharedPreferences.setMockInitialValues({
      'lyrics_cache_a': '{"provider":"qq","lyric":"x","timestamp":1}',
      'manual_lyrics_cache_a': '{"provider":"qq","lyric":"x","timestamp":1}',
    });
    final usage = await LyricsCache().usage();
    expect(usage.count, 1);
    expect(usage.bytes, greaterThan(0));
  });

  test('clear 同时清理规范键与历史 manual 键，不碰其它键', () async {
    SharedPreferences.setMockInitialValues({
      'lyrics_cache_a': '{}',
      'manual_lyrics_cache_a': '{}',
      'other_key': 'keep',
    });
    await LyricsCache().clear();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('lyrics_cache_a'), isFalse);
    expect(prefs.containsKey('manual_lyrics_cache_a'), isFalse);
    expect(prefs.getString('other_key'), 'keep');
  });

  test('usageOf 只统计该曲目的规范键字节', () async {
    const value = '{"provider":"qq","lyric":"x","timestamp":1}';
    SharedPreferences.setMockInitialValues({
      'lyrics_cache_qy:1': value,
      'lyrics_cache_qy:2': value,
      'manual_lyrics_cache_qy:1': value,
    });
    final usage = await LyricsCache().usageOf('qy:1');
    expect(usage.count, 1);
    expect(usage.bytes, utf8.encode(value).length);
    expect(await LyricsCache().usageOf('qy:404'), CacheUsage.zero);
  });

  test('remove 只删该曲目（规范键 + 历史键），其它曲目保留', () async {
    SharedPreferences.setMockInitialValues({
      'lyrics_cache_qy:1': '{}',
      'manual_lyrics_cache_qy:1': '{}',
      'lyrics_cache_qy:2': '{}',
    });
    await LyricsCache().remove('qy:1');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('lyrics_cache_qy:1'), isFalse);
    expect(prefs.containsKey('manual_lyrics_cache_qy:1'), isFalse);
    expect(prefs.containsKey('lyrics_cache_qy:2'), isTrue);
  });

  // 翻译 / 罗马音往返 + 旧版本 JSON（无扩展字段）兼容。
  test('翻译/罗马音写入后可读', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final cache = LyricsCache(prefs: prefs);

    await cache.write(
      'fake:1',
      LyricCacheData(
        provider: 'netease',
        lyric: '[00:01]a',
        translation: '[00:01]译',
        roma: '[00:01]romaji',
        timestamp: 1,
      ),
    );
    final read = await cache.read('fake:1');
    expect(read, isNotNull);
    expect(read!.translation, '[00:01]译');
    expect(read.roma, '[00:01]romaji');
  });

  test('旧版本 JSON（无翻译字段）按无扩展行读取', () async {
    SharedPreferences.setMockInitialValues({
      'lyrics_cache_fake:2': jsonEncode({
        'provider': 'qq',
        'lyric': '[00:01]b',
        'ts': 1,
      }),
    });
    final prefs = await SharedPreferences.getInstance();
    final cache = LyricsCache(prefs: prefs);

    final read = await cache.read('fake:2');
    expect(read, isNotNull);
    expect(read!.lyric, '[00:01]b');
    expect(read.translation, isNull);
    expect(read.roma, isNull);
  });

  // TTL：命中不访问 Provider、0 为永不过期、过期重取并回写、缩短后立即生效。
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
