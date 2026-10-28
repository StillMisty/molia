import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/app_network_image.dart';
import 'package:molia/widgets/cover_deck_metrics.dart';
import 'package:molia/widgets/player.dart';
import 'package:molia/widgets/player_cover_deck.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// 封面堆叠尺寸：与播放器同一预算口径（封面边 240 → 堆叠 360 × 254.4）。
final _deck = coverDeckMetricsFor(
  availableWidth: 240 * coverDeckHorizontalFactor,
  availableHeight: 300,
);

/// 对账与会话外槽位更新：
/// - 提交对账到非预览曲目：中心封面 220ms 原位交叉淡化校正；
/// - 空闲期槽位身份变化（next 换人/变空）：180ms 原位交叉淡化；
/// - 左槽「上一首」语义（快照 previous：播放顺序最近一首 → 队列前一位 → 空）；
/// - 中心封面同 id、URL 更新：250ms 交叉淡化换图；
/// - 提交匹配路径：续走落位，不回起点重播。
///
/// 断言只读外部可观察行为：卡片身份语义 key、Opacity 透明度与全局位置、
/// 后端调用；不读私有字段。存在常驻波浪动画，不能 pumpAndSettle，按固定
/// 时长 pump 采样中间态。
Track _track(String id, {String? artwork}) => Track(
      id: TrackId('fake', id),
      title: 'Title $id',
      artists: [Artist(name: 'Artist $id')],
      album: 'Album',
      duration: const Duration(seconds: 30),
      artwork: artwork == null ? null : Artwork(uri: Uri.parse(artwork)),
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

  /// 自定义快照：空闲身份变化（current 不变、队列/next 变化）与同 id 换图用。
  ///
  /// [previous] 缺省按后端口径回退队列前一位（与真实后端一致）。
  void emitCustom({
    required Track current,
    required List<Track> queue,
    required int index,
    Track? previous,
    Track? next,
  }) {
    backend.emit(BackendSnapshot(
      current: current,
      queue: queue,
      currentIndex: index,
      next: next,
      previous: previous ?? (index > 0 ? queue[index - 1] : null),
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
    // 等首帧落定（冷启动恢复态首帧已是稳态；保留一拍覆盖布局/入场）。
    await tester.pump(const Duration(milliseconds: 900));
  }

  /// 直接挂载封面堆叠（不经过播放器：带封面的曲目会触发播放器的取色/
  /// 预取路径，与换图淡化无关）；宿主按快照 current 重建 displayTrack，
  /// 等价播放器对封面堆叠的喂法。
  Future<void> pumpDeckHost(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<PlaybackProvider>.value(
        value: playback,
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: _DeckHost(fullCoverKey: GlobalKey()),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // 等首帧落定（冷启动恢复态首帧已是稳态；保留一拍覆盖布局/入场）。
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

  /// 拖动距离：deck 的换场行程是封面边长的 0.6（`_coverSwapRange`），
  /// 硬编码像素会随版式缩放漂移。
  double dragFor(WidgetTester tester, double fraction) =>
      tester.getSize(find.byKey(PlayerCoverDeck.centerCoverCardKey)).width *
      0.6 *
      fraction;

  /// 指定封面卡相对堆叠中心的横向偏移。
  double cardDx(WidgetTester tester, Finder finder) =>
      tester.getCenter(finder).dx -
      tester.getCenter(find.byKey(Player.artworkSwipeHostKey)).dx;

  Finder sideCard({required bool left, required Track track}) =>
      find.byKey(PlayerCoverDeck.sideCoverCardKey(left: left, id: track.id));

  /// 指定封面卡内渲染的图片 URL（AppNetworkImage.url；空串 = 无封面）。
  List<String?> cardImageUrls(WidgetTester tester, Finder card) => tester
      .widgetList<AppNetworkImage>(
          find.descendant(of: card, matching: find.byType(AppNetworkImage)))
      .map((image) => image.url)
      .toList();

  testWidgets('对账到非预览曲目：中心 220ms 原位交叉淡化校正到实际曲目', (tester) async {
    emitFor('b');
    await pumpPlayer(tester);
    final double leftDx = sampleCoverOpacities(tester).first.dx;

    // 左滑提交下一首（预览目标 c）；提交过渡走完后再对账到 d（不匹配）。
    await tester.timedDrag(
      find.byKey(Player.artworkSwipeHostKey),
      Offset(-dragFor(tester, 0.83), 0),
      const Duration(milliseconds: 300),
    );
    expect(backend.calls, contains('next'));
    await tester.pump(const Duration(milliseconds: 400));

    emitFor('d');
    // 检测帧（先泵掉通知节流的补发窗口）：校正从 0 起步，旧预览卡满、实际卡 0。
    await tester.pump(const Duration(milliseconds: 50));

    final outgoing = find.byKey(PlayerCoverDeck.outgoingCoverCardKey);
    final center = find.byKey(PlayerCoverDeck.centerCoverCardKey);
    expect(outgoing, findsOneWidget, reason: '校正期间旧预览卡应渲染（淡出起点）');
    expect(center, findsOneWidget);
    expect(nearestOpacityOf(tester, outgoing), closeTo(1.0, 0.01));
    expect(nearestOpacityOf(tester, center), closeTo(0.0, 0.01));
    // 原位交叉：两张卡都在中心，无位移。
    expect(cardDx(tester, outgoing), closeTo(0, 0.5));
    expect(cardDx(tester, center), closeTo(0, 0.5));

    await tester.pump(const Duration(milliseconds: 40)); // 220ms 前段
    final double outMid = nearestOpacityOf(tester, outgoing);
    final double inMid = nearestOpacityOf(tester, center);
    expect(outMid, allOf(greaterThan(0.1), lessThan(0.9)),
        reason: '校正中间帧旧预览卡应处于中间值（实际 $outMid）');
    expect(inMid, allOf(greaterThan(0.1), lessThan(0.9)),
        reason: '校正中间帧实际曲目卡应处于中间值（实际 $inMid）');
    expect(outMid + inMid, closeTo(1.0, 0.01), reason: '同位置交叉淡化：透明度互补');
    expect(cardDx(tester, outgoing), closeTo(0, 0.5));
    expect(cardDx(tester, center), closeTo(0, 0.5));

    await tester.pump(const Duration(milliseconds: 190)); // 220ms 走完
    expect(outgoing, findsNothing, reason: '校正结束旧预览卡应撤下');
    expect(nearestOpacityOf(tester, center), closeTo(1.0, 0.01));
    expect(cardDx(tester, center), closeTo(0, 0.5));
    // 中心即实际曲目；槽位按新快照重建：左 = 播放顺序最近一首 c，右 = 空。
    expect(find.byKey(PlayerCoverDeck.centerCoverTrackKey(d.id)), findsOneWidget,
        reason: '校正结束后中心应展示实际曲目 d');
    expect(sideCard(left: true, track: c), findsOneWidget,
        reason: '校正后左槽应重建为 previous c');
    expect(nearestOpacityOf(tester, sideCard(left: true, track: c)),
        closeTo(0.85, 0.01));
    expect(cardDx(tester, sideCard(left: true, track: c)), closeTo(leftDx, 1.5));
    expect(sideCard(left: false, track: c), findsNothing,
        reason: 'c 不应同时出现在右槽');
    expect(opacitiesNear(sampleCoverOpacities(tester), -leftDx), isEmpty,
        reason: 'd 之后没有下一首，右槽应为空');
    expect(find.text('Title d'), findsWidgets);

    await tester.pump(const Duration(milliseconds: 400)); // 通知节流计时器跑完
    expect(tester.takeException(), isNull);
  });

  testWidgets('校正期间的新拖动被忽略：不产生新预览/提交，校正照常走完', (tester) async {
    emitFor('b');
    await pumpPlayer(tester);

    // 左滑提交下一首（预览目标 c）；提交过渡走完后再对账到 d（不匹配）。
    await tester.timedDrag(
      find.byKey(Player.artworkSwipeHostKey),
      Offset(-dragFor(tester, 0.83), 0),
      const Duration(milliseconds: 300),
    );
    expect(backend.calls, contains('next'));
    await tester.pump(const Duration(milliseconds: 400));

    emitFor('d');
    await tester.pump(const Duration(milliseconds: 50)); // 校正检测帧

    final outgoing = find.byKey(PlayerCoverDeck.outgoingCoverCardKey);
    final center = find.byKey(PlayerCoverDeck.centerCoverCardKey);
    final double outStart = nearestOpacityOf(tester, outgoing);
    expect(outStart, closeTo(1.0, 0.01));

    // 校正中途尝试拖动：右滑（previous c 是可预览目标，这次拖动
    // 本身满足提交条件），但校正期间必须被忽略。两次移动累计超过阈值后松手。
    final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(Player.artworkSwipeHostKey)));
    await gesture.moveBy(Offset(dragFor(tester, 0.31), 0));
    await tester.pump(const Duration(milliseconds: 60));
    await gesture.moveBy(Offset(dragFor(tester, 0.31), 0));
    await tester.pump(const Duration(milliseconds: 60));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 60));

    // 拖动被忽略：没有第二次提交，中心保持校正原位（未进入拖动预览）。
    expect(backend.calls.where((call) => call == 'next').length, 1,
        reason: '校正期间的新拖动不得再提交切歌');
    expect(backend.calls.where((call) => call == 'previous').length, 0);
    expect(cardDx(tester, center), closeTo(0, 0.5),
        reason: '校正期间不得进入拖动预览（中心不产生位移）');
    final double outMid = nearestOpacityOf(tester, outgoing);
    expect(outMid, lessThan(outStart),
        reason: '校正照常推进：旧预览卡继续淡出（实际 $outMid）');
    expect(nearestOpacityOf(tester, center), closeTo(1.0 - outMid, 0.01),
        reason: '校正交叉淡化不被打断（透明度互补）');

    // 校正走完：中心为实际曲目 d，旧预览卡撤下。
    await tester.pump(const Duration(milliseconds: 120));
    expect(outgoing, findsNothing, reason: '校正结束旧预览卡应撤下');
    expect(find.byKey(PlayerCoverDeck.centerCoverTrackKey(d.id)), findsOneWidget,
        reason: '校正结束后中心应为实际曲目 d');
    expect(cardDx(tester, center), closeTo(0, 0.5));

    await tester.pump(const Duration(milliseconds: 400)); // 通知节流计时器跑完
    expect(tester.takeException(), isNull);
  });

  testWidgets('提交匹配路径：对账续走落位，动画不回起点重播', (tester) async {
    emitFor('b');
    await pumpPlayer(tester);

    // 90px 提交（超过 80px 阈值但未走完行程）：提交过渡仍在进行中。
    await tester.timedDrag(
      find.byKey(Player.artworkSwipeHostKey),
      const Offset(-90, 0),
      const Duration(milliseconds: 300),
    );
    expect(backend.calls, contains('next'));
    await tester.pump(const Duration(milliseconds: 20));

    final center = find.byKey(PlayerCoverDeck.centerCoverCardKey);
    final double before = cardDx(tester, center);
    expect(before, greaterThan(10), reason: '提交过渡应仍在进行（中心未落位）');

    emitFor('c'); // 对账到预览目标 → 无缝完成
    await tester.pump(const Duration(milliseconds: 20));
    final double after = cardDx(tester, center);
    expect(after, lessThan(before),
        reason: '对账匹配应从当前进度续走（起点约 72，重播会跳回满偏移）');
    expect(after, greaterThan(0));

    await tester.pump(const Duration(milliseconds: 400));
    expect(cardDx(tester, center), closeTo(0, 1));
    expect(nearestOpacityOf(tester, center), closeTo(1.0, 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('空闲 next 变化：换人与变空都走 180ms 原位交叉淡化', (tester) async {
    emitFor('b');
    await pumpPlayer(tester);
    final double rightDx = sampleCoverOpacities(tester).last.dx;

    // 播放中列表变化：下一首 c → d（current 不变）。
    emitCustom(current: b, queue: [a, b, d], index: 1, previous: a, next: d);
    // 检测帧（先泵掉通知节流的补发窗口）：淡化从 0 起步（旧身份满、新身份 0）。
    await tester.pump(const Duration(milliseconds: 50));

    final oldCard = sideCard(left: false, track: c);
    final newCard = sideCard(left: false, track: d);
    expect(oldCard, findsOneWidget, reason: '旧身份（c）应作为淡出起点渲染');
    expect(newCard, findsOneWidget, reason: '新身份（d）应作为淡入目标渲染');
    expect(nearestOpacityOf(tester, oldCard), closeTo(0.85, 0.01));
    expect(nearestOpacityOf(tester, newCard), closeTo(0.0, 0.01));
    expect(cardDx(tester, oldCard), closeTo(rightDx, 0.5));
    expect(cardDx(tester, newCard), closeTo(rightDx, 0.5));

    await tester.pump(const Duration(milliseconds: 40)); // 180ms 前段
    final double oldMid = nearestOpacityOf(tester, oldCard);
    final double newMid = nearestOpacityOf(tester, newCard);
    expect(oldMid, allOf(greaterThan(0.1), lessThan(0.8)),
        reason: '旧身份应处于淡出中间值（实际 $oldMid）');
    expect(newMid, allOf(greaterThan(0.1), lessThan(0.8)),
        reason: '新身份应处于淡入中间值（实际 $newMid）');
    expect(oldMid + newMid, closeTo(0.85, 0.01), reason: '同槽位交叉淡化：透明度互补');
    // 原位：全程无位移/缩放/旋转。
    expect(cardDx(tester, oldCard), closeTo(rightDx, 0.5));
    expect(cardDx(tester, newCard), closeTo(rightDx, 0.5));

    await tester.pump(const Duration(milliseconds: 160)); // 淡化结束
    expect(oldCard, findsNothing, reason: '淡化结束旧身份应撤下');
    expect(nearestOpacityOf(tester, newCard), closeTo(0.85, 0.01));

    await tester.pump(const Duration(milliseconds: 400)); // 通知节流计时器跑完
    expect(tester.takeException(), isNull);

    // 同一槽位再变空：旧身份（d）淡出为空，不允许残留封面卡。
    emitCustom(current: b, queue: [a, b], index: 1, previous: a, next: null);
    await tester.pump(const Duration(milliseconds: 50)); // 检测帧

    final emptyOldCard = sideCard(left: false, track: d);
    expect(emptyOldCard, findsOneWidget);
    expect(nearestOpacityOf(tester, emptyOldCard), closeTo(0.85, 0.01));

    await tester.pump(const Duration(milliseconds: 40));
    final double emptyMid = nearestOpacityOf(tester, emptyOldCard);
    expect(emptyMid, allOf(greaterThan(0.1), lessThan(0.8)),
        reason: '变空时旧身份应处于淡出中间值（实际 $emptyMid）');
    expect(cardDx(tester, emptyOldCard), closeTo(rightDx, 0.5));

    await tester.pump(const Duration(milliseconds: 160));
    expect(emptyOldCard, findsNothing);
    expect(opacitiesNear(sampleCoverOpacities(tester), rightDx), isEmpty,
        reason: '变空后右槽不应再有封面卡');

    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  });

  testWidgets('左槽语义：无历史时回退队列前一位，当前在队首则留空', (tester) async {
    // 队列 [a,b,c]，当前 c（index 2），无播放历史 → 左槽回退队列前一位 b。
    emitCustom(current: c, queue: [a, b, c], index: 2);
    await pumpPlayer(tester);

    final leftCard = sideCard(left: true, track: b);
    expect(leftCard, findsOneWidget, reason: '无历史时左槽应显示队列前一位 b');
    expect(nearestOpacityOf(tester, leftCard), closeTo(0.85, 0.01));
    expect(cardDx(tester, leftCard),
        closeTo(sampleCoverOpacities(tester).first.dx, 0.5));
    expect(tester.takeException(), isNull);

    // 切到队首（current a）：没有可展示的上一首 → 左槽留空。
    emitCustom(current: a, queue: [a, b, c], index: 0, next: b);
    await pumpPlayer(tester);

    expect(sideCard(left: true, track: a), findsNothing,
        reason: '队首没有上一首：左槽应留空');
    expect(sideCard(left: true, track: b), findsNothing);
    // 右槽照常显示下一首，证明堆叠已正常渲染。
    expect(sideCard(left: false, track: b), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('中心封面同 id、URL 更新：250ms 交叉淡化换图，不播切歌动画', (tester) async {
    // 音源补图（null → URL）与后续换图（URL → URL）都走 250ms 交叉淡化。
    final b1 = _track('b', artwork: 'https://img.example/b1.jpg');
    final b2 = _track('b', artwork: 'https://img.example/b2.jpg');
    emitCustom(current: b, queue: [a, b, c], index: 1, previous: a, next: c);
    // 直接挂载封面堆叠（带封面的曲目会触发播放器的取色/预取路径，与换图
    // 淡化无关）；宿主按快照 current 重建 displayTrack，等价播放器的喂法。
    await pumpDeckHost(tester);
    final double centerDx =
        tester.getCenter(find.byKey(PlayerCoverDeck.swipeHostKey)).dx;

    final center = find.byKey(PlayerCoverDeck.centerCoverCardKey);
    final outgoing = find.byKey(PlayerCoverDeck.outgoingArtworkCardKey);
    expect(outgoing, findsNothing, reason: '稳态不应有旧图卡');

    /// 一轮换图：首帧旧图满、新图 0，中段两者中间值，250ms 后旧图撤下。
    Future<void> expectArtworkRefresh(
        Track newTrack, String newUrl, String reason) async {
      emitCustom(
          current: newTrack, queue: [a, newTrack, c], index: 1, previous: a, next: c);
      // 检测帧（先泵掉通知节流的补发窗口）：换图从 0 起步，旧图满、新图 0。
      await tester.pump(const Duration(milliseconds: 50));
      expect(outgoing, findsOneWidget, reason: '$reason：旧图卡应渲染（淡出起点）');
      expect(nearestOpacityOf(tester, outgoing), closeTo(1.0, 0.01));
      expect(nearestOpacityOf(tester, center), closeTo(0.0, 0.01));
      // 原位交叉：无位移。
      expect(tester.getCenter(outgoing).dx - centerDx, closeTo(0, 0.5));
      expect(tester.getCenter(center).dx - centerDx, closeTo(0, 0.5));
      // 旧图卡不得渲染新 URL（起点确实是被替换掉的那张图）。
      expect(cardImageUrls(tester, outgoing), isNot(contains(newUrl)),
          reason: '$reason：旧图卡不应渲染新 URL');

      await tester.pump(const Duration(milliseconds: 50)); // 250ms 前段
      final double outMid = nearestOpacityOf(tester, outgoing);
      final double inMid = nearestOpacityOf(tester, center);
      expect(outMid, allOf(greaterThan(0.1), lessThan(0.9)), reason: reason);
      expect(inMid, allOf(greaterThan(0.1), lessThan(0.9)), reason: reason);
      expect(outMid + inMid, closeTo(1.0, 0.01));

      await tester.pump(const Duration(milliseconds: 250)); // 换图走完
      expect(outgoing, findsNothing, reason: '$reason：结束应撤下旧图卡');
      expect(nearestOpacityOf(tester, center), closeTo(1.0, 0.01));
      expect(cardImageUrls(tester, center), contains(newUrl),
          reason: '$reason：中心应展示新 URL');
      expect(find.byKey(PlayerCoverDeck.centerCoverTrackKey(b.id)),
          findsOneWidget,
          reason: '换图不改变曲目身份');
    }

    // 1) 音源补图：无封面 → b1。
    await expectArtworkRefresh(b1, 'https://img.example/b1.jpg', '音源补图');
    // 2) 后续换图：b1 → b2。
    await expectArtworkRefresh(b2, 'https://img.example/b2.jpg', '换图');

    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  });

  testWidgets('切歌占位：中心卡不借旧封面作占位（目标图未命中走中性回退）', (tester) async {
    final b1 = _track('b', artwork: 'https://img.example/b.jpg');
    final c = _track('c'); // 无封面
    emitCustom(current: b1, queue: [a, b1, c], index: 1, previous: a, next: c);
    // 直接挂载封面堆叠（带封面的曲目会触发播放器的取色/预取路径）。
    await pumpDeckHost(tester);

    // 切到无封面的 c：中心卡（c）不得拿旧封面 b 当加载占位——否则目标图
    // 未预热时旧封面会从新卡下面透出来（连切残影的叠加来源）。
    emitCustom(
        current: c, queue: [a, b1, c], index: 2, previous: b1, next: null);
    await tester.pump(const Duration(milliseconds: 50)); // 检测帧
    await tester.pump(); // 动画首 tick

    final center = find.byKey(PlayerCoverDeck.centerCoverCardKey);
    final image = tester.widget<AppNetworkImage>(
        find.descendant(of: center, matching: find.byType(AppNetworkImage)).first);
    expect(image.url, isNull, reason: '新曲目 c 无封面（渲染回退占位）');
    expect(image.placeholder, isNot(isA<AppNetworkImage>()),
        reason: '中心卡不得用上一首封面当占位（应走曲目自己的默认封面 / 中性回退）');
    // 滑出卡仍是旧曲目 b 自己的封面（旧封面作为动画内容保留，不是占位）。
    final outgoing = find.byKey(PlayerCoverDeck.outgoingCoverCardKey);
    expect(
      tester
          .widget<AppNetworkImage>(
            find
                .descendant(of: outgoing, matching: find.byType(AppNetworkImage))
                .first,
          )
          .url,
      'https://img.example/b.jpg',
    );

    await tester.pump(const Duration(milliseconds: 400)); // 动画走完
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 400)); // 通知节流计时器跑完
  });

  testWidgets('两侧身份在淡化窗口内先后变化：后变化的一侧同样走交叉淡化', (tester) async {
    emitFor('b');
    await pumpPlayer(tester);
    final steady = sampleCoverOpacities(tester);
    final double leftDx = steady.first.dx;
    final double rightDx = steady.last.dx;

    // 右槽先变化：c → d。
    emitCustom(current: b, queue: [a, b, d], index: 1, previous: a, next: d);
    await tester.pump(const Duration(milliseconds: 50)); // 检测帧
    await tester.pump(const Duration(milliseconds: 50)); // 右槽淡化中

    // 左槽接着变化：a → c（同一个淡化窗口内）。
    emitCustom(current: b, queue: [c, b, d], index: 1, previous: c, next: d);
    await tester.pump(const Duration(milliseconds: 50));

    final leftOld = sideCard(left: true, track: a);
    final leftNew = sideCard(left: true, track: c);
    expect(leftOld, findsOneWidget, reason: '后变化的一侧也应有淡出起点（不硬切身份）');
    expect(leftNew, findsOneWidget);
    final double leftOldOpacity = nearestOpacityOf(tester, leftOld);
    final double leftNewOpacity = nearestOpacityOf(tester, leftNew);
    expect(leftOldOpacity, allOf(greaterThan(0.0), lessThan(0.85)));
    expect(leftNewOpacity, allOf(greaterThan(0.0), lessThan(0.85)));
    expect(leftOldOpacity + leftNewOpacity, closeTo(0.85, 0.01));
    expect(cardDx(tester, leftOld), closeTo(leftDx, 0.5));
    expect(cardDx(tester, leftNew), closeTo(leftDx, 0.5));
    expect(cardDx(tester, sideCard(left: false, track: d)),
        closeTo(rightDx, 0.5));

    await tester.pump(const Duration(milliseconds: 200));
    expect(leftOld, findsNothing);
    expect(nearestOpacityOf(tester, leftNew), closeTo(0.85, 0.01));
    expect(nearestOpacityOf(tester, sideCard(left: false, track: d)),
        closeTo(0.85, 0.01));

    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  });

  testWidgets('空闲淡换期间身份再次变化：以当前透明度接管新身份，不重启动画', (tester) async {
    final e = _track('e');
    emitFor('b');
    await pumpPlayer(tester);
    final double rightDx = sampleCoverOpacities(tester).last.dx;

    // 第一段变化：c → d，等淡化过半。
    emitCustom(current: b, queue: [a, b, d], index: 1, previous: a, next: d);
    await tester.pump(const Duration(milliseconds: 50)); // 检测帧
    await tester.pump(const Duration(milliseconds: 60)); // 淡化过半
    final double midValue = nearestOpacityOf(tester, sideCard(left: false, track: d));
    expect(midValue, greaterThan(0.1));

    // 第二段变化：d → e（淡化尚未结束）。
    emitCustom(current: b, queue: [a, b, e], index: 1, previous: a, next: e);
    await tester.pump(const Duration(milliseconds: 50)); // 检测帧（接管，不重启）
    final newCard = sideCard(left: false, track: e);
    expect(newCard, findsOneWidget);
    expect(sideCard(left: false, track: d), findsNothing,
        reason: '淡化中的新目标变化：直接接管新身份，不保留已作废的中间身份');
    // 不重启：新身份以当前透明度接管（透明度不回到 0），旧身份继续淡出。
    expect(nearestOpacityOf(tester, newCard), greaterThan(0.1));
    expect(cardDx(tester, newCard), closeTo(rightDx, 0.5));

    await tester.pump(const Duration(milliseconds: 200));
    expect(sideCard(left: false, track: c), findsNothing);
    expect(nearestOpacityOf(tester, newCard), closeTo(0.85, 0.01));

    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  });
}

/// 封面堆叠宿主：按快照 current 重建 displayTrack（等价播放器的喂法）。
class _DeckHost extends StatelessWidget {
  const _DeckHost({required this.fullCoverKey});

  final GlobalKey fullCoverKey;

  @override
  Widget build(BuildContext context) {
    final track =
        context.select<PlaybackProvider, Track?>((p) => p.snapshot.current);
    return PlayerCoverDeck(
      displayTrack: track,
      artDimension: _deck.artDimension,
      stackDimension: _deck.stackWidth,
      stackHeight: _deck.stackHeight,
      fullCoverKey: fullCoverKey,
    );
  }
}
