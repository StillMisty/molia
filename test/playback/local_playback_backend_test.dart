import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/mapping/track_mapper.dart';
import 'package:molia/data/playback/local_playback_backend.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/music_source.dart' show PlayableStream;
import 'package:molia/models/play_mode.dart';
import 'package:molia/playback/local_playback_service.dart';
import 'package:molia/sources/source_track.dart';

/// 覆写状态的假服务：不触碰 just_audio 平台通道，只验证 backend 的映射/委托。
class _FakeService extends LocalPlaybackService {
  _FakeService()
      : super(
          resolver: (track, {String? quality}) async => 'http://127.0.0.1/a.wav',
        );

  final List<SourceTrack> _queue = [];
  int _index = -1;
  bool _playing = false;
  final bool _loading = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _error;
  PlayMode _mode = PlayMode.sequential;
  String? _contextName;

  int playTracksCalls = 0;
  int playQueueIndexCalls = 0;
  int stopCalls = 0;
  final List<String> calls = [];

  @override
  bool get hasTrack => _index >= 0 && _index < _queue.length;

  @override
  bool get isPlaying => _playing;

  @override
  bool get isLoading => _loading;

  @override
  PlayMode get mode => _mode;

  @override
  String? get lastError => _error;

  @override
  SourceTrack? get currentSourceTrack => hasTrack ? _queue[_index] : null;

  @override
  Duration get position => _position;

  @override
  Duration get duration => _duration;

  @override
  List<SourceTrack> get queueTracks => List.unmodifiable(_queue);

  @override
  int get currentIndex => _index;

  @override
  Map<String, dynamic>? get currentTrackMap {
    if (!hasTrack) return null;
    return {
      'context': {
        'type': 'lx',
        'name': _contextName ?? '',
        'uri': 'lx:${_contextName ?? ''}',
      },
    };
  }

  void seed(
    List<SourceTrack> tracks, {
    int index = 0,
    String? contextName,
    bool playing = true,
    Duration duration = Duration.zero,
    Duration position = Duration.zero,
    String? error,
  }) {
    _queue
      ..clear()
      ..addAll(tracks);
    _index = index;
    _contextName = contextName;
    _playing = playing;
    _duration = duration;
    _position = position;
    _error = error;
    notifyListeners();
  }

  void change({bool? playing, Duration? position, String? error}) {
    if (playing != null) _playing = playing;
    if (position != null) _position = position;
    if (error != null) _error = error;
    notifyListeners();
  }

  @override
  Future<void> playTracks(
    List<SourceTrack> tracks,
    int index, {
    String? contextName,
  }) async {
    playTracksCalls++;
    calls.add('playTracks');
    seed(
      tracks,
      index: index.clamp(0, tracks.length - 1),
      contextName: contextName,
    );
  }

  @override
  Future<void> playQueueIndex(int index) async {
    playQueueIndexCalls++;
    calls.add('playQueueIndex');
    _index = index;
    notifyListeners();
  }

  @override
  Future<void> toggle() async {
    calls.add('toggle');
    _playing = !_playing;
    notifyListeners();
  }

  @override
  Future<void> seek(Duration position) async {
    calls.add('seek');
    _position = position;
    notifyListeners();
  }

  @override
  Future<void> skipToNext() async => calls.add('next');

  @override
  Future<void> skipToPrevious() async => calls.add('previous');

  @override
  Future<void> setMode(PlayMode mode) async {
    calls.add('setMode');
    _mode = mode;
    notifyListeners();
  }

  @override
  Future<void> stop({bool clear = true}) async {
    stopCalls++;
    calls.add('stop');
    _index = -1;
    _queue.clear();
    _playing = false;
    notifyListeners();
  }
}

