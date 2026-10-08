import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/playback/default_playback_facade.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/playback_backend.dart';
import 'package:molia/domain/ports/state_listenable.dart';
import 'package:molia/domain/ports/ui_messenger.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 领域端口的 ValueNotifier 实现（与数据层实现同构）。
class _TestListenable<T> extends ValueNotifier<T> implements StateListenable<T> {
  _TestListenable(super.value);
}

class FakeBackend implements PlaybackBackend {
  final _TestListenable<BackendSnapshot> _notifier =
      _TestListenable(BackendSnapshot.empty);

  final List<String> calls = [];
  PlaybackRequest? lastRequest;

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
    calls.add('setMode:${mode.name}');
    // 真实后端会把模式变化反映到快照；Fake 保持一致。
    final current = _notifier.value;
    _notifier.value = BackendSnapshot(
      current: current.current,
      queue: current.queue,
      currentIndex: current.currentIndex,
      next: current.next,
      upcoming: current.upcoming,
      history: current.history,
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
  Future<void> setVolume(double value) async {}
}

class FakeMessenger implements UiMessenger {
  final List<String> messages = [];
  final List<SourceFailure> failures = [];

  @override
  void showMessage(String message) => messages.add(message);

  @override
  void showFailure(SourceFailure failure) => failures.add(failure);
}

Track _track(String id, {String? title}) {
  return Track(
    id: TrackId('fake', id),
    title: title ?? 'Title $id',
    artists: [Artist(name: 'Artist $id')],
    album: 'Album',
    duration: const Duration(seconds: 30),
    artwork: Artwork(uri: Uri.parse('https://img.example/$id.jpg')),
    origin: TrackOrigin.lx,
    payload: {'id': id},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DefaultPlaybackFacade 快照', () {
    test('值未变不发；position 变化不触发快照通知', () {
      final backend = FakeBackend();
      final facade = DefaultPlaybackFacade(backend: backend);
      final track = _track('a');

      var snapshotNotifies = 0;
      facade.snapshot.addListener(() => snapshotNotifies++);

      backend.emit(BackendSnapshot(
        current: track,
        queue: [track],
        currentIndex: 0,
        isPlaying: true,
      ));
      expect(snapshotNotifies, 1);

      // 新对象、值相等：合并重复事件。
      backend.emit(BackendSnapshot(
        current: track,
        queue: [track],
        currentIndex: 0,
        isPlaying: true,
      ));
      expect(snapshotNotifies, 1);

      // 仅 position 变化：走高频通道，不进快照。
      backend.emit(BackendSnapshot(
        current: track,
        queue: [track],
        currentIndex: 0,
        isPlaying: true,
        position: const Duration(seconds: 2),
      ));
      expect(snapshotNotifies, 1);

      // 播放状态变化：快照通知。
      backend.emit(BackendSnapshot(
        current: track,
        queue: [track],
        currentIndex: 0,
        isPlaying: false,
      ));
      expect(snapshotNotifies, 2);
    });

    test('position 通道 ≥250ms 变化才发（≤4Hz），换曲直接对齐', () {
      final backend = FakeBackend();
      final facade = DefaultPlaybackFacade(backend: backend);
      final track = _track('a');

      var positionNotifies = 0;
      facade.position.addListener(() => positionNotifies++);

      void emitPosition(int ms) => backend.emit(BackendSnapshot(
            current: track,
            queue: [track],
            currentIndex: 0,
            isPlaying: true,
            position: Duration(milliseconds: ms),
          ));

      emitPosition(300); // 换曲（null → a）直接对齐
      expect(positionNotifies, 1);
      expect(facade.position.value, const Duration(milliseconds: 300));

      emitPosition(400); // Δ100ms：不发
      expect(positionNotifies, 1);

      emitPosition(700); // Δ300ms：发
      expect(positionNotifies, 2);

      emitPosition(800); // Δ100ms：不发
      expect(positionNotifies, 2);

      // 换曲后即使进度回退到 0 也直接对齐（不受阈值抑制）。
      final other = _track('b');
      backend.emit(BackendSnapshot(
        current: other,
        queue: [other],
        currentIndex: 0,
        isPlaying: true,
        position: Duration.zero,
      ));
      expect(positionNotifies, 3);
      expect(facade.position.value, Duration.zero);
    });

    test('错误归一化写入 snapshot.error', () {
      final backend = FakeBackend();
      final facade = DefaultPlaybackFacade(backend: backend);
      final track = _track('a');
      final failure = SourceFailure.from('LxEngineException: 音源不可用');

      backend.emit(BackendSnapshot(
        current: track,
        queue: [track],
        currentIndex: 0,
        error: failure,
      ));

      expect(facade.snapshot.value.error, failure);
      expect(facade.snapshot.value.error!.kind, FailureKind.scriptError);
      expect(facade.isLocal, isTrue);
    });
  });

