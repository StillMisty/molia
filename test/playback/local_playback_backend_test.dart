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
  String? get contextName => _contextName;

  @override
  SourceTrack? get nextSourceTrack {
    if (!hasTrack) return null;
    final next = _index + 1;
    return next < _queue.length ? _queue[next] : null;
  }

  @override
  SourceTrack? get previousSourceTrack {
    if (!hasTrack || _index <= 0) return null;
    return _queue[_index - 1];
  }

  @override
  List<SourceTrack> get upNextTracks {
    if (!hasTrack) return const [];
    return List.unmodifiable(_queue.sublist(_index + 1));
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

  final List<List<SourceTrack>> enqueued = [];

  @override
  Future<void> enqueueTracks(List<SourceTrack> tracks) async {
    calls.add('enqueueTracks');
    enqueued.add(List.of(tracks));
    _queue.addAll(tracks);
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

  final List<double> volumes = [];

  @override
  Future<void> setVolume(double volume) async {
    calls.add('setVolume');
    volumes.add(volume);
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

  /// 换源：记录并原地替换（模拟真实服务按 id 全量命中）。
  final Map<String, SourceTrack> replacedTracks = {};

  @override
  Future<void> replaceQueueTrack(String trackId, SourceTrack track) async {
    calls.add('replaceQueueTrack');
    replacedTracks[trackId] = track;
    for (var i = 0; i < _queue.length; i++) {
      if (_queue[i].id == trackId) _queue[i] = track;
    }
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

  test('enqueueTracks 转换后追加队列（快照队列增长，不打断当前）', () async {
    service.seed([_source('a')], index: 0, playing: true);
    final before = backend.state.value.queue.length;

    await backend.enqueueTracks([trackFromSourceTrack(_source('b'))]);

    expect(service.calls, contains('enqueueTracks'));
    expect(service.enqueued.single.single.id, 'fake:b');
    final snapshot = backend.state.value;
    expect(snapshot.queue.length, before + 1);
    expect(snapshot.queue.last.id.id, 'b');
    expect(snapshot.current?.id.id, 'a', reason: '当前曲目不变');
  });

  test('状态映射：current/queue/next/previous/upNext/duration/context/error', () {
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
    expect(snapshot.next?.id.id, 'b');
    expect(snapshot.upNext.map((t) => t.id.id), ['b']);
    expect(snapshot.previous, isNull);

    // 下标回退：previous 透传服务解析结果（当前在队尾时 next 为空）。
    service.seed([a, b], index: 1, playing: true);
    final atEnd = backend.state.value;
    expect(atEnd.previous?.id.id, 'a');
    expect(atEnd.next, isNull);
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

  test('stopAfterCurrentTrack：标志转发到服务', () {
    backend.setStopAfterCurrentTrack(true);
    expect(service.stopAfterCurrentTrack, isTrue);

    backend.setStopAfterCurrentTrack(false);
    expect(service.stopAfterCurrentTrack, isFalse);
  });

  test('replaceQueueTrack：转换后替换队列同 id 曲目（快照更新，当前不受影响）', () async {
    service.seed([_source('a'), _source('b')], index: 0, playing: true);
    final replacement = trackFromSourceTrack(_source('b', title: '新版本'));

    await backend.replaceQueueTrack('fake:b', replacement);

    expect(service.calls, contains('replaceQueueTrack'));
    expect(service.replacedTracks['fake:b']?.title, '新版本');
    final snapshot = backend.state.value;
    expect(snapshot.queue.map((t) => t.title), ['Title', '新版本']);
    expect(snapshot.queue.last.id, const TrackId('fake', 'b'));
    expect(snapshot.current?.id.id, 'a', reason: '未命中当前曲目时不重载');
  });

  test('setVolume 委托服务；能力位 volume 为真', () async {
    expect(backend.capabilities.volume, isTrue);
    await backend.setVolume(0.4);
    expect(service.calls, contains('setVolume'));
    expect(service.volumes, [0.4]);
  });

  test('可选能力：toggleFavorite 抛 unsupported', () async {
    final track = trackFromSourceTrack(_source('a'));
    await expectLater(
      backend.toggleFavorite(track),
      throwsA(isA<SourceFailure>()
          .having((f) => f.kind, 'kind', FailureKind.unsupported)),
    );
  });
}
