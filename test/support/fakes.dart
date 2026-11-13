import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/data/settings/settings_registry.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/ports/library_store.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/playback_facade.dart';
import 'package:molia/domain/ports/state_listenable.dart';
import 'package:molia/domain/ports/ui_messenger.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/playback/playback_power_policy.dart';
import 'package:molia/playback/playback_session_coordinator.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/playback_feel_store.dart';
import 'package:molia/services/playback_observer.dart';
import 'package:molia/services/playback_session_store.dart';

/// 领域端口的 ValueNotifier 实现（与数据层实现同构，测试用）。
class TestListenable<T> extends ValueNotifier<T> implements StateListenable<T> {
  TestListenable(super.value);
}

/// 测试用的一帧播放状态：低频快照 + 独立进度。
///
/// 只用于把「同一时刻的快照与进度」打包传给 [FakePlaybackFacade.emitFrame]，
/// 不是生产快照类型；测试 helper 因此不必把 position 塞回快照。
typedef TestPlaybackFrame = ({PlaybackSnapshot snapshot, Duration position});

/// 记录调用与最后一次 load 请求的假播放引擎。
///
/// 实现 [PlaybackFacade]（单快照 + 独立 position 通道）而不是旧的双快照
/// 后端：测试与生产走同一套接口，`emit` 只接受 [PlaybackSnapshot]，
/// 进度通过独立参数推进，避免测试重新长出一套 position 快照。
class FakePlaybackFacade implements PlaybackFacade {
  final TestListenable<PlaybackSnapshot> _notifier = TestListenable(
    PlaybackSnapshot.empty,
  );

  /// 高频进度通道：由 [emit] 的可选 `position` 参数推进。
  final TestListenable<Duration> _position = TestListenable(Duration.zero);

  final List<String> calls = [];
  PlaybackRequest? lastRequest;
  List<Track>? lastEnqueued;

  /// 「播完当前歌曲后停止」标志的最近值（与真实引擎一样由定时关闭下发）。
  bool? stopAfterCurrentTrack;
  final List<bool> stopAfterCurrentTrackCalls = [];

  // 与真实服务一致用同步广播：完成事件必须在自动切歌的状态更新之前送达。
  final StreamController<Track> _trackCompletions =
      StreamController<Track>.broadcast(sync: true);

  /// 模拟后端自然播完当前曲目（自动切歌之前）。
  void emitTrackCompletion(Track track) => _trackCompletions.add(track);

  @override
  Stream<Track> get trackCompletions => _trackCompletions.stream;

  @override
  void setStopAfterCurrentTrack(bool enabled) {
    stopAfterCurrentTrack = enabled;
    stopAfterCurrentTrackCalls.add(enabled);
  }

  /// 音量下发记录（provider 音量链路测试用；有效音量含静音时的 0）。
  final List<double> volumes = [];

  /// 推一帧快照；`position` 同时推进独立进度通道（先于快照通知，与真实
  /// 引擎的发布顺序一致：协调者处理快照时会读到同一时刻的进度）。
  void emit(PlaybackSnapshot snapshot, {Duration? position}) {
    if (position != null) _position.value = position;
    _notifier.value = snapshot;
  }

  /// 推一帧「快照 + 进度」（helper 打包用）。
  void emitFrame(TestPlaybackFrame frame) =>
      emit(frame.snapshot, position: frame.position);

  @override
  StateListenable<PlaybackSnapshot> get snapshot => _notifier;

  @override
  StateListenable<Duration> get position => _position;

  @override
  Future<void> playTracks(PlaybackRequest request) async {
    calls.add('load');
    lastRequest = request;
  }

