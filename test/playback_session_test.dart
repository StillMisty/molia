import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/services/playback_session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

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

/// 模拟真实后端的装载过程：load 时先推送「当前曲目 + 进度 0」的加载态，
/// 用于复现「恢复播放时进度条先回 0 再跳回恢复进度」；
/// [gate] 非空时停在取链阶段，模拟慢取链（装载期间的用户操作窗口）。
class _LoadingBackend extends FakePlaybackBackend {
  _LoadingBackend({this.gate});

  final Completer<void>? gate;

  @override
  Future<void> load(PlaybackRequest request) async {
    await super.load(request);
    final track = request.tracks[request.startIndex];
    emit(BackendSnapshot(
      current: track,
      queue: request.tracks,
      currentIndex: request.startIndex,
      isLoading: true,
      position: Duration.zero,
      duration: track.duration ?? Duration.zero,
      mode: state.value.mode,
    ));
    final gate = this.gate;
    if (gate != null) await gate.future;
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
      context: const PlaybackContext(
        name: '收藏',
        type: 'lx',
        uri: 'lx:收藏',
      ),
    );

    await store.save(session);
    final loaded = await store.load();

    expect(loaded, isNotNull);
    expect(loaded!.tracks, hasLength(2));
    expect(loaded.index, 1);
    expect(loaded.position, const Duration(seconds: 42));
    expect(loaded.mode, PlayMode.shuffle);
    expect(loaded.context?.name, '收藏');
    expect(loaded.tracks[0].artwork?.uri.toString(),
        'https://img.example/a.jpg');
    // raw（payload）必须原样保留：恢复播放依赖它重新取链。
    expect(loaded.tracks[0].payload['songmid'], 'mid_a');
  });

  test('冷启动恢复：展示上次曲目/封面/进度，可继续播放并 seek 回进度', () async {
    final store = PlaybackSessionStore();
    await store.save(PlaybackSession(
      tracks: [
        _track('a'),
        _track('b', artwork: 'https://img.example/b.jpg'),
      ],
      index: 1,
      position: const Duration(seconds: 20),
      mode: PlayMode.sequential,
      context: const PlaybackContext(name: '队列', type: 'lx', uri: 'lx:队列'),
    ));

    final backend = FakePlaybackBackend();
    final provider = buildTestPlaybackProvider(backend: backend);
    addTearDown(provider.dispose);
    await provider.preferencesReady;

    // 恢复态：UI 能拿到曲目/封面/进度/队列。
    expect(provider.hasRestoredSession, isTrue);
    expect(provider.hasTrack, isTrue);
    expect(provider.snapshot.current?.title, 'Title b');
    expect(provider.snapshot.current?.artwork?.uri.toString(),
        'https://img.example/b.jpg');
    expect(provider.currentTrackId, const TrackId('fake', 'b'));
    // 恢复会话保留队列里 index-1：左侧「上一首」封面不因重启丢失。
    expect(provider.snapshot.history.last.title, 'Title a');
    expect(provider.position.value, const Duration(seconds: 20));
    expect(provider.snapshot.next, isNull);
    expect(provider.snapshot.upcoming, isEmpty);

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

  test('重启后恢复态仍可调整播放模式，恢复播放沿用所选模式', () async {
    await PlaybackSessionStore().save(PlaybackSession(
      tracks: [_track('a')],
      index: 0,
      position: Duration.zero,
      mode: PlayMode.shuffle,
    ));

    final backend = FakePlaybackBackend();
    final provider = buildTestPlaybackProvider(backend: backend);
    addTearDown(provider.dispose);
    await provider.preferencesReady;

    // 恢复态展示会话里的模式。
    expect(provider.currentMode, PlayMode.shuffle);

    // 恢复态切换模式（模式按钮同路径）：UI 立即跟随。
    await provider.togglePlayMode();
    expect(provider.currentMode, PlayMode.singleRepeat);
    expect(provider.snapshot.mode, PlayMode.singleRepeat);
    expect(backend.state.value.mode, PlayMode.singleRepeat);

    // 新模式写入恢复会话：重启后仍保留。
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect((await PlaybackSessionStore().load())?.mode,
        PlayMode.singleRepeat);

    // 会话模式与后端不一致（启动默认模式覆盖后端）+ 恢复播放：
    // 恢复时应把会话模式带给后端（shuffle 顺序依赖装载前的模式）。
    await provider.setPlayMode(PlayMode.shuffle);
    await provider.setDefaultPlayMode(PlayMode.sequential);
    expect(backend.state.value.mode, PlayMode.sequential);

    await provider.resumeRestoredSession();
    expect(backend.state.value.mode, PlayMode.shuffle);
    expect(provider.currentMode, PlayMode.shuffle);
  });

  test('启动恢复开关关闭：冷启动不装载恢复态，会话数据保留', () async {
    SharedPreferences.setMockInitialValues({
      kRestoreSessionEnabled.name: false,
    });
    await PlaybackSessionStore().save(PlaybackSession(
      tracks: [_track('a')],
      index: 0,
      position: const Duration(seconds: 12),
      mode: PlayMode.sequential,
    ));

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
    await PlaybackSessionStore().save(PlaybackSession(
      tracks: [_track('a')],
      index: 0,
      position: const Duration(seconds: 12),
      mode: PlayMode.sequential,
    ));

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

  test('恢复播放：seek 落地前进度不闪回 0（保持恢复进度）', () async {
    await PlaybackSessionStore().save(PlaybackSession(
      tracks: [_track('a')],
      index: 0,
      position: const Duration(seconds: 20),
      mode: PlayMode.sequential,
    ));

    final backend = _LoadingBackend();
    final provider = buildTestPlaybackProvider(backend: backend);
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
    expect((await PlaybackSessionStore().load())?.position,
        const Duration(seconds: 20));
  });

  test('恢复装载期间用户 seek 优先于保存进度', () async {
    await PlaybackSessionStore().save(PlaybackSession(
      tracks: [_track('a')],
      index: 0,
      position: const Duration(seconds: 20),
      mode: PlayMode.sequential,
    ));

    final gate = Completer<void>();
    final backend = _LoadingBackend(gate: gate);
    final provider = buildTestPlaybackProvider(backend: backend);
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
    expect((await PlaybackSessionStore().load())?.position,
        const Duration(seconds: 60));
  });

  test('flushPlaybackSession：后台强制保存最新进度（不等节流窗口）', () async {
    final backend = FakePlaybackBackend();
    final provider = buildTestPlaybackProvider(backend: backend);
    addTearDown(provider.dispose);
    await provider.preferencesReady;

    backend.emit(BackendSnapshot(
      current: _track('a'),
      queue: [_track('a')],
      currentIndex: 0,
      isPlaying: true,
      position: const Duration(seconds: 7),
      duration: const Duration(seconds: 30),
    ));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect((await PlaybackSessionStore().load())?.position,
        const Duration(seconds: 7));

    // 播放推进到 30s：节流窗口内不会自动落盘（先强制保存 7s 重置窗口，
    // 避免测试时长影响节流判定）。
    provider.flushPlaybackSession();
    backend.emit(BackendSnapshot(
      current: _track('a'),
      queue: [_track('a')],
      currentIndex: 0,
      isPlaying: true,
      position: const Duration(seconds: 30),
      duration: const Duration(seconds: 30),
    ));
    await Future<void>.delayed(Duration.zero);
    expect((await PlaybackSessionStore().load())?.position,
        const Duration(seconds: 7));

    // 生命周期 paused：强制落盘到最新进度。
    provider.flushPlaybackSession();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect((await PlaybackSessionStore().load())?.position,
        const Duration(seconds: 30));
  });

  test('真实播放后保存会话：新实例可恢复（含 raw）', () async {
    final backend = FakePlaybackBackend();
    final provider = buildTestPlaybackProvider(backend: backend);
    addTearDown(provider.dispose);
    await provider.preferencesReady;

    backend.emit(BackendSnapshot(
      current: _track('a', artwork: 'https://img.example/a.jpg'),
      queue: [_track('a'), _track('b')],
      currentIndex: 0,
      upcoming: [_track('b')],
      isPlaying: true,
      position: const Duration(seconds: 7),
      duration: const Duration(seconds: 30),
    ));
    // 保存是异步的：让微任务/SharedPreferences 写入完成。
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final session = await PlaybackSessionStore().load();
    expect(session, isNotNull);
    expect(session!.tracks, hasLength(2));
    expect(session.index, 0);
    expect(session.tracks[0].payload['songmid'], 'mid_a');
  });
}
