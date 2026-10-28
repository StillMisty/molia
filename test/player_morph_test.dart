import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/cover_appearance.dart';
import 'package:molia/widgets/molia_mark.dart';
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

  /// 飞行副本图片的裁剪圆角。
  ///
  /// 圆角由 `CoverCard` 的逐帧外观裁剪（`appearance.clip`）唯一给出；
  /// MorphCover 内部仍有一层零圆角 ClipRRect（图片子树的稳定壳），
  /// 取 `CoverCard` 下第一个 ClipRRect 才是对外可见的裁剪。
  BorderRadius coverClip(WidgetTester tester) {
    final clip = tester.widget<ClipRRect>(
      find
          .descendant(
            of: find.byType(CoverCard),
            matching: find.byType(ClipRRect),
          )
          .first,
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

  /// 飞行副本内回退图标尺寸（无封面时副本只走默认回退这一个 MoliaMark）。
  double fallbackIconSize(WidgetTester tester) {
    return tester
        .widget<MoliaMark>(
          find.descendant(
            of: find.byType(PlayerMorphFlight),
            matching: find.byType(MoliaMark),
          ),
        )
        .size!;
  }

  test('pageDeckRevealAt：进入尾段展开，离开时段时间对称地先收回', () {
    // 进入：前半程收在中心，落位帧完全展开。
    expect(PlayerMorphController.pageDeckRevealAt(0, toPage: true), 0);
    expect(PlayerMorphController.pageDeckRevealAt(0.4, toPage: true), 0);
    expect(PlayerMorphController.pageDeckRevealAt(0.55, toPage: true), 0);
    expect(PlayerMorphController.pageDeckRevealAt(1, toPage: true), 1);
    // 离开：progress=0 时仍完全展开，约 45% 行程就已收回中心；后段页面层
    // 已淡出，不再做看不见的收回。
    expect(PlayerMorphController.pageDeckRevealAt(0, toPage: false), 1);
    expect(PlayerMorphController.pageDeckRevealAt(0.45, toPage: false), 0);
    expect(PlayerMorphController.pageDeckRevealAt(0.55, toPage: false), 0);
    expect(PlayerMorphController.pageDeckRevealAt(1, toPage: false), 0);
    // 与进入方向时间对称：leave(p) == enter(1-p)。
    for (final double p in [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]) {
      expect(
        PlayerMorphController.pageDeckRevealAt(p, toPage: false),
        PlayerMorphController.pageDeckRevealAt(1 - p, toPage: true),
      );
    }
  });

  testWidgets('双向飞行：外观（圆角/描边/阴影）与回退图标严格取两端真身', (tester) async {
    // 端点值由 cover_appearance_test.dart 精确覆盖，这里只锁 widget 级接线：
    // 飞行副本的起点/落点必须与两端真身一致，不随插值参数发生跳变。
    const pageIcon = 280 * playerCoverFallbackIconRatio;

    // 前进（顶栏 → 播放页）起点：与顶栏真身同款——圆角 8（裁剪也是 8）、
    // 无描边/阴影，回退图标 22。
    await pumpFlight(tester, toPage: true, value: 0);
    expect(tester.takeException(), isNull);
    expect(coverClip(tester), BorderRadius.circular(8));
    final forwardStart = coverDecoration(tester);
    expect(forwardStart.borderRadius, BorderRadius.circular(8));
    expect(forwardStart.border!.top.color.a, 0);
    expect(forwardStart.boxShadow, isNull);
    expect(fallbackIconSize(tester), barCoverFallbackIconSize);

    // 飞行前 80% 完全不创建 BoxShadow（逐帧重画的主要 raster 嫌疑）。
    await pumpFlight(tester, toPage: true, value: 0.5);
    expect(coverDecoration(tester).boxShadow, isNull);
    await pumpFlight(tester, toPage: false, value: 0.5);
    expect(coverDecoration(tester).boxShadow, isNull);

    // 前进落点：与播放页真身同款——外圆角 18、1px 描边内缘裁剪 17、柔和
    // 阴影，回退图标（边长 × 0.35）。
    await pumpFlight(
      tester,
      toPage: true,
      value: PlayerMorphFlight.flightPortion,
    );
    expect(coverClip(tester), BorderRadius.circular(17));
    final forwardEnd = coverDecoration(tester);
    expect(forwardEnd.borderRadius, BorderRadius.circular(18));
    expect(forwardEnd.border!.top.color.a, closeTo(1, 1e-6));
    expect(forwardEnd.boxShadow!.first.color.a, closeTo(0.28, 1e-6));
    expect(fallbackIconSize(tester), closeTo(pageIcon, 1e-6));

    // 反向（播放页 → 顶栏）起飞帧 t=0 位于播放页端：回归——若外观仍按 t
    // 插值，大封面圆角会瞬间从 18 掉到 8（看起来「圆角消失」），并在顶栏端
    // 以 18 落位（与顶栏真身 8 不匹配）。
    await pumpFlight(tester, toPage: false, value: 0);
    expect(tester.takeException(), isNull);
    expect(coverClip(tester), BorderRadius.circular(17));
    final backwardStart = coverDecoration(tester);
    expect(backwardStart.borderRadius, BorderRadius.circular(18));
    expect(backwardStart.border!.top.color.a, closeTo(1, 1e-6));
    expect(backwardStart.boxShadow!.first.color.a, closeTo(0.28, 1e-6));
    expect(fallbackIconSize(tester), closeTo(pageIcon, 1e-6));

    // 反向落点与顶栏真身同款：圆角 8、无描边/阴影、图标 22，交接瞬间不跳变。
    await pumpFlight(
      tester,
      toPage: false,
      value: PlayerMorphFlight.flightPortion,
    );
    expect(coverClip(tester), BorderRadius.circular(8));
    final backwardEnd = coverDecoration(tester);
    expect(backwardEnd.borderRadius, BorderRadius.circular(8));
    expect(backwardEnd.border!.top.color.a, 0);
    expect(backwardEnd.boxShadow, isNull);
    expect(fallbackIconSize(tester), barCoverFallbackIconSize);
  });

  testWidgets('rectOf：返回含祖先缩放的真实屏幕矩形', (tester) async {
    // 回归：`localToGlobal(Offset.zero) & box.size` 在祖先有缩放（暂停态
    // 封面 0.98、按压 0.96）时给出错误尺寸/位置，飞行副本落位跳变。
    final controller = PlayerMorphController();
    addTearDown(controller.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: Transform.scale(
            scale: 0.5,
            alignment: Alignment.topLeft,
            child: SizedBox(key: key, width: 200, height: 200),
          ),
        ),
      ),
    );
    expect(controller.rectOf(key), const Rect.fromLTWH(0, 0, 100, 100));
  });
}
