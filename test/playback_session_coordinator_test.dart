/// 播放会话协调者：三阶段状态机（idle → restored → live → idle）、恢复期命令
/// 路由、恢复态与 live 的交接、以及「PlaybackSessionStore 唯一写者」的落盘
/// 口径（动作落盘、无周期写、flush 可 await）。
///
/// 假后端 + 真实 facade + 记录型假 store：断言只经公开接口（resolve / phase /
/// 命令路由结果 / position）与注入的假入口，不读私有字段。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/playback/default_playback_facade.dart';
import 'package:molia/data/settings/settings_access.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/data/settings/settings_registry.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/playback/playback_power_policy.dart';
import 'package:molia/playback/playback_session_coordinator.dart';
import 'package:molia/services/playback_session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';
import 'support/settings_test_support.dart';

Track _track(String id) => Track(
  id: TrackId('fake', id),
  title: 'Title $id',
  artists: [Artist(name: 'Artist $id')],
  album: 'Album $id',
  duration: const Duration(seconds: 30),
  origin: TrackOrigin.lx,
  payload: {'songmid': 'mid_$id'},
);

/// 真实播放的一帧后端快照（与真实后端同构：队列 + 下标 + 进度）。
BackendSnapshot _live(
  Track current, {
  List<Track>? queue,
  int index = 0,
  bool playing = true,
  Duration position = Duration.zero,
  PlayMode mode = PlayMode.sequential,
}) {
  final tracks = queue ?? [current];
  return BackendSnapshot(
    current: current,
    queue: tracks,
    currentIndex: index,
    next: index + 1 < tracks.length ? tracks[index + 1] : null,
    previous: index > 0 ? tracks[index - 1] : null,
    previousOfPrevious: index > 1 ? tracks[index - 2] : null,
    upNext: index >= 0 ? tracks.sublist(index + 1) : const [],
    isPlaying: playing,
    position: position,
    duration: current.duration ?? Duration.zero,
    mode: mode,
  );
}

/// 记录写入口径的假 store（[persist] 为 true 时同时写真实存储，
/// 用于验证 clear 与在途写入的先后）。
class _RecordingSessionStore extends PlaybackSessionStore {
  _RecordingSessionStore({this.persist = false});

  final bool persist;

  /// 写请求调用顺序（save / savePosition / clear）。
  final List<String> calls = [];

  /// 整份落盘的会话。
  final List<PlaybackSession> saves = [];

  /// 轻量进度落盘（毫秒）。
  final List<int> positions = [];

  @override
  Future<void> save(PlaybackSession session) {
    calls.add('save');
    saves.add(session);
    return persist ? super.save(session) : Future<void>.value();
  }

  @override
  Future<void> savePosition(int positionMs) {
    calls.add('savePosition');
    positions.add(positionMs);
    return persist ? super.savePosition(positionMs) : Future<void>.value();
  }

  @override
  Future<void> saveRaw(Map<String, dynamic> raw) {
    calls.add('saveRaw');
    return persist ? super.saveRaw(raw) : Future<void>.value();
  }

  @override
  Future<void> clear() {
    calls.add('clear');
    return persist ? super.clear() : Future<void>.value();
  }
}

/// 模拟真实后端的装载过程：load 时先推送「当前曲目 + 进度 0」的加载态
/// （复现恢复播放的进度闪回窗口），[gate] 非空时停在取链阶段（用户操作窗口）。
class _LoadingBackend extends FakePlaybackBackend {
  _LoadingBackend({this.gate});

  final Completer<void>? gate;