  @override
  Future<void> enqueueTracks(List<Track> tracks) async {
    calls.add('enqueueTracks');
    lastEnqueued = tracks;
    // 与真实引擎一致：追加后队列增长，推一帧状态让订阅方读到。
    final current = _notifier.value;
    _notifier.value = PlaybackSnapshot(
      current: current.current,
      queue: [...current.queue, ...tracks],
      currentIndex: current.currentIndex,
      next: current.next,
      previous: current.previous,
      previousOfPrevious: current.previousOfPrevious,
      upNext: [...current.upNext, ...tracks],
      upNextIndices: [
        if (current.upNextIndices.length == current.upNext.length)
          ...current.upNextIndices,
        for (var i = 0; i < tracks.length; i++) current.queue.length + i,
      ],
      isPlaying: current.isPlaying,
      isLoading: current.isLoading,
      duration: current.duration,
      mode: current.mode,
      context: current.context,
      quality: current.quality,
      error: current.error,
    );
  }

  /// 队列移动：记录调用并按真实队列语义推一帧快照（测试可断言 UI 跟随）。
  @override
  Future<bool> moveQueueIndex(int from, int to) async {
    calls.add('moveQueueIndex:$from:$to');
    final current = _notifier.value;
    if (current.mode == PlayMode.shuffle ||
        from < 0 ||
        to < 0 ||
        from >= current.queue.length ||
        to >= current.queue.length ||
        from == to ||
        from == current.currentIndex ||
        to == current.currentIndex) {
      return false;
    }
    final queue = List<Track>.of(current.queue);
    final track = queue.removeAt(from);
    queue.insert(to, track);
    var index = current.currentIndex;
    if (from < to && index > from && index <= to) index--;
    if (to < from && index >= to && index < from) index++;
    _notifier.value = PlaybackSnapshot(
      current: current.current,
      queue: List<Track>.unmodifiable(queue),
      currentIndex: index,
      next: current.next,
      previous: current.previous,
      previousOfPrevious: current.previousOfPrevious,
      upNext: current.upNext,
      upNextIndices: current.upNextIndices,
      isPlaying: current.isPlaying,
      isLoading: current.isLoading,
      duration: current.duration,
      mode: current.mode,
      context: current.context,
      quality: current.quality,
      error: current.error,
    );
    return true;
  }

  /// 队列移除：记录调用并按真实队列语义推一帧快照。
  @override
  Future<bool> removeQueueIndex(int index) async {
    calls.add('removeQueueIndex:$index');
    final current = _notifier.value;
    if (index < 0 ||
        index >= current.queue.length ||
        index == current.currentIndex) {
      return false;
    }
    final queue = List<Track>.of(current.queue);
    final removed = queue.removeAt(index);
    final currentIndex = index < current.currentIndex
        ? current.currentIndex - 1
        : current.currentIndex;
    _notifier.value = PlaybackSnapshot(
      current: current.current,
      queue: List<Track>.unmodifiable(queue),
      currentIndex: currentIndex,
      next: current.next,
      previous: current.previous,
      previousOfPrevious: current.previousOfPrevious,
      upNext: [
        for (final track in current.upNext)
          if (track != removed) track,
      ],
      upNextIndices: const [],
      isPlaying: current.isPlaying,
      isLoading: current.isLoading,
      duration: current.duration,
      mode: current.mode,
      context: current.context,
      quality: current.quality,
      error: current.error,
    );
    return true;
  }

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');