  group('DefaultPlaybackFacade 控制委托', () {
    test('load/play/pause/seek/next/previous/setMode/stop 全部委托 backend',
        () async {
      final backend = FakeBackend();
      final facade = DefaultPlaybackFacade(backend: backend);
      final track = _track('a');

      final request = PlaybackRequest(
        tracks: [track],
        startIndex: 0,
        context: const PlaybackContext(
          name: '集成测试',
          type: 'lx',
          uri: 'lx:集成测试',
        ),
      );
      await facade.playTracks(request);
      expect(backend.calls, ['load']);
      expect(backend.lastRequest, request);

      await facade.toggle(); // 未播放 → play
      expect(backend.calls.last, 'play');

      backend.emit(BackendSnapshot(
        current: track,
        queue: [track],
        currentIndex: 0,
        isPlaying: true,
      ));
      await facade.toggle(); // 播放中 → pause
      expect(backend.calls.last, 'pause');

      await facade.seek(const Duration(seconds: 3));
      expect(backend.calls.last, 'seek');
      expect(facade.position.value, const Duration(seconds: 3),
          reason: 'seek 后进度立即对齐，不等待后端 tick');

      await facade.next();
      expect(backend.calls.last, 'next');
      await facade.previous();
      expect(backend.calls.last, 'previous');
      await facade.setMode(PlayMode.shuffle);
      expect(backend.calls.last, 'setMode:shuffle');
      await facade.playQueueIndex(1);
      expect(backend.calls.last, 'playQueueIndex:1');
      await facade.stop();
      expect(backend.calls.last, 'stop');
    });

    test('playTrackInContext：队列内跳转 / 队列外单曲加载', () async {
      final backend = FakeBackend();
      final facade = DefaultPlaybackFacade(backend: backend);
      final trackA = _track('a');
      final trackB = _track('b');

      backend.emit(BackendSnapshot(
        current: trackA,
        queue: [trackA, trackB],
        currentIndex: 0,
        upcoming: [trackB],
      ));

      await facade.playTrackInContext(trackB);
      expect(backend.calls.last, 'playQueueIndex:1');

      final trackC = _track('c');
      await facade.playTrackInContext(trackC);
      expect(backend.calls.last, 'load');
      expect(backend.lastRequest!.tracks, [trackC]);
      expect(backend.lastRequest!.startIndex, 0);
    });
  });

