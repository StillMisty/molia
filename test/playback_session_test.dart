import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:molia/data/playback/playback_engine.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/data/settings/settings_module.dart';
import 'package:molia/data/settings/settings_registry.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/playback_feel.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/music_source.dart' show PlayableStream;
import 'package:molia/models/play_mode.dart';
import 'package:molia/playback/local_playback_service.dart';
import 'package:molia/playback/playback_session_coordinator.dart';
import 'package:molia/providers/sleep_timer.dart';
import 'package:molia/services/playback_feel_store.dart';
import 'package:molia/services/playback_session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';
import 'support/memory_database.dart';

/// 上次播放会话：持久化往返 + 冷启动恢复（封面/进度/继续播放）。
Track _track(String id, {String? artwork}) => Track(
  id: TrackId('fake', id),
  title: 'Title $id',
  artists: [Artist(name: 'Artist $id')],
  album: 'Album $id',
  duration: const Duration(seconds: 30),
  artwork: artwork == null ? null : Artwork(uri: Uri.parse(artwork)),
  origin: TrackOrigin.lx,
  payload: {'id': id, 'songmid': 'mid_$id'},
);

/// 记录会话提交的存储：区分「命令面暂停（提交一次）」与
/// 「直接 facade.pause（不落盘）」。
class _RecordingSessionStore extends PlaybackSessionStore {
  final List<PlaybackSession> saves = [];

  @override
  Future<void> save(PlaybackSession session) {
    saves.add(session);
    return super.save(session);
  }
}

/// 模拟真实引擎的装载过程：load 时先推送「当前曲目 + 进度 0」的加载态，
/// 用于复现「恢复播放时进度条先回 0 再跳回恢复进度」；
/// [gate] 非空时停在取链阶段，模拟慢取链（装载期间的用户操作窗口）。
class _LoadingFacade extends FakePlaybackFacade {
  _LoadingFacade({this.gate});

  final Completer<void>? gate;

  @override
  Future<void> playTracks(PlaybackRequest request) async {
    await super.playTracks(request);
    final track = request.tracks[request.startIndex];
    emit(
      PlaybackSnapshot(
        current: track,
        queue: request.tracks,
        currentIndex: request.startIndex,
        isLoading: true,
        duration: track.duration ?? Duration.zero,
        mode: snapshot.value.mode,
      ),
      position: Duration.zero,
    );
    final gate = this.gate;
    if (gate != null) await gate.future;
  }
}

/// 最简播放器：真实 `LocalPlaybackService` 的淡变 / 暂停链路测试用。
///
/// 只实现服务用到的接口，不触碰 just_audio 平台通道；音量写入忽略，但
/// 播放/暂停状态照常广播，让引擎发布快照。
class _FadePlayer extends AudioPlayer {
  final StreamController<PlayerState> _states =
      StreamController<PlayerState>.broadcast();
  final StreamController<Duration> _positions =
      StreamController<Duration>.broadcast();
  final StreamController<PlayerException> _errors =
      StreamController<PlayerException>.broadcast();

  bool _playing = false;
  ProcessingState _processingState = ProcessingState.idle;
  Duration _position = Duration.zero;

  @override
  bool get playing => _playing;

  @override
  ProcessingState get processingState => _processingState;

  @override
  Duration get position => _position;

  @override
  Duration? get duration => const Duration(seconds: 30);

  @override
  Stream<PlayerState> get playerStateStream => _states.stream;

  @override
  Stream<Duration> get positionStream => _positions.stream;

  @override
  Stream<PlayerException> get errorStream => _errors.stream;

  @override
  Future<Duration?> setAudioSource(
    AudioSource audioSource, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    _processingState = ProcessingState.ready;
    return duration;
  }

  @override
  Future<void> play() async {
    if (_playing) return;
    _playing = true;
    _states.add(PlayerState(true, _processingState));
  }