  /// seek 落点记录（断言恢复流程末尾用的是用户目标）。
  final List<Duration> seeks = [];

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    await super.seek(position);
  }

  @override
  Future<void> load(PlaybackRequest request) async {
    await super.load(request);
    final track = request.tracks[request.startIndex];
    emit(
      BackendSnapshot(
        current: track,
        queue: request.tracks,
        currentIndex: request.startIndex,
        isLoading: true,
        position: Duration.zero,
        duration: track.duration ?? Duration.zero,
        mode: state.value.mode,
      ),
    );
    final gate = this.gate;
    if (gate != null) await gate.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlaybackBackend backend;
  late DefaultPlaybackFacade facade;
  late _RecordingSessionStore store;
  late PlaybackSessionCoordinator session;

  /// 装配协调者：[backendOverride] 给特殊后端（慢取链装载），
  /// [persistStore] 让假 store 同时写真实存储，[onRestoredTrack] 记录恢复曲目，
  /// [settings] 给与 provider 同源的设置注册表（重载钩子测试），
  /// [powerPolicy] 给共享的功耗策略（前后台落盘节流测试）。
  PlaybackSessionCoordinator build({
    FakePlaybackBackend? backendOverride,
    bool persistStore = false,
    RestoredTrackReporter? onRestoredTrack,
    SettingsAccess? settings,
    PlaybackPowerPolicy? powerPolicy,
  }) {
    backend = backendOverride ?? FakePlaybackBackend();
    facade = DefaultPlaybackFacade(backend: backend);
    store = _RecordingSessionStore(persist: persistStore);
    session = PlaybackSessionCoordinator(
      facade: facade,
      store: store,
      settings: settings ?? testSettingsRegistry(),
      onRestoredTrack: onRestoredTrack,
      powerPolicy: powerPolicy,
    );
    addTearDown(session.dispose);
    return session;
  }

  /// 预置一份持久化会话（冷启动前上一次运行留下的）。
  Future<void> seedSession(PlaybackSession value) =>
      PlaybackSessionStore().save(value);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('阶段迁移：装载进 restored，真实播放接管进 live，停止回 idle', () async {
    build();
    expect(session.phase, PlaybackSessionPhase.idle);
    expect(session.hasRestoredSession, isFalse);

    await seedSession(
      PlaybackSession(
        tracks: [_track('a'), _track('b')],
        index: 1,
        position: const Duration(seconds: 20),
        mode: PlayMode.shuffle,
        context: const PlaybackContext(name: '收藏', type: 'lx', uri: 'lx:收藏'),
      ),
    );

    expect(await session.load(), isTrue);
    expect(session.phase, PlaybackSessionPhase.restored);
    expect(session.hasRestoredSession, isTrue);

    // 恢复态出口：协调者构造的恢复快照（facade 此时还是空的）。
    final restored = session.resolve(facade.snapshot.value);
    expect(restored.current?.id.id, 'b');
    expect(restored.queue.map((track) => track.id.id), ['a', 'b']);
    expect(restored.currentIndex, 1);
    expect(restored.previous?.id.id, 'a');
    expect(restored.next, isNull);
    expect(restored.mode, PlayMode.shuffle);
    expect(restored.isPlaying, isFalse);
    expect(restored.context?.name, '收藏');
    // 进度通道显示保存的进度（不是 facade 的 0）。
    expect(session.position.value, const Duration(seconds: 20));

    // 真实播放接管：恢复数据丢弃，快照原样透传 facade。
    final live = _track('c');
    backend.emit(_live(live, position: const Duration(seconds: 3)));
    expect(session.phase, PlaybackSessionPhase.live);
    expect(session.hasRestoredSession, isFalse);
    expect(session.resolve(facade.snapshot.value).current?.id.id, 'c');
    expect(session.position.value, const Duration(seconds: 3));

    // 停止播放（真实后端随后清空队列）：回 idle。
    await session.stopPlayback();
    backend.emit(BackendSnapshot.empty);
    expect(session.phase, PlaybackSessionPhase.idle);
  });

  test('恢复态列表循环：next / previous / previousOfPrevious / upNext 按队列回绕', () async {
    build();
    await seedSession(
      PlaybackSession(
        tracks: [_track('a'), _track('b'), _track('c')],
        index: 2,
        mode: PlayMode.listLoop,
      ),
    );
    expect(await session.load(), isTrue);

    final restored = session.resolve(facade.snapshot.value);
    expect(restored.next?.id.id, 'a');
    expect(restored.previous?.id.id, 'b');
    expect(restored.previousOfPrevious?.id.id, 'a');
    expect(restored.upNext.map((track) => track.id.id), ['a', 'b']);
  });

  test('恢复态 shuffle：没有洗牌顺序时 next / upNext 为空，不按下标近似', () async {
    build();
    await seedSession(
      PlaybackSession(
        tracks: [_track('a'), _track('b'), _track('c')],
        index: 1,
        mode: PlayMode.shuffle,
      ),
    );
    expect(await session.load(), isTrue);

    final restored = session.resolve(facade.snapshot.value);
    // 洗牌排列不落盘：恢复态不知道「下一首」，不能用 b 的下标 +1 冒充 c。
    expect(restored.next, isNull);
    expect(restored.upNext, isEmpty);
    // 上一首不依赖洗牌顺序：回退队列前一位。
    expect(restored.previous?.id.id, 'a');
    expect(restored.previousOfPrevious, isNull);
  });

  test('恢复态停止播放：撤下恢复数据、清空持久化会话', () async {
    build(persistStore: true);
    await seedSession(
      PlaybackSession(
        tracks: [_track('a')],
        index: 0,
        position: const Duration(seconds: 12),
      ),
    );
    expect(await session.load(), isTrue);
    expect(session.phase, PlaybackSessionPhase.restored);

    await session.stopPlayback();
    await session.pendingWrite;

    // 恢复数据撤下 + 存储清空：下次启动不会再出现。
    expect(session.hasRestoredSession, isFalse);
    expect(session.phase, PlaybackSessionPhase.idle);
    expect(store.calls, ['clear']);
    expect(await PlaybackSessionStore().loadRaw(), isNull);
  });

  test('恢复期命令路由：seek 只改保存进度并夹取到曲目时长', () async {
    build();
    await seedSession(
      PlaybackSession(
        tracks: [_track('a'), _track('b')],
        index: 1,
        position: const Duration(seconds: 10),
      ),
    );
    expect(await session.load(), isTrue);

    // 超过曲目时长（30s）：夹取到时长；不碰真实播放。
    await session.seekToPosition(const Duration(seconds: 45));
    expect(session.position.value, const Duration(seconds: 30));
    expect(store.saves.last.position, const Duration(seconds: 30));
    expect(backend.calls, isEmpty);

    // 负值：夹取到 0。
    await session.seekToPosition(const Duration(seconds: -5));
    expect(session.position.value, Duration.zero);
    expect(backend.calls, isEmpty);
  });

  test('恢复期命令路由：越界切歌 no-op；点队列条目从该曲目恢复播放', () async {
    build();
    await seedSession(
      PlaybackSession(
        tracks: [_track('a'), _track('b')],
        index: 1,
        position: const Duration(seconds: 10),
      ),
    );
    expect(await session.load(), isTrue);

    // 队尾：越界 no-op。
    expect(await session.skipToNext(), PlaybackCommandOutcome.none);
    expect(backend.calls, isEmpty);
    expect(session.phase, PlaybackSessionPhase.restored);

    // 点恢复队列里的第一首：从该下标恢复播放（不 seek 回旧曲进度）。
    expect(
      await session.playQueueItemById(const TrackId('fake', 'a').uri),
      PlaybackCommandOutcome.trackAndQueue,
    );
    expect(backend.calls, ['setMode', 'load']);
    expect(backend.lastRequest?.startIndex, 0);
    expect(session.hasRestoredSession, isFalse);

    // 未命中（恢复队列里没有）：空操作。
    expect(
      await session.playQueueItemById('fake:zzz'),
      PlaybackCommandOutcome.none,
    );
  });

  test('恢复态：模式 / 换源改写保存的会话并落盘；未命中不算失败', () async {
    build();
    await seedSession(
      PlaybackSession(
        tracks: [_track('a'), _track('b')],
        index: 0,
        position: const Duration(seconds: 10),
      ),
    );
    expect(await session.load(), isTrue);

    // 模式：后端先落地（shuffle 洗牌顺序依赖装载前模式），会话同步改写。
    await session.setPlayMode(PlayMode.shuffle);
    expect(backend.calls, ['setMode']);
    expect(session.resolve(facade.snapshot.value).mode, PlayMode.shuffle);
    expect(store.saves.last.mode, PlayMode.shuffle);

    // 换源命中恢复队列：原地替换并落盘（facade 队列为空，不转发）。
    expect(await session.replaceTrack(_track('a'), _track('a2')), isTrue);
    expect(backend.calls, ['setMode']);
    expect(store.saves.last.tracks.first.id.id, 'a2');
    expect(session.resolve(facade.snapshot.value).queue.first.id.id, 'a2');

    // 未命中：不落盘、不转发，返回 false。
    final saves = store.saves.length;
    expect(await session.replaceTrack(_track('zzz'), _track('zzz2')), isFalse);
    expect(store.saves, hasLength(saves));
  });

  test('恢复播放：会话模式先落地 + seek 回保存进度，成功后恢复数据丢弃', () async {
    build(backendOverride: _LoadingBackend());
    await seedSession(
      PlaybackSession(
        tracks: [_track('a')],
        index: 0,
        position: const Duration(seconds: 20),
        mode: PlayMode.shuffle,
      ),
    );
    expect(await session.load(), isTrue);

    expect(await session.resume(), PlaybackCommandOutcome.trackAndQueue);
    expect(backend.calls, ['setMode', 'load', 'seek']);
    expect(backend.lastRequest?.startIndex, 0);
    // 装载时的强制保存记的是 0；恢复流程末尾把恢复进度写回会话。
    expect(store.saves.first.position, Duration.zero);
    expect(store.saves.last.position, const Duration(seconds: 20));
    // 交接完成：恢复数据丢弃，进度通道交还底层（落在恢复进度上）。
    expect(session.hasRestoredSession, isFalse);
    expect(session.position.value, const Duration(seconds: 20));

    // 重复触发：恢复流程不在跑时也没得恢复（数据已丢弃）。
    expect(await session.resume(), PlaybackCommandOutcome.none);
  });

  test('恢复装载：进度不闪回 0、用户 seek 优先、末尾写回用户目标', () async {
    final gate = Completer<void>();
    build(backendOverride: _LoadingBackend(gate: gate));
    await seedSession(
      PlaybackSession(
        tracks: [_track('a')],
        index: 0,
        position: const Duration(seconds: 20),
      ),
    );
    expect(await session.load(), isTrue);

    // 记录进度通道暴露给 UI 的全部中间值。
    final observed = <Duration>[];
    session.position.addListener(() => observed.add(session.position.value));

    final resume = session.resume();
    await Future<void>.delayed(Duration.zero);
    // 装载把后端进度对齐到 0：期间不把它暴露给 UI（先回首部再跳回）。
    expect(session.position.value, const Duration(seconds: 20));
    expect(observed, isNot(contains(Duration.zero)));

    // 装载期间用户拖到 60s：恢复流程末尾以它为准。
    await session.seekToPosition(const Duration(seconds: 60));
    gate.complete();
    expect(await resume, PlaybackCommandOutcome.trackAndQueue);

    expect(
      (backend as _LoadingBackend).seeks.last,
      const Duration(seconds: 60),
    );
    expect(session.position.value, const Duration(seconds: 60));
    expect(store.saves.last.position, const Duration(seconds: 60));
    expect(observed, isNot(contains(Duration.zero)));
  });

  test('命令面 play / pause：按阶段路由，暂停只补写一次、播放不重写会话', () async {
    build(persistStore: true);

    // idle：没有可作用的对象，空操作。
    expect(await session.play(), PlaybackCommandOutcome.none);
    expect(await session.pause(), PlaybackCommandOutcome.none);
    expect(backend.calls, isEmpty);

    final a = _track('a');
    backend.emit(_live(a, playing: false));
    expect(store.calls, ['save']);

    // 暂停态收到播放键：下发 play，并作为显式动作提交一次 cursor。
    expect(await session.play(), PlaybackCommandOutcome.trackOnly);
    expect(backend.calls, ['play']);
    expect(store.saves, hasLength(2), reason: '播放是动作，提交一次进度');

    // 已在播：幂等，不再下发（旧 handler 的 hasTrack && !isPlaying 口径）。
    backend.emit(_live(a, playing: true, position: const Duration(seconds: 1)));
    expect(await session.play(), PlaybackCommandOutcome.none);
    expect(backend.calls, ['play']);

    // 暂停：快照监听会强制落盘；这里假后端不推暂停态，命令面补一次。
    final savesBeforePause = store.saves.length;
    final paused = await session.pause();
    expect(paused, PlaybackCommandOutcome.trackOnly);
    expect(paused.committed, isTrue, reason: '命令返回即已提交（ADR-0010）');
    expect(backend.calls, ['play', 'pause']);
    expect(store.saves, hasLength(savesBeforePause + 1));
    // 返回即已落盘（persistStore 写的是真实存储）。
    expect(
      (await PlaybackSessionStore().load())?.position,
      const Duration(seconds: 1),
    );
  });

  test('命令面 play / pause：恢复态点播放走恢复流程，暂停不误触发起播', () async {
    build();
    await seedSession(
      PlaybackSession(
        tracks: [_track('a'), _track('b')],
        index: 1,
        position: const Duration(seconds: 10),
      ),
    );
    expect(await session.load(), isTrue);

    // 恢复态没有真实播放：暂停是空操作，不能把 resume 当成 toggle。
    expect(await session.pause(), PlaybackCommandOutcome.none);
    expect(backend.calls, isEmpty);
    expect(session.phase, PlaybackSessionPhase.restored);

    expect(await session.play(), PlaybackCommandOutcome.trackAndQueue);
    expect(backend.calls, ['setMode', 'load', 'seek']);
    expect(session.hasRestoredSession, isFalse);
  });

  test('命令面切模式：live 写当前模式并立即落盘', () async {
    build();
    backend.emit(_live(_track('a'), mode: PlayMode.sequential));

    await session.togglePlayMode();

    expect(backend.calls.last, 'setMode');
    expect(facade.snapshot.value.mode, PlayMode.singleRepeat);
    expect(store.saves.last.mode, PlayMode.singleRepeat);
  });

  test('恢复态切模式：按保存会话的模式循环并落盘', () async {
    build();
    await seedSession(
      PlaybackSession(
        tracks: [_track('a')],
        index: 0,
        mode: PlayMode.sequential,
      ),
    );
    expect(await session.load(), isTrue);

    await session.togglePlayMode();

    expect(backend.calls, ['setMode']);
    expect(session.resolve(facade.snapshot.value).mode, PlayMode.singleRepeat);
    expect(store.saves.last.mode, PlayMode.singleRepeat);
  });

  test('命令面队列跳转：恢复态按下标恢复播放，live 直达后端，越界空操作', () async {
    build(backendOverride: _LoadingBackend());
    await seedSession(
      PlaybackSession(
        tracks: [_track('a'), _track('b')],
        index: 0,
        position: const Duration(seconds: 10),
      ),
    );
    expect(await session.load(), isTrue);

    expect(await session.playQueueIndex(5), PlaybackCommandOutcome.none);
    expect(backend.calls, isEmpty);

    expect(
      await session.playQueueIndex(1),
      PlaybackCommandOutcome.trackAndQueue,
    );
    expect(backend.calls, ['setMode', 'load']);
    expect((backend as _LoadingBackend).lastRequest?.startIndex, 1);
    expect(session.hasRestoredSession, isFalse);

    // 恢复后进入 live：同一命令转发给后端队列跳转。
    expect(await session.playQueueIndex(0), PlaybackCommandOutcome.trackOnly);
    expect(backend.calls.last, 'playQueueIndex:0');
    expect(await session.playQueueIndex(9), PlaybackCommandOutcome.none);
    expect(backend.calls.last, 'playQueueIndex:0');
  });

  test('系统停止命令：先提交当前会话再停，保留可恢复会话', () async {
    build(persistStore: true);
    final a = _track('a');
    backend.emit(_live(a, position: const Duration(seconds: 5)));
    expect(store.saves, hasLength(1));

    // 进度推进本身不落盘（没有周期写）；只有停止前的强制提交能带上它。
    backend.emit(_live(a, position: const Duration(seconds: 7)));
    expect(store.saves, hasLength(1));

    await session.stop();

    expect(store.saves, hasLength(2));
    expect(store.saves.last.position, const Duration(seconds: 7));
    expect(
      store.calls,
      isNot(contains('clear')),
      reason: '系统停止是「停在此处，可恢复」，不是 UI 的结束会话',
    );
    expect(backend.calls.last, 'stop');
    expect(await PlaybackSessionStore().load(), isNotNull);
  });

  test('UI 停止释放会话引用；系统停止仍保留可恢复会话', () async {
    build(persistStore: true);
    final a = _track('a');
    final b = _track('b');
    backend.emit(_live(a, queue: [a, b], position: const Duration(seconds: 5)));
    expect(session.lastWrittenSession, isNotNull);

    // UI 的「本次会话结束」：清持久化之外，也不再引用上一份完整队列。
    await session.stopPlayback();
    await session.pendingWrite;
    expect(session.lastWrittenSession, isNull, reason: '停止后常驻内存里不应还挂着一整份队列');

    // 系统媒体「停止」是可恢复语义：随后的整份落盘与引用都要保留。
    backend.emit(_live(_track('c'), queue: [_track('c')]));
    expect(session.lastWrittenSession, isNotNull);
    await session.stop();
    expect(session.lastWrittenSession, isNotNull);
    expect(store.calls.last, 'save');
    expect(
      store.calls.where((call) => call == 'clear'),
      hasLength(1),
      reason: '只有 UI 停止清持久化，系统停止不清',
    );
  });

  test('单写者：切歌整份落盘 → 暂停强制落盘 → 停止清除，写请求按序', () async {
    build(persistStore: true);
    final a = _track('a');

    // 切歌：整份落盘（含队列 / 下标 / 模式 / 上下文与当前进度）。
    backend.emit(_live(a, position: const Duration(seconds: 5)));
    expect(store.calls, ['save']);
    expect(store.saves.single.tracks.single.id.uri, 'fake:a');
    expect(store.saves.single.index, 0);
    expect(store.saves.single.position, const Duration(seconds: 5));

    // 进度推进：不落盘（快照内容没变）。
    backend.emit(_live(a, position: const Duration(seconds: 6)));
    expect(store.calls, ['save']);

    // 暂停：播放态转暂停是动作，立即落盘最新进度。
    backend.emit(
      _live(a, position: const Duration(seconds: 7), playing: false),
    );
    expect(store.calls, ['save', 'save']);
    expect(store.saves.last.position, const Duration(seconds: 7));

    // 停止：清除落在在途保存之后，不会被旧保存复活。
    await session.stopPlayback();
    await session.pendingWrite;
    expect(store.calls, ['save', 'save', 'clear']);
    expect(await PlaybackSessionStore().loadRaw(), isNull);
  });

  test('同步端口：远端应用 / 删除走同一个 store 写队列，与本地保存在途时按序', () async {
    build(persistStore: true);
    backend.emit(_live(_track('a'), position: const Duration(seconds: 1)));

    // 本地强制落盘与远端应用接连入队：pendingWrite 是同一个队列的尾巴，
    // 远端写入不会插到在途本地保存之前。
    final local = session.flushSession();
    final remote = session.applyRemote({
      PlaybackSessionStore.savedAtKey: 99000,
      'index': 0,
      'positionMs': 7000,
      'mode': 'sequential',
      'tracks': [
        {
          'sourceKey': 'fake',
          'id': 'b',
          'title': '远端曲目',
          'origin': 'lx',
          'payload': const <String, Object?>{},
        },
      ],
    });
    await session.pendingWrite;
    await Future.wait([local, remote]);

    // 切歌一次 + flush 一次 + 远端原样写入一次，顺序即调用顺序。
    expect(store.calls, ['save', 'save', 'saveRaw']);
    final raw = await session.loadRaw();
    expect(raw![PlaybackSessionStore.savedAtKey], 99000);
    expect((raw['tracks'] as List).single['title'], '远端曲目');

    // 远端删除也入同一队列：清除后不会被在途保存复活。
    await session.clearRemote();
    expect(store.calls.last, 'clear');
    expect(await PlaybackSessionStore().loadRaw(), isNull);
  });

  test('live seek：落点强制落盘并等写完（与系统 seek 同口径）', () async {
    build();
    final a = _track('a');
    backend.emit(_live(a, position: const Duration(seconds: 5)));
    expect(store.saves, hasLength(1));

    // 应用内 seek 也必须立即落盘（进程随后被杀可恢复新位置）。
    await session.seekToPosition(const Duration(seconds: 42));

    expect(backend.calls.last, 'seek');
    expect(store.saves, hasLength(2));
    expect(store.saves.last.position, const Duration(seconds: 42));
  });

  test('live 换源落盘：当前曲目交给快照监听，非当前槽位才补写一次', () async {
    build();
    final a = _track('a');
    final b = _track('b');
    backend.emit(_live(b, queue: [a, b], index: 1));
    expect(store.calls, ['save'], reason: '起播切歌一次');

    // 当前曲目换源：新 id 触发快照监听整份落盘，不应再补写一遍。
    await session.replaceTrack(b, _track('b2'));
    expect(store.calls, ['save', 'save']);
    expect(store.saves.last.tracks.map((track) => track.id.id), ['a', 'b2']);

    // 非当前槽位换源：current.id 不变，监听不触发，需要显式补写一次。
    await session.replaceTrack(a, _track('a2'));
    expect(store.calls, ['save', 'save', 'save']);
    expect(store.saves.last.tracks.map((track) => track.id.id), ['a2', 'b2']);
  });

  test('命令面换源：恢复态 / 未命中 no-op，live 转发并等会话提交', () async {
    build(persistStore: true);
    final a = _track('a');

    // 恢复态：自动换源只由真实播放失败触发，不作用于保存的会话。
    await seedSession(PlaybackSession(tracks: [a], index: 0));
    expect(await session.load(), isTrue);
    expect(
      await session.replaceQueueTrack('fake:a', _track('a2')),
      PlaybackCommandOutcome.none,
    );
    expect(backend.calls, isEmpty);
    expect(session.resolve(facade.snapshot.value).current?.id.id, 'a');

    // live：uri 不在队列 → no-op（不转发、不落盘）。
    backend.emit(_live(a, position: const Duration(seconds: 1)));
    expect(store.calls, ['save']);
    expect(
      await session.replaceQueueTrack('fake:zzz', _track('zzz2')),
      PlaybackCommandOutcome.none,
    );
    expect(backend.calls, isEmpty);
    expect(store.calls, ['save']);

    // 当前曲目换源：新 id 由快照监听整份落盘，命令面不再重复写。
    expect(
      await session.replaceQueueTrack('fake:a', _track('a2')),
      PlaybackCommandOutcome.trackAndQueue,
    );
    expect(backend.calls, ['replaceQueueTrack:fake:a']);
    expect(store.calls, ['save', 'save']);
    expect(store.saves.last.tracks.single.id.uri, 'fake:a2');
    // 返回即已写入（persistStore 写真实存储）：重开恢复的是新来源。
    expect(
      (await PlaybackSessionStore().load())?.tracks.single.id.uri,
      'fake:a2',
    );

    // 同 id 换元数据：current.id 未变、快照监听不触发，命令面补写一次。
    final renamed = Track(
      id: const TrackId('fake', 'a2'),
      title: 'Renamed',
      artists: [Artist(name: 'Artist')],
      duration: const Duration(seconds: 30),
      origin: TrackOrigin.lx,
      payload: const {'songmid': 'mid_a2'},
    );
    expect(
      await session.replaceQueueTrack('fake:a2', renamed),
      PlaybackCommandOutcome.trackAndQueue,
    );
    expect(store.calls, ['save', 'save', 'save']);
    expect(store.saves.last.tracks.single.title, 'Renamed');
  });

  test('进度 tick / loading 抖动：不写 payload，也不做周期落盘', () async {
    build();
    final a = _track('a');
    backend.emit(_live(a));
    expect(store.calls, ['save']);
    expect(store.positions, isEmpty);

    // 位置推进 / loading 抖动都不改变可持久化内容。
    backend.emit(_live(a, position: const Duration(seconds: 1)));
    backend.emit(_live(a, position: const Duration(seconds: 2), playing: true));
    backend.emit(_live(a, position: const Duration(seconds: 3)));
    expect(store.calls, ['save']);
    expect(store.positions, isEmpty);
  });

  test('进入后台提交一次；后台进度 tick 不再写', () async {
    final policy = PlaybackPowerPolicy();
    addTearDown(policy.dispose);
    build(powerPolicy: policy);
    final a = _track('a');
    backend.emit(_live(a, position: const Duration(seconds: 1)));
    expect(store.calls, ['save']);

    backend.emit(_live(a, position: const Duration(seconds: 2)));
    expect(store.calls, ['save']);

    policy.markBackground();
    expect(store.calls, ['save', 'save']);
    expect(store.saves.last.position, const Duration(seconds: 2));
    expect(store.saves.last.tracks.single.id.uri, 'fake:a');

    // 后台再推进很久：没有定时器，不写盘。
    backend.emit(_live(a, position: const Duration(seconds: 16)));
    backend.emit(_live(a, position: const Duration(seconds: 17)));
    expect(store.calls, ['save', 'save']);
    expect(store.positions, isEmpty);

    // 回前台也不额外写。
    policy.markForeground();
    expect(store.calls, ['save', 'save']);
  });

  test('后台暂停 / 切歌仍是动作落盘', () async {
    final policy = PlaybackPowerPolicy();
    addTearDown(policy.dispose);
    build(powerPolicy: policy);
    final a = _track('a');
    final b = _track('b');
    backend.emit(_live(a, position: const Duration(seconds: 1), queue: [a, b]));

    policy.markBackground();
    final savesBeforePause = store.saves.length;
    backend.emit(
      _live(
        a,
        position: const Duration(seconds: 2),
        playing: false,
        queue: [a, b],
      ),
    );
    expect(store.saves.length, savesBeforePause + 1);
    expect(store.saves.last.position, const Duration(seconds: 2));

    // 切歌：同样立即落盘（含新曲目 / 下标）。
    backend.emit(_live(b, index: 1, position: Duration.zero, queue: [a, b]));
    expect(store.saves.length, savesBeforePause + 2);
    expect(store.saves.last.tracks.map((track) => track.id.uri), [
      'fake:a',
      'fake:b',
    ]);
    expect(store.saves.last.index, 1);
  });

  test('曲末完成：单曲循环 / 列表循环单曲重播也落盘一次', () async {
    build();
    final a = _track('a');
    backend.emit(_live(a, position: const Duration(seconds: 29)));
    expect(store.saves, hasLength(1));

    backend.emitTrackCompletion(a);
    expect(store.saves, hasLength(2));
    expect(store.saves.last.position, const Duration(seconds: 29));

    // 单曲循环重播：后端从 0 重新推进，曲目 id 不变；完成事件再写一次。
    backend.emit(_live(a, position: Duration.zero));
    backend.emit(_live(a, position: const Duration(seconds: 30)));
    expect(store.saves, hasLength(2), reason: '进度 tick 本身不落盘');
    backend.emitTrackCompletion(a);
    expect(store.saves, hasLength(3));
  });

  test('队列追加（AI 续推）：内容变化写 payload，loading 抖动不重复写', () async {
    build();
    final a = _track('a');
    final b = _track('b');
    backend.emit(_live(a, queue: [a]));
    expect(store.saves, hasLength(1));

    await backend.enqueueTracks([b]);
    expect(store.saves, hasLength(2));
    expect(store.saves.last.tracks.map((track) => track.id.id), ['a', 'b']);

    // 同一队列 + 同一曲目，进度 / loading 抖动不写。
    backend.emit(_live(a, queue: [a, b], position: const Duration(seconds: 3)));
    expect(store.saves, hasLength(2));
  });

  test('flushSession：把最新进度写回并等它写完（退后台 / 退出入口）', () async {
    build(persistStore: true);
    final a = _track('a');
    backend.emit(_live(a, position: const Duration(seconds: 5)));

    backend.emit(_live(a, position: const Duration(seconds: 30)));
    expect(store.saves, hasLength(1), reason: '进度推进不会自动落盘');

    await session.flushSession();
    expect(store.saves, hasLength(2));
    expect(store.saves.last.position, const Duration(seconds: 30));
    // 返回时已落盘（不是入队就返回）。
    expect(
      (await PlaybackSessionStore().load())?.position,
      const Duration(seconds: 30),
    );
  });

  test('装载跳过恢复：无会话 / 已有真实播放都不进恢复态', () async {
    build();

    // 无会话。
    expect(await session.load(), isFalse);
    expect(session.phase, PlaybackSessionPhase.idle);

    // 已有真实播放（如系统媒体会话恢复）：恢复数据不覆盖它。
    backend.emit(_live(_track('c')));
    await seedSession(PlaybackSession(tracks: [_track('a')], index: 0));
    expect(await session.load(), isFalse);
    expect(session.hasRestoredSession, isFalse);
    expect(session.phase, PlaybackSessionPhase.live);
    expect(session.resolve(facade.snapshot.value).current?.id.id, 'c');
  });

  test('装载跳过恢复：开关关闭时不装载，会话数据保留', () async {
    SharedPreferences.setMockInitialValues({
      kRestoreSessionEnabled.name: false,
    });
    build();
    await seedSession(PlaybackSession(tracks: [_track('a')], index: 0));

    expect(await session.load(), isFalse);
    expect(session.restoreSessionEnabled, isFalse);
    expect(session.phase, PlaybackSessionPhase.idle);
    // 会话没有被清掉：重新开启开关后仍可恢复。
    expect(await PlaybackSessionStore().load(), isNotNull);
  });

  test('关闭恢复开关：撤下未播放的恢复态并报告变化', () async {
    build();
    await seedSession(
      PlaybackSession(
        tracks: [_track('a')],
        index: 0,
        position: const Duration(seconds: 12),
      ),
    );
    expect(await session.load(), isTrue);

    expect(await session.setRestoreSessionEnabled(false), isTrue);
    expect(session.restoreSessionEnabled, isFalse);
    expect(session.hasRestoredSession, isFalse);
    expect(session.phase, PlaybackSessionPhase.idle);
    // 幂等：再关一次不再报告变化。
    expect(await session.setRestoreSessionEnabled(false), isFalse);
  });

  test('reloadRestoreSessionPreference：值未变不报告变化', () async {
    final settings = SettingsRegistry(keys: kAllSettingsKeys);
    build(settings: settings);

    // 初始字段 = 键默认值（开），存储也是默认开 → 未变。
    expect(await session.reloadRestoreSessionPreference(), isFalse);
    expect(session.phase, PlaybackSessionPhase.idle);
  });

  test('reloadRestoreSessionPreference：远端关闭开关撤下恢复态并报告变化', () async {
    final settings = SettingsRegistry(keys: kAllSettingsKeys);
    build(settings: settings);
    await seedSession(
      PlaybackSession(
        tracks: [_track('a')],
        index: 0,
        position: const Duration(seconds: 12),
      ),
    );
    expect(await session.load(), isTrue);

    // 远端同步应用关闭值（协调者尚未看见）→ 重载钩子撤下恢复态。
    await settings.write(kRestoreSessionEnabled, false);
    expect(await session.reloadRestoreSessionPreference(), isTrue);
    expect(session.restoreSessionEnabled, isFalse);
    expect(session.hasRestoredSession, isFalse);
    expect(session.phase, PlaybackSessionPhase.idle);

    // 再 reload：值未变 → 不报告变化。
    expect(await session.reloadRestoreSessionPreference(), isFalse);
  });

  test('reloadRestoreSessionPreference：远端开启开关重新装载并报告变化', () async {
    SharedPreferences.setMockInitialValues({
      kRestoreSessionEnabled.name: false,
    });
    final settings = SettingsRegistry(keys: kAllSettingsKeys);
    build(settings: settings);
    await seedSession(
      PlaybackSession(
        tracks: [_track('a')],
        index: 0,
        position: const Duration(seconds: 12),
      ),
    );
    expect(await session.load(), isFalse, reason: '关闭时不装载');
    expect(session.phase, PlaybackSessionPhase.idle);

    // 远端同步应用开启值 → 重载钩子重新装载恢复态。
    await settings.write(kRestoreSessionEnabled, true);
    expect(await session.reloadRestoreSessionPreference(), isTrue);
    expect(session.restoreSessionEnabled, isTrue);
    expect(session.hasRestoredSession, isTrue);
    expect(session.resolve(facade.snapshot.value).current?.id.id, 'a');

    // 已装载：再 reload 值未变 → 不报告变化。
    expect(await session.reloadRestoreSessionPreference(), isFalse);
  });

  test('reloadRestoreSessionPreference：开启但无会话时不报告变化', () async {
    SharedPreferences.setMockInitialValues({
      kRestoreSessionEnabled.name: false,
    });
    final settings = SettingsRegistry(keys: kAllSettingsKeys);
    build(settings: settings);

    await settings.write(kRestoreSessionEnabled, true);
    expect(await session.reloadRestoreSessionPreference(), isFalse);
    expect(session.restoreSessionEnabled, isTrue);
    expect(session.phase, PlaybackSessionPhase.idle);
  });

  test('reloadFromStore：远端删除会话撤下恢复态；有会话则重新装载', () async {
    build();
    await seedSession(PlaybackSession(tracks: [_track('a')], index: 0));
    expect(await session.load(), isTrue);

    // 远端删除会话：撤下本地恢复态并报告变化。
    await PlaybackSessionStore().clear();
    expect(await session.reloadFromStore(), isTrue);
    expect(session.hasRestoredSession, isFalse);
    expect(session.phase, PlaybackSessionPhase.idle);

    // 远端写回新会话：重新装载。
    await seedSession(PlaybackSession(tracks: [_track('b')], index: 0));
    expect(await session.reloadFromStore(), isTrue);
    expect(session.hasRestoredSession, isTrue);
    expect(session.resolve(facade.snapshot.value).current?.id.id, 'b');

    // 真实播放中：恢复数据不覆盖它。
    backend.emit(_live(_track('c')));
    expect(await session.reloadFromStore(), isFalse);
    expect(session.resolve(facade.snapshot.value).current?.id.id, 'c');
  });

  test('恢复曲目展示回调：装载时报告恢复曲目（不落盘、不写历史）', () async {
    final restored = <Track>[];
    build(onRestoredTrack: restored.add);
    await seedSession(
      PlaybackSession(
        tracks: [_track('a'), _track('b')],
        index: 1,
        position: const Duration(seconds: 5),
      ),
    );

    expect(await session.load(), isTrue);
    expect(restored.map((track) => track.id.id), ['b']);
    // 装载不进写路径：恢复曲目并未真正起播。
    expect(store.calls, isEmpty);
  });
}
