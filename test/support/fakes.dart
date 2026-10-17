import 'package:flutter/foundation.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/data/playback/default_playback_facade.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/ports/library_store.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/playback_backend.dart';
import 'package:molia/domain/ports/state_listenable.dart';
import 'package:molia/domain/ports/ui_messenger.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/playback/playback_session_coordinator.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/playback_observer.dart';
import 'package:molia/services/playback_session_store.dart';

/// 领域端口的 ValueNotifier 实现（与数据层实现同构，测试用）。
class TestListenable<T> extends ValueNotifier<T> implements StateListenable<T> {
  TestListenable(super.value);
}

/// 记录调用与最后一次 load 请求的假播放后端。
class FakePlaybackBackend implements PlaybackBackend {
  final TestListenable<BackendSnapshot> _notifier =
      TestListenable(BackendSnapshot.empty);

  final List<String> calls = [];
  PlaybackRequest? lastRequest;
  List<Track>? lastEnqueued;

  /// 音量下发记录（provider 音量链路测试用；有效音量含静音时的 0）。
  final List<double> volumes = [];

  void emit(BackendSnapshot snapshot) => _notifier.value = snapshot;

  @override
  PlaybackBackendKind get kind => PlaybackBackendKind.local;

  @override
  PlaybackCapabilities get capabilities => const PlaybackCapabilities(
        seek: true,
        next: true,
        previous: true,
        queue: true,
        setMode: true,
        volume: true,
      );

  @override
  bool canHandle(Track track) => true;

  @override
  StateListenable<BackendSnapshot> get state => _notifier;

  @override
  Future<void> load(PlaybackRequest request) async {
    calls.add('load');
    lastRequest = request;
  }

  @override
  Future<void> enqueueTracks(List<Track> tracks) async {
    calls.add('enqueueTracks');
    lastEnqueued = tracks;
    // 与真实后端一致：追加后队列增长，推一帧状态让订阅方读到。
    final current = _notifier.value;
    _notifier.value = BackendSnapshot(
      current: current.current,
      queue: [...current.queue, ...tracks],
      currentIndex: current.currentIndex,
      next: current.next,
      previous: current.previous,
      upNext: [...current.upNext, ...tracks],
      isPlaying: current.isPlaying,
      isLoading: current.isLoading,
      position: current.position,
      duration: current.duration,
      mode: current.mode,
      context: current.context,
      error: current.error,
    );
  }

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> seek(Duration position) async => calls.add('seek');

  @override
  Future<void> next() async => calls.add('next');

  @override
  Future<void> previous() async => calls.add('previous');

  @override
  Future<void> setMode(PlayMode mode) async {
    calls.add('setMode');
    // 与真实后端一致：模式变化会推送状态，让 facade/provider 读到新值。
    final current = _notifier.value;
    _notifier.value = BackendSnapshot(
      current: current.current,
      queue: current.queue,
      currentIndex: current.currentIndex,
      next: current.next,
      previous: current.previous,
      upNext: current.upNext,
      isPlaying: current.isPlaying,
      isLoading: current.isLoading,
      position: current.position,
      duration: current.duration,
      mode: mode,
      context: current.context,
      error: current.error,
    );
  }

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> playQueueIndex(int index) async =>
      calls.add('playQueueIndex:$index');

  @override
  Future<bool> toggleFavorite(Track track) async => false;

  @override
  Future<void> setVolume(double value) async {
    // 只记专用列表：`calls` 保持「播放控制委托」语义，供既有测试断言。
    volumes.add(value);
  }

  @override
  Future<void> updateTrackArtwork(String trackUri, Uri? artwork) async {
    calls.add('updateTrackArtwork:$trackUri');
    lastArtworkTrackUri = trackUri;
    lastArtworkUri = artwork?.toString();
  }

  /// 换源：记录调用并把快照中同 id 曲目替换为 [newTrack]（与真实后端一致，
  /// 推一帧新队列让订阅方读到；替换当前曲目即重新加载，错误清空）。
  @override
  Future<void> replaceQueueTrack(String trackUri, Track newTrack) async {
    calls.add('replaceQueueTrack:$trackUri');
    lastReplacedTrackUri = trackUri;
    lastReplacedTrack = newTrack;
    final current = _notifier.value;
    Track swap(Track track) => track.id.uri == trackUri ? newTrack : track;
    _notifier.value = BackendSnapshot(
      current: current.current == null ? null : swap(current.current!),
      queue: [for (final track in current.queue) swap(track)],
      currentIndex: current.currentIndex,
      next: current.next == null ? null : swap(current.next!),
      previous: current.previous == null ? null : swap(current.previous!),
      upNext: [for (final track in current.upNext) swap(track)],
      isPlaying: current.isPlaying,
      isLoading: current.isLoading,
      position: current.position,
      duration: current.duration,
      mode: current.mode,
      context: current.context,
      error: null,
    );
  }

  /// 最近一次封面回写的曲目与 URL（封面补取测试用）。
  String? lastArtworkTrackUri;
  String? lastArtworkUri;

  /// 最近一次换源的旧曲目 uri 与新曲目（换源测试用）。
  String? lastReplacedTrackUri;
  Track? lastReplacedTrack;
}

class FakeMessenger implements UiMessenger {
  final List<String> messages = [];
  final List<SourceFailure> failures = [];

  @override
  void showMessage(String message) => messages.add(message);

  @override
  void showFailure(SourceFailure failure) => failures.add(failure);
}

/// 用假后端组装 PlaybackProvider（不触碰真实播放服务/SharedPreferences）。
///
/// 副作用观察者与组合根同构接线（先建观察者、provider 创建后挂接）；历史 /
/// 封面补取等经它生效，会话落盘由注入的会话协调者承担（恢复曲目展示接观察者）。
/// `provider.dispose` 会一并释放它们。
PlaybackProvider buildTestPlaybackProvider({
  FakePlaybackBackend? backend,
  CatalogService? catalogService,
  LibraryStore? libraryRepository,
  PlaybackSessionStore? sessionStore,
  Future<String?> Function(Track track)? artworkResolver,
}) {
  final b = backend ?? FakePlaybackBackend();
  final facade = DefaultPlaybackFacade(backend: b);
  final store = sessionStore ?? PlaybackSessionStore();
  final observer = PlaybackObserver(
    facade: facade,
    libraryRepository: libraryRepository,
    artworkResolver: artworkResolver,
  );
  final session = PlaybackSessionCoordinator(
    facade: facade,
    store: store,
    onRestoredTrack: observer.showRestoredTrack,
  );
  final provider = PlaybackProvider(
    facade: facade,
    messenger: FakeMessenger(),
    catalogService: catalogService,
    observer: observer,
    sessionCoordinator: session,
  );
  // 与组合根同构：provider 先订阅、观察者后挂接（facade 监听顺序一致）。
  observer.attach();
  return provider;
}
