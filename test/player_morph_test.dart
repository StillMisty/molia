import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/player_morph.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// 顶栏 ⇄ 播放页共享封面飞行：外观（圆角/描边/阴影）在双向飞行中
/// 都必须精确匹配起点与落点真身。
///
/// 曲目刻意不带封面 URL：飞行副本走回退路径，不触发网络取图；
/// 回退路径同样必须被 ClipRRect 裁剪（这也是回归项之一）。
Track _track() => Track(
      id: TrackId('fake', 'a'),
      title: 'Title',
      artists: [Artist(name: 'Artist')],
      album: 'Album',
      duration: const Duration(seconds: 30),
      origin: TrackOrigin.lx,
      payload: {'id': 'a'},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlaybackBackend backend;
  late PlaybackProvider playback;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    backend = FakePlaybackBackend();
    playback = buildTestPlaybackProvider(backend: backend);
    backend.emit(BackendSnapshot(
      current: _track(),
      queue: [_track()],
      currentIndex: 0,
      isPlaying: true,
      position: const Duration(seconds: 5),
      duration: const Duration(seconds: 30),
    ));
  });

  tearDown(() => playback.dispose());

  Future<void> pumpFlight(
    WidgetTester tester, {
    required bool toPage,
    required double value,
  }) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<PlaybackProvider>.value(
        value: playback,
        child: MaterialApp(
          home: PlayerMorphFlight(
            animation: AlwaysStoppedAnimation<double>(value),
            geometry: PlayerMorphGeometry(
              barCover: const Rect.fromLTWH(0, 0, 32, 32),
              pageCover: const Rect.fromLTWH(40, 80, 280, 280),
              toPage: toPage,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// 飞行副本图片的裁剪圆角（MorphCover 内部 ClipRRect）。
  BorderRadius coverClip(WidgetTester tester) {
    final clip = tester.widget<ClipRRect>(
      find.descendant(
        of: find.byType(MorphCover),
        matching: find.byType(ClipRRect),
      ),
    );
    return clip.borderRadius as BorderRadius;
  }

  /// 飞行副本外框（带描边的那个 Container）的装饰。
  BoxDecoration coverDecoration(WidgetTester tester) {
    final container = tester.widget<Container>(
      find.descendant(
        of: find.byType(PlayerMorphFlight),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Container &&
              widget.decoration is BoxDecoration &&
              (widget.decoration! as BoxDecoration).border != null,
        ),
      ),
    );
    return container.decoration! as BoxDecoration;
  }

  testWidgets('前进（顶栏 → 播放页）：起点顶栏外观、落点播放页外观', (tester) async {
    await pumpFlight(tester, toPage: true, value: 0);
    expect(tester.takeException(), isNull);
    // 起点与顶栏真身同款：圆角 8（裁剪也是 8）、无描边/阴影。
    expect(coverClip(tester), BorderRadius.circular(8));
    final start = coverDecoration(tester);
    expect(start.borderRadius, BorderRadius.circular(8));
    expect(start.border!.top.color.a, 0);
    expect(start.boxShadow!.first.color.a, 0);

    await pumpFlight(
      tester,
      toPage: true,
      value: PlayerMorphFlight.flightPortion,
    );
    // 落点与播放页真身同款：外圆角 18、1px 描边内缘裁剪 17、柔和阴影。
    expect(coverClip(tester), BorderRadius.circular(17));
    final end = coverDecoration(tester);
    expect(end.borderRadius, BorderRadius.circular(18));
    expect(end.border!.top.color.a, closeTo(1, 1e-6));
    expect(end.boxShadow!.first.color.a, closeTo(0.28, 1e-6));
  });

  testWidgets('反向（播放页 → 顶栏）：起点即播放页外观，落点为顶栏外观', (tester) async {
    // 回归：反向飞行起飞帧 t=0 位于播放页端。若外观仍按 t 插值，大封面
    // 圆角会瞬间从 18 掉到 8（看起来「圆角消失」），并在顶栏端以 18 落位
    // （与顶栏真身 8 不匹配）。
    await pumpFlight(tester, toPage: false, value: 0);
    expect(tester.takeException(), isNull);
    expect(coverClip(tester), BorderRadius.circular(17));
    final start = coverDecoration(tester);
    expect(start.borderRadius, BorderRadius.circular(18));
    expect(start.border!.top.color.a, closeTo(1, 1e-6));
    expect(start.boxShadow!.first.color.a, closeTo(0.28, 1e-6));

    // 落点与顶栏真身同款：圆角 8、无描边/阴影，交接瞬间不跳变。
    await pumpFlight(
      tester,
      toPage: false,
      value: PlayerMorphFlight.flightPortion,
    );
    expect(coverClip(tester), BorderRadius.circular(8));
    final end = coverDecoration(tester);
    expect(end.borderRadius, BorderRadius.circular(8));
    expect(end.border!.top.color.a, 0);
    expect(end.boxShadow!.first.color.a, 0);
  });
}
