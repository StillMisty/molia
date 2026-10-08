import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/player.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// 播放页重设计 smoke 测试：封面手势（点中间播放/暂停、点邻位切歌）、
/// 可拖动进度滑杆、迷你/完整连续过渡与共享封面飞行。
///
/// 曲目刻意不带封面 URL：避免测试中触发网络预取/取色路径。
Track _track(String id) => Track(
      id: TrackId('fake', id),
      title: 'Title $id',
      artists: [Artist(name: 'Artist $id')],
      album: 'Album',
      duration: const Duration(seconds: 30),
      origin: TrackOrigin.lx,
      payload: {'id': id},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlaybackBackend backend;
  late PlaybackProvider playback;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    backend = FakePlaybackBackend();
    playback = buildTestPlaybackProvider(backend: backend);
  });

  tearDown(() => playback.dispose());

  void emitThreeTracks() {
    final a = _track('a');
    final b = _track('b');
    final c = _track('c');
    backend.emit(BackendSnapshot(
      current: b,
      queue: [a, b, c],
      currentIndex: 1,
      upcoming: [c],
      isPlaying: true,
      position: const Duration(seconds: 5),
      duration: const Duration(seconds: 30),
    ));
  }

  Future<void> pumpPlayer(
    WidgetTester tester, {
    required AnimationController expand,
    VoidCallback? onToggleExpand,
    Size size = const Size(420, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: Scaffold(
            body: SizedBox(
              height: size.height,
              child: Player(
                expandAnimation: expand,
                onToggleExpand: onToggleExpand,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // 首帧会触发一次切歌入场动画（封面堆叠 460ms）：等它结束再断言
    // 稳态邻位封面的可点状态。
    await tester.pump(const Duration(milliseconds: 600));
  }

  /// 当前封面（唯一带横向拖动 + 点击手势的封面）。
  Finder mainCoverGesture() => find.byWidgetPredicate(
        (widget) =>
            widget is GestureDetector &&
            widget.onHorizontalDragStart != null &&
            widget.onTap != null,
      );

  /// 邻位封面（可点击切歌；child 是封面卡 SizedBox）。
  Finder sideCoverGesture() => find.byWidgetPredicate(
        (widget) =>
            widget is GestureDetector &&
            widget.onTap != null &&
            widget.onHorizontalDragStart == null &&
            widget.behavior == HitTestBehavior.opaque &&
            widget.child is SizedBox,
      );

  testWidgets('完整布局：进度滑杆可拖动、无渲染异常', (tester) async {
    emitThreeTracks();
    final expand = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 360),
      value: 1.0,
    );
    addTearDown(expand.dispose);

    await pumpPlayer(tester, expand: expand);

    expect(tester.takeException(), isNull);
    final slider = tester.widget<M3ESlider>(find.byType(M3ESlider));
    expect(slider.onChanged, isNotNull);
    expect(slider.onChangeEnd, isNotNull);
    expect(slider.value, 5000);
    expect(slider.max, 30000);
    expect(mainCoverGesture(), findsOneWidget);
  });

  testWidgets('点击封面播放/暂停；点击邻位封面切歌', (tester) async {
    emitThreeTracks();
    final expand = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 360),
      value: 1.0,
    );
    addTearDown(expand.dispose);

    await pumpPlayer(tester, expand: expand);

    // 中间封面：播放中 → 点击暂停。
    await tester.tap(mainCoverGesture());
    await tester.pump();
    expect(backend.calls, contains('pause'));

    // 右邻位封面 = 下一首（上一首历史为空，只有右侧可点）。
    // 注意：邻位封面只有外侧条带可见，中心被当前封面盖住——
    // 点击必须落在右缘，否则会命中当前封面（播放/暂停）。
    final side = sideCoverGesture();
    expect(side, findsOneWidget);
    final sideRect = tester.getRect(side);
    await tester.tapAt(Offset(sideRect.right - 8, sideRect.center.dy));
    await tester.pump();
    expect(backend.calls, contains('next'));
    // 让 provider 的通知节流计时器跑完，避免测试结束时报 pending timer。
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('拖动进度滑杆提交 seek', (tester) async {
    emitThreeTracks();
    final expand = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 360),
      value: 1.0,
    );
    addTearDown(expand.dispose);

    await pumpPlayer(tester, expand: expand);

    final slider = find.byType(M3ESlider);
    final rect = tester.getRect(slider);
    // 从滑杆中部拖到约 80% 位置（默认 5s/30s ≈ 17%）。
    await tester.dragFrom(
      Offset(rect.left + rect.width * 0.17, rect.center.dy),
      Offset(rect.width * 0.6, 0),
    );
    await tester.pump();
    expect(backend.calls, contains('seek'));
    // seek 落点等待计时器（1500ms 兜底）+ 通知节流计时器跑完。
    await tester.pump(const Duration(milliseconds: 1600));
  });

  testWidgets('收起/展开：高度连续过渡 + 封面飞行无异常', (tester) async {
    emitThreeTracks();
    final expand = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 360),
      value: 1.0,
    );
    addTearDown(expand.dispose);

    await pumpPlayer(tester, expand: expand, onToggleExpand: () {});

    // 收起：中途与终点都不应抛异常（封面飞行副本使用两端锚点）。
    // 滑杆波浪是常驻动画，不能用 pumpAndSettle，按固定时长推进。
    expand.reverse();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 220));
    expect(expand.value, 0.0);
    expect(tester.takeException(), isNull);

    // 展开：回到完整布局。
    expand.forward();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 220));
    expect(expand.value, 1.0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏（320 逻辑宽）不溢出', (tester) async {
    emitThreeTracks();
    final expand = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 360),
      value: 1.0,
    );
    addTearDown(expand.dispose);

    await pumpPlayer(
      tester,
      expand: expand,
      size: const Size(320, 700),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(M3ESlider), findsOneWidget);
  });
}
