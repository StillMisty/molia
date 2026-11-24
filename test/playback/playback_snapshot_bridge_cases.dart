import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/app_providers.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';
import '../support/provider_test_scope.dart';

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

  group('播放快照桥', () {
    test('UI 读快照、命令走控制器，两者指向同一启动期实例', () async {
      final facade = FakePlaybackFacade();
      final provider = buildTestPlaybackProvider(facade: facade);
      addTearDown(provider.dispose);
      final scope = ProviderTestScope()..put<PlaybackProvider>(provider);
      await provider.preferencesReady;

      expect(scope.container.read(playbackProvider), isA<PlaybackState>());
      expect(
        identical(scope.container.read(playbackControllerProvider), provider),
        isTrue,
        reason: '控制器读的就是组合根登记的实例',
      );

      var snapshotNotifies = 0;
      final subscription = scope.container.listen(
        playbackProvider,
        (_, _) => snapshotNotifies++,
      );
      addTearDown(subscription.close);

      final track = _track('a');
      PlaybackSnapshot frame({bool isPlaying = true}) => PlaybackSnapshot(
        current: track,
        queue: [track],
        currentIndex: 0,
        isPlaying: isPlaying,
        duration: const Duration(seconds: 30),
      );

      facade.emit(frame());
      await Future<void>.delayed(const Duration(milliseconds: 350));

      final state = scope.container.read(playbackProvider);
      expect(state.snapshot.current?.id, track.id);
      expect(state.isPlaying, isTrue);
      expect(state.hasTrack, isTrue);
      expect(snapshotNotifies, greaterThan(0), reason: '曲目变化必须镜像到快照');

      // 高频进度不进快照：只为当前位置发 tick，不为它重建 Riverpod 状态。
      final notifiesBeforeTicks = snapshotNotifies;
      for (var ms = 250; ms <= 1000; ms += 250) {
        facade.emit(frame(), position: Duration(milliseconds: ms));
      }
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(snapshotNotifies, notifiesBeforeTicks, reason: '进度 tick 不得触发快照通知');
      expect(
        scope.container.read(playbackControllerProvider).currentPosition,
        const Duration(milliseconds: 1000),
        reason: '进度仍从控制器的高频通道读取',
      );

      // 命令经控制器落地，快照随后跟上。
      await scope.container.read(playbackControllerProvider).toggleMute();
      expect(scope.container.read(playbackProvider).muted, isTrue);
    });

    test('可空版：未接线时快照与控制器都为 null', () {
      final scope = ProviderTestScope();

      expect(scope.container.read(maybePlaybackProvider), isNull);
      expect(scope.container.read(maybePlaybackControllerProvider), isNull);
    });
  });
}
