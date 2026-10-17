/// 系统媒体控制（通知 / 锁屏 / 耳机键）的会话落盘与冷启动恢复。
///
/// 复现路径：系统控制暂停 → 冷启动；断言「存储」与「恢复」两端：
/// - 暂停 / 停止 / 切播放顺序这些**直接落到 LocalPlaybackService** 的控制动作，
///   返回时会话必须已经写回本地（`pendingWrite` 收口在会话协调者的
///   `flushSession`）；
/// - 冷启动（新 provider / 新后端，同一存储）恢复上一首 + 队列 + 模式 + 进度，
///   且 `isPlaying=false`（不自动起播）。
///
/// 装配与组合根 `buildPlaybackStack` 同构：真实 facade / 观察者 / 会话协调者 /
/// provider + 假服务（不触碰 just_audio），`LocalAudioHandler` 按组合根方式
/// 回填会话落盘。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/mapping/track_mapper.dart';
import 'package:molia/data/playback/default_playback_facade.dart';
import 'package:molia/data/playback/local_playback_backend.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/music_source.dart' show PlayableStream;
import 'package:molia/models/play_mode.dart';
import 'package:molia/playback/local_audio_handler.dart';
import 'package:molia/playback/local_playback_service.dart';
import 'package:molia/playback/playback_session_coordinator.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/playback_observer.dart';
import 'package:molia/services/playback_session_store.dart';
import 'package:molia/sources/source_track.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_media_session_backend.dart';
import '../support/fakes.dart';

SourceTrack _source(String id) => SourceTrack(
      sourceKey: 'fake',
      origin: 'builtin',
      title: 'Title $id',
      artist: 'Artist $id',
      album: 'Album $id',
      duration: const Duration(seconds: 30),
      raw: {'songmid': id},
    );

/// 只覆写状态的假服务（不触碰 just_audio 平台通道）：`toggle` / `toggleMode`
/// / `stop` 与真实服务同语义（改状态 + 通知；stop 清空队列）。
class _FakeService extends LocalPlaybackService {
  _FakeService()
      : super(
          resolver: (track, {String? quality}) async =>
              'http://127.0.0.1/a.wav',
        );

  final List<SourceTrack> _queue = [];
  int _index = -1;
  bool _playing = false;
  Duration _position = Duration.zero;
  PlayMode _mode = PlayMode.sequential;
  String? _contextName;

  int toggleCalls = 0;
  int toggleModeCalls = 0;
  int stopCalls = 0;

  @override
  bool get hasTrack => _index >= 0 && _index < _queue.length;

  @override
  bool get isPlaying => _playing;

  @override
  bool get isLoading => false;

  @override
  PlayMode get mode => _mode;

  @override
  String? get lastError => null;

  @override
  SourceTrack? get currentSourceTrack => hasTrack ? _queue[_index] : null;

  @override
  Duration get position => _position;

  @override
  Duration get duration => Duration.zero;

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
  List<SourceTrack> get upNextTracks {
    if (!hasTrack) return const [];
    return List.unmodifiable(_queue.sublist(_index + 1));
  }

  /// 起播（等价 `playTracks` 装载完成后的状态）。
  void seed(
    List<SourceTrack> tracks, {
    int index = 0,
    String? contextName,
    bool playing = true,
    Duration position = Duration.zero,
    PlayMode mode = PlayMode.sequential,
  }) {
    _queue
      ..clear()
      ..addAll(tracks);
    _index = index;
    _contextName = contextName;
    _playing = playing;
    _position = position;
    _mode = mode;
    notifyListeners();
  }

  /// 播放推进（位置 tick / 播放态变化），不触发观察者的强制落盘。
  void advance({Duration? position, bool? playing}) {
    if (position != null) _position = position;
    if (playing != null) _playing = playing;
    notifyListeners();
  }

  @override
  Future<void> toggle() async {
    toggleCalls++;
    if (!hasTrack) return;
    _playing = !_playing;
    notifyListeners();
  }

