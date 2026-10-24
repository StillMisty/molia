import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/mapping/track_mapper.dart';
import 'package:molia/data/playback/local_playback_backend.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/music_source.dart' show PlayableStream;
import 'package:molia/models/play_mode.dart';
import 'package:molia/playback/local_playback_service.dart';
import 'package:molia/playback/queue_projection.dart';
import 'package:molia/sources/source_track.dart';

/// 覆写状态的假服务：不触碰 just_audio 平台通道，只验证 backend 的映射/委托。
class _FakeService extends LocalPlaybackService {
  _FakeService()
      : super(
          resolver: (track, {String? quality}) async =>
              PlayableStream(Uri.parse('http://127.0.0.1/a.wav')),
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

  /// 队列内容版本号：与真实服务同口径，只在队列内容变更时自增。
  int _queueRevision = 0;

  /// 当前洗牌排列（仅在 shuffle 模式下参与投影）。
  List<int>? _shuffleIndices;

  /// 播放顺序栈的最近一首（投影 previous 优先读它）。
  int? _previousIndex;

  /// `queueProjection` 的求值次数：用来钉住「一次快照只求一次投影」。
  int projectionBuilds = 0;

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
  int get queueRevision => _queueRevision;

  @override
  String? get contextName => _contextName;

  /// 与真实服务同源（`projectQueue`）；旧实现覆写三个 getter 各自算一份，
  /// 生产侧改用一次性投影后由本 getter 统一供数。
  @override
  QueueProjection<SourceTrack> get queueProjection {
    projectionBuilds++;
    return projectQueue(
      _queue,
      currentIndex: _index,
      mode: _mode,
      order: QueueOrder(
        shuffleIndices: _mode == PlayMode.shuffle ? _shuffleIndices : null,
        previousIndex: _previousIndex,
      ),
      idOf: (track) => track.id,
    );
  }

  void seed(
    List<SourceTrack> tracks, {
    int index = 0,
    String? contextName,
    bool playing = true,
    Duration duration = Duration.zero,
    Duration position = Duration.zero,
    String? error,
    PlayMode? mode,
    List<int>? shuffleIndices,
    int? previousIndex,
  }) {
    _queue
      ..clear()
      ..addAll(tracks);
    _queueRevision++;
    _index = index;
    _contextName = contextName;
    _playing = playing;
    _duration = duration;
    _position = position;
    _error = error;
    if (mode != null) _mode = mode;
    _shuffleIndices = shuffleIndices;
    _previousIndex = previousIndex;
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
    _queueRevision++;
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
    _queueRevision++;
    _playing = false;
    notifyListeners();
  }

  /// 换源：记录并原地替换（模拟真实服务按 id 全量命中）。
  final Map<String, SourceTrack> replacedTracks = {};

  @override
  Future<void> replaceQueueTrack(String trackId, SourceTrack track) async {
    calls.add('replaceQueueTrack');
    replacedTracks[trackId] = track;
    var hit = false;
    for (var i = 0; i < _queue.length; i++) {
      if (_queue[i].id == trackId) {
        _queue[i] = track;
        hit = true;
      }
    }
    if (!hit) return;
    _queueRevision++;
    notifyListeners();
  }

  /// 补图：与真实服务同口径，封面真变了才替换并自增版本号。
  @override
  void updateTrackArtwork(String trackId, String? coverUrl) {
    final index = _queue.indexWhere((track) => track.id == trackId);
    if (index < 0) return;
    final old = _queue[index];
    final next = (coverUrl == null || coverUrl.isEmpty) ? null : coverUrl;
    if (old.coverUrl == next) return;
    _queue[index] = old.copyWith(coverUrl: next);
    _queueRevision++;
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

  test('next/previous/upNext 与投影一致：线性模式', () {
    service.seed(
      [_source('a'), _source('b'), _source('c')],
      index: 1,
      mode: PlayMode.sequential,
    );

    var snapshot = backend.state.value;
    expect(snapshot.next?.id.id, 'c');
    expect(snapshot.previous?.id.id, 'a');
    expect(snapshot.upNext.map((t) => t.id.id), ['c']);

    // 列表循环队尾：下一首回绕队首，upNext 补上队首到当前之前。
    service.seed(
      [_source('a'), _source('b'), _source('c')],
      index: 2,
      mode: PlayMode.listLoop,
    );
    snapshot = backend.state.value;
    expect(snapshot.next?.id.id, 'a');
    expect(snapshot.previous?.id.id, 'b');
    expect(snapshot.upNext.map((t) => t.id.id), ['a', 'b']);
  });

  test('next/previous/upNext 与投影一致：shuffle 排列与轮末', () {
    final a = _source('a');
    final b = _source('b');
    final c = _source('c');

    // 排列 [c, a, b]，当前 a：下一首 b，队列前一位不是「上一首」。
    service.seed(
      [a, b, c],
      index: 0,
      mode: PlayMode.shuffle,
      shuffleIndices: const [2, 0, 1],
    );
    var snapshot = backend.state.value;
    expect(snapshot.next?.id.id, 'b');
    expect(snapshot.previous, isNull);
    expect(snapshot.upNext.map((t) => t.id.id), ['b']);

    // 轮末：peek 不重洗，next / upNext 为空。
    service.seed(
      [a, b, c],
      index: 1,
      mode: PlayMode.shuffle,
      shuffleIndices: const [2, 0, 1],
    );
    snapshot = backend.state.value;
    expect(snapshot.next, isNull);
    expect(snapshot.previous?.id.id, 'a');
    expect(snapshot.upNext, isEmpty);

    // 播放顺序栈优先于队列前一位。
    service.seed(
      [a, b, c],
      index: 1,
      mode: PlayMode.sequential,
      previousIndex: 2,
    );
    expect(backend.state.value.previous?.id.id, 'c');
  });

  test('一次快照只求一次队列投影', () {
    service.seed([_source('a'), _source('b'), _source('c')], index: 1);

    service.projectionBuilds = 0;
    service.change(position: const Duration(seconds: 2));

    expect(service.projectionBuilds, 1);
    expect(backend.state.value.position, const Duration(seconds: 2));
  });

  test('队列映射按 queueRevision 复用：位置 / 播放态变化不重建', () {
    service.seed([_source('a'), _source('b')], index: 0);

    final initial = backend.state.value.queue;
    expect(initial, hasLength(2));

    service.change(playing: false, position: const Duration(seconds: 1));

    final afterTick = backend.state.value;
    expect(afterTick.isPlaying, isFalse);
    expect(afterTick.position, const Duration(seconds: 1));
    expect(identical(afterTick.queue, initial), isTrue, reason: '队列未变应复用');
    expect(identical(afterTick.queue[0], initial[0]), isTrue);
  });

  test('queueRevision 变更使队列映射失效', () async {
    service.seed([_source('a'), _source('b')], index: 0);
    final initial = backend.state.value.queue;

    // 追加：队列内容变化 → 重新映射。
    await backend.enqueueTracks([trackFromSourceTrack(_source('c'))]);
    final appended = backend.state.value.queue;
    expect(appended.map((t) => t.id.id), ['a', 'b', 'c']);
    expect(identical(appended, initial), isFalse);

    // 补图：原地替换同样自增版本号 → 新映射，封面更新。
    await backend.updateTrackArtwork(
      'fake:b',
      Uri.parse('https://img.example/b-new.jpg'),
    );
    final artwork = backend.state.value.queue;
    expect(identical(artwork, appended), isFalse);
    expect(artwork[1].artwork?.uri.toString(), 'https://img.example/b-new.jpg');

    // 换源：命中队列 → 失效并反映新曲目。
    await backend.replaceQueueTrack(
      'fake:b',
      trackFromSourceTrack(_source('b', title: '新版本')),
    );
    final replaced = backend.state.value.queue;
    expect(identical(replaced, artwork), isFalse);
    expect(replaced[1].title, '新版本');

    // 清空：停止后队列为空且不复用旧映射。
    await backend.stop();
    expect(backend.state.value.queue, isEmpty);
    expect(identical(backend.state.value.queue, replaced), isFalse);
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
