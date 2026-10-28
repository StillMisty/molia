import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/ports/music_source.dart' show PlayableStream;
import 'package:molia/playback/audio_predownload.dart';
import 'package:molia/playback/audio_predownloader.dart';
import 'package:molia/playback/next_track_preloader.dart';
import 'package:molia/services/audio_cache_store.dart';
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

  final AudioPredownloadTask? Function(
      SourceTrack track, PlayableStream stream)? onCall;
  final List<(String trackId, PlayableStream stream, String? quality)> calls =
      [];

  @override
  Future<AudioPredownloadTask?> predownload({
    required SourceTrack track,
    required PlayableStream stream,
    String? quality,
  }) async {
    calls.add((track.id, stream, quality));
    return onCall?.call(track, stream);
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
  Future<Map<String, int>> listFiles(String dirPath) async => const {};

  @override
  Future<int> deleteWhere(
    String dirPath, {
    required bool Function(String fileName) test,
  }) async =>
      0;

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
  Future<CacheSweepResult> sweepArtwork(
    String dirPath, {
    required int maxObjects,
    required int staleDays,
  }) async =>
      CacheSweepResult.failed;
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
          return PlayableStream(
            Uri.parse('https://cdn.example/${track.id}.mp3'),
          );
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

    test('后台禁止字节预取：直链仍预热，预下载器不启动', () async {
      final resolved = <String>[];
      final downloader = _RecordingPredownloader();
      final preloader = NextTrackPreloader(
        resolver: (track, {quality}) async {
          resolved.add(track.id);
          return PlayableStream(
            Uri.parse('https://cdn.example/x.mp3'),
          );
        },
        predownloader: downloader,
        canPredownloadBytes: () => false,
      );

      await preloader.preload(_track('b'));

      expect(resolved, ['wy:b'], reason: '切歌时的取链仍要命中缓存');
      expect(downloader.calls, isEmpty, reason: '后台不再下载整首下一曲');
    });

    test('解析成功后把直链交给预下载器（同音质）', () async {
      final downloader = _RecordingPredownloader();
      final preloader = NextTrackPreloader(
        resolver: (track, {quality}) async => PlayableStream(
          Uri.parse('https://cdn.example/x.mp3'),
        ),
        preferredQuality: () => '320k',
        predownloader: downloader,
      );

      await preloader.preload(_track('b', qualities: const [
        SourceQuality(type: '320k'),
      ]));

      expect(downloader.calls, hasLength(1));
      expect(downloader.calls.single.$2.uri.toString(),
          'https://cdn.example/x.mp3');
      expect(downloader.calls.single.$3, '320k');
    });

    test('headers 原样交给预下载器（B 站直链依赖 Referer）', () async {
      const headers = {
        'Referer': 'https://www.bilibili.com/',
        'User-Agent': 'Mozilla/5.0',
      };
      final downloader = _RecordingPredownloader();
      final preloader = NextTrackPreloader(
        resolver: (track, {quality}) async => PlayableStream(
          Uri.parse('https://cdn.example/x.m4a'),
          headers: headers,
        ),
        predownloader: downloader,
      );

      await preloader.preload(_track('b'));

      expect(downloader.calls.single.$2.headers, headers);
    });

    test('解析失败静默（不抛出）', () async {
      final preloader = NextTrackPreloader(
        resolver: (track, {quality}) async => throw StateError('boom'),
      );

      await preloader.preload(_track('b'));
    });

    test('取消后的在途解析不再启动预取', () async {
      final completer = Completer<PlayableStream>();
      final downloader = _RecordingPredownloader();
      final preloader = NextTrackPreloader(
        resolver: (track, {quality}) => completer.future,
        predownloader: downloader,
      );

      final loading = preloader.preload(_track('b'));
      preloader.cancelPending();
      completer.complete(
        PlayableStream(Uri.parse('https://cdn.example/x.mp3')),
      );
      await loading;

      expect(downloader.calls, isEmpty);
    });

    test('新请求取消旧的预取任务，旧结果作废', () async {
      final cancelled = <String>[];
      final downloader = _RecordingPredownloader(
        onCall: (track, stream) => AudioPredownloadTask(
          done: Completer<void>().future,
          onCancel: () => cancelled.add(track.id),
        ),
      );
      final preloader = NextTrackPreloader(
        resolver: (track, {quality}) async => PlayableStream(
          Uri.parse('https://cdn.example/x.mp3'),
        ),
        predownloader: downloader,
      );

      await preloader.preload(_track('a'));
      await preloader.preload(_track('b'));

      expect(cancelled, ['wy:a']);
    });
  });

  group('预取所有权（起播前）', () {
    test('桌面：目标匹配时保留在途任务，不取消', () async {
      final cancelled = <String>[];
      final downloader = _RecordingPredownloader(
        onCall: (track, stream) => AudioPredownloadTask(
          done: Completer<void>().future,
          onCancel: () => cancelled.add(track.id),
        ),
      );
      final preloader = NextTrackPreloader(
        resolver: (track, {quality}) async => PlayableStream(
          Uri.parse('https://cdn.example/${track.id}.mp3'),
        ),
        predownloader: downloader,
      );

      final track = _track('b');
      await preloader.preload(track);
      expect(preloader.targetTrackId, track.id);
      expect(preloader.hasPendingTask, isTrue);

      final reused = preloader.retainForPlayback(
        track,
        reuseInFlight: true,
      );

      expect(reused, isTrue);
      expect(cancelled, isEmpty);
      expect(preloader.targetTrackId, isNull, reason: '投机目标已提升为当前曲目');
      expect(preloader.isCacheWriteInFlight(track), isTrue);
    });

    test('桌面：目标不匹配时取消未完成的预取', () async {
      final cancelled = <String>[];
      final downloader = _RecordingPredownloader(
        onCall: (track, stream) => AudioPredownloadTask(
          done: Completer<void>().future,
          onCancel: () => cancelled.add(track.id),
        ),
      );
      final preloader = NextTrackPreloader(
        resolver: (track, {quality}) async => PlayableStream(
          Uri.parse('https://cdn.example/${track.id}.mp3'),
        ),
        predownloader: downloader,
      );

      final trackA = _track('a');
      await preloader.preload(trackA);
      final reused = preloader.retainForPlayback(
        _track('b'),
        reuseInFlight: true,
      );

      expect(reused, isFalse);
      expect(cancelled, [trackA.id]);
      expect(preloader.targetTrackId, isNull);
      expect(preloader.isCacheWriteInFlight(trackA), isFalse);
    });

    test('移动端：即使目标匹配也在起播前取消（避免与边播边缓存双写）', () async {
      final cancelled = <String>[];
      final downloader = _RecordingPredownloader(
        onCall: (track, stream) => AudioPredownloadTask(
          done: Completer<void>().future,
          onCancel: () => cancelled.add(track.id),
        ),
      );
      final preloader = NextTrackPreloader(
        resolver: (track, {quality}) async => PlayableStream(
          Uri.parse('https://cdn.example/${track.id}.mp3'),
        ),
        predownloader: downloader,
      );

      final track = _track('b');
      await preloader.preload(track);
      final reused = preloader.retainForPlayback(
        track,
        reuseInFlight: false,
      );

      expect(reused, isFalse);
      expect(cancelled, [track.id]);
      expect(preloader.isCacheWriteInFlight(track), isFalse);
    });

    test('桌面：保留当前曲目写入后，继续预取下一首不取消它', () async {
      final cancelled = <String>[];
      final downloader = _RecordingPredownloader(
        onCall: (track, stream) => AudioPredownloadTask(
          done: Completer<void>().future,
          onCancel: () => cancelled.add(track.id),
        ),
      );
      final preloader = NextTrackPreloader(
        resolver: (track, {quality}) async => PlayableStream(
          Uri.parse('https://cdn.example/${track.id}.mp3'),
        ),
        predownloader: downloader,
      );

      final trackB = _track('b');
      final trackC = _track('c');
      await preloader.preload(trackB);
      expect(
        preloader.retainForPlayback(trackB, reuseInFlight: true),
        isTrue,
      );

      await preloader.preload(trackC);

      expect(cancelled, isEmpty, reason: '当前曲目的写入不能被下一首预取取消');
      expect(preloader.targetTrackId, trackC.id);
      expect(preloader.isCacheWriteInFlight(trackB), isTrue);
      expect(
        downloader.calls.map((call) => call.$1),
        [trackB.id, trackC.id],
      );
    });

    test('桌面：取链途中切到该曲目，提升后仍会启动预下载', () async {
      final resolved = Completer<PlayableStream>();
      final downloader = _RecordingPredownloader(
        onCall: (track, stream) => AudioPredownloadTask(
          done: Completer<void>().future,
          onCancel: () {},
        ),
      );
      final preloader = NextTrackPreloader(
        resolver: (track, {quality}) => resolved.future,
        predownloader: downloader,
      );

      final track = _track('a');
      final loading = preloader.preload(track);
      // 取链尚未返回时用户就切到了这一首。
      expect(
        preloader.retainForPlayback(track, reuseInFlight: true),
        isTrue,
      );
      expect(preloader.isCacheWriteInFlight(track), isTrue);

      resolved.complete(
        PlayableStream(Uri.parse('https://cdn.example/a.mp3')),
      );
      await loading;

      expect(downloader.calls, hasLength(1));
      expect(preloader.hasPendingTask, isTrue);
    });

    test('任务落位后释放所有权，下一次起播可以重新起 writer', () async {
      final done = Completer<void>();
      final downloader = _RecordingPredownloader(
        onCall: (track, stream) => AudioPredownloadTask(
          done: done.future,
          onCancel: () {},
        ),
      );
      final preloader = NextTrackPreloader(
        resolver: (track, {quality}) async => PlayableStream(
          Uri.parse('https://cdn.example/${track.id}.mp3'),
        ),
        predownloader: downloader,
      );

      final track = _track('a');
      await preloader.preload(track);
      expect(
        preloader.retainForPlayback(track, reuseInFlight: true),
        isTrue,
      );

      done.complete();
      await Future<void>.delayed(Duration.zero);

      expect(preloader.isCacheWriteInFlight(track), isFalse);
      expect(
        preloader.retainForPlayback(track, reuseInFlight: true),
        isFalse,
        reason: '任务结束后不再占用写入所有权',
      );
    });

    test('预下载器跳过时不占用缓存写入所有权', () async {
      final downloader = _RecordingPredownloader(
        onCall: (track, stream) => null,
      );
      final preloader = NextTrackPreloader(
        resolver: (track, {quality}) async => PlayableStream(
          Uri.parse('https://cdn.example/${track.id}.mp3'),
        ),
        predownloader: downloader,
      );

      final track = _track('a');
      await preloader.preload(track);

      expect(preloader.isCacheWriteInFlight(track), isFalse);
      expect(
        preloader.retainForPlayback(track, reuseInFlight: true),
        isFalse,
      );
    });

    test('当前曲目写入在途时，重复预取同一目标不再启动第二份', () async {
      final downloader = _RecordingPredownloader(
        onCall: (track, stream) => AudioPredownloadTask(
          done: Completer<void>().future,
          onCancel: () {},
        ),
      );
      final preloader = NextTrackPreloader(
        resolver: (track, {quality}) async => PlayableStream(
          Uri.parse('https://cdn.example/${track.id}.mp3'),
        ),
        predownloader: downloader,
      );

      final track = _track('a');
      await preloader.preload(track);
      expect(
        preloader.retainForPlayback(track, reuseInFlight: true),
        isTrue,
      );

      await preloader.preload(track);

      expect(downloader.calls, hasLength(1));
    });
  });

  group('CacheAudioPredownloader', () {
    test('非 http(s) / m3u8 直链直接跳过', () async {
      final started = <String>[];
      final downloader = CacheAudioPredownloader(
        cacheService: CacheService(storage: _FakeCacheStorage()),
        platformSupported: () => true,
        starter: ({required uri, required targetPath, headers}) {
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
          stream: PlayableStream(Uri.parse('file:///tmp/a.mp3')),
        ),
        isNull,
      );
      expect(
        await downloader.predownload(
          track: _track('a'),
          stream: PlayableStream(Uri.parse('https://cdn.example/live.m3u8')),
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
        Map<String, String>? headers,
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
          stream: PlayableStream(Uri.parse('https://cdn.example/a.mp3')),
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
          stream: PlayableStream(Uri.parse('https://cdn.example/a.mp3')),
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
          stream: PlayableStream(Uri.parse('https://cdn.example/a.mp3')),
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
        starter: ({required uri, required targetPath, headers}) {
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
        stream: PlayableStream(Uri.parse('https://cdn.example/b.mp3')),
        quality: '320k',
      );
      expect(task, isNotNull);
      expect(started, hasLength(1));
      expect(
        started.single,
        p.join(
          '/tmp/molia_audio',
          AudioCacheStore.keyForSource(track, quality: '320k'),
        ),
      );

      completer.complete();
      await task!.done;
      await Future<void>.delayed(Duration.zero);
      expect(storage.enforceCalls, 1);
    });

    test('headers 透传给预取启动器；空 headers 归为 null', () async {
      final storage = _FakeCacheStorage(audioDir: '/tmp/molia_audio');
      final captured = <Map<String, String>?>[];
      final downloader = CacheAudioPredownloader(
        cacheService: CacheService(storage: storage),
        platformSupported: () => true,
        starter: ({required uri, required targetPath, headers}) {
          captured.add(headers);
          return AudioPredownloadTask(
            done: Completer<void>().future,
            onCancel: () {},
          );
        },
      );

      await downloader.predownload(
        track: _track('a'),
        stream: PlayableStream(
          Uri.parse('https://cdn.example/a.m4a'),
          headers: {'Referer': 'https://www.bilibili.com/'},
        ),
      );
      await downloader.predownload(
        track: _track('b'),
        stream: PlayableStream(Uri.parse('https://cdn.example/b.m4a')),
      );

      expect(captured, [
        {'Referer': 'https://www.bilibili.com/'},
        null,
      ]);
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

    test('请求头带到预取请求（B 站 Referer 不能丢）', () async {
      final dir = await Directory.systemTemp.createTemp('molia_predownload');
      addTearDown(() => dir.delete(recursive: true));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final received = Completer<HttpHeaders>();
      server.listen((request) {
        received.complete(request.headers);
        request.response
          ..headers.contentType = ContentType.binary
          ..add(const [1]);
        request.response.close();
      });

      final target = p.join(dir.path, 'headers.m4a');
      final task = startAudioPredownload(
        uri: Uri.parse('http://127.0.0.1:${server.port}/headers.m4a'),
        targetPath: target,
        headers: const {
          'Referer': 'https://www.bilibili.com/',
          'User-Agent': 'Mozilla/5.0',
        },
      );
      expect(task, isNotNull);
      await task!.done;

      final headers = await received.future;
      expect(headers.value('referer'), 'https://www.bilibili.com/');
      expect(headers.value('user-agent'), 'Mozilla/5.0');
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