  @override
  Future<void> toggleMode() async {
    toggleModeCalls++;
    _mode = PlayMode.values[(_mode.index + 1) % PlayMode.values.length];
    notifyListeners();
  }

  @override
  Future<void> setMode(PlayMode mode) async {
    _mode = mode;
    notifyListeners();
  }

  @override
  Future<void> stop({bool clear = true}) async {
    stopCalls++;
    _playing = false;
    if (clear) {
      _queue.clear();
      _index = -1;
      _position = Duration.zero;
      _contextName = null;
    }
    notifyListeners();
  }
}

/// 组合根同构装配：假服务 ← 真实后端 / facade / 观察者 / provider + handler。
class _Harness {
  _Harness() {
    final backend = LocalPlaybackBackend(
      service: service,
      resolver: (track, quality) async =>
          PlayableStream(Uri.parse('http://127.0.0.1/a.wav')),
    );
    facade = DefaultPlaybackFacade(backend: backend);
    store = PlaybackSessionStore();
    observer = PlaybackObserver(facade: facade);
    session = PlaybackSessionCoordinator(
      facade: facade,
      store: store,
      onRestoredTrack: observer.showRestoredTrack,
    );
    provider = PlaybackProvider(
      facade: facade,
      messenger: FakeMessenger(),
      observer: observer,
      sessionCoordinator: session,
    );
    handler = LocalAudioHandler(service, backend: mediaBackend);
    // 与 `buildPlaybackStack` 同一接线：handler 建好后回填会话落盘。
    handler.attachSessionPersister(session.flushSession);
    observer.attach();
  }

  final _FakeService service = _FakeService();
  final FakeMediaSessionBackend mediaBackend = FakeMediaSessionBackend();
  late final DefaultPlaybackFacade facade;
  late final PlaybackSessionStore store;
  late final PlaybackObserver observer;
  late final PlaybackSessionCoordinator session;
  late final PlaybackProvider provider;
  late final LocalAudioHandler handler;

  void dispose() {
    handler.dispose();
    provider.dispose();
    service.dispose();
    mediaBackend.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('系统控制暂停 → 冷启动：恢复上一首 / 队列 / 模式 / 进度，不自动起播', () async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    harness.service.seed(
      [_source('a'), _source('b'), _source('c')],
      index: 1,
      playing: true,
      position: const Duration(seconds: 5),
      mode: PlayMode.shuffle,
      contextName: '收藏',
    );
    await harness.provider.preferencesReady;

    // 播放推进到 6s（在观察者的 1s 节流窗口内，不会被自动落盘）。
    harness.service.advance(position: const Duration(seconds: 6));

    // 系统控制路径：通知 / 锁屏 / 耳机键的暂停直接落到服务。
    await harness.handler.pause();
    expect(harness.service.toggleCalls, 1);
    expect(harness.provider.isPlaying, isFalse);

    // 存储：暂停动作返回时会话已在本地（含暂停时的进度）。
    final stored = await PlaybackSessionStore().load();
    expect(stored, isNotNull);
    expect(stored!.tracks.map((track) => track.id.id), ['a', 'b', 'c']);
    expect(stored.index, 1, reason: '恢复的是暂停时的那一首');
    expect(stored.position, const Duration(seconds: 6));
    expect(stored.mode, PlayMode.shuffle);
    expect(stored.context?.name, '收藏');

    // 冷启动：新 provider / 新后端，同一存储。
    final coldStart = buildTestPlaybackProvider();
    addTearDown(coldStart.dispose);
    await coldStart.preferencesReady;
    expect(coldStart.hasRestoredSession, isTrue);
    expect(coldStart.hasTrack, isTrue);
    expect(coldStart.snapshot.current?.title, 'Title b');
    expect(
        coldStart.snapshot.queue.map((track) => track.id.id), ['a', 'b', 'c']);
    expect(coldStart.currentMode, PlayMode.shuffle);
    expect(coldStart.currentPosition, const Duration(seconds: 6));
    expect(coldStart.isPlaying, isFalse, reason: '恢复态不自动起播');
  });