  /// 与真实引擎一致：按当前快照播放态选择 pause / play。
  @override
  Future<void> toggle() async {
    if (snapshot.value.isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  @override
  Future<void> seek(Duration position) async {
    calls.add('seek');
    _position.value = position;
  }

  @override
  Future<void> next() async => calls.add('next');

  @override
  Future<void> previous() async => calls.add('previous');

  @override
  Future<void> setMode(PlayMode mode) async {
    calls.add('setMode');
    // 与真实引擎一致：模式变化会推送状态，让 facade/provider 读到新值。
    final current = _notifier.value;
    _notifier.value = PlaybackSnapshot(
      current: current.current,
      queue: current.queue,
      currentIndex: current.currentIndex,
      next: current.next,
      previous: current.previous,
      previousOfPrevious: current.previousOfPrevious,
      upNext: current.upNext,
      isPlaying: current.isPlaying,
      isLoading: current.isLoading,
      duration: current.duration,
      mode: mode,
      context: current.context,
      quality: current.quality,
      error: current.error,
    );
  }

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> playQueueIndex(int index) async =>
      calls.add('playQueueIndex:$index');

  /// 切换音质：记录调用并推一帧带新 quality 的快照（与真实引擎一致）。
  @override
  Future<void> setCurrentQuality(String quality) async {
    calls.add('setCurrentQuality:$quality');
    final current = _notifier.value;
    _notifier.value = PlaybackSnapshot(
      current: current.current,
      queue: current.queue,
      currentIndex: current.currentIndex,
      next: current.next,
      previous: current.previous,
      previousOfPrevious: current.previousOfPrevious,
      upNext: current.upNext,
      isPlaying: current.isPlaying,
      isLoading: current.isLoading,
      duration: current.duration,
      mode: current.mode,
      context: current.context,
      quality: quality,
      error: current.error,
    );
  }

  @override
  Future<void> setVolume(double value) async {
    // 只记专用列表：`calls` 保持「播放控制委托」语义，供既有测试断言。
    volumes.add(value);
  }

  /// 暂停淡出进行中（真实服务在淡出窗口内为 true；假引擎默认 false）。
  @override
  bool pauseTransitioning = false;

  /// 播放手感 / 睡眠淡出的最近下发值（provider 与定时关闭接线测试用）。
  Duration? fadeDuration;
  bool? smartShuffle;
  final List<Duration> sleepFades = [];
  final List<bool> sleepFadeCancels = [];

  @override
  void setFadeDuration(Duration duration) => fadeDuration = duration;

  @override
  void setSmartShuffle(bool enabled) => smartShuffle = enabled;

  @override
  void startSleepFade(Duration duration) => sleepFades.add(duration);

  @override
  void cancelSleepFade({bool restore = true}) => sleepFadeCancels.add(restore);

  @override
  Future<void> updateTrackArtwork(String trackUri, Uri? artwork) async {
    calls.add('updateTrackArtwork:$trackUri');
    lastArtworkTrackUri = trackUri;
    lastArtworkUri = artwork?.toString();
  }

  /// 换源：记录调用并把快照中同 id 曲目替换为 [newTrack]（与真实引擎一致，
  /// 推一帧新队列让订阅方读到；替换当前曲目即重新加载，错误清空）。
  @override
  Future<void> replaceQueueTrack(String trackUri, Track newTrack) async {
    calls.add('replaceQueueTrack:$trackUri');
    lastReplacedTrackUri = trackUri;
    lastReplacedTrack = newTrack;
    final current = _notifier.value;
    Track swap(Track track) => track.id.uri == trackUri ? newTrack : track;
    _notifier.value = PlaybackSnapshot(
      current: current.current == null ? null : swap(current.current!),
      queue: [for (final track in current.queue) swap(track)],
      currentIndex: current.currentIndex,
      next: current.next == null ? null : swap(current.next!),
      previous: current.previous == null ? null : swap(current.previous!),
      previousOfPrevious: current.previousOfPrevious == null
          ? null
          : swap(current.previousOfPrevious!),
      upNext: [for (final track in current.upNext) swap(track)],
      isPlaying: current.isPlaying,
      isLoading: current.isLoading,
      duration: current.duration,
      mode: current.mode,
      context: current.context,
      quality: current.quality,
      error: null,
    );
  }

  /// 最近一次封面回写的曲目与 URL（封面补取测试用）。
  String? lastArtworkTrackUri;
  String? lastArtworkUri;

  /// 最近一次换源的旧曲目 uri 与新曲目（换源测试用）。
  String? lastReplacedTrackUri;
  Track? lastReplacedTrack;

  void dispose() {
    _trackCompletions.close();
    _position.dispose();
    _notifier.dispose();
  }
}

class FakeMessenger implements UiMessenger {
  final List<String> messages = [];
  final List<SourceFailure> failures = [];

  @override
  void showMessage(String message) => messages.add(message);

  @override
  void showFailure(SourceFailure failure) => failures.add(failure);
}

/// 用假播放引擎组装 PlaybackProvider（不触碰真实播放服务/SharedPreferences）。
///
/// 副作用观察者与组合根同构接线（先建观察者、provider 创建后挂接）；历史 /
/// 封面补取等经它生效，会话落盘由注入的会话协调者承担（恢复曲目展示接观察者）。
/// `provider.dispose` 会一并释放它们。
/// 测试用会话协调者：与 provider 共用同一 facade / 设置注册表（组合根口径）。
///
/// 直建 [PlaybackProvider] 的测试一律经它装配，避免每处重复
/// facade + store + settings 的接线；需要自定义 store / 观察者 / 功耗策略时
/// 显式传入。
PlaybackSessionCoordinator buildTestSessionCoordinator({
  required PlaybackFacade facade,
  SettingsRegistry? settings,
  PlaybackSessionStore? sessionStore,
  PlaybackObserver? observer,
  PlaybackPowerPolicy? powerPolicy,
  Future<Set<String>> Function()? recentTrackIds,
  bool Function()? smartShuffleEnabled,
}) {
  return PlaybackSessionCoordinator(
    facade: facade,
    store: sessionStore ?? PlaybackSessionStore(),
    settings: settings ?? SettingsRegistry(keys: kAllSettingsKeys),
    onRestoredTrack: observer?.showRestoredTrack,
    powerPolicy: powerPolicy,
    recentTrackIds: recentTrackIds,
    smartShuffleEnabled: smartShuffleEnabled,
  );
}

PlaybackProvider buildTestPlaybackProvider({
  PlaybackFacade? facade,
  UiMessenger? messenger,
  CatalogService? catalogService,
  LibraryStore? libraryRepository,
  PlaybackSessionStore? sessionStore,
  SettingsRegistry? settings,
  Future<String?> Function(Track track)? artworkResolver,
  Duration volumePersistDebounce = const Duration(milliseconds: 400),
  PlaybackFeelStore? feelStore,
  Future<Set<String>> Function()? recentTrackIds,
  bool Function()? smartShuffleEnabled,
}) {
  final playbackFacade = facade ?? FakePlaybackFacade();
  // 设置注册表一处实例：provider 的重载钩子与协调者的读取同源（组合根口径）。
  final registry = settings ?? SettingsRegistry(keys: kAllSettingsKeys);
  final observer = PlaybackObserver(
    facade: playbackFacade,
    libraryRepository: libraryRepository,
    artworkResolver: artworkResolver,
  );
  // 与组合根一致：智能随机开关读 provider 的当前值（provider 在本函数末尾
  // 构造，协调者的 load 在异步读库之后才真正用到这个闭包）。
  late final PlaybackProvider provider;
  final session = buildTestSessionCoordinator(
    facade: playbackFacade,
    sessionStore: sessionStore,
    settings: registry,
    observer: observer,
    recentTrackIds: recentTrackIds,
    smartShuffleEnabled:
        smartShuffleEnabled ?? () => provider.smartShuffleEnabled,
  );
  provider = PlaybackProvider(
    facade: playbackFacade,
    messenger: messenger ?? FakeMessenger(),
    catalogService: catalogService,
    observer: observer,
    sessionCoordinator: session,
    settings: registry,
    volumePersistDebounce: volumePersistDebounce,
    feelStore: feelStore,
  );
  // 与组合根同构：provider 先订阅、观察者后挂接（facade 监听顺序一致）。
  observer.attach();
  return provider;
}