  @override
  Future<void> pause() async {
    if (!_playing) return;
    _playing = false;
    _states.add(PlayerState(false, _processingState));
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    _position = position ?? Duration.zero;
    _positions.add(_position);
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> stop() async {
    _playing = false;
    _processingState = ProcessingState.idle;
    _states.add(PlayerState(false, _processingState));
  }

  @override
  Future<void> dispose() async {
    await _states.close();
    await _positions.close();
    await _errors.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('PlaybackSessionStore 往返：队列/下标/进度/模式/上下文/raw 原样', () async {
    final store = PlaybackSessionStore();
    final session = PlaybackSession(
      tracks: [
        _track('a', artwork: 'https://img.example/a.jpg'),
        _track('b'),
      ],
      index: 1,
      position: const Duration(seconds: 42),
      mode: PlayMode.shuffle,
      context: const PlaybackContext(name: '收藏', type: 'lx', uri: 'lx:收藏'),
    );

    await store.save(session);
    final loaded = await store.load();

    expect(loaded, isNotNull);
    expect(loaded!.tracks, hasLength(2));
    expect(loaded.index, 1);
    expect(loaded.position, const Duration(seconds: 42));
    expect(loaded.mode, PlayMode.shuffle);
    expect(loaded.context?.name, '收藏');
    expect(
      loaded.tracks[0].artwork?.uri.toString(),
      'https://img.example/a.jpg',
    );
    // raw（payload）必须原样保留：恢复播放依赖它重新取链。
    expect(loaded.tracks[0].payload['songmid'], 'mid_a');
  });

  test('新会话默认列表循环；旧 sequential 原样保留，未知模式回退列表循环', () async {
    expect(
      PlaybackSession(tracks: [_track('a')], index: 0).mode,
      PlayMode.listLoop,
    );

    final store = PlaybackSessionStore();
    Map<String, dynamic> raw(String mode) => {
      'index': 0,
      'positionMs': 0,
      'mode': mode,
      'tracks': [
        {
          'sourceKey': 'fake',
          'id': 'a',
          'title': 'Title a',
          'artists': const <Object?>[],
          'origin': 'lx',
          'payload': const <String, Object?>{},
        },
      ],
    };

    await store.saveRaw(raw('sequential'));
    expect((await store.load())?.mode, PlayMode.sequential);

    await store.saveRaw(raw('unknown'));
    expect((await store.load())?.mode, PlayMode.listLoop);
  });

  test('savePosition 只改 cursor 进度：payload JSON 不动，load 合并最新进度', () async {
    final store = PlaybackSessionStore();
    await store.save(
      PlaybackSession(
        tracks: [_track('a')],
        index: 0,
        position: const Duration(seconds: 1),
        mode: PlayMode.sequential,
      ),
    );
    final db = sharedSessionDatabase;
    final payloadBefore =
        (await db.select(db.playbackSessionPayloads).getSingle()).json;

    await store.savePosition(42000);

    // payload 里的 positionMs 仍是整份写入时的值（进度只写 cursor 行）。
    final payloadAfter =
        (await db.select(db.playbackSessionPayloads).getSingle()).json;
    expect(payloadAfter, payloadBefore);
    expect(payloadAfter, contains('"positionMs":1000'));
    // load / loadRaw 把 cursor 合并成完整会话。
    expect((await store.load())!.position, const Duration(seconds: 42));
    expect((await store.loadRaw())!['positionMs'], 42000);
  });

  test('落盘回调：save 通知（标记会话待外发），saveRaw 不通知', () async {
    var saved = 0;
    final store = PlaybackSessionStore()..onSaved = () => saved++;

    await store.save(
      PlaybackSession(
        tracks: [_track('a')],
        index: 0,
        position: Duration.zero,
        mode: PlayMode.sequential,
      ),
    );
    expect(saved, 1);

    // 同步适配器应用远端会话走 saveRaw：不应回传待发标记。
    await store.saveRaw(const {
      'tracks': <Object?>[],
      'index': 0,
      'savedAt': 1,
    });
    expect(saved, 1);
  });

  test('冷启动恢复：展示上次曲目/封面/进度，可继续播放并 seek 回进度', () async {
    final store = PlaybackSessionStore();
    await store.save(
      PlaybackSession(
        tracks: [
          _track('a'),
          _track('b', artwork: 'https://img.example/b.jpg'),
        ],
        index: 1,
        position: const Duration(seconds: 20),
        mode: PlayMode.sequential,
        context: const PlaybackContext(name: '队列', type: 'lx', uri: 'lx:队列'),
      ),
    );

    final backend = FakePlaybackFacade();
    final provider = buildTestPlaybackProvider(facade: backend);
    addTearDown(provider.dispose);
    await provider.preferencesReady;

    // 恢复态：UI 能拿到曲目/封面/进度/队列。
    expect(provider.hasRestoredSession, isTrue);
    expect(provider.hasTrack, isTrue);
    expect(provider.snapshot.current?.title, 'Title b');
    expect(
      provider.snapshot.current?.artwork?.uri.toString(),
      'https://img.example/b.jpg',
    );
    expect(provider.currentTrackId, const TrackId('fake', 'b'));
    // 恢复会话保留队列里 index-1：左侧「上一首」封面不因重启丢失。
    expect(provider.snapshot.previous?.title, 'Title a');
    expect(provider.position.value, const Duration(seconds: 20));
    expect(provider.snapshot.next, isNull);

    // 恢复态 seek：只更新保存的进度，不碰真实播放。
    await provider.seekToPosition(25000);
    expect(provider.position.value, const Duration(seconds: 25));
    expect(backend.calls.where((call) => call == 'seek'), isEmpty);

    // 点播放 = 重新取链 + 跳回进度。
    await provider.togglePlayPause();
    expect(backend.calls, contains('load'));
    expect(backend.calls, contains('seek'));
    expect(provider.hasRestoredSession, isFalse);
    // 恢复播放后进度通道交还底层：落在保存的进度上。
    expect(provider.position.value, const Duration(seconds: 25));
  });

  test('恢复态切歌：从新下标立即恢复播放，首/末越界 no-op', () async {
    await PlaybackSessionStore().save(
      PlaybackSession(
        tracks: [_track('a'), _track('b')],
        index: 0,
        position: const Duration(seconds: 12),
        mode: PlayMode.sequential,
      ),
    );

    final backend = FakePlaybackFacade();
    final provider = buildTestPlaybackProvider(facade: backend);
    addTearDown(provider.dispose);
    await provider.preferencesReady;
    expect(provider.hasRestoredSession, isTrue);

    // 首曲跳过 previous：越界 no-op，保持恢复态。
    await provider.skipToPrevious();
    expect(backend.calls, isNot(contains('load')));
    expect(provider.hasRestoredSession, isTrue);

    // 切下一首：立即起播（与点队列条目同一语义）；不 seek 回旧曲进度。
    await provider.skipToNext();
    expect(backend.calls, contains('load'));
    expect(backend.lastRequest?.startIndex, 1);
    expect(backend.calls, isNot(contains('seek')));
    expect(provider.hasRestoredSession, isFalse);
    expect(provider.currentPosition, Duration.zero);
  });

  test('恢复态列表循环：队尾下一首回队首', () async {
    await PlaybackSessionStore().save(
      PlaybackSession(
        tracks: [_track('a'), _track('b'), _track('c')],
        index: 2,
        mode: PlayMode.listLoop,
      ),
    );

    final backend = FakePlaybackFacade();
    final provider = buildTestPlaybackProvider(facade: backend);
    addTearDown(provider.dispose);
    await provider.preferencesReady;

    await provider.skipToNext();
    expect(backend.lastRequest?.startIndex, 0);
    expect(backend.lastRequest?.tracks.map((track) => track.id.id), [
      'a',
      'b',
      'c',
    ]);
  });

  test('恢复态列表循环：队首上一首回队尾', () async {
    await PlaybackSessionStore().save(
      PlaybackSession(
        tracks: [_track('a'), _track('b'), _track('c')],
        index: 0,
        mode: PlayMode.listLoop,
      ),
    );

    final backend = FakePlaybackFacade();
    final provider = buildTestPlaybackProvider(facade: backend);
    addTearDown(provider.dispose);
    await provider.preferencesReady;

    await provider.skipToPrevious();
    expect(backend.lastRequest?.startIndex, 2);
  });

  test('恢复态随机：展示本轮顺序，skipToNext 沿用同一排列', () async {
    await PlaybackSessionStore().save(
      PlaybackSession(
        tracks: [_track('a'), _track('b'), _track('c')],
        index: 0,
        mode: PlayMode.shuffle,
      ),
    );

    final backend = FakePlaybackFacade();
    final provider = buildTestPlaybackProvider(facade: backend);
    addTearDown(provider.dispose);
    await provider.preferencesReady;

    // 恢复态装载时就有本轮排列：右槽 next / 队列「接下来」不再为空。
    final restored = provider.snapshot;
    expect(restored.next, isNotNull);
    expect(restored.next!.id, isNot(restored.current!.id));
    expect(restored.upNext, hasLength(2));
    final restoredOrder = [restored.currentIndex, ...restored.upNextIndices];
    expect(restoredOrder.toSet(), {0, 1, 2});

    await provider.skipToNext();
    final request = backend.lastRequest!;
    // 恢复态展示的下一首就是起播下标，且排列原样交给后端复用：
    // 不再每次按队列下标 +1，也不会重新洗一轮换掉右槽。
    expect(request.startIndex, restoredOrder[1]);
    expect(request.startIndex, isNot(0));
    expect(request.shuffleIndices, restoredOrder);
    expect(request.shuffleIndices, contains(request.startIndex));
    expect(backend.snapshot.value.mode, PlayMode.shuffle);
  });

  test('恢复态随机 + 证据：展示顺序与交给播放的顺序一致', () async {
    await PlaybackSessionStore().save(
      PlaybackSession(
        tracks: [for (var i = 0; i < 12; i++) _track('t$i')],
        index: 4,
        mode: PlayMode.shuffle,
      ),
    );

    final backend = FakePlaybackFacade();
    final provider = buildTestPlaybackProvider(
      facade: backend,
      recentTrackIds: () async => {for (var i = 0; i < 12; i++) 'fake:t$i'},
    );
    addTearDown(provider.dispose);
    await provider.preferencesReady;

    final restored = provider.snapshot;
    final restoredOrder = [restored.currentIndex, ...restored.upNextIndices];
    expect(restoredOrder, hasLength(12));
    expect(restoredOrder.toSet(), {for (var i = 0; i < 12; i++) i});
    expect(restoredOrder.first, 4, reason: '当前曲目仍置首');

    await provider.skipToNext();
    expect(backend.lastRequest?.shuffleIndices, restoredOrder);
  });

  test('恢复态智能随机关闭：有证据也生成均匀轮次', () async {
    await PlaybackSessionStore().save(
      PlaybackSession(
        tracks: [for (var i = 0; i < 12; i++) _track('t$i')],
        index: 0,
        mode: PlayMode.shuffle,
      ),
    );
    // 设备本地已保存「智能随机」关闭；必须早于恢复态装载读取。
    await PlaybackFeelStore().save(
      fade: PlaybackFadePreset.ms200,
      smartShuffle: false,
    );

    final backend = FakePlaybackFacade();
    final provider = buildTestPlaybackProvider(
      facade: backend,
      recentTrackIds: () async => {for (var i = 0; i < 12; i++) 'fake:t$i'},
    );
    addTearDown(provider.dispose);
    await provider.preferencesReady;

    expect(provider.smartShuffleEnabled, isFalse);
    expect(
      provider.restoredRoundWeighted,
      isFalse,
      reason: '开关关闭时恢复态也不能生成加权轮次',
    );

    final restored = provider.snapshot;
    final restoredOrder = [restored.currentIndex, ...restored.upNextIndices];
    await provider.skipToNext();
    expect(backend.lastRequest?.shuffleIndices, restoredOrder);
  });

  test('重启后恢复态仍可调整播放模式，恢复播放沿用所选模式', () async {
    await PlaybackSessionStore().save(
      PlaybackSession(
        tracks: [_track('a')],
        index: 0,
        position: Duration.zero,
        mode: PlayMode.shuffle,
      ),
    );

    final backend = FakePlaybackFacade();
    final provider = buildTestPlaybackProvider(facade: backend);
    addTearDown(provider.dispose);
    await provider.preferencesReady;

    // 恢复态展示会话里的模式。
    expect(provider.currentMode, PlayMode.shuffle);

    // 恢复态切换模式（模式按钮同路径）：UI 立即跟随。
    await provider.togglePlayMode();
    expect(provider.currentMode, PlayMode.listLoop);
    expect(provider.snapshot.mode, PlayMode.listLoop);
    expect(backend.snapshot.value.mode, PlayMode.listLoop);

    // 新模式写入恢复会话：重启后仍保留。
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect((await PlaybackSessionStore().load())?.mode, PlayMode.listLoop);

    // 会话模式与后端不一致（启动默认模式覆盖后端）+ 恢复播放：
    // 恢复时应把会话模式带给后端（shuffle 顺序依赖装载前的模式）。
    await provider.setPlayMode(PlayMode.shuffle);
    await provider.setDefaultPlayMode(PlayMode.sequential);
    expect(backend.snapshot.value.mode, PlayMode.sequential);

    await provider.resumeRestoredSession();
    expect(backend.snapshot.value.mode, PlayMode.shuffle);
    expect(provider.currentMode, PlayMode.shuffle);
  });

  test('启动恢复开关关闭：冷启动不装载恢复态，会话数据保留', () async {
    SharedPreferences.setMockInitialValues({
      kRestoreSessionEnabled.name: false,
    });
    await PlaybackSessionStore().save(
      PlaybackSession(
        tracks: [_track('a')],
        index: 0,
        position: const Duration(seconds: 12),
        mode: PlayMode.sequential,
      ),
    );

    final provider = buildTestPlaybackProvider();
    addTearDown(provider.dispose);
    await provider.preferencesReady;

    expect(provider.restoreSessionEnabled, isFalse);
    expect(provider.hasRestoredSession, isFalse);
    expect(provider.hasTrack, isFalse);
    // 会话没有被清掉：重新开启开关后仍可恢复。
    expect(await PlaybackSessionStore().load(), isNotNull);
  });

  test('关闭启动恢复开关：立即撤下未播放的恢复态并持久化', () async {
    await PlaybackSessionStore().save(
      PlaybackSession(
        tracks: [_track('a')],
        index: 0,
        position: const Duration(seconds: 12),
        mode: PlayMode.sequential,
      ),
    );

    final provider = buildTestPlaybackProvider();
    addTearDown(provider.dispose);
    await provider.preferencesReady;
    expect(provider.hasRestoredSession, isTrue);

    await provider.setRestoreSessionEnabled(false);
    expect(provider.restoreSessionEnabled, isFalse);
    expect(provider.hasRestoredSession, isFalse);
    expect(provider.hasTrack, isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kRestoreSessionEnabled.name), isFalse);
  });

  test('远端同步改「启动时恢复上次播放」：reload 撤下恢复态并通知 UI', () async {
    await PlaybackSessionStore().save(
      PlaybackSession(
        tracks: [_track('a')],
        index: 0,
        position: const Duration(seconds: 12),
        mode: PlayMode.sequential,
      ),
    );

    final settings = SettingsRegistry(keys: kAllSettingsKeys);
    final provider = buildTestPlaybackProvider(settings: settings);
    addTearDown(provider.dispose);
    await provider.preferencesReady;
    expect(provider.hasRestoredSession, isTrue);
    settings.mount(
      SettingsModule(
        keys: [kRestoreSessionEnabled],
        reload: provider.reloadRestoreSessionPreference,
      ),
    );

    var notifies = 0;
    provider.addListener(() => notifies++);

    // 远端同步应用关闭值：组合根挂载的 reload 撤下恢复态。
    await settings.applyRemote(kRestoreSessionEnabled, false);
    await settings.reloadApplied();

    expect(provider.restoreSessionEnabled, isFalse);
    expect(provider.hasRestoredSession, isFalse);
    expect(provider.hasTrack, isFalse);
    // 通知经节流器派发（track 16ms / queue 300ms）。
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(notifies, greaterThan(0), reason: '恢复态撤下后 UI 必须刷新');
  });

  test('远端同步改「启动时恢复上次播放」：reload 重新装载并通知 UI', () async {
    SharedPreferences.setMockInitialValues({
      kRestoreSessionEnabled.name: false,
    });
    await PlaybackSessionStore().save(
      PlaybackSession(
        tracks: [_track('a')],
        index: 0,
        position: const Duration(seconds: 12),
        mode: PlayMode.sequential,
      ),
    );

    final settings = SettingsRegistry(keys: kAllSettingsKeys);
    final provider = buildTestPlaybackProvider(settings: settings);
    addTearDown(provider.dispose);
    await provider.preferencesReady;
    expect(provider.restoreSessionEnabled, isFalse);
    expect(provider.hasRestoredSession, isFalse);
    settings.mount(
      SettingsModule(
        keys: [kRestoreSessionEnabled],
        reload: provider.reloadRestoreSessionPreference,
      ),
    );

    var notifies = 0;
    provider.addListener(() => notifies++);

    // 远端同步应用开启值：重新装载恢复态（会话数据仍在）。
    await settings.applyRemote(kRestoreSessionEnabled, true);
    await settings.reloadApplied();

    expect(provider.restoreSessionEnabled, isTrue);
    expect(provider.hasRestoredSession, isTrue);
    expect(provider.snapshot.current?.title, 'Title a');
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(notifies, greaterThan(0), reason: '重新装载恢复态后 UI 必须刷新');
  });

  test('恢复播放：seek 落地前进度不闪回 0（保持恢复进度）', () async {
    await PlaybackSessionStore().save(
      PlaybackSession(
        tracks: [_track('a')],
        index: 0,
        position: const Duration(seconds: 20),
        mode: PlayMode.sequential,
      ),
    );

    final backend = _LoadingFacade();
    final provider = buildTestPlaybackProvider(facade: backend);
    addTearDown(provider.dispose);
    await provider.preferencesReady;
    expect(provider.position.value, const Duration(seconds: 20));

    // 记录进度通道暴露给 UI 的全部中间值。
    final observed = <Duration>[];
    provider.position.addListener(() => observed.add(provider.position.value));

    await provider.togglePlayPause();

    // 装载时后端进度对齐到 0：期间不应把 0 暴露给 UI（先回首部再跳回）。
    expect(observed, isNot(contains(Duration.zero)));
    expect(provider.position.value, const Duration(seconds: 20));
    expect(backend.calls, contains('seek'));

    // 装载时的强制保存记的是 0；恢复流程末尾应立即写回恢复进度。
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(
      (await PlaybackSessionStore().load())?.position,
      const Duration(seconds: 20),
    );
  });

  test('恢复装载期间用户 seek 优先于保存进度', () async {
    await PlaybackSessionStore().save(
      PlaybackSession(
        tracks: [_track('a')],
        index: 0,
        position: const Duration(seconds: 20),
        mode: PlayMode.sequential,
      ),
    );

    final gate = Completer<void>();
    final backend = _LoadingFacade(gate: gate);
    final provider = buildTestPlaybackProvider(facade: backend);
    addTearDown(provider.dispose);
    await provider.preferencesReady;

    // 点播放后停在取链阶段，用户此时拖到 60s。
    final resume = provider.togglePlayPause();
    await Future<void>.delayed(Duration.zero);
    await provider.seekToPosition(60000);
    gate.complete();
    await resume;

    // 恢复流程不应把用户目标覆盖回保存进度。
    expect(provider.currentPosition, const Duration(seconds: 60));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(
      (await PlaybackSessionStore().load())?.position,
      const Duration(seconds: 60),
    );
  });

  test('suspendPlaybackSession：退后台 / 退出入口强制保存最新进度', () async {
    final backend = FakePlaybackFacade();
    final provider = buildTestPlaybackProvider(facade: backend);
    addTearDown(provider.dispose);
    await provider.preferencesReady;

    backend.emit(
      PlaybackSnapshot(
        current: _track('a'),
        queue: [_track('a')],
        currentIndex: 0,
        isPlaying: true,
        duration: const Duration(seconds: 30),
      ),
      position: const Duration(seconds: 7),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(
      (await PlaybackSessionStore().load())?.position,
      const Duration(seconds: 7),
    );

    // 先提交 7s；随后进度推进到 30s：没有周期写，存储仍是 7s。
    await provider.suspendPlaybackSession();
    backend.emit(
      PlaybackSnapshot(
        current: _track('a'),
        queue: [_track('a')],
        currentIndex: 0,
        isPlaying: true,
        duration: const Duration(seconds: 30),
      ),
      position: const Duration(seconds: 30),
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      (await PlaybackSessionStore().load())?.position,
      const Duration(seconds: 7),
    );

    // 生命周期 paused：强制落盘到最新进度。
    await provider.suspendPlaybackSession();
    expect(
      (await PlaybackSessionStore().load())?.position,
      const Duration(seconds: 30),
    );
  });

  test('真实播放后保存会话：新实例可恢复（含 raw）', () async {
    final backend = FakePlaybackFacade();
    final provider = buildTestPlaybackProvider(facade: backend);
    addTearDown(provider.dispose);
    await provider.preferencesReady;

    backend.emit(
      PlaybackSnapshot(
        current: _track('a', artwork: 'https://img.example/a.jpg'),
        queue: [_track('a'), _track('b')],
        currentIndex: 0,
        isPlaying: true,
        duration: const Duration(seconds: 30),
      ),
      position: const Duration(seconds: 7),
    );
    // 保存是异步的：让微任务/SharedPreferences 写入完成。
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final session = await PlaybackSessionStore().load();
    expect(session, isNotNull);
    expect(session!.tracks, hasLength(2));
    expect(session.index, 0);
    expect(session.tracks[0].payload['songmid'], 'mid_a');
  });

  /// 真实淡变链路（服务 + 引擎 + 协调者）的最小装配。
  Future<
    ({
      LocalPlaybackService service,
      PlaybackEngine engine,
      PlaybackSessionCoordinator session,
      _RecordingSessionStore store,
    })
  >
  buildFadeChain() async {
    final player = _FadePlayer();
    final service = LocalPlaybackService(
      resolver: (track, {String? quality}) async =>
          PlayableStream(Uri.parse('file:///tmp/molia-session-fade.mp3')),
      player: player,
      fadeDuration: const Duration(milliseconds: 120),
    );
    addTearDown(service.dispose);
    final engine = PlaybackEngine(service: service);
    addTearDown(engine.dispose);
    final store = _RecordingSessionStore();
    final session = buildTestSessionCoordinator(
      facade: engine,
      sessionStore: store,
      settings: SettingsRegistry(keys: kAllSettingsKeys),
    );
    addTearDown(session.dispose);

    await engine.playTracks(
      PlaybackRequest(tracks: [_track('a')], startIndex: 0),
    );
    await Future<void>.delayed(Duration.zero);
    await session.pendingWrite;
    await session.seekToPosition(const Duration(seconds: 7));
    await session.pendingWrite;
    store.saves.clear();
    return (service: service, engine: engine, session: session, store: store);
  }

  test('淡变后暂停：会话只提交一次，冷启动恢复为暂停态', () async {
    final chain = await buildFadeChain();

    await chain.session.pause();
    await chain.session.pendingWrite;

    expect(chain.store.saves, hasLength(1), reason: '淡出结束后的暂停只落盘一次');
    expect(chain.store.saves.single.position, const Duration(seconds: 7));

    final restored = buildTestSessionCoordinator(
      facade: FakePlaybackFacade(),
      settings: SettingsRegistry(keys: kAllSettingsKeys),
    );
    addTearDown(restored.dispose);
    expect(await restored.load(), isTrue);
    expect(restored.displaySnapshot.current?.title, 'Title a');
    expect(restored.displaySnapshot.isPlaying, isFalse);
    expect(restored.position.value, const Duration(seconds: 7));
  });

  test('淡变进行中不写会话、不改快照、不推进度', () async {
    final chain = await buildFadeChain();
    final snapshotBefore = chain.engine.snapshot.value;
    final positionBefore = chain.engine.position.value;
    var snapshotNotifies = 0;
    var positionNotifies = 0;
    void onSnapshot() => snapshotNotifies++;
    void onPosition() => positionNotifies++;
    chain.engine.snapshot.addListener(onSnapshot);
    chain.engine.position.addListener(onPosition);
    addTearDown(() {
      chain.engine.snapshot.removeListener(onSnapshot);
      chain.engine.position.removeListener(onPosition);
    });

    chain.engine.startSleepFade(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(chain.store.saves, isEmpty);
    expect(chain.engine.snapshot.value, snapshotBefore);
    expect(chain.engine.position.value, positionBefore);
    expect(snapshotNotifies, 0);
    expect(positionNotifies, 0);
    chain.engine.cancelSleepFade();
  });

  test('定时关闭到点：经命令面暂停并在返回前提交会话', () async {
    final backend = FakePlaybackFacade();
    final store = _RecordingSessionStore();
    final provider = buildTestPlaybackProvider(
      facade: backend,
      sessionStore: store,
    );
    addTearDown(provider.dispose);
    await provider.preferencesReady;

    // 起播一帧：切歌快照先提交一次（进度 7s），定时到点时应提交同一进度。
    final a = _track('a');
    backend.emit(
      PlaybackSnapshot(
        current: a,
        queue: [a],
        currentIndex: 0,
        isPlaying: true,
        duration: const Duration(seconds: 30),
      ),
      position: const Duration(seconds: 7),
    );
    expect(store.saves, hasLength(1));
    expect(store.saves.single.position, const Duration(seconds: 7));

    // 播放推进到 8s：到点暂停必须提交最新进度，而不是停在切歌时的 7s。
    backend.emit(
      PlaybackSnapshot(
        current: a,
        queue: [a],
        currentIndex: 0,
        isPlaying: true,
        duration: const Duration(seconds: 30),
      ),
      position: const Duration(seconds: 8),
    );
    expect(store.saves, hasLength(1), reason: '进度 tick 不重写整份会话');

    // 极短倒计时：ticker 周期固定 1s，第一次 tick 即越过 deadline 到点。
    // 这里要验证到点立即暂停并提交进度，先关掉「等本曲播完」。
    provider.sleepTimer.setWaitForTrackEnd(false);
    provider.sleepTimer.startCountdown(const Duration(milliseconds: 10));
    // 留 200ms 给命令面暂停 + 写队列排空（真实时间，无法注入时钟）。
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    expect(provider.sleepTimer.value.mode, SleepTimerMode.off);
    expect(backend.calls, contains('pause'));
    // 命令面暂停在返回前提交最新进度（内容没变时不会重复写）。
    expect(store.saves, hasLength(2));
    expect(store.saves.last.position, const Duration(seconds: 8));
  });
}
