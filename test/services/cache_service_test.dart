import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/cache_service.dart';
import 'package:molia/services/cache_storage_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late IoCacheStorage storage;
  late CacheService service;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    tempRoot = await Directory.systemTemp.createTemp('cache_service_test_');
    storage = IoCacheStorage(
      audioDirOverride: '${tempRoot.path}/audio_cache',
      artworkDirOverride: '${tempRoot.path}/artwork_cache',
    );
    service = CacheService(
      prefs: prefs,
      storage: storage,
      audioProtectAge: Duration.zero, // 测试文件视为“非活动”
    );
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  Future<File> writeFile(String dir, String name, int sizeBytes,
      {Duration age = const Duration(days: 1)}) async {
    final file = File('$dir/$name');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List<int>.filled(sizeBytes, 0));
    await file.setLastModified(DateTime.now().subtract(age));
    return file;
  }

  group('策略默认值与读写', () {
    test('默认值：音频开 / 1024MB / 歌词 30 天 / 封面 1500 个 365 天', () async {
      expect(await service.audioEnabled(), isTrue);
      expect(await service.audioMaxMb(), 1024);
      expect(await service.lyricsTtlDays(), 30);
      expect(await service.artworkMaxObjects(), 1500);
      expect(await service.artworkStaleDays(), 365);
    });

    test('写入后立即读到新值（持久化键名固定）', () async {
      await service.setAudioEnabled(false);
      await service.setAudioMaxMb(64);
      await service.setLyricsTtlDays(0);
      await service.setArtworkMaxObjects(10);
      await service.setArtworkStaleDays(7);

      expect(prefs.getBool(CacheService.keyAudioEnabled), isFalse);
      expect(prefs.getInt(CacheService.keyAudioMaxMb), 64);
      expect(prefs.getInt(CacheService.keyLyricsTtlDays), 0);
      expect(prefs.getInt(CacheService.keyArtworkMaxObjects), 10);
      expect(prefs.getInt(CacheService.keyArtworkStaleDays), 7);

      expect(await service.audioEnabled(), isFalse);
      expect(await service.audioMaxMb(), 64);
      expect(await service.lyricsTtlDays(), 0);
      expect(await service.artworkMaxObjects(), 10);
      expect(await service.artworkStaleDays(), 7);
    });

    test('负数写入被夹到 0（0 = 不限制/永不过期）', () async {
      await service.setAudioMaxMb(-5);
      await service.setLyricsTtlDays(-1);
      expect(await service.audioMaxMb(), 0);
      expect(await service.lyricsTtlDays(), 0);
    });

    test('策略变更通知监听者', () async {
      final events = <CachePartition>[];
      void listener(CachePartition p) => events.add(p);
      service.addPolicyListener(listener);
      await service.setArtworkMaxObjects(5);
      await service.setArtworkStaleDays(3);
      service.removePolicyListener(listener);
      await service.setArtworkMaxObjects(6);
      expect(events, [CachePartition.artwork, CachePartition.artwork]);
    });
  });

  group('usage / clear', () {
    test('音频/封面按目录统计字节与文件数', () async {
      await writeFile('${tempRoot.path}/audio_cache', 'a.part', 100);
      await writeFile('${tempRoot.path}/audio_cache', 'b', 250);
      await writeFile('${tempRoot.path}/artwork_cache', 'c.jpg', 300);

      final audio = await service.usage(CachePartition.audio);
      expect(audio.bytes, 350);
      expect(audio.count, 2);

      final artwork = await service.usage(CachePartition.artwork);
      expect(artwork.bytes, 300);
      expect(artwork.count, 1);

      // 目录不存在 → zero。
      final empty = CacheService(
        prefs: prefs,
        storage: IoCacheStorage(
          audioDirOverride: '${tempRoot.path}/missing',
          artworkDirOverride: '${tempRoot.path}/missing2',
        ),
      );
      expect(await empty.usage(CachePartition.audio), CacheUsage.zero);
    });

    test('歌词按 prefs 键统计 UTF-8 字节与条数', () async {
      final value = jsonEncode({'provider': 'fake', 'lyric': '歌词', 'ts': 1});
      await prefs.setString('${CacheService.lyricsCacheKeyPrefix}1', value);
      await prefs.setString('${CacheService.lyricsCacheKeyPrefix}2', value);
      await prefs.setString('unrelated_key', 'x');

      final usage = await service.usage(CachePartition.lyrics);
      expect(usage.count, 2);
      expect(usage.bytes, utf8.encode(value).length * 2);

      await service.clear(CachePartition.lyrics);
      expect(await service.usage(CachePartition.lyrics), CacheUsage.zero);
      expect(prefs.getString('unrelated_key'), 'x');
    });

    test('clear 删除分区文件但保留目录；clearAll 清空三个分区', () async {
      await writeFile('${tempRoot.path}/audio_cache', 'a', 10);
      await writeFile('${tempRoot.path}/artwork_cache', 'b.jpg', 20);
      await prefs.setString('${CacheService.lyricsCacheKeyPrefix}1', '{}');

      await service.clear(CachePartition.audio);
      expect(Directory('${tempRoot.path}/audio_cache').existsSync(), isTrue);
      expect(await service.usage(CachePartition.audio), CacheUsage.zero);

      await writeFile('${tempRoot.path}/audio_cache', 'a2', 10);
      await service.clearAll();
      expect(await service.usage(CachePartition.audio), CacheUsage.zero);
      expect(await service.usage(CachePartition.artwork), CacheUsage.zero);
      expect(await service.usage(CachePartition.lyrics), CacheUsage.zero);
    });
  });

  group('音频 LRU 淘汰', () {
    test('超过上限按 mtime 从旧到新删除，最新文件保留', () async {
      const size = 600 * 1024; // 600KB
      final oldest =
          await writeFile('${tempRoot.path}/audio_cache', 'oldest', size);
      final middle = await writeFile('${tempRoot.path}/audio_cache', 'middle',
          size, age: const Duration(hours: 12));
      final newest = await writeFile('${tempRoot.path}/audio_cache', 'newest',
          size, age: const Duration(minutes: 1));

      // 上限 1MB：1.8MB → 删到 <= 1MB（删 2 个）。
      await service.setAudioMaxMb(1);

      expect(await oldest.exists(), isFalse);
      expect(await middle.exists(), isFalse);
      expect(await newest.exists(), isTrue);
      final usage = await service.usage(CachePartition.audio);
      expect(usage.count, 1);
    });

    test('protectAge 内修改的文件（正在写入）不删', () async {
      final active = CacheService(
        prefs: prefs,
        storage: storage,
        audioProtectAge: const Duration(hours: 1),
      );
      await writeFile('${tempRoot.path}/audio_cache', 'active', 600 * 1024,
          age: Duration.zero);
      await writeFile('${tempRoot.path}/audio_cache', 'idle', 600 * 1024,
          age: const Duration(days: 2));

      await active.setAudioMaxMb(1);
      expect(File('${tempRoot.path}/audio_cache/active').existsSync(), isTrue);
      expect(File('${tempRoot.path}/audio_cache/idle').existsSync(), isFalse);
    });

    test('上限为 0 表示不限制（不删除）', () async {
      final file = await writeFile(
          '${tempRoot.path}/audio_cache', 'big', 2 * 1024 * 1024);
      await service.setAudioMaxMb(0);
      expect(await file.exists(), isTrue);
    });
  });

  group('封面策略 sweep', () {
    test('过期文件被删除；未过期按数量 LRU 淘汰', () async {
      await writeFile('${tempRoot.path}/artwork_cache', 'stale.jpg', 10,
          age: const Duration(days: 400));
      await writeFile('${tempRoot.path}/artwork_cache', 'keep1.jpg', 10,
          age: const Duration(days: 1));
      await writeFile('${tempRoot.path}/artwork_cache', 'keep2.jpg', 10,
          age: const Duration(hours: 1));

      // staleDays=365 → 删 stale；maxObjects=1 → 再删最旧的 keep1。
      await service.setArtworkStaleDays(365);
      await service.setArtworkMaxObjects(1);
      await service.enforceArtworkPolicy();

      final remaining = Directory('${tempRoot.path}/artwork_cache')
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .toList();
      expect(remaining, ['keep2.jpg']);
    });

    test('staleDays=0 且 maxObjects=0 不删除', () async {
      final old = await writeFile('${tempRoot.path}/artwork_cache', 'old.jpg', 10,
          age: const Duration(days: 999));
      await service.setArtworkStaleDays(0);
      await service.setArtworkMaxObjects(0);
      await service.enforceArtworkPolicy();
      expect(await old.exists(), isTrue);
    });
  });

  group('audioCacheKey', () {
    test('默认 quality=auto，特殊字符替换且带哈希后缀', () {
      final key = CacheService.audioCacheKey(
        sourceKey: 'lx',
        songId: 'lx:abc/1',
      );
      expect(key, startsWith('lx_lx_abc_1_auto_'));
      expect(key.contains(':'), isFalse);
      expect(key.contains('/'), isFalse);

      expect(
        CacheService.audioCacheKey(sourceKey: 'wy', songId: '123'),
        'wy_123_auto',
      );
      expect(
        CacheService.audioCacheKey(
            sourceKey: 'wy', songId: '123', quality: '320k'),
        'wy_123_320k',
      );
      expect(
        CacheService.audioCacheKey(
            sourceKey: 'wy', songId: '123', quality: '  '),
        'wy_123_auto',
      );
    });

    test('不同原始 key 不会因替换字符而碰撞', () {
      final a = CacheService.audioCacheKey(sourceKey: 's', songId: 'a:b');
      final b = CacheService.audioCacheKey(sourceKey: 's', songId: 'a_b');
      expect(a, isNot(b));
    });
  });
}
