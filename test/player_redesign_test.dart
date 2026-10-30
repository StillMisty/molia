import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/cover_appearance.dart';
import 'package:molia/widgets/molia_mark.dart';
import 'package:molia/widgets/player.dart';
import 'package:molia/widgets/player_cover_deck.dart';
import 'package:molia/widgets/player_morph.dart';
import 'package:molia/widgets/seek_bar.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// 播放页 smoke 测试：封面手势（点中间播放/暂停、点邻位切歌）、
/// 可拖动进度滑杆、迷你/完整连续过渡与共享封面飞行。
///
/// 曲目刻意不带封面 URL：避免测试触发真实网络图片请求 / 取色路径。
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
      next: c,
      previous: a,
      isPlaying: true,
      position: const Duration(seconds: 5),
      duration: const Duration(seconds: 30),
    ));
  }

  /// 挂载播放器（高度用紧约束：与既有用例的既有口径一致）。
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
    // 等首帧落定后再断言稳态邻位封面的可点状态（恢复态首帧已是稳态）。
    await tester.pump(const Duration(milliseconds: 900));
  }

  /// 封面区手势宿主（唯一带横向拖动识别器的 GestureDetector；点击由
  /// 中心封面卡片自己承接）。
  Finder coverSwipeHost() => find.byKey(Player.artworkSwipeHostKey);

  /// 左/右邻位封面手势（可点击切歌；child 是封面卡 [CoverCard]）。
  ///
  /// 两侧都展示身份时堆叠里并存两个可点邻位，按几何（中心在堆叠中心
  /// 左侧/右侧）选择要操作的一侧。
  Finder sideCoverGesture(WidgetTester tester, {required bool left}) {
    final hostCenter = tester.getCenter(coverSwipeHost()).dx;
    return find.byElementPredicate((element) {
      final widget = element.widget;
      if (widget is! GestureDetector ||
          widget.onTap == null ||
          widget.onHorizontalDragStart != null ||
          widget.behavior != HitTestBehavior.opaque ||
          widget.child is! CoverCard) {
        return false;
      }
      final renderObject = element.renderObject;
      if (renderObject is! RenderBox || !renderObject.hasSize) return false;
      final center =
          renderObject.localToGlobal(renderObject.size.center(Offset.zero)).dx;
      return left ? center < hostCenter : center > hostCenter;
    });
  }

  /// 邻位封面可见外侧条带上的点击点。
  ///
  /// 邻位中心被当前封面盖住，点击必须落在外侧条带；封面较大时条带可能
  /// 伸出屏幕，取条带外缘但钳制在屏内（左：卡左缘 +8 与屏左 +8 取大；
  /// 右：卡右缘 -8 与屏右 -8 取小）。
  Offset sideCoverTapPoint(WidgetTester tester, Finder side,
      {required bool left}) {
    final center = tester.getCenter(side);
    final halfWidth = tester.getSize(side).width / 2;
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    final x = left
        ? math.max(8.0, center.dx - halfWidth + 8)
        : math.min(screen.width - 8, center.dx + halfWidth - 8);
    return Offset(x, center.dy);
  }

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
    await tester.tap(coverSwipeHost());
    await tester.pump();
    expect(backend.calls, contains('pause'));

    // 邻位封面只有外侧条带可见，中心被当前封面盖住——点击必须落在
    // 左/右缘，否则会命中当前封面（播放/暂停）。
    //
    // 右邻位封面 = 下一首 c：可点，走 skipToNext。
    final right = sideCoverGesture(tester, left: false);
    expect(right, findsOneWidget);
    await tester.tapAt(sideCoverTapPoint(tester, right, left: false));
    await tester.pump();
    expect(backend.calls, contains('next'));

    // 左邻位封面 = 队列前一位 a（无历史回退）：展示身份即可点，
    // 走 skipToPrevious（与后端 previous 的回退同源）。
    final left = sideCoverGesture(tester, left: true);
    expect(left, findsOneWidget);
    await tester.tapAt(sideCoverTapPoint(tester, left, left: true));
    await tester.pump();
    expect(backend.calls, contains('previous'));

    // 让 provider 的通知节流计时器跑完，避免测试结束时报 pending timer。
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('迷你条无曲目时播放 / 切歌键禁用（与其它传输面同契约）', (tester) async {
    // 回归：迷你条的播放 / 暂停（以及同排切歌键）此前不读 hasTrack，冷启动
    // 无曲目时仍可点；共享传输模块后与播放页 / 底栏 / 顶栏同一启用谓词。
    final expand = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 360),
      value: 0,
    );
    addTearDown(expand.dispose);

    await pumpPlayer(tester, expand: expand);
    for (final icon in const [
      Icons.play_arrow_rounded,
      Icons.skip_previous_rounded,
      Icons.skip_next_rounded,
    ]) {
      final button = tester.widget<M3EIconButton>(
        find.ancestor(
          of: find.byIcon(icon),
          matching: find.byType(M3EIconButton),
        ),
      );
      expect(button.onPressed, isNull, reason: '$icon 应在无曲目时禁用');
    }

    await tester.tap(find.byIcon(Icons.play_arrow_rounded),
        warnIfMissed: false);
    await tester.pump();
    expect(backend.calls, isEmpty, reason: '禁用键不发播放命令');
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

  testWidgets('小屏高度往返自洽：展开层内重算的封面尺寸与外层预算一致', (tester) async {
    // 回归：完整层被 OverflowBox 按 fullHeight 强制布局，并在该高度上再算
    // 一次封面尺寸。高度预算若预扣了不渲染的余量（如封面区纵向留白），
    // 展开态 art 会比外层预算小一截、容器底部空出等量空白。
    emitThreeTracks();

    /// 播放器区域用宽松高度约束（`Align` 而非 `SizedBox`）：紧约束会把
    /// 展开容器的插值高度压掉，量不到「容器底 − 内容底」。
    Future<void> pumpTopAligned(AnimationController? expand) async {
      tester.view.physicalSize = const Size(420, 900);
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
              body: Align(
                alignment: Alignment.topCenter,
                child: Player(
                  expandAnimation: expand,
                  onToggleExpand: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
    }

    double centerCoverWidth() =>
        tester.getSize(find.byKey(PlayerCoverDeck.centerCoverCardKey)).width;

    // 直接渲染完整版式：这一路的高度预算就是外层口径。
    await pumpTopAligned(null);
    final double directArt = centerCoverWidth();

    final expand = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 360),
      value: 1.0,
    );
    addTearDown(expand.dispose);
    await pumpTopAligned(expand);

    expect(centerCoverWidth(), closeTo(directArt, 0.5),
        reason: '展开层内再算的封面尺寸必须与外层预算一致（不双扣留白）');

    // 容器底部不得留下「扣掉却不渲染」的 48dp 空白（只允许内部预留余量）。
    final double bottomGap = tester.getRect(find.byType(Player)).bottom -
        tester.getRect(find.byType(SeekBar)).bottom;
    expect(bottomGap, greaterThanOrEqualTo(0));
    expect(bottomGap, lessThan(48), reason: '展开容器底部空白 $bottomGap');

    // 通知节流计时器跑完，避免 pending timer。
    await tester.pump(const Duration(milliseconds: 50));
  });

  /// 展开 / 收起端点与逐帧重建边界：完整层在弹簧中段保持同一 widget 实例，
  /// morph 锚点只在完整端点挂载。
  testWidgets('展开 / 收起端点：完整层逐帧不重建，morph 锚点只在完整态挂载',
      (tester) async {
    emitThreeTracks();
    final morph = PlayerMorphController();
    addTearDown(morph.dispose);
    final expand = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 360),
      value: 0,
    );
    addTearDown(expand.dispose);
    var toggles = 0;

    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // 宽松高度约束（`Align`）：迷你态才能量到 72 的真实高度。
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
            body: Align(
              alignment: Alignment.topCenter,
              child: Player(
                morph: morph,
                expandAnimation: expand,
                onToggleExpand: () => toggles++,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(
      tester.getSize(find.byType(Player)).height,
      closeTo(miniPlayerHeight, 0.5),
      reason: '展开进度 0 = 迷你条高度',
    );
    expect(
      morph.pageCoverKey.currentContext,
      isNull,
      reason: '迷你态不挂顶栏⇄播放页锚点（顶栏飞行走跳过路径）',
    );

    // 迷你层整条可点：完整层即使已挂载也不得拦截。
    await tester.tap(find.byType(Player));
    await tester.pump();
    expect(toggles, 1);

    final fullDeck = find.byType(PlayerCoverDeck);
    // 起手（status=forward）会抓一次封面飞行、触发一次整页重建；等它落定
    // 后再取稳定实例，比较弹簧中段两帧的完整层 widget。
    expand.value = 0.3;
    await tester.pump();
    final midDeck = tester.widget<PlayerCoverDeck>(fullDeck);
    expand.value = 0.6;
    await tester.pump();
    expect(
      identical(tester.widget<PlayerCoverDeck>(fullDeck), midDeck),
      isTrue,
      reason: '弹簧逐帧只重建高度 / 透明度 / 裁剪包装层，完整层保持同一实例',
    );

    // 完整端点：morph 锚点挂上，完整层交互可用。
    expand.value = 1;
    await tester.pump();
    expect(morph.pageCoverKey.currentContext, isNotNull);
    expect(
      tester.getSize(find.byType(Player)).height,
      greaterThan(miniPlayerHeight),
    );

    // 收起端点：锚点撤下，容器回到 72，迷你条仍可再次点开。
    expand.value = 0;
    await tester.pump();
    expect(morph.pageCoverKey.currentContext, isNull);
    expect(
      tester.getSize(find.byType(Player)).height,
      closeTo(miniPlayerHeight, 0.5),
    );
    await tester.tap(find.byType(Player));
    await tester.pump();
    expect(toggles, 2);
    expect(tester.takeException(), isNull);

    // 通知节流计时器跑完，避免测试结束时报 pending timer。
    await tester.pump(const Duration(milliseconds: 50));
  });

  /// 飞行副本封面内的回退图标尺寸（无封面时副本只走默认回退这一颗）。
  double? flightFallbackIconSize(WidgetTester tester) {
    final finder = find.descendant(
      of: find.byType(MorphCover),
      matching: find.byType(MoliaMark),
    );
    if (finder.evaluate().isEmpty) return null;
    return tester.widget<MoliaMark>(finder).size;
  }

  testWidgets('迷你⇄完整飞行：回退图标按两端真身插值（不再固定 64）', (tester) async {
    // 回归：副本回退图标固定 64 会与迷你端真身 24、完整端真身（边长 × 0.35）
    // 都不同，起手与落点各跳一次。
    emitThreeTracks();
    final expand = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 360),
      value: 1.0,
    );
    addTearDown(expand.dispose);

    await pumpPlayer(tester, expand: expand, onToggleExpand: () {});

    // 完整端真身：卡片边长与稳态回退图标（边长 × 0.35）。
    final fullCard = find.byKey(
      PlayerCoverDeck.centerCoverTrackKey(const TrackId('fake', 'b')),
    );
    final fullSize = tester.getSize(fullCard).width;
    final fullIcon = tester
        .widget<MoliaMark>(
          find.descendant(of: fullCard, matching: find.byType(MoliaMark)),
        )
        .size;
    expect(fullIcon, closeTo(fullSize * playerCoverFallbackIconRatio, 1e-6));

    // 收起：飞行起手帧与完整端真身同尺寸。
    expand.reverse();
    await tester.pump();
    expect(
      flightFallbackIconSize(tester),
      closeTo(fullSize * playerCoverFallbackIconRatio, 0.5),
    );

    // 收起完成：飞行副本撤下，迷你端真身回退图标 = 24。
    await tester.pump(const Duration(milliseconds: 400));
    expect(expand.value, 0.0);
    expect(flightFallbackIconSize(tester), isNull);
    final marks = tester
        .widgetList<MoliaMark>(find.byType(MoliaMark))
        .map((mark) => mark.size)
        .toList();
    expect(marks, contains(miniCoverFallbackIconSize));

    // 展开：飞行起手帧与迷你端真身同尺寸。
    expand.forward();
    await tester.pump();
    expect(
      flightFallbackIconSize(tester),
      closeTo(miniCoverFallbackIconSize, 0.5),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(expand.value, 1.0);
    expect(tester.takeException(), isNull);
    // 通知节流计时器跑完，避免测试结束时报 pending timer。
    await tester.pump(const Duration(milliseconds: 50));
  });
}
