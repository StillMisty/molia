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
import 'package:molia/widgets/playback_selectors.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 领域端口的 ValueNotifier 实现（与数据层实现同构）。
class _TestListenable<T> extends ValueNotifier<T>
    implements StateListenable<T> {
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
  Future<void> setMode(PlayMode mode) async =>
      calls.add('setMode:${mode.name}');

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
  @override
  void showMessage(String message) {}

  @override
  void showFailure(SourceFailure failure) {}
}

Track _track(String id) {
  return Track(
    id: TrackId('fake', id),
    title: 'Title $id',
    artists: [Artist(name: 'Artist $id')],
    album: 'Album',
    duration: const Duration(seconds: 30),
    origin: TrackOrigin.lx,
    payload: {'id': id},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('facade position 独立通道', () {
    test('position tick ≥250ms 才发（≤4Hz 去重），换曲直接对齐', () {
      final backend = FakeBackend();
      final facade = DefaultPlaybackFacade(backend: backend);
      final track = _track('a');

      var positionNotifies = 0;
      facade.position.addListener(() => positionNotifies++);

      void emitAt(int ms) => backend.emit(BackendSnapshot(
            current: track,
            queue: [track],
            currentIndex: 0,
            isPlaying: true,
            position: Duration(milliseconds: ms),
          ));

      // 首帧换曲（null → a）：直接对齐到 0（值未变不发）。
      backend.emit(BackendSnapshot(
        current: track,
        queue: [track],
        currentIndex: 0,
        isPlaying: true,
      ));

      // 10 次 100ms 间隔的 tick：只在累积差 ≥250ms 时发（300/600/900）。
      for (var ms = 100; ms <= 1000; ms += 100) {
        emitAt(ms);
      }
      expect(positionNotifies, 3, reason: '10 次 tick 只发 3 次（≤4Hz）');
      expect(facade.position.value, const Duration(milliseconds: 900),
          reason: '小于阈值的 tick 不更新通道值（最多滞后 250ms）');

      // 换曲（uri 变化）：即使进度回退也直接对齐，不受阈值抑制。
      final other = _track('b');
      backend.emit(BackendSnapshot(
        current: other,
        queue: [other],
        currentIndex: 0,
        isPlaying: true,
        position: Duration.zero,
      ));
      expect(positionNotifies, 4);
      expect(facade.position.value, Duration.zero);
    });

    test('position tick 不触发 PlaybackProvider.notifyListeners；快照变化仍通知',
        () async {
      final backend = FakeBackend();
      final facade = DefaultPlaybackFacade(backend: backend);
      final provider =
          PlaybackProvider(facade: facade, messenger: FakeMessenger());
      addTearDown(provider.dispose);

      var notifies = 0;
      provider.addListener(() => notifies++);

      final track = _track('a');
      BackendSnapshot snapshotAt(int ms, {bool isPlaying = true}) =>
          BackendSnapshot(
            current: track,
            queue: [track],
            currentIndex: 0,
            isPlaying: isPlaying,
            duration: const Duration(seconds: 60),
            position: Duration(milliseconds: ms),
          );

      backend.emit(snapshotAt(0));
      await Future<void>.delayed(const Duration(milliseconds: 350));
      final afterSnapshot = notifies;
      expect(afterSnapshot, greaterThanOrEqualTo(1), reason: '快照变化必须通知');

      // 纯 position tick（10 次 4Hz）：不得经过聚合 notifyListeners。
      for (var ms = 250; ms <= 2500; ms += 250) {
        backend.emit(snapshotAt(ms));
      }
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(notifies, afterSnapshot,
          reason: 'position tick 不得触发 notifyListeners');
      expect(provider.currentPosition, const Duration(milliseconds: 2500));
      expect(provider.currentTrack?['progress_ms'], 2500,
          reason: '兼容 map 的一次性读取仍拿到最新进度');

      // 快照（播放状态）变化：仍通知。
      backend.emit(snapshotAt(2500, isPlaying: false));
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(notifies, greaterThan(afterSnapshot));
    });
  });

  group('ProgressBarSelector', () {
    testWidgets('position 更新仅重建进度条自身，不重建兄弟节点', (tester) async {
      final backend = FakeBackend();
      final facade = DefaultPlaybackFacade(backend: backend);
      final provider =
          PlaybackProvider(facade: facade, messenger: FakeMessenger());
      addTearDown(provider.dispose);

      final track = _track('a');
      backend.emit(BackendSnapshot(
        current: track,
        queue: [track],
        currentIndex: 0,
        isPlaying: true,
        duration: const Duration(seconds: 60),
      ));

      var siblingBuilds = 0;
      var barBuilds = 0;
      var lastPositionMs = -1;
      var lastDuration = -1;
      var lastHasTrack = false;

      await tester.pumpWidget(
        ChangeNotifierProvider<PlaybackProvider>.value(
          value: provider,
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  Builder(
                    builder: (context) {
                      siblingBuilds++;
                      return const Text('sibling');
                    },
                  ),
                  ProgressBarSelector(
                    builder: (context, position, state, child) {
                      barBuilds++;
                      lastPositionMs = position.inMilliseconds;
                      lastDuration = state.duration;
                      lastHasTrack = state.hasTrack;
                      return const SizedBox(height: 8);
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      expect(lastHasTrack, isTrue);
      expect(lastDuration, 60000);

      final siblingBefore = siblingBuilds;
      final barBefore = barBuilds;

      backend.emit(BackendSnapshot(
        current: track,
        queue: [track],
        currentIndex: 0,
        isPlaying: true,
        duration: const Duration(seconds: 60),
        position: const Duration(milliseconds: 1500),
      ));
      await tester.pump();

      expect(barBuilds, greaterThan(barBefore), reason: '进度条应随 position 重建');
      expect(lastPositionMs, 1500);
      expect(siblingBuilds, siblingBefore, reason: '进度更新不得重建兄弟节点');
    });
  });

  group('PositionLineIndexBuilder', () {
    testWidgets('同一行内的 position tick 不重建，跨行才重建', (tester) async {
      final position = ValueNotifier<Duration>(Duration.zero);
      addTearDown(position.dispose);

      var builds = 0;
      var lastIndex = -1;
      int lineIndexFor(Duration value) => value.inSeconds ~/ 5; // 每 5s 一行

      await tester.pumpWidget(
        MaterialApp(
          home: PositionLineIndexBuilder(
            position: position,
            lineIndexFor: lineIndexFor,
            builder: (context, currentLineIndex) {
              builds++;
              lastIndex = currentLineIndex;
              return Text('$currentLineIndex');
            },
          ),
        ),
      );

      final before = builds;

      position.value = const Duration(seconds: 2); // 仍为第 0 行
      await tester.pump();
      expect(builds, before, reason: '行号未变不重建');

      position.value = const Duration(seconds: 6); // 跨到第 1 行
      await tester.pump();
      expect(builds, before + 1);
      expect(lastIndex, 1);
    });
  });
}
