import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/player.dart';
import 'package:molia/widgets/player_cover_deck.dart';
import 'package:molia/widgets/player_morph.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// 切歌视觉：窗口化交叉淡化（仅透明度、原位）、320ms、
/// 滑出卡全程渲染、无「从中心背后展开」入场特例。
///
/// 断言只读外部可观察行为：封面堆叠内各 Opacity 的透明度与全局位置（不读
/// 私有字段）。存在常驻波浪动画，不能 pumpAndSettle，按固定时长 pump 采样
/// 中间态；窗口位置用进度占比换算的 pump 时长表达。
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

  final a = _track('a');
  final b = _track('b');
  final c = _track('c');
  final d = _track('d');
  final order = [a, b, c, d];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    backend = FakePlaybackBackend();
    playback = buildTestPlaybackProvider(backend: backend);
  });

  tearDown(() => playback.dispose());

  void emitFor(String id) {
    final index = order.indexWhere((track) => track.id.id == id);
    backend.emit(BackendSnapshot(
      current: order[index],
      queue: order,
      currentIndex: index,
      next: index + 1 < order.length ? order[index + 1] : null,
      upcoming: index + 1 < order.length ? order.sublist(index + 1) : const [],
      history: index > 0 ? order.sublist(0, index) : const [],
      isPlaying: true,
      position: const Duration(seconds: 5),
      duration: const Duration(seconds: 30),
    ));
  }

  Future<void> pumpPlayer(
    WidgetTester tester, {
    AnimationController? expand,
    PlayerMorphController? morph,
  }) async {
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
            body: SizedBox(
              height: 900,
              child: Player(
                morph: morph,
                expandAnimation: expand,
                onToggleExpand: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // 首帧切歌入场动画：motor 弹簧（含容差拖尾约 0.7s）落定后才渲染
    // 稳态槽位，等它结束再操作。
    await tester.pump(const Duration(milliseconds: 900));
  }

  /// 封面堆叠内所有 Opacity 的（相对堆叠中心的横向偏移, 透明度）。
  List<({double dx, double opacity})> sampleCoverOpacities(
      WidgetTester tester) {
    final deckCenter =
        tester.getCenter(find.byKey(Player.artworkSwipeHostKey));
    final samples = <({double dx, double opacity})>[];
    for (final element in find
        .descendant(
          of: find.byKey(Player.artworkSwipeHostKey),
          matching: find.byType(Opacity),
        )
        .evaluate()) {
      final widget = element.widget as Opacity;
      final renderObject = element.renderObject;
      if (renderObject is! RenderBox || !renderObject.hasSize) continue;
      final center =
          renderObject.localToGlobal(renderObject.size.center(Offset.zero));
      samples.add((dx: center.dx - deckCenter.dx, opacity: widget.opacity));
    }
    samples.sort((left, right) => left.dx.compareTo(right.dx));
    return samples;
  }

  /// 落在 [dx] 附近（默认 ±6）的所有透明度采样值。
  List<double> opacitiesNear(
    List<({double dx, double opacity})> samples,
    double dx, {
    double radius = 6,
  }) =>
      samples
          .where((sample) => (sample.dx - dx).abs() < radius)
          .map((sample) => sample.opacity)
          .toList();

  /// 指定封面卡最近一层 Opacity 的透明度（卡的动画透明度层）。
  double nearestOpacityOf(WidgetTester tester, Finder finder) {
    final elements = finder.evaluate();
    expect(elements, hasLength(1), reason: '封面卡应唯一存在');
    double? opacity;
    elements.single.visitAncestorElements((ancestor) {
      final widget = ancestor.widget;
      if (widget is Opacity) {
        opacity = widget.opacity;
        return false;
      }
      return true;
    });
    expect(opacity, isNotNull, reason: '未找到封面卡的透明度层');
    return opacity!;
  }

  /// 指定封面卡相对堆叠中心的横向偏移。
  double cardDx(WidgetTester tester, Finder finder) =>
      tester.getCenter(finder).dx -
      tester.getCenter(find.byKey(Player.artworkSwipeHostKey)).dx;

  testWidgets('即时切歌：旧身份窗口先淡出、源侧新身份窗口后淡入，滑出卡全程渲染', (tester) async {
    emitFor('b');
    await pumpPlayer(tester);

    // 稳态基准：左=上一首 a、右=下一首 c（位置与 0.85 透明度）。
    final steady = sampleCoverOpacities(tester);
    expect(steady, hasLength(3));
    final double leftDx = steady.first.dx;
    final double rightDx = steady.last.dx;
    expect(leftDx, lessThan(-20));
    expect(rightDx, greaterThan(20));
    expect(steady.first.opacity, closeTo(0.85, 0.001));
    expect(steady.last.opacity, closeTo(0.85, 0.001));

    emitFor('c'); // 前进切歌 b→c
    await tester.pump(const Duration(milliseconds: 50)); // 检测帧：p=0

    // p=0 与稳态一致：滑出卡（旧中封 b）在中心原位，源槽位卡（c）仍是 0.85。
    final outgoing = find.byKey(PlayerCoverDeck.outgoingCoverCardKey);
    expect(outgoing, findsOneWidget,
        reason: '非拖动切歌的滑出卡必须从会话第一帧起渲染（旧实现从不渲染）');
    expect(cardDx(tester, outgoing), closeTo(0, 1));
    expect(nearestOpacityOf(tester, outgoing), closeTo(1.0, 0.01));
    expect(
      nearestOpacityOf(tester, find.byKey(PlayerCoverDeck.centerCoverCardKey)),
      closeTo(0.85, 0.01),
      reason: '进场卡起手透明度应与稳态源槽位卡一致（0.85），不是 1.0',
    );

    await tester.pump(); // 动画首 tick（elapsed 0）
    await tester.pump(const Duration(milliseconds: 50)); // 弹簧 p≈0.28

    final early = sampleCoverOpacities(tester);
    // 目标槽位旧身份（左侧 a）：窗口 p∈[0, 0.4] 淡出，处于中间值。
    final earlyOld = opacitiesNear(early, leftDx);
    expect(earlyOld, isNotEmpty);
    expect(earlyOld.reduce(math.min), allOf(greaterThan(0.0), lessThan(0.85)),
        reason: 'p≈0.28 旧槽位身份应处于淡出中间值（实际 $earlyOld）');
    // 源槽位新身份（右侧 d）：窗口 p∈[0.6, 1]，此刻尚未出现。
    final earlyNew = opacitiesNear(early, rightDx);
    expect(earlyNew, isNotEmpty);
    expect(earlyNew.reduce(math.max), lessThan(0.01),
        reason: 'p≈0.28 源侧新身份尚未出现（实际 $earlyNew）');
    // 滑出卡：正在向目标槽位滑动（既不在中心也未落位），透明度 1.0→0.85 中间。
    expect(outgoing, findsOneWidget);
    final outgoingDx = cardDx(tester, outgoing);
    expect(outgoingDx, lessThan(-10));
    expect(outgoingDx, greaterThan(leftDx + 10));
    expect(nearestOpacityOf(tester, outgoing),
        allOf(greaterThan(0.85), lessThan(1.0)));

    await tester.pump(const Duration(milliseconds: 90)); // 弹簧 p≈0.86
    final late = sampleCoverOpacities(tester);
    // 源侧新身份：淡入窗口中间值。
    final lateNew = opacitiesNear(late, rightDx);
    expect(lateNew, isNotEmpty);
    expect(lateNew.reduce(math.max), allOf(greaterThan(0.0), lessThan(0.85)),
        reason: 'p≈0.86 源侧新身份应处于淡入中间值（实际 $lateNew）');
    // 旧身份：淡出窗口已结束，退场为 0。
    expect(opacitiesNear(late, leftDx).reduce(math.min), lessThan(0.01),
        reason: 'p≈0.86 旧槽位身份应已淡出');

    await tester.pump(const Duration(milliseconds: 80)); // 弹簧 p≈1.0（轻微过冲）
    // 滑出卡逼近目标槽位：位置/透明度与稳态槽位卡完全重合。
    expect(cardDx(tester, outgoing), closeTo(leftDx, 1.5));
    expect(nearestOpacityOf(tester, outgoing), closeTo(0.85, 0.01));

    // 弹簧落定（含容差拖尾，视觉上早已静止）。
    await tester.pump(const Duration(milliseconds: 550));
    // 动画结束无 pop：目标槽位由稳态槽位卡无缝承接（同位置、0.85）。
    expect(outgoing, findsNothing);
    final idle = sampleCoverOpacities(tester);
    expect(opacitiesNear(idle, leftDx).reduce(math.max), closeTo(0.85, 0.01),
        reason: '动画结束无 pop：目标槽位稳态卡应与滑出卡终点重合');
    expect(opacitiesNear(idle, rightDx).reduce(math.max), closeTo(0.85, 0.01));

    await tester.pump(const Duration(milliseconds: 400)); // 通知节流计时器跑完
    expect(tester.takeException(), isNull);
  });

  testWidgets('进场卡透明度：起手 0.85，随进度连续升到 1.0（无起手闪跳）', (tester) async {
    emitFor('b');
    await pumpPlayer(tester);

    emitFor('c');
    await tester.pump(const Duration(milliseconds: 50)); // 检测帧 p=0
    final centerCard = find.byKey(PlayerCoverDeck.centerCoverCardKey);
    final start = nearestOpacityOf(tester, centerCard);
    expect(start, closeTo(0.85, 0.01),
        reason: '起手透明度应为 0.85（与稳态源槽位卡一致），而不是硬跳 1.0');

    await tester.pump(); // 动画首 tick
    await tester.pump(const Duration(milliseconds: 160)); // p=0.5
    final mid = nearestOpacityOf(tester, centerCard);
    expect(mid, greaterThan(start));
    expect(mid, lessThan(1.0), reason: '中段应处于 0.85→1.0 之间（实际 $mid）');

    await tester.pump(const Duration(milliseconds: 160)); // p=1.0
    expect(nearestOpacityOf(tester, centerCard), closeTo(1.0, 0.01));

    await tester.pump(const Duration(milliseconds: 400)); // 通知节流计时器跑完
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖动对账落位：源侧新身份 180ms 纯透明度淡入（无位移跳变）', (tester) async {
    emitFor('b');
    await pumpPlayer(tester);

    final steady = sampleCoverOpacities(tester);
    final double leftDx = steady.first.dx;
    final double rightDx = steady.last.dx;

    // 左滑提交下一首；后端未确认期间预览保持，随后 emitFor('c') 对账。
    await tester.timedDrag(
      find.byKey(Player.artworkSwipeHostKey),
      const Offset(-160, 0),
      const Duration(milliseconds: 300),
    );
    expect(backend.calls, contains('next'));
    await tester.pump(const Duration(milliseconds: 400)); // 提交过渡走完，等待对账

    emitFor('c');
    await tester.pump(const Duration(milliseconds: 50)); // 对账帧：淡入起点
    final atStart = sampleCoverOpacities(tester);
    final startNew = atStart
        .where((sample) => (sample.dx - rightDx).abs() < 6)
        .toList();
    expect(startNew, isNotEmpty);
    expect(startNew.map((sample) => sample.opacity).reduce(math.max),
        lessThan(0.01),
        reason: '对账落位帧源侧新身份从 0 起（不是直接 0.85）');
    // 纯透明度：起点就在稳态槽位，不做「从中心背后展开」的位移插值。
    expect(startNew.first.dx, closeTo(rightDx, 0.5));
    expect(opacitiesNear(atStart, leftDx).reduce(math.max),
        closeTo(0.85, 0.01),
        reason: '目标槽位滑出卡已落位（0.85），对账不应让画面回跳');

    await tester.pump(); // 淡入首 tick
    await tester.pump(const Duration(milliseconds: 90)); // 180ms 中段
    final mid = sampleCoverOpacities(tester);
    final midNew = mid
        .where((sample) => (sample.dx - rightDx).abs() < 6)
        .toList();
    expect(midNew.map((sample) => sample.opacity).reduce(math.max),
        allOf(greaterThan(0.0), lessThan(0.85)));
    for (final sample in midNew) {
      expect(sample.dx, closeTo(rightDx, 0.5),
          reason: '源侧新身份淡入期间不得发生位移');
    }

    await tester.pump(const Duration(milliseconds: 100));
    final end = sampleCoverOpacities(tester);
    expect(opacitiesNear(end, rightDx).reduce(math.max), closeTo(0.85, 0.01));

    await tester.pump(const Duration(milliseconds: 400)); // 通知节流计时器跑完
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除入场特例：顶栏飞行与展开落位不再触发侧邻位演出', (tester) async {
    emitFor('b');
    final morph = PlayerMorphController();
    addTearDown(morph.dispose);
    final expand = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 360),
      value: 1.0,
    );
    addTearDown(expand.dispose);
    await pumpPlayer(tester, expand: expand, morph: morph);

    /// 两侧邻位应始终以稳态出现（0.85、稳态槽位位置），无中间态演出。
    void expectSettledSides() {
      final sides = sampleCoverOpacities(tester)
          .where((sample) => sample.dx.abs() > 20)
          .toList();
      expect(sides, hasLength(2));
      for (final sample in sides) {
        expect(sample.opacity, closeTo(0.85, 0.01));
      }
      expect(sides.first.dx, lessThan(-20));
      expect(sides.last.dx, greaterThan(20));
    }

    // 顶栏⇄播放页飞行：隐藏沿与落位沿均无独立演出。
    morph.setPageHeaderHidden(true);
    await tester.pump();
    expectSettledSides();
    morph.setPageHeaderHidden(false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expectSettledSides();

    // 迷你 ⇄ 完整：收起与展开落位同样无独立演出（随层自身淡入）。
    expand.reverse();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expectSettledSides();
    expand.forward();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expectSettledSides();

    expect(tester.takeException(), isNull);
  });
}
