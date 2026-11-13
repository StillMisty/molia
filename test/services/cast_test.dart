import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/cast.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/cast_ports.dart';
import 'package:molia/domain/ports/music_source.dart';
import 'package:molia/services/cast/car_browse_tree.dart';
import 'package:molia/services/cast/cast_session_controller.dart';
import 'package:molia/services/cast/local_media_server.dart';

class _FakeDiscovery implements CastDiscovery {
  _FakeDiscovery(this.devices);

  List<CastDevice> devices;
  int stopCalls = 0;

  @override
  Future<List<CastDevice>> discover() async => devices;

  @override
  Future<void> stop() async => stopCalls++;
}

class _FakeTransport implements CastTransport {
  final List<String> calls = [];
  final List<CastMedia> played = [];
  CastRemoteState pollResult = const CastRemoteState();
  Completer<CastRemoteState>? pollGate;

  @override
  Future<void> connect(CastDevice device) async =>
      calls.add('connect:${device.id}');

  @override
  Future<void> play(CastMedia media) async {
    calls.add('play:${media.uri}');
    played.add(media);
  }

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> resume() async => calls.add('resume');

  @override
  Future<void> seek(Duration position) async =>
      calls.add('seek:${position.inMilliseconds}');

  @override
  Future<CastRemoteState> poll() async {
    calls.add('poll');
    final gate = pollGate;
    if (gate != null) return gate.future;
    return pollResult;
  }

  @override
  Future<void> stop() async => calls.add('stop');
}

class _FakePlayback implements CastPlaybackPort {
  int pauseCalls = 0;
  CastCandidate? next;
  int nextCalls = 0;

  @override
  Future<void> pauseForCast() async => pauseCalls++;