  test('系统控制停止：先落盘再停（队列被清空后冷启动仍可恢复）', () async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    harness.service.seed(
      [_source('a'), _source('b')],
      index: 0,
      playing: true,
      position: const Duration(seconds: 12),
      mode: PlayMode.singleRepeat,
    );
    await harness.provider.preferencesReady;
    // 播放推进到 20s：仍落在观察者的节流窗口内（只有停止时的落盘能带上它）。
    harness.service.advance(position: const Duration(seconds: 20));

    await harness.handler.stop();
    expect(harness.service.stopCalls, 1);
    // 停止后服务队列已清空（快照取不到会话）：恢复只能靠停止前的落盘。
    expect(harness.service.hasTrack, isFalse);
    expect(harness.provider.hasTrack, isFalse);

    final stored = await PlaybackSessionStore().load();
    expect(stored, isNotNull);
    expect(stored!.tracks.map((track) => track.id.id), ['a', 'b']);
    expect(stored.position, const Duration(seconds: 20));
    expect(stored.mode, PlayMode.singleRepeat);

    final coldStart = buildTestPlaybackProvider();
    addTearDown(coldStart.dispose);
    await coldStart.preferencesReady;
    expect(coldStart.hasRestoredSession, isTrue);
    expect(coldStart.snapshot.current?.id, const TrackId('fake', 'a'));
    expect(coldStart.currentPosition, const Duration(seconds: 20));
  });

  test('通知切换播放顺序：模式循环 + 会话落盘，App 内恢复态读同一模式', () async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    harness.service.seed(
      [_source('a')],
      index: 0,
      playing: true,
      position: const Duration(seconds: 3),
      mode: PlayMode.sequential,
    );
    await harness.provider.preferencesReady;

    await harness.handler.customAction(playModeActionId);
    expect(harness.service.toggleModeCalls, 1);
    // App 内 UI 读的是同一份快照：通知改模式，界面同步跟随。
    expect(harness.provider.currentMode, PlayMode.shuffle,
        reason: '顺序 → 随机（与 PlaybackProvider.togglePlayMode 同一顺序）');

    final stored = await PlaybackSessionStore().load();
    expect(stored?.mode, PlayMode.shuffle, reason: '模式是会话的一部分');
  });

  test('App 内切换播放模式：立即落盘（重开应用恢复改后的模式）', () async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    harness.service.seed([_source('a')], index: 0, playing: true);
    await harness.provider.preferencesReady;

    await harness.provider.setPlayMode(PlayMode.shuffle);
    final stored = await PlaybackSessionStore().load();
    expect(stored?.mode, PlayMode.shuffle);
  });

  test('flushPlaybackSession：返回时会话已落盘（可 await 的落盘契约）', () async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    harness.service.seed(
      [_source('a')],
      index: 0,
      playing: true,
      position: const Duration(seconds: 7),
    );
    await harness.provider.preferencesReady;

    await harness.provider.flushPlaybackSession();
    expect((await PlaybackSessionStore().load())?.position,
        const Duration(seconds: 7));
  });

  test('会话存储：写请求按调用顺序落盘，clear 不被在途保存复活', () async {
    final store = PlaybackSessionStore();
    // 在途保存（例如暂停时的强制落盘）后紧跟一次清除：
    // 串行化保证清除落在最后，用户「停止播放」后不会被旧保存写回。
    final save = store.save(PlaybackSession(
      tracks: [trackFromSourceTrack(_source('a'))],
      index: 0,
      position: const Duration(seconds: 30),
    ));
    final clear = store.clear();
    await store.pendingWrite;
    await save;
    await clear;

    expect(await store.loadRaw(), isNull);
    expect(await PlaybackSessionStore().load(), isNull);
  });
}
