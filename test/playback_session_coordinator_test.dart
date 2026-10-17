/// 播放会话协调者：三阶段状态机（idle → restored → live → idle）、恢复期命令
/// 路由、恢复态与 live 的交接、以及「PlaybackSessionStore 唯一写者」的落盘
/// 口径（整份 / 轻量进度 / 清除、1s 节流、1min 整份刷新、flush 可 await）。
///
/// 假后端 + 真实 facade + 记录型假 store：断言只经公开接口（resolve / phase /
/// 命令路由结果 / position）与注入的假入口，不读私有字段。时钟注入让节流
/// 边界可精确验证。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/playback/default_playback_facade.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/data/settings/settings_registry.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/playback/playback_session_coordinator.dart';
import 'package:molia/services/playback_session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

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

  late FakePlaybackBackend backend;
  late DefaultPlaybackFacade facade;
  late _RecordingSessionStore store;
  late PlaybackSessionCoordinator session;
  late DateTime now;

  /// 装配协调者：[backendOverride] 给特殊后端（慢取链装载），
  /// [persistStore] 让假 store 同时写真实存储，[onRestoredTrack] 记录恢复曲目，
  /// [settings] 给与 provider 同源的设置注册表（重载钩子测试）。
  PlaybackSessionCoordinator build({
    FakePlaybackBackend? backendOverride,
    bool persistStore = false,
    RestoredTrackReporter? onRestoredTrack,
    SettingsRegistry? settings,
  }) {
    backend = backendOverride ?? FakePlaybackBackend();
    facade = DefaultPlaybackFacade(backend: backend);
    store = _RecordingSessionStore(persist: persistStore);
    now = DateTime(2026, 1, 1, 12);
    session = PlaybackSessionCoordinator(
      facade: facade,
      store: store,
      settings: settings,
      clock: () => now,
      onRestoredTrack: onRestoredTrack,
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

    await seedSession(PlaybackSession(
      tracks: [_track('a'), _track('b')],
      index: 1,
      position: const Duration(seconds: 20),
      mode: PlayMode.shuffle,
      context: const PlaybackContext(name: '收藏', type: 'lx', uri: 'lx:收藏'),
    ));

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

  test('恢复态停止播放：撤下恢复数据、清空持久化会话', () async {
    build(persistStore: true);
    await seedSession(PlaybackSession(
      tracks: [_track('a')],
      index: 0,
      position: const Duration(seconds: 12),
    ));
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
    await seedSession(PlaybackSession(
      tracks: [_track('a'), _track('b')],
      index: 1,
      position: const Duration(seconds: 10),
    ));
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
    await seedSession(PlaybackSession(
      tracks: [_track('a'), _track('b')],
      index: 1,
      position: const Duration(seconds: 10),
    ));
    expect(await session.load(), isTrue);

    // 队尾：越界 no-op。
    expect(await session.skipToNext(), PlaybackCommandRoute.none);
    expect(backend.calls, isEmpty);
    expect(session.phase, PlaybackSessionPhase.restored);

    // 点恢复队列里的第一首：从该下标恢复播放（不 seek 回旧曲进度）。
    expect(
      await session.playQueueItemById(const TrackId('fake', 'a').uri),
      PlaybackCommandRoute.restored,
    );
    expect(backend.calls, ['setMode', 'load']);
    expect(backend.lastRequest?.startIndex, 0);
    expect(session.hasRestoredSession, isFalse);

    // 未命中（恢复队列里没有）：空操作。
    expect(await session.playQueueItemById('fake:zzz'),
        PlaybackCommandRoute.none);
  });

  test('恢复态：模式 / 换源改写保存的会话并落盘；未命中不算失败', () async {
    build();
    await seedSession(PlaybackSession(
      tracks: [_track('a'), _track('b')],
      index: 0,
      position: const Duration(seconds: 10),
    ));
    expect(await session.load(), isTrue);

    // 模式：后端先落地（shuffle 洗牌顺序依赖装载前模式），会话同步改写。
    await session.setPlayMode(PlayMode.shuffle);
    expect(backend.calls, ['setMode']);
    expect(session.resolve(facade.snapshot.value).mode, PlayMode.shuffle);
    expect(store.saves.last.mode, PlayMode.shuffle);

    // 换源命中恢复队列：原地替换并落盘（facade 队列为空，不转发）。
    expect(
      await session.replaceTrack(_track('a'), _track('a2')),
      isTrue,
    );
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
    await seedSession(PlaybackSession(
      tracks: [_track('a')],
      index: 0,
      position: const Duration(seconds: 20),
      mode: PlayMode.shuffle,
    ));
    expect(await session.load(), isTrue);

    expect(await session.resume(), PlaybackCommandRoute.restored);
    expect(backend.calls, ['setMode', 'load', 'seek']);
    expect(backend.lastRequest?.startIndex, 0);
    // 装载时的强制保存记的是 0；恢复流程末尾把恢复进度写回会话。
    expect(store.saves.first.position, Duration.zero);
    expect(store.saves.last.position, const Duration(seconds: 20));
    // 交接完成：恢复数据丢弃，进度通道交还底层（落在恢复进度上）。
    expect(session.hasRestoredSession, isFalse);
    expect(session.position.value, const Duration(seconds: 20));

    // 重复触发：恢复流程不在跑时也没得恢复（数据已丢弃）。
    expect(await session.resume(), PlaybackCommandRoute.none);
  });

  test('恢复装载：进度不闪回 0、用户 seek 优先、末尾写回用户目标', () async {
    final gate = Completer<void>();
    build(backendOverride: _LoadingBackend(gate: gate));
    await seedSession(PlaybackSession(
      tracks: [_track('a')],
      index: 0,
      position: const Duration(seconds: 20),
    ));
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
    expect(await resume, PlaybackCommandRoute.restored);

    expect((backend as _LoadingBackend).seeks.last,
        const Duration(seconds: 60));
    expect(session.position.value, const Duration(seconds: 60));
    expect(store.saves.last.position, const Duration(seconds: 60));
    expect(observed, isNot(contains(Duration.zero)));
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

    // 节流窗口内推进进度：不落盘。
    now = now.add(const Duration(milliseconds: 300));
    backend.emit(_live(a, position: const Duration(seconds: 6)));
    expect(store.calls, ['save']);

    // 暂停：强制落盘最新进度（不等节流窗口）。
    now = now.add(const Duration(milliseconds: 300));
    backend.emit(_live(a, position: const Duration(seconds: 7), playing: false));
    expect(store.calls, ['save', 'save']);
    expect(store.saves.last.position, const Duration(seconds: 7));

    // 停止：清除落在在途保存之后，不会被旧保存复活。
    await session.stopPlayback();
    await session.pendingWrite;
    expect(store.calls, ['save', 'save', 'clear']);
    expect(await PlaybackSessionStore().loadRaw(), isNull);
  });

  test('进度 tick：1s 节流只写轻量进度键，满一分钟整份刷新', () async {
    build();
    final a = _track('a');
    backend.emit(_live(a));
    expect(store.calls, ['save']);
    expect(store.positions, isEmpty);

    // 节流窗口内：进度 tick 不落盘。
    now = now.add(const Duration(milliseconds: 300));
    backend.emit(_live(a, position: const Duration(seconds: 1)));
    now = now.add(const Duration(milliseconds: 500));
    backend.emit(_live(a, position: const Duration(seconds: 2)));
    expect(store.positions, isEmpty);

    // 跨过 1s 窗口：只写轻量进度键（会话 JSON 不重写）。
    now = now.add(const Duration(milliseconds: 400));
    backend.emit(_live(a, position: const Duration(seconds: 3)));
    expect(store.positions, [3000]);
    expect(store.saves, hasLength(1));

    // 距上次整份落盘满 1 分钟：整份刷新一次（savedAt 抢占语义）。
    now = now.add(const Duration(minutes: 1));
    backend.emit(_live(a, position: const Duration(seconds: 4)));
    expect(store.saves, hasLength(2));
    expect(store.saves.last.position, const Duration(seconds: 4));
  });

  test('flushSession：节流窗口内强制落盘最新进度并等它写完', () async {
    build(persistStore: true);
    final a = _track('a');
    backend.emit(_live(a, position: const Duration(seconds: 5)));

    now = now.add(const Duration(milliseconds: 100));
    backend.emit(_live(a, position: const Duration(seconds: 30)));
    expect(store.saves, hasLength(1), reason: '节流窗口内不自动落盘');

    await session.flushSession();
    expect(store.saves, hasLength(2));
    expect(store.saves.last.position, const Duration(seconds: 30));
    // 返回时已落盘（不是入队就返回）。
    expect((await PlaybackSessionStore().load())?.position,
        const Duration(seconds: 30));
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
    await seedSession(PlaybackSession(
      tracks: [_track('a')],
      index: 0,
      position: const Duration(seconds: 12),
    ));
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
    await seedSession(PlaybackSession(
      tracks: [_track('a')],
      index: 0,
      position: const Duration(seconds: 12),
    ));
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
    await seedSession(PlaybackSession(
      tracks: [_track('a')],
      index: 0,
      position: const Duration(seconds: 12),
    ));
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
    await seedSession(PlaybackSession(
      tracks: [_track('a'), _track('b')],
      index: 1,
      position: const Duration(seconds: 5),
    ));

    expect(await session.load(), isTrue);
    expect(restored.map((track) => track.id.id), ['b']);
    // 装载不进写路径：恢复曲目并未真正起播。
    expect(store.calls, isEmpty);
  });
}