  @override
  Future<CastCandidate?> nextMedia() async {
    nextCalls++;
    return next;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CastSourcePolicy', () {
    CastSource local() => CastSource(
      origin: TrackOrigin.localFile,
      localFileUri: Uri.file('/music/a.flac'),
    );
    CastSource stream({
      Map<String, String> headers = const {},
      Duration? expires,
    }) => CastSource(
      origin: TrackOrigin.builtin,
      stream: PlayableStream(
        Uri.parse('https://example.com/a.mp3'),
        headers: headers,
        expiresIn: expires,
      ),
    );

    test('本地 / 下载曲目合格', () {
      expect(CastSourcePolicy.evaluate(local()).isEligible, isTrue);
      expect(
        CastSourcePolicy.evaluate(
          CastSource(
            origin: TrackOrigin.builtin,
            downloaded: true,
            localFileUri: Uri.file('/cache/a.mp3'),
          ),
        ).isEligible,
        isTrue,
      );
      expect(
        CastSourcePolicy.evaluate(CastSource(origin: TrackOrigin.localFile))
            .reason,
        CastRejectionReason.missingLocalFile,
      );
    });

    test('带请求头（B 站）按策略拒绝', () {
      expect(
        CastSourcePolicy.evaluate(
          stream(headers: {'Referer': 'https://www.bilibili.com'}),
        ).reason,
        CastRejectionReason.headersRequired,
      );
    });

    test('剩余有效期不足 10 分钟拒绝，无过期或足够长合格', () {
      expect(
        CastSourcePolicy.evaluate(stream(expires: const Duration(minutes: 9)))
            .reason,
        CastRejectionReason.shortLived,
      );
      expect(
        CastSourcePolicy.evaluate(stream(expires: const Duration(minutes: 10)))
            .isEligible,
        isTrue,
      );
      expect(CastSourcePolicy.evaluate(stream()).isEligible, isTrue);
      expect(
        CastSourcePolicy.evaluate(
          CastSource(
            origin: TrackOrigin.builtin,
            stream: PlayableStream(Uri.parse('file:///a.mp3')),
          ),
        ).reason,
        CastRejectionReason.unsupportedScheme,
      );
    });
  });

  group('CastSessionController', () {
    late _FakeDiscovery discovery;
    late _FakeTransport transport;
    late _FakePlayback playback;
    late List<CastNotice> notices;
    late CastSessionController controller;

    const device = CastDevice(id: 'r1', name: 'Living room');

    setUp(() {
      discovery = _FakeDiscovery([device]);
      transport = _FakeTransport();
      playback = _FakePlayback();
      notices = [];
      controller = CastSessionController(
        discovery: discovery,
        transport: transport,
        playback: playback,
        onNotice: notices.add,
      );
    });

    tearDown(() => controller.dispose());

    CastCandidate localCandidate({String id = 'a'}) => CastCandidate(
      media: CastMedia(
        title: 'Song $id',
        uri: Uri.parse('http://127.0.0.1:9999/m/t/$id'),
      ),
      source: CastSource(
        origin: TrackOrigin.localFile,
        localFileUri: Uri.file('/music/$id.flac'),
      ),
    );

    test('发现 → 连接 → 投屏只暂停本地一次', () async {
      expect(await controller.discover(), [device]);
      expect(controller.state, CastSessionState.idle);
      await controller.connect(device);
      expect(controller.state, CastSessionState.connected);
      await controller.cast(localCandidate());
      expect(playback.pauseCalls, 1);
      expect(transport.played, hasLength(1));
      expect(controller.current?.title, 'Song a');
      await controller.cast(localCandidate(id: 'b'));
      expect(playback.pauseCalls, 1, reason: '同一会话只暂停本地一次');
    });

    test('下一首重新做来源判定；不合格不碰远端', () async {
      await controller.discover();
      await controller.connect(device);
      await controller.cast(localCandidate());
      playback.next = CastCandidate(
        media: CastMedia(title: 'Bili', uri: Uri.parse('https://bili/a.m4a')),
        source: CastSource(
          origin: TrackOrigin.builtin,
          stream: PlayableStream(
            Uri.parse('https://bili/a.m4a'),
            headers: {'Referer': 'https://www.bilibili.com'},
          ),
        ),
      );
      final plays = transport.played.length;
      await controller.next();
      expect(transport.played.length, plays);
      expect(controller.lastRejection, CastRejectionReason.headersRequired);
      expect(notices.last, CastNotice.sourceRejected);
    });

    test('命令串行；过期轮询不覆盖新命令', () async {
      await controller.discover();
      await controller.connect(device);
      await controller.cast(localCandidate());
      transport.calls.clear();

      final gate = Completer<CastRemoteState>();
      transport.pollGate = gate;
      final polling = controller.poll();
      await Future<void>.delayed(Duration.zero);
      final seeking = controller.seek(const Duration(seconds: 30));
      await seeking;
      gate.complete(
        const CastRemoteState(position: Duration(seconds: 1), isPlaying: true),
      );
      await polling;
      expect(controller.remote.position, const Duration(seconds: 30));
      expect(transport.calls, ['poll', 'seek:30000']);

      transport.pollGate = null;
      unawaited(controller.pause());
      unawaited(controller.resume());
      unawaited(controller.seek(const Duration(seconds: 5)));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(transport.calls.where((call) => call != 'poll'), [
        'seek:30000',
        'pause',
        'resume',
        'seek:5000',
      ]);
    });

    test('断开停远端、只提示一次、不恢复本地', () async {
      await controller.discover();
      await controller.connect(device);
      await controller.cast(localCandidate());
      notices.clear();
      await controller.disconnect();
      expect(controller.state, CastSessionState.idle);
      expect(transport.calls.last, 'stop');
      expect(notices, [CastNotice.disconnected]);
      expect(controller.localPaused, isFalse);
      // CastPlaybackPort 没有 resume：编译期即保证不会自动恢复本地音频。
    });
  });

  group('CarBrowseTreeBuilder', () {
    const tracks = [
      CarTrack(stableId: 'kw:1', title: 'One'),
      CarTrack(stableId: 'kw:2', title: 'Two'),
    ];

    test('空集合也保留四个根', () {
      final roots = CarBrowseTreeBuilder.build(
        queue: const [],
        favorites: const [],
        recent: const [],
        playlists: const [],
      );
      expect(roots.map((node) => node.id), [
        'queue',
        'favorites',
        'recent',
        'playlists',
      ]);
      expect(roots.every((node) => node.children.isEmpty), isTrue);
    });

    test('队列叶子映射真实下标，收藏 / 最近 / 歌单动作稳定', () {
      final roots = CarBrowseTreeBuilder.build(
        queue: tracks,
        favorites: [tracks.first],
        recent: [tracks.last],
        playlists: const [CarPlaylist(id: 7, name: 'Road', tracks: tracks)],
      );
      final queue = roots.first;
      expect(queue.children[1].id, 'queue:1');
      expect(queue.children[1].queueIndex, 1);
      final queueAction = CarBrowseTreeBuilder.actionFor(queue.children[1]);
      expect(queueAction?.kind, CarPlayActionKind.queueIndex);
      expect(queueAction?.queueIndex, 1);

      final favorite = roots[1].children.single;
      expect(favorite.id, 'favorite:kw:1');
      expect(CarBrowseTreeBuilder.actionFor(favorite)?.trackId, 'kw:1');

      final playlist = roots[3].children.single;
      expect(playlist.id, 'playlist:7');
      expect(playlist.children[1].id, 'playlist:7:1');
      final action = CarBrowseTreeBuilder.actionFor(playlist.children[1]);
      expect(action?.kind, CarPlayActionKind.playlistTrack);
      expect(action?.playlistId, 7);
      expect(action?.queueIndex, 1);
      expect(CarBrowseTreeBuilder.actionFor(playlist), isNull);
    });
  });

  group('LocalMediaServer', () {
    late Directory dir;
    late File file;
    late LocalMediaServer server;
    late HttpClient client;
    HttpOverrides? previous;

    setUp(() async {
      previous = HttpOverrides.current;
      HttpOverrides.global = null;
      dir = await Directory.systemTemp.createTemp('molia_cast_');
      file = File('${dir.path}/song.mp3');
      await file.writeAsBytes(List<int>.generate(10, (i) => 65 + i));
      server = LocalMediaServer(bindAddress: InternetAddress.loopbackIPv4);
      await server.start(files: {'song': file});
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await server.stop();
      await dir.delete(recursive: true);
      HttpOverrides.global = previous;
    });

    Future<(int, List<int>, HttpHeaders)> get(Uri uri) async {
      final request = await client.getUrl(uri);
      final response = await request.close();
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
      }
      return (response.statusCode, bytes, response.headers);
    }

    test('完整请求、Range 与 HEAD', () async {
      final uri = server.uriFor('song')!;
      final (status, bytes, headers) = await get(uri);
      expect(status, 200);
      expect(bytes, List<int>.generate(10, (i) => 65 + i));
      expect(headers.contentType?.mimeType, 'audio/mpeg');

      final (rangeStatus, rangeBytes, rangeHeaders) = await get(
        uri.replace(queryParameters: {}),
      );
      expect(rangeStatus, 200);
      expect(rangeBytes, bytes);

      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=2-4');
      final response = await request.close();
      final ranged = <int>[];
      await for (final chunk in response) {
        ranged.addAll(chunk);
      }
      expect(response.statusCode, 206);
      expect(ranged, [67, 68, 69]);
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 2-4/10',
      );
      expect(response.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');

      final head = await client.headUrl(uri);
      final headResponse = await head.close();
      expect(headResponse.statusCode, 200);
      expect(headResponse.contentLength, 10);
      await headResponse.drain<void>();
    });

    test('错误令牌 / 未登记 / 路径穿越都是 404', () async {
      final base = server.uriFor('song')!;
      final wrongToken = base.replace(pathSegments: ['m', 'wrong', 'song']);
      expect((await get(wrongToken)).$1, 404);
      final unknown = base.replace(
        pathSegments: ['m', base.pathSegments[1], 'other'],
      );
      expect((await get(unknown)).$1, 404);
      final traversal = base.replace(
        pathSegments: ['m', base.pathSegments[1], '..', 'song'],
      );
      expect((await get(traversal)).$1, 404);
      final root = base.replace(pathSegments: const ['m']);
      expect((await get(root)).$1, 404);
    });

    test('结束后地址失效', () async {
      final uri = server.uriFor('song')!;
      await server.stop();
      expect(server.uriFor('song'), isNull);
      await expectLater(get(uri), throwsA(isA<SocketException>()));
    });
  });
}
