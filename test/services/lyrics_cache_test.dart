import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show md5;
import 'package:flutter/services.dart';
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

/// 歌词缓存文件名约定（与实现一致：trackId 的 md5 + `.json`）。
File lyricsFile(Directory directory, String trackId) {
  final name = md5.convert(utf8.encode(trackId)).toString();
  return File('${directory.path}${Platform.pathSeparator}$name.json');
}

/// 歌词缓存测试面：文件后端读写 / 原子写入 / 旧 prefs 迁移 / 用量统计，
/// 以及旧版 prefs 回退行为与 TTL 过期重取。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late SharedPreferences prefs;
  late CacheService cacheService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    tempRoot = await Directory.systemTemp.createTemp('lyrics_cache_test_');
    cacheService = CacheService(
      prefs: prefs,
      storage: MemoryCacheStorage(),
    );
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  // 基础：文件读写、旧版 prefs 条目兼容、用量统计与清理的键范围。
  test('write/read 往返（文件后端，内容与 toJson 一致）', () async {
    final cache = LyricsCache(prefs: prefs, directory: tempRoot);
    final data = LyricCacheData(
      provider: 'netease',
      lyric: '[00:01]hi',
      timestamp: 123,
    );
    await cache.write('kw:1', data);

    final file = lyricsFile(tempRoot, 'kw:1');
    expect(await file.exists(), isTrue);
    expect(await file.readAsString(), jsonEncode(data.toJson()));
    // 原子写入：正式文件由 rename 落成，不留下临时文件。
    expect(
      tempRoot.listSync().where((entity) => entity.path.endsWith('.tmp')),
      isEmpty,
    );

    final entry = await cache.read('kw:1');
    expect(entry, isNotNull);
    expect(entry!.provider, 'netease');
    expect(entry.lyric, '[00:01]hi');
    expect(entry.timestamp, 123);

    // 覆盖已有文件同样走 rename（Windows 也要求 replace 语义）。
    await cache.write(
      'kw:1',
      LyricCacheData(provider: 'netease', lyric: '[00:02]new', timestamp: 124),
    );
    expect((await cache.read('kw:1'))!.lyric, '[00:02]new');
    expect(
      tempRoot.listSync().where((entity) => entity.path.endsWith('.tmp')),
      isEmpty,
    );
  });

  test('trackId 含路径分隔符/非法字符时仍落在同一目录', () async {
    final cache = LyricsCache(prefs: prefs, directory: tempRoot);
    const trackId = r'lx:a/b\c:d?e*f';
    await cache.write(
      trackId,
      LyricCacheData(provider: 'lx', lyric: '[00:01]safe', timestamp: 1),
    );

    expect((await cache.read(trackId))!.lyric, '[00:01]safe');
    expect(tempRoot.listSync().whereType<Directory>(), isEmpty);
    expect(lyricsFile(tempRoot, trackId).existsSync(), isTrue);
  });

  test('默认构造（无 directory / resolver）只走 prefs，不调用 path_provider', () async {
    // 通道替身会返回可用路径：默认构造若错误地启用文件后端，就会写文件而
    // 不是 prefs，同时 calls 递增。widget 测试的 fake async 里这类 Future
    // 不会完成，正是 `pumpAndSettle` 超时的根因。
    var pathProviderCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        pathProviderCalls++;
        return tempRoot.path;
      },
    );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
    });

    final cache = LyricsCache(prefs: prefs);
    final data = LyricCacheData(
      provider: 'prefs',
      lyric: '[00:01]prefs',
      timestamp: 4,
    );
    await cache.write('default', data);

    final raw = jsonEncode(data.toJson());
    expect(prefs.getString('lyrics_cache_default'), raw);
    expect(await lyricsFile(tempRoot, 'default').exists(), isFalse);

    final read = await cache.read('default');
    expect(read, isNotNull);
    expect(read!.lyric, '[00:01]prefs');
    expect(
      await cache.usageOf('default'),
      CacheUsage(bytes: utf8.encode(raw).length, count: 1),
    );
    expect(
      await cache.usage(),
      CacheUsage(bytes: utf8.encode(raw).length, count: 1),
    );

    await cache.remove('default');
    expect(prefs.containsKey('lyrics_cache_default'), isFalse);

    // 无参数构造同样走 SharedPreferences（测试里是 mock 实例）。
    final bare = LyricsCache();
    await bare.write('bare', data);
    expect(prefs.getString('lyrics_cache_bare'), raw);
    await bare.remove('bare');
    expect(prefs.containsKey('lyrics_cache_bare'), isFalse);

    expect(pathProviderCalls, 0);
    expect(
      Directory('${tempRoot.path}${Platform.pathSeparator}lyrics_cache')
          .existsSync(),
      isFalse,
    );
  });

  test('显式 directoryResolver 才启用文件后端', () async {
    final cache = LyricsCache(
      prefs: prefs,
      directoryResolver: () async => tempRoot,
    );
    await cache.write(
      'resolver',
      LyricCacheData(provider: 'file', lyric: '[00:01]resolver', timestamp: 5),
    );

    expect(await lyricsFile(tempRoot, 'resolver').exists(), isTrue);
    expect(prefs.containsKey('lyrics_cache_resolver'), isFalse);
    expect((await cache.read('resolver'))!.lyric, '[00:01]resolver');
  });

  test('prefs 损坏条目按未命中处理', () async {
    await prefs.setString('lyrics_cache_x', 'not-json');
    expect(await LyricsCache(directory: tempRoot).read('x'), isNull);
  });

  test('usage 只统计规范键（历史 manual 键不算用量）', () async {
    await prefs.setString(
      'lyrics_cache_a',
      '{"provider":"qq","lyric":"x","timestamp":1}',
    );
    await prefs.setString(
      'manual_lyrics_cache_a',
      '{"provider":"qq","lyric":"x","timestamp":1}',
    );
    final usage = await LyricsCache(directory: tempRoot).usage();
    expect(usage.count, 1);
    expect(usage.bytes, greaterThan(0));
  });

  test('clear 同时清理规范键与历史 manual 键，不碰其它键', () async {
    await prefs.setString('lyrics_cache_a', '{}');
    await prefs.setString('manual_lyrics_cache_a', '{}');
    await prefs.setString('other_key', 'keep');

    await LyricsCache(directory: tempRoot).clear();

    expect(prefs.containsKey('lyrics_cache_a'), isFalse);
    expect(prefs.containsKey('manual_lyrics_cache_a'), isFalse);
    expect(prefs.getString('other_key'), 'keep');
  });

  test('usageOf 只统计该曲目的规范键字节', () async {
    const value = '{"provider":"qq","lyric":"x","timestamp":1}';
    await prefs.setString('lyrics_cache_qy:1', value);
    await prefs.setString('lyrics_cache_qy:2', value);
    await prefs.setString('manual_lyrics_cache_qy:1', value);

    final usage = await LyricsCache(directory: tempRoot).usageOf('qy:1');
    expect(usage.count, 1);
    expect(usage.bytes, utf8.encode(value).length);
    expect(
      await LyricsCache(directory: tempRoot).usageOf('qy:404'),
      CacheUsage.zero,
    );
  });

  test('remove 只删该曲目（规范键 + 历史键），其它曲目保留', () async {
    await prefs.setString('lyrics_cache_qy:1', '{}');
    await prefs.setString('manual_lyrics_cache_qy:1', '{}');
    await prefs.setString('lyrics_cache_qy:2', '{}');

    await LyricsCache(directory: tempRoot).remove('qy:1');

    expect(prefs.containsKey('lyrics_cache_qy:1'), isFalse);
    expect(prefs.containsKey('manual_lyrics_cache_qy:1'), isFalse);
    expect(prefs.containsKey('lyrics_cache_qy:2'), isTrue);
  });

  // 翻译 / 罗马音往返 + 旧版本 JSON（无扩展字段）兼容。
  test('翻译/罗马音写入后可读', () async {
    final cache = LyricsCache(prefs: prefs, directory: tempRoot);

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
    await prefs.setString(
      'lyrics_cache_fake:2',
      jsonEncode({
        'provider': 'qq',
        'lyric': '[00:01]b',
        'ts': 1,
      }),
    );
    final cache = LyricsCache(prefs: prefs, directory: tempRoot);

    final read = await cache.read('fake:2');
    expect(read, isNotNull);
    expect(read!.lyric, '[00:01]b');
    expect(read.translation, isNull);
    expect(read.roma, isNull);
  });

  // TTL：命中不访问 Provider、0 为永不过期、过期重取并回写、缩短后立即生效。
  LyricsService serviceWith(_CountingProvider provider) => LyricsService(
        providers: [provider],
        prefs: prefs,
        cacheService: cacheService,
        lyricsCache: LyricsCache(prefs: prefs, directory: tempRoot),
      );

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

    final result = await serviceWith(provider).getLyrics('t', 'a', 'track1');
    expect(result!.lyric, '[00:00]cached');
    expect(result.provider, 'seeded');
    expect(provider.searchCalls, 0);
    // 命中旧 prefs 条目后已迁移成文件。
    expect(prefs.containsKey('lyrics_cache_track1'), isFalse);
    expect(lyricsFile(tempRoot, 'track1').existsSync(), isTrue);
  });

  test('TTL=0（永不过期）：1970 年的时间戳也命中', () async {
    await cacheService.setLyricsTtlDays(0);
    await prefs.setString('lyrics_cache_track2', cacheEntry('[00:00]old', 1));
    final provider = _CountingProvider();

    final result = await serviceWith(provider).getLyrics('t', 'a', 'track2');
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
    final service = serviceWith(provider);

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
    final service = serviceWith(provider);

    // 默认 30 天：命中。
    expect(
      (await service.getLyrics('t', 'a', 'track4'))!.lyric,
      '[00:00]month old',
    );
    expect(provider.searchCalls, 0);

    // 改为 7 天后同一条目立即过期。
    await cacheService.setLyricsTtlDays(7);
    final refreshed = await service.getLyrics('t', 'a', 'track4');
    expect(refreshed!.lyric, '[00:00]fresh lyric');
    expect(provider.searchCalls, 1);
  });

  group('文件后端', () {
    test('usage / usageOf 与文件字节数一致', () async {
      final cache = LyricsCache(prefs: prefs, directory: tempRoot);
      await cache.write(
        'a',
        LyricCacheData(provider: 'p', lyric: '[00:01]a', timestamp: 1),
      );
      final fileA = lyricsFile(tempRoot, 'a');
      final sizeA = await fileA.length();

      expect(
        await cache.usageOf('a'),
        CacheUsage(bytes: sizeA, count: 1),
      );
      expect(await cache.usage(), CacheUsage(bytes: sizeA, count: 1));

      await cache.write(
        'b',
        LyricCacheData(provider: 'p', lyric: '[00:01]b', timestamp: 2),
      );
      final sizeB = await lyricsFile(tempRoot, 'b').length();

      expect(await cache.usageOf('b'), CacheUsage(bytes: sizeB, count: 1));
      expect(
        await cache.usage(),
        CacheUsage(bytes: sizeA + sizeB, count: 2),
      );
      expect(await cache.usageOf('missing'), CacheUsage.zero);
    });

    test('CacheService.attachLyricsCache 后统计与清理走同一个文件实例', () async {
      final cache = LyricsCache(prefs: prefs, directory: tempRoot);
      cacheService.attachLyricsCache(cache);
      await cache.write(
        'attached',
        LyricCacheData(provider: 'p', lyric: '[00:01]attached', timestamp: 6),
      );

      final fileBytes = await lyricsFile(tempRoot, 'attached').length();
      expect(
        await cacheService.usage(CachePartition.lyrics),
        CacheUsage(bytes: fileBytes, count: 1),
      );

      await cacheService.clearLyricsForTrack('attached');
      expect(lyricsFile(tempRoot, 'attached').existsSync(), isFalse);
      expect(
        await cacheService.usage(CachePartition.lyrics),
        CacheUsage.zero,
      );
    });

    test('损坏文件返回 null，不回退旧 prefs 条目', () async {
      final cache = LyricsCache(prefs: prefs, directory: tempRoot);
      await cache.write(
        'bad',
        LyricCacheData(provider: 'file', lyric: '[00:01]new', timestamp: 2),
      );
      await lyricsFile(tempRoot, 'bad').writeAsString('not-json');
      // 文件损坏时若回退 prefs，会绕过 TTL 返回更旧的歌词。
      await prefs.setString(
        'lyrics_cache_bad',
        cacheEntry('[00:01]stale prefs', 1),
      );

      expect(await cache.read('bad'), isNull);
      // 没有回退，也就不会迁移/删除旧键。
      expect(prefs.containsKey('lyrics_cache_bad'), isTrue);
    });

    test('旧版 prefs 条目读取后迁移成文件并删除旧键', () async {
      const value = '{"provider":"legacy","lyric":"[00:01]old","ts":7}';
      await prefs.setString('lyrics_cache_legacy:1', value);
      final cache = LyricsCache(prefs: prefs, directory: tempRoot);

      final read = await cache.read('legacy:1');
      expect(read, isNotNull);
      expect(read!.provider, 'legacy');
      expect(read.lyric, '[00:01]old');
      expect(read.timestamp, 7);

      expect(prefs.containsKey('lyrics_cache_legacy:1'), isFalse);
      final file = lyricsFile(tempRoot, 'legacy:1');
      expect(await file.exists(), isTrue);
      expect(await file.readAsString(), value);

      // 迁移后只依赖文件：不注入 prefs 也能命中。
      final again = await LyricsCache(directory: tempRoot).read('legacy:1');
      expect(again!.lyric, '[00:01]old');
    });

    test('usage / usageOf 包含尚未迁移的旧 prefs 条目', () async {
      const legacy = '{"provider":"qq","lyric":"旧","ts":1}';
      await prefs.setString('lyrics_cache_old', legacy);
      final cache = LyricsCache(prefs: prefs, directory: tempRoot);
      await cache.write(
        'new',
        LyricCacheData(provider: 'p', lyric: '[00:01]新', timestamp: 2),
      );

      final fileBytes = await lyricsFile(tempRoot, 'new').length();
      final legacyBytes = utf8.encode(legacy).length;
      expect(
        await cache.usage(),
        CacheUsage(bytes: fileBytes + legacyBytes, count: 2),
      );
      expect(
        await cache.usageOf('old'),
        CacheUsage(bytes: legacyBytes, count: 1),
      );
      expect(
        await cache.usageOf('new'),
        CacheUsage(bytes: fileBytes, count: 1),
      );
    });

    test('remove / clear 删除文件；write 不动历史 manual 键', () async {
      final cache = LyricsCache(prefs: prefs, directory: tempRoot);
      await cache.write(
        'a',
        LyricCacheData(provider: 'p', lyric: 'a', timestamp: 1),
      );
      await cache.write(
        'b',
        LyricCacheData(provider: 'p', lyric: 'b', timestamp: 2),
      );
      await prefs.setString('manual_lyrics_cache_a', '{}');
      await prefs.setString('manual_lyrics_cache_b', '{}');

      // 写路径只清同曲目规范键，不碰历史重复键。
      await prefs.setString('lyrics_cache_a', '{}');
      await cache.write(
        'a',
        LyricCacheData(provider: 'p', lyric: 'a2', timestamp: 3),
      );
      expect(prefs.containsKey('lyrics_cache_a'), isFalse);
      expect(prefs.containsKey('manual_lyrics_cache_a'), isTrue);

      await cache.remove('a');
      expect(lyricsFile(tempRoot, 'a').existsSync(), isFalse);
      expect(prefs.containsKey('manual_lyrics_cache_a'), isFalse);
      expect(lyricsFile(tempRoot, 'b').existsSync(), isTrue);

      // 文件已被其它路径删掉时 clear 不能失败。
      await lyricsFile(tempRoot, 'b').delete();
      await cache.clear();
      expect(tempRoot.listSync().whereType<File>(), isEmpty);
      expect(prefs.containsKey('manual_lyrics_cache_b'), isFalse);
    });

    test('目录不可用时回退 prefs（读写 / 用量 / 删除）', () async {
      final blocker = File('${tempRoot.path}${Platform.pathSeparator}blocker');
      await blocker.writeAsString('not a directory');
      final unusable =
          Directory('${blocker.path}${Platform.pathSeparator}lyrics_cache');
      final cache = LyricsCache(prefs: prefs, directory: unusable);

      await cache.write(
        'fb',
        LyricCacheData(provider: 'fallback', lyric: '[00:01]fb', timestamp: 3),
      );
      final raw = prefs.getString('lyrics_cache_fb');
      expect(raw, isNotNull);

      final read = await cache.read('fb');
      expect(read, isNotNull);
      expect(read!.provider, 'fallback');
      expect(read.lyric, '[00:01]fb');

      final bytes = utf8.encode(raw!).length;
      expect(await cache.usageOf('fb'), CacheUsage(bytes: bytes, count: 1));
      expect(await cache.usage(), CacheUsage(bytes: bytes, count: 1));

      await cache.remove('fb');
      expect(prefs.containsKey('lyrics_cache_fb'), isFalse);
      expect(await cache.read('fb'), isNull);

      // clear 在目录不可用时同样只清 prefs，不抛异常。
      await prefs.setString('lyrics_cache_other', '{}');
      await prefs.setString('manual_lyrics_cache_other', '{}');
      await cache.clear();
      expect(prefs.containsKey('lyrics_cache_other'), isFalse);
      expect(prefs.containsKey('manual_lyrics_cache_other'), isFalse);
    });
  });
}
