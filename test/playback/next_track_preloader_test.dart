import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/playback/audio_predownload.dart';
import 'package:molia/playback/audio_predownloader.dart';
import 'package:molia/playback/next_track_preloader.dart';
import 'package:molia/services/cache_service.dart';
import 'package:molia/services/cache_types.dart';
import 'package:molia/sources/source_track.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

SourceTrack _track(String id, {List<SourceQuality> qualities = const []}) =>
    SourceTrack(
      sourceKey: 'wy',
      origin: 'builtin',
      title: 'Song $id',
      artist: 'Artist',
      album: 'Album',
      qualities: qualities,
      raw: {'songId': id},
    );

/// 记录调用的假预下载器。
class _RecordingPredownloader implements AudioPredownloader {
  _RecordingPredownloader({this.onCall});

  final AudioPredownloadTask? Function(SourceTrack track, String url)? onCall;
  final List<(String trackId, String url, String? quality)> calls = [];

  @override
  Future<AudioPredownloadTask?> predownload({
    required SourceTrack track,
    required String url,
    String? quality,
  }) async {
    calls.add((track.id, url, quality));
    return onCall?.call(track, url);
  }
}

/// 假缓存存储：音频目录可控，其余空实现。
class _FakeCacheStorage implements CacheStorage {
  _FakeCacheStorage({this.audioDir = '/tmp/molia_audio_cache'});

  final String? audioDir;
  int enforceCalls = 0;

  @override
  Future<String?> audioCacheDir() async => audioDir;

  @override
  Future<String?> artworkCacheDir() async => null;

  @override
  Future<int?> totalSpaceBytes() async => null;

  @override
  Future<CacheUsage> usage(String dirPath) async => CacheUsage.zero;

  @override
  Future<CacheUsage> usageMatching(
    String dirPath, {
    required String prefix,
  }) async =>
      CacheUsage.zero;

  @override
  Future<CacheDeleteResult> deleteMatching(
    String dirPath, {
    required String prefix,
    Duration protectAge = Duration.zero,
  }) async =>
      const CacheDeleteResult();

  @override
  Future<void> clear(String dirPath) async {}

  @override
  Future<int> enforceAudioLimit(
    String dirPath, {
    required int maxBytes,
    required Duration protectAge,
  }) async {
    enforceCalls++;
    return 0;
  }

  @override
  Future<int> sweepArtwork(
    String dirPath, {
    required int maxObjects,
    required int staleDays,
  }) async =>
      0;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('NextTrackPreloader', () {
    test('预热下一首直链：与播放同源的音质选择', () async {
      final calls = <(String trackId, String? quality)>[];
      final preloader = NextTrackPreloader(
        resolver: (track, {quality}) async {
          calls.add((track.id, quality));
          return 'https://cdn.example/${track.id}.mp3';
        },
        preferredQuality: () => '128k',
      );

      await preloader.preload(_track('b', qualities: const [
        SourceQuality(type: '320k'),
        SourceQuality(type: '128k'),
      ]));

      expect(calls, hasLength(1));
      expect(calls.single.$2, '128k');
    });

    test('解析成功后把直链交给预下载器（同音质）', () async {
      final downloader = _RecordingPredownloader();
      final preloader = NextTrackPreloader(
        resolver: (track, {quality}) async => 'https://cdn.example/x.mp3',
        preferredQuality: () => '320k',
        predownloader: downloader,
      );

      await preloader.preload(_track('b', qualities: const [
        SourceQuality(type: '320k'),
      ]));

      expect(downloader.calls, hasLength(1));
      expect(downloader.calls.single.$2, 'https://cdn.example/x.mp3');
      expect(downloader.calls.single.$3, '320k');
    });

    test('解析失败静默（不抛出）', () async {
      final preloader = NextTrackPreloader(
        resolver: (track, {quality}) async => throw StateError('boom'),
      );

      await preloader.preload(_track('b'));
    });

    test('取消后的在途解析不再启动预取', () async {
      final completer = Completer<String>();
      final downloader = _RecordingPredownloader();
      final preloader = NextTrackPreloader(
        resolver: (track, {quality}) => completer.future,
        predownloader: downloader,
      );

      final loading = preloader.preload(_track('b'));
      preloader.cancelPending();
      completer.complete('https://cdn.example/x.mp3');
      await loading;

      expect(downloader.calls, isEmpty);
    });

    test('新请求取消旧的预取任务，旧结果作废', () async {
      final cancelled = <String>[];
      final downloader = _RecordingPredownloader(
        onCall: (track, url) => AudioPredownloadTask(
          done: Completer<void>().future,
          onCancel: () => cancelled.add(track.id),
        ),
      );
      final preloader = NextTrackPreloader(
        resolver: (track, {quality}) async => 'https://cdn.example/x.mp3',
        predownloader: downloader,
      );

      await preloader.preload(_track('a'));
      await preloader.preload(_track('b'));

      expect(cancelled, ['wy:a']);
    });
  });

