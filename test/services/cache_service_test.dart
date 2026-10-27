import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/audio_cache_store.dart';
import 'package:molia/services/cache_service.dart';
import 'package:molia/services/cache_storage_io.dart';

import '../support/memory_cache_storage.dart';

import 'package:shared_preferences/shared_preferences.dart';

/// 固定设备容量的存储假件：容量可控，其余委托真实 IO 实现（指向临时目录）。
class _FixedSpaceStorage extends IoCacheStorage {
  _FixedSpaceStorage(this.totalBytes, {required String root})
      : super(
          audioDirOverride: '$root/audio_cache',
          artworkDirOverride: '$root/artwork_cache',
        );

  final int? totalBytes;

  @override
  Future<int?> totalSpaceBytes() async => totalBytes;
}

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

  Future<File> writeFile(
    String dir,
    String name,
    int sizeBytes, {
    Duration age = const Duration(days: 1),
  }) async {
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

  group('设备容量建议默认值', () {
    test('缺键默认上限 = 设备容量/128，下限 256MB', () async {
      // 256GB 设备 → 2048MB。
      final big = CacheService(
        prefs: prefs,
        storage: _FixedSpaceStorage(
          256 * 1024 * 1024 * 1024,
          root: tempRoot.path,
        ),
      );
      expect(await big.suggestedAudioMaxMb(), 2048);
      expect(await big.audioMaxMb(), 2048);

      // 8GB 设备 → 64MB，低于下限 → 256MB。
      final small = CacheService(
        prefs: prefs,
        storage: _FixedSpaceStorage(
          8 * 1024 * 1024 * 1024,
          root: tempRoot.path,
        ),
      );
      expect(
        await small.suggestedAudioMaxMb(),
        CacheService.audioMaxSuggestionFloorMb,
      );
      expect(await small.audioMaxMb(), CacheService.audioMaxSuggestionFloorMb);
    });

    test('容量不可知：建议为 null，缺键回退固定默认值', () async {
      final unknown = CacheService(
        prefs: prefs,
        storage: _FixedSpaceStorage(null, root: tempRoot.path),
      );
      expect(await unknown.suggestedAudioMaxMb(), isNull);
      expect(await unknown.audioMaxMb(), CacheService.defaultAudioMaxMb);
    });

    test('已写入的值优先于设备容量建议', () async {
      await prefs.setInt(CacheService.keyAudioMaxMb, 64);
      final service = CacheService(
        prefs: prefs,
        storage: _FixedSpaceStorage(
          512 * 1024 * 1024 * 1024,
          root: tempRoot.path,
        ),
      );
      expect(await service.audioMaxMb(), 64);
    });
  });

  group('usage / clear', () {
    test('音频/封面按目录递归统计字节与文件数', () async {
      await writeFile('${tempRoot.path}/audio_cache', 'a.part', 100);
      await writeFile('${tempRoot.path}/audio_cache', 'b', 250);
      // 缓存目录可能分桶（封面常见）：嵌套文件同样计入。
      await writeFile('${tempRoot.path}/audio_cache/nested', 'c', 50);
      await writeFile('${tempRoot.path}/artwork_cache', 'c.jpg', 300);

      final audio = await service.usage(CachePartition.audio);
      expect(audio.bytes, 400);
      expect(audio.count, 3);

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
      final oldest = await writeFile(
        '${tempRoot.path}/audio_cache',
        'oldest',
        size,
      );
      final middle = await writeFile(
        '${tempRoot.path}/audio_cache',
        'middle',
        size,
        age: const Duration(hours: 12),
      );
      final newest = await writeFile(
        '${tempRoot.path}/audio_cache',
        'newest',
        size,
        age: const Duration(minutes: 1),
      );

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
      await writeFile(
        '${tempRoot.path}/audio_cache',
        'active',
        600 * 1024,
        age: Duration.zero,
      );
      await writeFile(
        '${tempRoot.path}/audio_cache',
        'idle',
        600 * 1024,
        age: const Duration(days: 2),
      );

      await active.setAudioMaxMb(1);
      expect(File('${tempRoot.path}/audio_cache/active').existsSync(), isTrue);
      expect(File('${tempRoot.path}/audio_cache/idle').existsSync(), isFalse);
    });

    test('上限为 0 表示不限制（不删除）', () async {
      final file = await writeFile(
        '${tempRoot.path}/audio_cache',
        'big',
        2 * 1024 * 1024,
      );
      await service.setAudioMaxMb(0);
      expect(await file.exists(), isTrue);
    });
  });

  group('封面策略 sweep', () {
    test('staleDays=0 且 maxObjects=0 不删除，并回报存活文件', () async {
      final old = await writeFile(
        '${tempRoot.path}/artwork_cache',
        'old.jpg',
        10,
        age: const Duration(days: 999),
      );
      await service.setArtworkStaleDays(0);
      await service.setArtworkMaxObjects(0);
      final result = await service.enforceArtworkPolicy();
      expect(result.deleted, 0);
      expect(result.remainingRelativePaths, {'old.jpg'});
      expect(await old.exists(), isTrue);
    });

    test('目录不可用：返回 failed（remaining 为 null）', () async {
      final unavailable = CacheService(
        prefs: prefs,
        storage: MemoryCacheStorage(),
      );
      final result = await unavailable.enforceArtworkPolicy();
      expect(result.deleted, 0);
      expect(result.remainingRelativePaths, isNull);
    });
  });

  group('单曲缓存（音频 / 歌词）', () {
    test('按曲目前缀统计与清理：命中所有音质变体，不误伤其它曲目', () async {
      final audioDir = '${tempRoot.path}/audio_cache';
      final sameTrack320 = AudioCacheStore.key(
        sourceKey: 'wy',
        songId: '123',
        quality: '320k',
      );
      final sameTrackFlac = AudioCacheStore.key(
        sourceKey: 'wy',
        songId: '123',
        quality: 'flac',
      );
      final otherTrack = AudioCacheStore.key(
        sourceKey: 'wy',
        songId: '1234',
        quality: '320k',
      );
      // 特殊字符走哈希后缀路径：前缀匹配同样成立。
      final specialKey = AudioCacheStore.key(
        sourceKey: 'lx',
        songId: 'lx:abc/1',
        quality: '128k',
      );
      await writeFile(audioDir, sameTrack320, 100);
      await writeFile(audioDir, sameTrackFlac, 200);
      await writeFile(audioDir, otherTrack, 400);
      await writeFile(audioDir, specialKey, 300);

      expect(
        await service.audioUsageForTrack(sourceKey: 'wy', songId: '123'),
        const CacheUsage(bytes: 300, count: 2),
      );
      expect(
        await service.audioUsageForTrack(sourceKey: 'lx', songId: 'lx:abc/1'),
        const CacheUsage(bytes: 300, count: 1),
      );

      final result = await service.clearAudioForTrack(
        sourceKey: 'wy',
        songId: '123',
      );
      expect(result.deleted, const CacheUsage(bytes: 300, count: 2));
      expect(result.skipped, 0);
      expect(File('$audioDir/$sameTrack320').existsSync(), isFalse);
      expect(File('$audioDir/$otherTrack').existsSync(), isTrue);
      expect(File('$audioDir/$specialKey').existsSync(), isTrue);
      expect(
        await service.audioUsageForTrack(sourceKey: 'wy', songId: '123'),
        CacheUsage.zero,
      );
    });

    test('正在写入（protectAge 内修改）的文件跳过并计数', () async {
      final active = CacheService(
        prefs: prefs,
        storage: storage,
        audioProtectAge: const Duration(hours: 1),
      );
      final writing = AudioCacheStore.key(
        sourceKey: 'kg',
        songId: '7',
        quality: '320k',
      );
      final idle = AudioCacheStore.key(
        sourceKey: 'kg',
        songId: '7',
        quality: '128k',
      );
      await writeFile(
        '${tempRoot.path}/audio_cache',
        writing,
        100,
        age: Duration.zero,
      );
      await writeFile(
        '${tempRoot.path}/audio_cache',
        idle,
        200,
        age: const Duration(days: 1),
      );

      final result = await active.clearAudioForTrack(
        sourceKey: 'kg',
        songId: '7',
      );
      expect(result.deleted, const CacheUsage(bytes: 200, count: 1));
      expect(result.skipped, 1);
      expect(
        File('${tempRoot.path}/audio_cache/$writing').existsSync(),
        isTrue,
      );
      expect(File('${tempRoot.path}/audio_cache/$idle').existsSync(), isFalse);
    });

    test('无缓存 / 无目录（无文件系统）：zero 与空结果', () async {
      expect(
        await service.audioUsageForTrack(sourceKey: 'kw', songId: 'missing'),
        CacheUsage.zero,
      );
      expect(
        await service.clearAudioForTrack(sourceKey: 'kw', songId: 'missing'),
        const CacheDeleteResult(),
      );

      final noFs = CacheService(prefs: prefs, storage: MemoryCacheStorage());
      expect(
        await noFs.audioUsageForTrack(sourceKey: 'kw', songId: 'x'),
        CacheUsage.zero,
      );
      expect(
        (await noFs.clearAudioForTrack(sourceKey: 'kw', songId: 'x')).deleted,
        CacheUsage.zero,
      );
    });

    test('歌词：单曲占用与清理（只动该曲目的规范键）', () async {
      await prefs.setString(
        '${CacheService.lyricsCacheKeyPrefix}wy:1',
        jsonEncode({'provider': 'netease', 'lyric': '歌词', 'ts': 1}),
      );
      await prefs.setString('${CacheService.lyricsCacheKeyPrefix}wy:2', '{}');

      final usage = await service.lyricsUsageForTrack('wy:1');
      expect(usage.count, 1);
      expect(usage.bytes, greaterThan(0));

      await service.clearLyricsForTrack('wy:1');
      expect(await service.lyricsUsageForTrack('wy:1'), CacheUsage.zero);
      expect(
        prefs.getString('${CacheService.lyricsCacheKeyPrefix}wy:2'),
        isNotNull,
      );
    });

    test('AudioCacheStore.keyPrefix 与 key 同源（文件名以它开头）', () {
      for (final songId in ['123', 'lx:abc/1']) {
        final prefix = AudioCacheStore.keyPrefix(
          sourceKey: 'lx',
          songId: songId,
        );
        for (final quality in ['auto', '320k', 'flac24bit']) {
          expect(
            AudioCacheStore.key(
              sourceKey: 'lx',
              songId: songId,
              quality: quality,
            ),
            startsWith(prefix),
          );
        }
      }
    });

    test('索引 / 占用只认完整文件：半成品与边车不计入', () async {
      final audioDir = '${tempRoot.path}/audio_cache';
      final complete = AudioCacheStore.key(
        sourceKey: 'kw',
        songId: '9',
        quality: '320k',
      );
      await writeFile(audioDir, complete, 400);
      await writeFile(audioDir, '$complete$audioCachePartSuffix', 900);
      await writeFile(audioDir, '$complete$audioCacheMimeSuffix', 7);
      await writeFile(audioDir, 'kw_9_flac$audioCachePredownloadSuffix', 500);

      expect(await service.audioCacheIndex(), {complete: 400});
      expect(
        await service.audioUsageForTrack(sourceKey: 'kw', songId: '9'),
        const CacheUsage(bytes: 400, count: 1),
      );
      expect(
        await service.audioWritingUsageForTrack(sourceKey: 'kw', songId: '9'),
        const CacheUsage(bytes: 1407, count: 3),
      );
    });

    test('启动清扫半成品：删 .part / .predl，保留完整文件与 .mime 边车', () async {
      final audioDir = '${tempRoot.path}/audio_cache';
      final complete = AudioCacheStore.key(
        sourceKey: 'kw',
        songId: '9',
        quality: '320k',
      );
      await writeFile(audioDir, complete, 400);
      await writeFile(audioDir, '$complete$audioCachePartSuffix', 900);
      await writeFile(audioDir, '$complete$audioCacheMimeSuffix', 7);
      await writeFile(audioDir, 'kw_9_flac$audioCachePredownloadSuffix', 500);

      expect(await service.cleanupAudioPartials(), 2);
      final remaining = Directory(audioDir)
          .listSync()
          .whereType<File>()
          .map((file) => file.uri.pathSegments.last)
          .toList()
        ..sort();
      expect(remaining, [complete, '$complete$audioCacheMimeSuffix']..sort());
    });
  });

  group('AudioCacheStore.key', () {});
}
