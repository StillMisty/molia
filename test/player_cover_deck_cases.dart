import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/app_network_image.dart';
import 'package:molia/widgets/cover_appearance.dart'
    show CoverAppearance, CoverCard;
import 'package:molia/widgets/cover_deck_metrics.dart';
import 'package:molia/widgets/player.dart';
import 'package:molia/widgets/player_cover_deck.dart';
import 'package:molia/widgets/player_morph.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// 与播放器同一预算口径（封面边 240 → 堆叠 360 × 254.4）。
final _deck = coverDeckMetricsFor(
  availableWidth: 240 * coverDeckHorizontalFactor,
  availableHeight: 300,
);

/// 封面堆叠模块的切歌方向：从队列点选/跳转到当前之前的曲目时，进场中心封面
/// 必须从左侧滑入（方向向后），而不是一律按向前。
///
/// 方向在动画中间帧是外部可观察的：进场中心封面（[PlayerCoverDeck.
/// centerCoverCardKey]）的全局中心相对封面手势宿主（堆叠）中心偏左 = 向后
/// 入场；偏右 = 向前入场。这里不做 pumpAndSettle（常驻波浪动画），按固定
/// 时长采样中间态。
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

  /// 模拟后端切到指定曲目：next / previous 与队列保持一致。
  void emitFor(String id) {
    final index = order.indexWhere((track) => track.id.id == id);
    backend.emit(BackendSnapshot(
      current: order[index],
      queue: order,
      currentIndex: index,
      next: index + 1 < order.length ? order[index + 1] : null,
      previous: index > 0 ? order[index - 1] : null,
      isPlaying: true,
      position: const Duration(seconds: 5),
      duration: const Duration(seconds: 30),
    ));
  }

  Future<void> pumpPlayer(WidgetTester tester) async {
    final expand = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 360),
      value: 1.0,
    );
    addTearDown(expand.dispose);
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
                expandAnimation: expand,
                onToggleExpand: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // 等首帧落定后再操作（冷启动恢复态首帧已是稳态）。
    await tester.pump(const Duration(milliseconds: 600));
  }

  /// 采样切歌动画中间帧：进场中心封面相对堆叠中心的位置。
  ///
  /// 返回负值 = 从左侧入场（向后），正值 = 从右侧入场（向前）。
  Future<double> sampleIncomingOffset(WidgetTester tester) async {
    await tester.pump(); // 检测到切歌：这一帧仍是稳态，post-frame 才启动动画
    await tester.pump(); // 动画首 tick（进度 0）
    await tester.pump(const Duration(milliseconds: 150)); // 中间态
    final deckCenter = tester.getCenter(find.byKey(Player.artworkSwipeHostKey));
    final coverCenter =
        tester.getCenter(find.byKey(PlayerCoverDeck.centerCoverCardKey));
    return coverCenter.dx - deckCenter.dx;
  }

  testWidgets('队列点选：进场封面按队列下标方向从对应一侧滑入', (tester) async {
    // 队列 [A,B,C,D]，当前 C（previous B、next D 都已缓存为提示）。
    emitFor('c');
    await pumpPlayer(tester);

    // 直接点选队首 A：新快照 next=B 与 previous 都命中不了提示，
    // 只能靠队列下标判定方向（防止退化为「一律向前」）。
    emitFor('a');
    final offset = await sampleIncomingOffset(tester);
    expect(offset, lessThan(-4),
        reason: '向后切歌时进场封面应从左侧滑入，中间帧中心应偏左（实际 $offset）');

    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Title a'), findsWidgets);
    expect(tester.takeException(), isNull);

    // 当前 A 点选 C：方向向前，从右侧滑入。
    emitFor('c');
    final forwardOffset = await sampleIncomingOffset(tester);
    expect(forwardOffset, greaterThan(4),
        reason: '向前切歌时进场封面应从右侧滑入，中间帧中心应偏右（实际 $forwardOffset）');

    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Title c'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  /// 元素的真实屏上矩形（含祖先 Transform）：与飞行锚点同一口径。
  Rect renderedRect(WidgetTester tester, Finder finder) {
    final box = tester.renderObject<RenderBox>(finder);
    return Rect.fromPoints(
      box.localToGlobal(Offset.zero),
      box.localToGlobal(box.size.bottomRight(Offset.zero)),
    );
  }

  /// 侧槽展开半程的投影宽度：卡片整体缩放 + 同进度旋转后，
  /// 左上 → 右下角点的水平距离（旋转绕中心，取 cos − sin）。
  double projectedSideWidth(double sideSize, double scale, double angle) =>
      sideSize * scale * (math.cos(angle) - math.sin(angle));

  /// 指定卡片最近一层 Opacity（侧 reveal 包装的透明度层）。
  double nearestOpacityOf(WidgetTester tester, Finder finder) {
    final elements = finder.evaluate();
    expect(elements, hasLength(1), reason: '卡片应唯一存在');
    double? opacity;
    elements.single.visitAncestorElements((ancestor) {
      final widget = ancestor.widget;
      if (widget is Opacity) {
        opacity = widget.opacity;
        return false;
      }
      return true;
    });
    expect(opacity, isNotNull, reason: '未找到卡片的透明度层');
    return opacity!;
  }

  testWidgets('飞行 reveal：侧槽从中心展开/收回，中心封面锚点矩形不变', (tester) async {
    emitFor('b'); // 队列 a,b,c,d：左槽 a、右槽 c
    final morph = PlayerMorphController();
    addTearDown(morph.dispose);
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
          home: Scaffold(
            body: Center(
              child: PlayerCoverDeck(
                displayTrack: b,
                artDimension: _deck.artDimension,
                stackDimension: _deck.stackWidth,
                stackHeight: _deck.stackHeight,
                fullCoverKey: GlobalKey(),
                morph: morph,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    final left = find.byKey(
      PlayerCoverDeck.sideCoverCardKey(left: true, id: a.id),
    );
    final right = find.byKey(
      PlayerCoverDeck.sideCoverCardKey(left: false, id: c.id),
    );
    final double sideSize = _deck.artDimension * 0.78;
    final double offset = _deck.artDimension * 0.30;
    final Rect anchorSteady = morph.rectOf(morph.pageCoverKey)!;
    final double deckDx =
        tester.getCenter(find.byKey(PlayerCoverDeck.swipeHostKey)).dx;

    // reveal = 0：两侧收在中心但 element/图片状态保留（scale 0 + 透明 + 不
    // 响应指针），飞行尾段展开时不重建 AppNetworkImage/闪占位。
    morph.setPageDeckReveal(0);
    await tester.pump();
    expect(left, findsOneWidget);
    expect(right, findsOneWidget);
    expect(renderedRect(tester, left).width, lessThan(1));
    expect(renderedRect(tester, right).width, lessThan(1));
    expect(nearestOpacityOf(tester, left), 0);
    expect(nearestOpacityOf(tester, right), 0);
    expect(morph.rectOf(morph.pageCoverKey), anchorSteady,
        reason: '侧槽收回不得改变中心封面锚点矩形');

    // reveal 只驱动侧槽包装层：deck 主 builder / 卡片子树不应逐帧重建。
    final previousProbe = debugOnRebuildDirtyWidget;
    var coverCardRebuilds = 0;
    debugOnRebuildDirtyWidget = (element, _) {
      if (element.widget is CoverCard) coverCardRebuilds += 1;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previousProbe);

    // reveal = 0.5：两侧从中心展开（位置/缩放/透明度按进度，倾角始终保持
    // 稳态 ±0.05；倾角不能从 0 开始插值，否则会先水平出现再倾斜）。
    morph.setPageDeckReveal(0.5);
    await tester.pump();
    expect(coverCardRebuilds, 0,
        reason: 'reveal 逐帧只重建 Transform/Opacity 包装，不重建卡片图片子树');
    debugOnRebuildDirtyWidget = previousProbe;
    final double eased = Curves.easeOutCubic.transform(0.5);
    final Rect leftMid = renderedRect(tester, left);
    final Rect rightMid = renderedRect(tester, right);
    const double midAngle = 0.05;
    expect(
      leftMid.width,
      closeTo(projectedSideWidth(sideSize, eased, -midAngle), 1),
      reason: '半程侧槽卡按同进度缩放（左槽旋转为负，已带旋转）',
    );
    expect(
      rightMid.width,
      closeTo(projectedSideWidth(sideSize, eased, midAngle), 1),
    );
    expect(
      leftMid.center.dx - deckDx,
      closeTo(-offset * eased, 1),
      reason: '左槽从中心向左展开（半程）',
    );
    expect(
      rightMid.center.dx - deckDx,
      closeTo(offset * eased, 1),
      reason: '右槽从中心向右展开（半程）',
    );
    expect(morph.rectOf(morph.pageCoverKey), anchorSteady,
        reason: '展开过程中中心锚点必须是稳态矩形（飞行落点不能漂移）');

    // reveal = 1：稳态侧槽几何，中心锚点仍不变。
    morph.setPageDeckReveal(1);
    await tester.pump();
    final Rect leftSteady = renderedRect(tester, left);
    expect(leftSteady.center.dx - deckDx, closeTo(-offset, 1));
    expect(tester.getSize(left).width, closeTo(sideSize, 0.01),
        reason: '稳态侧槽卡边长保持 0.78×封面边');
    expect(renderedRect(tester, right).center.dx - deckDx, closeTo(offset, 1));
    expect(morph.rectOf(morph.pageCoverKey), anchorSteady);

    // 侧槽外观必须按 0.78 缩放：换场结束帧的滑出卡是「主封面尺寸 ×
    // scale 0.78」，若侧槽仍用页面端 r18/1px/24px 阴影，落位后圆角、
    // 描边、阴影会再跳一档（用户反馈的切歌完成二次变化）。
    final leftCard = tester.widget<CoverCard>(left);
    final rightCard = tester.widget<CoverCard>(right);
    for (final card in [leftCard, rightCard]) {
      expect(
        card.appearance.radius,
        closeTo(CoverAppearance.page.radius * 0.78, 1e-6),
      );
      expect(
        card.appearance.stroke,
        closeTo(CoverAppearance.page.stroke * 0.78, 1e-6),
      );
      expect(
        card.appearance.shadow,
        closeTo(CoverAppearance.page.shadow * 0.78, 1e-6),
      );
      expect(card.appearance.clip.topLeft.x,
          closeTo(CoverAppearance.page.clip.topLeft.x * 0.78, 1e-6));
    }
    final centerCoverCard = tester.widget<CoverCard>(
      find.descendant(
        of: find.byKey(PlayerCoverDeck.centerCoverCardKey),
        matching: find.byType(CoverCard),
      ),
    );
    expect(centerCoverCard.appearance.radius, CoverAppearance.page.radius,
        reason: '中心卡保持页面端外观');

    // 飞行期间侧槽点击关闭：pageHeaderHidden 即「副本接管」状态。
    int previousCalls() =>
        backend.calls.where((call) => call == 'previous').length;
    // 邻位只有外侧条带可见：点左缘，避免命中压在上面的中心封面。
    final Offset leftEdgeTap =
        Offset(leftSteady.left + 8, leftSteady.center.dy);
    await tester.tapAt(leftEdgeTap);
    await tester.pump();
    expect(previousCalls(), 1, reason: '前提：稳态左槽可点击切上一首');
    morph.setPageHeaderHidden(true);
    await tester.pump();
    await tester.tapAt(leftEdgeTap);
    await tester.pump();
    expect(previousCalls(), 1, reason: '飞行期间侧槽点击必须被忽略');
    morph.setPageHeaderHidden(false);
    await tester.pump();
    expect(tester.takeException(), isNull);

    // 中心封面点击 = 播放/暂停：飞行期间也必须被整层 IgnorePointer 冻结。
    int pauseCalls() => backend.calls.where((call) => call == 'pause').length;
    final centerCard = find.byKey(PlayerCoverDeck.centerCoverCardKey);
    await tester.tap(centerCard);
    await tester.pump();
    expect(pauseCalls(), 1, reason: '前提：稳态中心点击可切播放/暂停');
    morph.setPageHeaderHidden(true);
    await tester.pump();
    await tester.tap(centerCard, warnIfMissed: false);
    await tester.pump();
    expect(pauseCalls(), 1, reason: '飞行期间中心点击不得切播放/暂停');
    morph.setPageHeaderHidden(false);
    await tester.pump();
    await tester.tap(centerCard);
    await tester.pump();
    expect(pauseCalls(), 2, reason: '恢复后中心点击应恢复播放/暂停');
    // 播放命令的 provider 通知节流计时器跑完，避免测试结束时报 pending timer。
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('拖动预览：中心目标无封面时不嵌套当前封面占位', (tester) async {
    final current = Track(
      id: const TrackId('fake', 'cur'),
      title: 'Title cur',
      artists: const [Artist(name: 'Artist cur')],
      album: 'Album',
      duration: const Duration(seconds: 30),
      artwork: Artwork(uri: Uri.parse('https://img.example/cur.jpg')),
      origin: TrackOrigin.lx,
      payload: const {'id': 'cur'},
    );
    final next = Track(
      id: const TrackId('fake', 'nxt'),
      title: 'Title nxt',
      artists: const [Artist(name: 'Artist nxt')],
      album: 'Album',
      duration: const Duration(seconds: 30),
      origin: TrackOrigin.lx,
      payload: const {'id': 'nxt'},
    );
    backend.emit(BackendSnapshot(
      current: current,
      queue: [current, next],
      currentIndex: 0,
      next: next,
      upNext: [next],
      isPlaying: true,
      position: const Duration(seconds: 5),
      duration: const Duration(seconds: 30),
    ));
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
          home: Scaffold(
            body: Center(
              child: PlayerCoverDeck(
                displayTrack: current,
                artDimension: _deck.artDimension,
                stackDimension: _deck.stackWidth,
                stackHeight: _deck.stackHeight,
                fullCoverKey: GlobalKey(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    final double range = _deck.artDimension * 0.6;
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(PlayerCoverDeck.swipeHostKey)),
    );
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump();
    await gesture.moveBy(Offset(-(range * 0.5 - 30), 0));
    await tester.pump();

    final center = find.byKey(PlayerCoverDeck.centerCoverCardKey);
    final image = tester.widget<AppNetworkImage>(
      find
          .descendant(of: center, matching: find.byType(AppNetworkImage))
          .first,
    );
    expect(image.url, isNull, reason: '预览目标是下一首（无封面）');
    expect(image.placeholder, isNot(isA<AppNetworkImage>()),
        reason: '中心卡不得把当前曲目封面嵌套成占位（旧封面会从新卡下面透出）');
    final outgoing = find.byKey(PlayerCoverDeck.outgoingCoverCardKey);
    expect(
      tester
          .widget<AppNetworkImage>(
            find
                .descendant(of: outgoing, matching: find.byType(AppNetworkImage))
                .first,
          )
          .url,
      'https://img.example/cur.jpg',
      reason: '滑出卡仍展示当前曲目自己的封面',
    );

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  });
}