SourceTrack _source(String id, {String title = 'Title'}) => SourceTrack(
      sourceKey: 'fake',
      origin: 'lx',
      title: title,
      artist: 'Artist',
      album: 'Album',
      coverUrl: 'https://img.example/$id.jpg',
      duration: const Duration(seconds: 30),
      raw: {'id': id, 'extra': 'raw-$id'},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeService service;
  late LocalPlaybackBackend backend;

  setUp(() {
    service = _FakeService();
    backend = LocalPlaybackBackend(
      service: service,
      resolver: (track, quality) async => PlayableStream(
        Uri.parse('http://127.0.0.1/${track.id.id}.wav'),
      ),
    );
  });

  tearDown(() {
    backend.dispose();
    service.dispose();
  });

  test('状态映射：current/queue/upcoming/duration/context/error', () {
    final a = _source('a');
    final b = _source('b');
    service.seed(
      [a, b],
      index: 0,
      contextName: '集成测试',
      playing: true,
      duration: const Duration(seconds: 42),
      error: 'LxEngineException: 音源不可用',
    );

    final snapshot = backend.state.value;
    expect(snapshot.current?.id, const TrackId('fake', 'a'));
    expect(snapshot.queue, hasLength(2));
    expect(snapshot.currentIndex, 0);
    expect(snapshot.upcoming.map((t) => t.id.id), ['b']);
    expect(snapshot.isPlaying, isTrue);
    expect(snapshot.duration, const Duration(seconds: 42));
    expect(snapshot.context?.name, '集成测试');
    expect(snapshot.error?.kind, FailureKind.scriptError);
    expect(backend.kind, PlaybackBackendKind.local);
    expect(backend.canHandle(snapshot.current!), isTrue);
  });

  test('state 值未变不发；变化才发', () {
    final a = _source('a');
    var notifies = 0;
    backend.state.addListener(() => notifies++);

    service.seed([a], index: 0, playing: true);
    expect(notifies, 1);

    // 相同值（仅重新 notify）→ backend 快照相等，不发。
    service.change();
    expect(notifies, 1);

    // position 变化属于后端快照（facade 负责拆分高频通道）。
    service.change(position: const Duration(seconds: 1));
    expect(notifies, 2);
  });

  test('load 委托 playTracks 且 raw 原样回传', () async {
    final domainA = trackFromSourceTrack(_source('a'));
    final domainB = trackFromSourceTrack(_source('b'));

    await backend.load(PlaybackRequest(
      tracks: [domainA, domainB],
      startIndex: 1,
      context: const PlaybackContext(name: 'ctx', type: 'lx', uri: 'lx:ctx'),
    ));

    expect(service.playTracksCalls, 1);
    expect(service.currentSourceTrack?.id, 'fake:b');
    expect(service.currentSourceTrack?.title, 'Title');
    expect(identical(service.currentSourceTrack?.raw, domainB.payload), isTrue,
        reason: 'raw 必须原样回传');
    expect(backend.state.value.context?.name, 'ctx');
  });

  test('解析器端口：SourceTrack → Track → PlayableStream', () async {
    final stream = await backend.resolveLegacyUrl(_source('a'), quality: '320k');
    expect(stream, 'http://127.0.0.1/a.wav');
    final streamNoQuality = await backend.resolveStream(
      trackFromSourceTrack(_source('b')),
    );
    expect(streamNoQuality.uri.path, '/b.wav');
  });

  test('控制委托：play/pause/seek/next/previous/setMode/stop/queueIndex',
      () async {
    final a = _source('a');
    final b = _source('b');
    service.seed([a, b], index: 0, playing: false);

    await backend.play();
    expect(service.calls.last, 'toggle');
    expect(backend.state.value.isPlaying, isTrue);

    await backend.pause();
    expect(service.calls.last, 'toggle');
    expect(backend.state.value.isPlaying, isFalse);

    await backend.seek(const Duration(seconds: 3));
    expect(service.calls.last, 'seek');
    expect(backend.state.value.position, const Duration(seconds: 3));

    await backend.next();
    expect(service.calls.last, 'next');
    await backend.previous();
    expect(service.calls.last, 'previous');

    await backend.setMode(PlayMode.shuffle);
    expect(service.calls.last, 'setMode');
    expect(backend.state.value.mode, PlayMode.shuffle);

    await backend.playQueueIndex(1);
    expect(service.playQueueIndexCalls, 1);
    expect(backend.state.value.currentIndex, 1);

    await backend.stop();
    expect(service.stopCalls, 1);
    expect(backend.state.value.current, isNull);
  });

  test('可选能力：toggleFavorite / setVolume 抛 unsupported', () async {
    final track = trackFromSourceTrack(_source('a'));
    await expectLater(
      backend.toggleFavorite(track),
      throwsA(isA<SourceFailure>()
          .having((f) => f.kind, 'kind', FailureKind.unsupported)),
    );
    await expectLater(
      backend.setVolume(0.5),
      throwsA(isA<SourceFailure>()
          .having((f) => f.kind, 'kind', FailureKind.unsupported)),
    );
  });
}