  group('领域快照形状', () {
    test('current / next / upcoming / history', () {
      final backend = FakeBackend();
      final facade = DefaultPlaybackFacade(backend: backend);
      final previous = _track('z');
      final current = _track('a');
      final next = _track('b');

      backend.emit(BackendSnapshot(
        current: current,
        queue: [previous, current, next],
        currentIndex: 1,
        next: next,
        upcoming: [next],
        history: [previous],
        isPlaying: true,
        duration: const Duration(seconds: 42),
        context: const PlaybackContext(
          name: '集成测试',
          type: 'lx',
          uri: 'lx:集成测试',
        ),
      ));

      final snapshot = facade.snapshot.value;
      expect(snapshot.current?.id, const TrackId('fake', 'a'));
      expect(snapshot.current?.title, 'Title a');
      expect(snapshot.next?.id, const TrackId('fake', 'b'));
      expect(snapshot.upcoming.map((track) => track.id.id), ['b']);
      expect(snapshot.history.map((track) => track.id.id), ['z']);
      expect(snapshot.isPlaying, isTrue);
      expect(snapshot.duration, const Duration(seconds: 42));
      expect(snapshot.context?.name, '集成测试');

      // 队列末尾（顺序模式）→ next 为 null（由后端解析），upcoming 为空。
      backend.emit(BackendSnapshot(
        current: next,
        queue: [previous, current, next],
        currentIndex: 2,
        mode: PlayMode.sequential,
      ));
      expect(facade.snapshot.value.next, isNull);
      expect(facade.snapshot.value.upcoming, isEmpty);
    });

    test('进度不进入低频快照；seek 立即对齐 position 通道', () async {
      final backend = FakeBackend();
      final facade = DefaultPlaybackFacade(backend: backend);
      final track = _track('a');
      backend.emit(BackendSnapshot(
        current: track,
        queue: [track],
        currentIndex: 0,
        isPlaying: true,
      ));
      expect(facade.snapshot.value.current?.title, 'Title a');
      expect(facade.position.value, Duration.zero);

      await facade.seek(const Duration(milliseconds: 1500));
      expect(facade.position.value, const Duration(milliseconds: 1500));
      // 快照值不变（position 不参与低频快照相等性）。
      expect(facade.snapshot.value.current?.title, 'Title a');
    });
  });

  group('PlaybackProvider（facade + messenger 注入）', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('状态读领域快照；错误经 messenger 上报；控制委托 backend',
        () async {
      final backend = FakeBackend();
      final facade = DefaultPlaybackFacade(backend: backend);
      final messenger = FakeMessenger();
      final provider = PlaybackProvider(facade: facade, messenger: messenger);
      addTearDown(provider.dispose);

      final track = _track('a');
      backend.emit(BackendSnapshot(
        current: track,
        queue: [track],
        currentIndex: 0,
        isPlaying: true,
        error: SourceFailure.from('LxEngineException: boom'),
      ));

      expect(provider.hasTrack, isTrue);
      expect(provider.isPlaying, isTrue);
      expect(provider.isLoading, isFalse);
      expect(provider.snapshot.current?.title, 'Title a');
      expect(provider.currentMode, PlayMode.sequential);

      expect(messenger.failures, hasLength(1));
      expect(messenger.failures.single.kind, FailureKind.scriptError);

      await provider.togglePlayPause();
      expect(backend.calls, contains('pause'));

      await provider.setPlayMode(PlayMode.shuffle);
      expect(backend.calls, contains('setMode:shuffle'));
      expect(provider.currentMode, PlayMode.shuffle);

      await provider.stopLocalPlayback();
      expect(backend.calls, contains('stop'));
    });

    test('playLocalQueueItemById 基于 facade 队列实现', () async {
      final backend = FakeBackend();
      final facade = DefaultPlaybackFacade(backend: backend);
      final provider =
          PlaybackProvider(facade: facade, messenger: FakeMessenger());
      addTearDown(provider.dispose);

      final trackA = _track('a');
      final trackB = _track('b');
      backend.emit(BackendSnapshot(
        current: trackA,
        queue: [trackA, trackB],
        currentIndex: 0,
        upcoming: [trackB],
      ));

      // 命中队列：跳转播放
      await provider.playLocalQueueItemById('fake:b');
      expect(backend.calls.last, 'playQueueIndex:1');

      // 未命中队列：不做任何操作
      final callsBefore = List<String>.from(backend.calls);
      await provider.playLocalQueueItemById('fake:missing');
      expect(backend.calls, callsBefore);
    });
  });
}