  group('CacheAudioPredownloader', () {
    test('非 http(s) / m3u8 直链直接跳过', () async {
      final started = <String>[];
      final downloader = CacheAudioPredownloader(
        cacheService: CacheService(storage: _FakeCacheStorage()),
        platformSupported: () => true,
        starter: ({required uri, required targetPath}) {
          started.add(targetPath);
          return AudioPredownloadTask(
            done: Completer<void>().future,
            onCancel: () {},
          );
        },
      );

      expect(
        await downloader.predownload(
          track: _track('a'),
          url: 'file:///tmp/a.mp3',
        ),
        isNull,
      );
      expect(
        await downloader.predownload(
          track: _track('a'),
          url: 'https://cdn.example/live.m3u8',
        ),
        isNull,
      );
      expect(started, isEmpty);
    });

    test('策略不允许 / 平台不支持 / 缓存关闭时跳过', () async {
      final storage = _FakeCacheStorage();
      final started = <String>[];
      AudioPredownloadTask? starter({
        required Uri uri,
        required String targetPath,
      }) {
        started.add(targetPath);
        return AudioPredownloadTask(
          done: Completer<void>().future,
          onCancel: () {},
        );
      }

      final blocked = CacheAudioPredownloader(
        cacheService: CacheService(storage: storage),
        allowed: () => false,
        platformSupported: () => true,
        starter: starter,
      );
      expect(
        await blocked.predownload(
          track: _track('a'),
          url: 'https://cdn.example/a.mp3',
        ),
        isNull,
      );

      final unsupported = CacheAudioPredownloader(
        cacheService: CacheService(storage: storage),
        platformSupported: () => false,
        starter: starter,
      );
      expect(
        await unsupported.predownload(
          track: _track('a'),
          url: 'https://cdn.example/a.mp3',
        ),
        isNull,
      );

      SharedPreferences.setMockInitialValues(
        {CacheService.keyAudioEnabled: false},
      );
      final disabled = CacheAudioPredownloader(
        cacheService: CacheService(storage: storage),
        platformSupported: () => true,
        starter: starter,
      );
      expect(
        await disabled.predownload(
          track: _track('a'),
          url: 'https://cdn.example/a.mp3',
        ),
        isNull,
      );
      expect(started, isEmpty);
    });

    test('正常路径：目标为音频缓存键，完成后触发 LRU 淘汰', () async {
      final storage = _FakeCacheStorage(audioDir: '/tmp/molia_audio');
      final completer = Completer<void>();
      final started = <String>[];
      final downloader = CacheAudioPredownloader(
        cacheService: CacheService(storage: storage),
        platformSupported: () => true,
        starter: ({required uri, required targetPath}) {
          started.add(targetPath);
          return AudioPredownloadTask(
            done: completer.future,
            onCancel: () {},
          );
        },
      );

      final track = _track('b');
      final task = await downloader.predownload(
        track: track,
        url: 'https://cdn.example/b.mp3',
        quality: '320k',
      );
      expect(task, isNotNull);
      expect(started, hasLength(1));
      expect(
        started.single,
        p.join(
          '/tmp/molia_audio',
          CacheService.audioCacheKey(
            sourceKey: 'wy',
            songId: track.id,
            quality: '320k',
          ),
        ),
      );

      completer.complete();
      await task!.done;
      await Future<void>.delayed(Duration.zero);
      expect(storage.enforceCalls, 1);
    });
  });

  group('startAudioPredownload（IO）', () {
    test('流式下载完成后原子落位；已缓存则跳过', () async {
      final dir = await Directory.systemTemp.createTemp('molia_predownload');
      addTearDown(() => dir.delete(recursive: true));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        request.response
          ..headers.contentType = ContentType.binary
          ..add(const [1, 2, 3, 4]);
        request.response.close();
      });

      final target = p.join(dir.path, 'x.mp3');
      final uri = Uri.parse('http://127.0.0.1:${server.port}/x.mp3');

      final task = startAudioPredownload(uri: uri, targetPath: target);
      expect(task, isNotNull);
      await task!.done;

      expect(File(target).existsSync(), isTrue);
      expect(await File(target).readAsBytes(), const [1, 2, 3, 4]);
      expect(File('$target.predl').existsSync(), isFalse);

      // 已缓存：不再启动下载。
      expect(startAudioPredownload(uri: uri, targetPath: target), isNull);
    });

    test('HTTP 失败静默清理半成品', () async {
      final dir = await Directory.systemTemp.createTemp('molia_predownload');
      addTearDown(() => dir.delete(recursive: true));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        request.response.statusCode = HttpStatus.notFound;
        request.response.close();
      });

      final target = p.join(dir.path, 'y.mp3');
      final task = startAudioPredownload(
        uri: Uri.parse('http://127.0.0.1:${server.port}/y.mp3'),
        targetPath: target,
      );
      expect(task, isNotNull);
      await task!.done;

      expect(File(target).existsSync(), isFalse);
      expect(File('$target.predl').existsSync(), isFalse);
    });
  });
}
