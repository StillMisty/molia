import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/mapping/track_mapper.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/services/audio_cache_store.dart';
import 'package:molia/services/cache_storage_io.dart';

import '../support/memory_cache_storage.dart';

import 'package:molia/services/cache_types.dart';
import 'package:molia/sources/source_track.dart';

/// 音频缓存目录约定：命名 / 完整性 / 索引 / 命中 / 清扫。
///
/// 只经 [AudioCacheStore] 的接口断言；文件系统用临时目录的真实 IO 实现
/// （无文件系统场景用空实现），命中探测注入真实的存在性判断。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late IoCacheStorage storage;
  late AudioCacheStore store;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('audio_cache_store_test_');
    storage = IoCacheStorage(
      audioDirOverride: '${tempRoot.path}/audio_cache',
      artworkDirOverride: '${tempRoot.path}/artwork_cache',
    );
    store = AudioCacheStore(storage: storage);
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  /// 现算而不是缓存：临时目录每个用例重建。
  String audioDir() => '${tempRoot.path}/audio_cache';

  Future<File> writeFile(
    String name,
    int sizeBytes, {
    Duration age = const Duration(days: 1),
  }) async {
    final file = File('${audioDir()}/$name');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List<int>.filled(sizeBytes, 0));
    await file.setLastModified(DateTime.now().subtract(age));
    return file;
  }

  Future<bool> fileExists(String path) => File(path).exists();

  Future<List<String>> namesIn(String dir) async {
    final names = Directory(dir)
        .listSync()
        .whereType<File>()
        .map((file) => file.uri.pathSegments.last)
        .toList();
    names.sort();
    return names;
  }

  Track track({
    String sourceKey = 'kw',
    String id = 'a',
    List<AudioQuality> qualities = const [],
  }) =>
      Track(
        id: TrackId(sourceKey, id),
        title: 'Title $id',
        origin: TrackOrigin.lx,
        qualities: qualities,
        payload: const {},
      );

  group('命名', () {
    test('key 默认 quality=auto，特殊字符替换且带哈希后缀（不碰撞）', () {
      expect(
        AudioCacheStore.key(sourceKey: 'wy', songId: '123'),
        'wy_123_auto',
      );
      expect(
        AudioCacheStore.key(sourceKey: 'wy', songId: '123', quality: '320k'),
        'wy_123_320k',
      );
      expect(
        AudioCacheStore.key(sourceKey: 'wy', songId: '123', quality: '  '),
        'wy_123_auto',
      );

      final special = AudioCacheStore.key(sourceKey: 'lx', songId: 'lx:abc/1');
      expect(special, startsWith('lx_lx_abc_1_auto_'));
      expect(special.contains(':'), isFalse);
      expect(special.contains('/'), isFalse);
      // 替换前后不同的原串不会映射到同一文件名。
      expect(
        AudioCacheStore.key(sourceKey: 's', songId: 'a:b'),
        isNot(AudioCacheStore.key(sourceKey: 's', songId: 'a_b')),
      );
    });

    test('keyPrefix 与 key 同源：文件名以前缀开头（含哈希后缀路径）', () {
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

    test('keyForSource 与 keyForTrack 同名：复合曲目 id 不写进文件名', () {
      // 播放侧只有 SourceTrack，页面侧只有领域 Track；两边必须落在同一文件名上。
      final sourceTrack = SourceTrack(
        sourceKey: 'kw',
        origin: 'builtin',
        title: 'Song',
        artist: 'Singer',
        album: 'Album',
        qualities: const [SourceQuality(type: '320k')],
        raw: const {'songmid': 'a'},
      );
      final domain = trackFromSourceTrack(sourceTrack);

      final written = AudioCacheStore.keyForSource(
        sourceTrack,
        quality: '320k',
      );
      expect(AudioCacheStore.keyForTrack(domain, quality: '320k'), written);
      // 旧命名（把 `SourceTrack.id` 当 songId）会写出带冒号的文件名。
      expect(written.contains(':'), isFalse);
      expect(
        AudioCacheStore.keyPrefixForTrack(domain),
        AudioCacheStore.keyPrefix(sourceKey: 'kw', songId: 'a'),
      );
    });

    test('isCompleteFileName 排除 .part / .predl / .mime（大小写不敏感）', () {
      expect(AudioCacheStore.isCompleteFileName('kw_1_320k'), isTrue);
      expect(AudioCacheStore.isCompleteFileName('kw_1_320k.mp3'), isTrue);
      for (final suffix in [
        audioCachePartSuffix,
        audioCachePredownloadSuffix,
        audioCacheMimeSuffix,
      ]) {
        expect(AudioCacheStore.isCompleteFileName('kw_1_320k$suffix'), isFalse);
        expect(
          AudioCacheStore.isCompleteFileName(
            'kw_1_320k${suffix.toUpperCase()}',
          ),
          isFalse,
        );
      }
    });
  });

  group('索引与占用', () {
    test('files 保留原始列举；index 只含完整文件', () async {
      final complete = AudioCacheStore.key(
        sourceKey: 'kw',
        songId: '9',
        quality: '320k',
      );
      await writeFile(complete, 400);
      await writeFile('$complete$audioCachePartSuffix', 900);
      await writeFile('$complete$audioCacheMimeSuffix', 7);
      await writeFile('kw_9_flac$audioCachePredownloadSuffix', 500);

      expect(await store.files(), {
        complete: 400,
        '$complete$audioCachePartSuffix': 900,
        '$complete$audioCacheMimeSuffix': 7,
        'kw_9_flac$audioCachePredownloadSuffix': 500,
      });
      expect(await store.index(), {complete: 400});
    });

    test('usageForTrack 只算完整文件；writingUsageForTrack 只算半成品 / 边车', () async {
      final complete = AudioCacheStore.key(
        sourceKey: 'kw',
        songId: '9',
        quality: '320k',
      );
      await writeFile(complete, 400);
      await writeFile('$complete$audioCachePartSuffix', 900);
      await writeFile('$complete$audioCacheMimeSuffix', 7);
      await writeFile('kw_9_flac$audioCachePredownloadSuffix', 500);

      expect(
        await store.usageForTrack(sourceKey: 'kw', songId: '9'),
        const CacheUsage(bytes: 400, count: 1),
      );
      expect(
        await store.writingUsageForTrack(sourceKey: 'kw', songId: '9'),
        const CacheUsage(bytes: 1407, count: 3),
      );
      expect(
        await store.usageForTrack(sourceKey: 'kw', songId: 'other'),
        CacheUsage.zero,
      );
    });

    test('目录不可用（无文件系统）：空表与 zero', () async {
      final noFs = AudioCacheStore(storage: MemoryCacheStorage());
      expect(await noFs.directoryPath(), isNull);
      expect(await noFs.files(), isEmpty);
      expect(await noFs.index(), isEmpty);
      expect(
        await noFs.usageForTrack(sourceKey: 'kw', songId: 'a'),
        CacheUsage.zero,
      );
      expect(await noFs.cleanupPartials(), 0);
      expect(
        await noFs.clearForTrack(sourceKey: 'kw', songId: 'a'),
        const CacheDeleteResult(),
      );
    });
  });

  group('命中', () {
    test('完整文件命中；同名 .part 说明还没落成，不算命中', () async {
      final t = track(qualities: const [AudioQuality(type: '320k')]);
      final name = AudioCacheStore.keyForTrack(t, quality: '320k');

      expect(
        await store.hitPathForTrack(t, quality: '320k', fileExists: fileExists),
        isNull,
      );

      await writeFile(name, 400);
      expect(
        await store.hitPathForTrack(t, quality: '320k', fileExists: fileExists),
        '${audioDir()}/$name',
      );

      // 另一个音质没有文件：不串音质命中。
      expect(
        await store.hitPathForTrack(t, quality: 'flac', fileExists: fileExists),
        isNull,
      );

      await writeFile('$name$audioCachePartSuffix', 900);
      expect(
        await store.hitPathForTrack(t, quality: '320k', fileExists: fileExists),
        isNull,
      );
    });

    test('.mime 边车只是元数据，不阻止命中', () async {
      final t = track(qualities: const [AudioQuality(type: '320k')]);
      final name = AudioCacheStore.keyForTrack(t, quality: '320k');
      await writeFile(name, 400);
      await writeFile('$name$audioCacheMimeSuffix', 7);

      expect(
        await store.hitPathForTrack(t, quality: '320k', fileExists: fileExists),
        '${audioDir()}/$name',
      );
    });

    test('存在性走注入的文件系统视图（缓存栈之外的存储也能判命中）', () async {
      final t = track(qualities: const [AudioQuality(type: '320k')]);
      final name = AudioCacheStore.keyForTrack(t, quality: '320k');
      final probed = <String>[];
      Future<bool> probe(String path) async {
        probed.add(path);
        return path == '${audioDir()}/$name';
      }

      expect(
        await store.hitPathForTrack(t, quality: '320k', fileExists: probe),
        '${audioDir()}/$name',
      );
      expect(probed, [
        '${audioDir()}/$name',
        '${audioDir()}/$name$audioCachePartSuffix',
      ]);
    });

    test('目录不可用（无文件系统）：一律不命中', () async {
      final noFs = AudioCacheStore(storage: MemoryCacheStorage());
      final t = track(qualities: const [AudioQuality(type: '320k')]);
      expect(
        await noFs.hitPathForTrack(t, quality: '320k', fileExists: fileExists),
        isNull,
      );
    });
  });

  group('按曲目的已缓存音质', () {
    test('按曲目音质顺序去重，只认有内容的完整文件', () {
      final t = track(
        qualities: const [
          AudioQuality(type: '320k'),
          AudioQuality(type: '320k'),
          AudioQuality(type: ''),
          AudioQuality(type: 'flac'),
          AudioQuality(type: '128k'),
        ],
      );
      final index = {
        AudioCacheStore.keyForTrack(t, quality: '320k'): 400,
        // 空文件不算命中。
        AudioCacheStore.keyForTrack(t, quality: 'flac'): 0,
      };

      expect(AudioCacheStore.cachedQualitiesForTrack(t, index), ['320k']);
    });

    test('原始列举（含 .part）不算命中：未落成的文件不可离线播', () {
      final t = track(qualities: const [AudioQuality(type: '320k')]);
      final name = AudioCacheStore.keyForTrack(t, quality: '320k');

      expect(
        AudioCacheStore.cachedQualitiesForTrack(t, {
          name: 400,
          '$name$audioCachePartSuffix': 900,
        }),
        isEmpty,
      );
    });
  });

  group('清扫与单曲清理', () {
    test('cleanupPartials 删 .part / .predl，保留完整文件与 .mime 边车', () async {
      final complete = AudioCacheStore.key(
        sourceKey: 'kw',
        songId: '9',
        quality: '320k',
      );
      await writeFile(complete, 400);
      await writeFile('$complete$audioCachePartSuffix', 900);
      await writeFile('$complete$audioCacheMimeSuffix', 7);
      await writeFile('kw_9_flac$audioCachePredownloadSuffix', 500);

      expect(await store.cleanupPartials(), 2);
      expect(
        await namesIn(audioDir()),
        [complete, '$complete$audioCacheMimeSuffix']..sort(),
      );
    });

    test('clearForTrack 清同曲目所有音质变体，不误伤其它曲目', () async {
      final t = track();
      final key320 = AudioCacheStore.keyForTrack(t, quality: '320k');
      final keyFlac = AudioCacheStore.keyForTrack(t, quality: 'flac');
      final other = AudioCacheStore.key(sourceKey: 'kw', songId: 'b');
      await writeFile(key320, 100);
      await writeFile(keyFlac, 200);
      await writeFile(other, 400);

      final result = await store.clearForTrack(sourceKey: 'kw', songId: 'a');
      expect(result.deleted, const CacheUsage(bytes: 300, count: 2));
      expect(result.skipped, 0);
      expect(await namesIn(audioDir()), [other]);
    });

    test('protectAge 内修改的文件（正在写入）跳过并计数', () async {
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
      await writeFile(writing, 100, age: Duration.zero);
      await writeFile(idle, 200);

      final result = await store.clearForTrack(
        sourceKey: 'kg',
        songId: '7',
        protectAge: const Duration(hours: 1),
      );
      expect(result.deleted, const CacheUsage(bytes: 200, count: 1));
      expect(result.skipped, 1);
      expect(await namesIn(audioDir()), [writing]);
    });
  });
}
