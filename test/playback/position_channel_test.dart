import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/playback_selectors.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

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

  group('position 独立通道', () {
    test(
      'position tick 不触发 PlaybackProvider.notifyListeners；快照变化仍通知',
      () async {
        final facade = FakePlaybackFacade();
        final provider = buildTestPlaybackProvider(facade: facade);
        addTearDown(provider.dispose);

        var notifies = 0;
        provider.addListener(() => notifies++);

        final track = _track('a');
        PlaybackSnapshot snapshotAt({bool isPlaying = true}) =>
            PlaybackSnapshot(
              current: track,
              queue: [track],
              currentIndex: 0,
              isPlaying: isPlaying,
              duration: const Duration(seconds: 60),
            );

        facade.emit(snapshotAt(), position: Duration.zero);
        await Future<void>.delayed(const Duration(milliseconds: 350));
        final afterSnapshot = notifies;
        expect(afterSnapshot, greaterThanOrEqualTo(1), reason: '快照变化必须通知');

        // 纯 position tick（10 次 4Hz）：不得经过聚合 notifyListeners。
        for (var ms = 250; ms <= 2500; ms += 250) {
          facade.emit(snapshotAt(), position: Duration(milliseconds: ms));
        }
        await Future<void>.delayed(const Duration(milliseconds: 350));
        expect(
          notifies,
          afterSnapshot,
          reason: 'position tick 不得触发 notifyListeners',
        );
        expect(provider.currentPosition, const Duration(milliseconds: 2500));
        expect(
          provider.position.value,
          const Duration(milliseconds: 2500),
          reason: 'position 通道一次性读取拿到最新进度',
        );

        // 快照（播放状态）变化：仍通知。
        facade.emit(
          snapshotAt(isPlaying: false),
          position: const Duration(milliseconds: 2500),
        );
        await Future<void>.delayed(const Duration(milliseconds: 350));
        expect(notifies, greaterThan(afterSnapshot));
      },
    );
  });

  group('ProgressBarSelector', () {
    testWidgets('position 更新仅重建进度条自身，不重建兄弟节点', (tester) async {
      final facade = FakePlaybackFacade();
      final provider = buildTestPlaybackProvider(facade: facade);
      addTearDown(provider.dispose);

      final track = _track('a');
      facade.emit(
        PlaybackSnapshot(
          current: track,
          queue: [track],
          currentIndex: 0,
          isPlaying: true,
          duration: const Duration(seconds: 60),
        ),
      );

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

      facade.emit(
        PlaybackSnapshot(
          current: track,
          queue: [track],
          currentIndex: 0,
          isPlaying: true,
          duration: const Duration(seconds: 60),
        ),
        position: const Duration(milliseconds: 1500),
      );
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

    testWidgets('enabled=false 时不订阅 position，重新启用后同步最新行', (tester) async {
      final position = ValueNotifier<Duration>(Duration.zero);
      addTearDown(position.dispose);

      var builds = 0;
      var lastIndex = -1;
      int lineIndexFor(Duration value) => value.inSeconds ~/ 5;

      Widget build({required bool enabled}) => MaterialApp(
        home: PositionLineIndexBuilder(
          position: position,
          enabled: enabled,
          lineIndexFor: lineIndexFor,
          builder: (context, currentLineIndex) {
            builds++;
            lastIndex = currentLineIndex;
            return Text('$currentLineIndex');
          },
        ),
      );

      await tester.pumpWidget(build(enabled: false));
      expect(lastIndex, 0);
      final before = builds;

      // 隐藏期间进度继续走：没有监听 → 不重建、行号也不前进。
      position.value = const Duration(seconds: 12); // 第 2 行
      await tester.pump();
      expect(builds, before, reason: '禁用时不得订阅 position');
      expect(lastIndex, 0, reason: '禁用期间不跟随进度');

      // 重新可见：一次重建同步到最新行（而不是从旧行慢慢追）。
      await tester.pumpWidget(build(enabled: true));
      expect(builds, greaterThan(before));
      expect(lastIndex, 2, reason: '重新启用时同步最新行号');

      // 恢复订阅后继续跟随。
      position.value = const Duration(seconds: 18); // 第 3 行
      await tester.pump();
      expect(lastIndex, 3);
    });

    testWidgets('enabled 翻转与通道替换交错时不重复监听', (tester) async {
      final first = ValueNotifier<Duration>(Duration.zero);
      final second = ValueNotifier<Duration>(const Duration(seconds: 30));
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      var lastIndex = -1;
      int lineIndexFor(Duration value) => value.inSeconds ~/ 5;

      Widget build({
        required ValueNotifier<Duration> position,
        required bool enabled,
      }) => MaterialApp(
        home: PositionLineIndexBuilder(
          position: position,
          enabled: enabled,
          lineIndexFor: lineIndexFor,
          builder: (context, currentLineIndex) {
            lastIndex = currentLineIndex;
            return Text('$currentLineIndex');
          },
        ),
      );

      // 禁用 → 换通道：旧通道没挂监听，新通道也不该挂。
      await tester.pumpWidget(build(position: first, enabled: false));
      expect(lastIndex, 0);
      await tester.pumpWidget(build(position: second, enabled: false));
      expect(lastIndex, 6, reason: '父级重建时按新通道同步一次行号');
      second.value = const Duration(seconds: 60); // 第 12 行
      await tester.pump();
      expect(lastIndex, 6, reason: '禁用时换通道也不能开始监听');

      // 启用：同步最新行；之后两条通道交错变化只跟随当前通道。
      await tester.pumpWidget(build(position: second, enabled: true));
      expect(lastIndex, 12);

      await tester.pumpWidget(build(position: second, enabled: false));
      await tester.pumpWidget(build(position: second, enabled: true));
      second.value = const Duration(seconds: 66); // 第 13 行
      await tester.pump();
      expect(lastIndex, 13);
    });
  });
}
