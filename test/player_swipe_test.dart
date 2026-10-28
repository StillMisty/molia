import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/player.dart';
import 'package:molia/widgets/player_cover_deck.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// 封面左右滑动切歌：必须用「move 之间 pump 帧」的拖动（timedDrag 或手动
/// 逐帧）来测——`tester.drag` 在同一次事件循环里发完 down/move/up，跳过了
/// 真机每帧重建的节奏，会让「手势宿主被换型重建 → 识别器 dispose」的
/// 滑到一半冻住问题在测试里完全隐形。
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

  /// 模拟后端切到指定曲目：next / previous / 再上一首 / upNext 与队列一致。
  void emitFor(String id) {
    final index = order.indexWhere((track) => track.id.id == id);
    backend.emit(BackendSnapshot(
      current: order[index],
      queue: order,
      currentIndex: index,
      next: index + 1 < order.length ? order[index + 1] : null,
      previous: index > 0 ? order[index - 1] : null,
      previousOfPrevious: index > 1 ? order[index - 2] : null,
      upNext: order.sublist(index + 1),
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

  /// 封面区手势宿主（拖动期间 element 稳定，见 Player.artworkSwipeHostKey）。
  Finder coverSwipeHost() => find.byKey(Player.artworkSwipeHostKey);

  int nextCalls() => backend.calls.where((call) => call == 'next').length;
  int previousCalls() =>
      backend.calls.where((call) => call == 'previous').length;

  /// 中心封面相对堆叠中心的横向偏移（0 = 稳态；拖动预览/切歌期间非 0）。
  double cardDx(WidgetTester tester, Finder finder) =>
      tester.getCenter(finder).dx -
      tester.getCenter(coverSwipeHost()).dx;

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

  /// 指定卡片在封面 Stack 中的子节点序号；序号越大越晚绘制（越在上层）。
  int cardPaintIndex(WidgetTester tester, Key key) {
    final stack = tester.element(
      find
          .descendant(
            of: find.byKey(PlayerCoverDeck.stackKey),
            matching: find.byType(Stack),
          )
          .first,
    );
    final target = tester.element(find.byKey(key));
    final children = <Element>[];
    stack.visitChildElements(children.add);
    bool contains(Element root) {
      var found = false;
      void visit(Element element) {
        if (element == target) found = true;
        if (!found) element.visitChildElements(visit);
      }

      visit(root);
      return found;
    }

    for (var i = 0; i < children.length; i++) {
      if (contains(children[i])) return i;
    }
    fail('未在封面 Stack 中找到 $key');
  }

  /// 拖动行程：deck 的换场行程是封面边长的 0.6（`_coverSwapRange`），
  /// 硬编码像素会随版式缩放漂移。
  double dragFor(WidgetTester tester, double fraction) =>
      tester.getSize(find.byKey(PlayerCoverDeck.centerCoverCardKey)).width *
      0.6 *
      fraction;

  testWidgets('逐帧横滑提交切歌：左滑下一首、右滑上一首，后端到位后落位新曲目', (tester) async {
    emitFor('b');
    await pumpPlayer(tester);

    await tester.timedDrag(
      coverSwipeHost(),
      const Offset(-160, 0),
      const Duration(milliseconds: 300),
    );
    // 提交是立即的（不等后端取链），预览保持到快照切换到目标。
    expect(nextCalls(), 1);
    expect(tester.takeException(), isNull);

    emitFor('c');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    // 对账落位：标题已是新曲目，且没有卡在等待态。
    expect(find.text('Title c'), findsWidgets);
    expect(tester.takeException(), isNull);

    // 右滑回到上一首：当前 c 的播放顺序前一位是 b。
    await tester.timedDrag(
      coverSwipeHost(),
      const Offset(160, 0),
      const Duration(milliseconds: 300),
    );
    expect(previousCalls(), 1);

    emitFor('b');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('Title b'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖动距离按真实按下位置计算（touch slop 不被吃掉）', (tester) async {
    emitFor('b');
    await pumpPlayer(tester);

    final gesture =
        await tester.startGesture(tester.getCenter(coverSwipeHost()));
    // 总计 100px：必须从真实按下位置累计；若从「手势确认位置」起算
    // 只剩 70px，达不到 80 提交阈值。
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-70, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(nextCalls(), 1);
    emitFor('c');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
  });

  testWidgets('未达阈值回弹，不切歌', (tester) async {
    emitFor('b');
    await pumpPlayer(tester);

    final gesture =
        await tester.startGesture(tester.getCenter(coverSwipeHost()));
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));

    expect(nextCalls(), 0);
    expect(previousCalls(), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖动到下一首再滑回：回弹期间目标槽位不得闪成当前封面', (tester) async {
    emitFor('b'); // 队列 a,b,c：右槽 = 下一首 c
    await pumpPlayer(tester);

    final double range = dragFor(tester, 1.0);
    final gesture =
        await tester.startGesture(tester.getCenter(coverSwipeHost()));
    // 先移动一段确认横滑，再走到下一首预览，最后拖回当前附近（p≈0.15）。
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump();
    await gesture.moveBy(Offset(-(range * 0.7 - 30), 0));
    await tester.pump();
    await gesture.moveBy(Offset(range * 0.55, 0));
    await tester.pump();
    // 停一拍再松手：速度估计清零，确保按「未达阈值」回弹而不是甩动提交。
    await tester.pump(const Duration(milliseconds: 300));

    expect(
        find.byKey(PlayerCoverDeck.centerCoverTrackKey(c.id)), findsOneWidget,
        reason: '拖动预览的中心位应是下一首');

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(
        find.byKey(PlayerCoverDeck.centerCoverTrackKey(c.id)), findsOneWidget,
        reason: '回弹期间中心卡仍是预览目标（不是当前曲目）');
    expect(find.byKey(PlayerCoverDeck.centerCoverTrackKey(b.id)), findsNothing,
        reason: '目标槽位不得在回弹半途显示当前封面');

    // 回弹落位：中心回当前、右槽恢复下一首，全程没有提交切歌。
    await tester.pump(const Duration(milliseconds: 700));
    expect(
        find.byKey(PlayerCoverDeck.centerCoverTrackKey(b.id)), findsOneWidget);
    expect(find.byKey(PlayerCoverDeck.centerCoverTrackKey(c.id)), findsNothing);
    expect(
      find.byKey(PlayerCoverDeck.sideCoverCardKey(left: false, id: c.id)),
      findsOneWidget,
      reason: '回弹落位后右槽应恢复下一首',
    );
    expect(nextCalls(), 0);
    expect(previousCalls(), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('左滑到下一首：下下张在拖动中进入右槽，落位后不重放淡入', (tester) async {
    emitFor('b'); // 队列 a,b,c,d：当前 b，右槽 c，再下一首 d
    await pumpPlayer(tester);
    expect(
      playback.snapshot.upNext.map((track) => track.id.id),
      ['c', 'd'],
      reason: '测试快照应带实际播放顺序',
    );

    final double range = dragFor(tester, 1.0);
    final gesture =
        await tester.startGesture(tester.getCenter(coverSwipeHost()));
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump();
    await gesture.moveBy(Offset(-(range * 0.8 - 30), 0));
    await tester.pump();

    final dCard = find.byKey(
      PlayerCoverDeck.sideCoverCardKey(left: false, id: d.id),
    );
    expect(dCard, findsOneWidget, reason: '拖动预览应提前渲染再下一首 d');
    expect(
      nearestOpacityOf(tester, dCard),
      greaterThan(0.1),
      reason: 'p≈0.8 时源侧新身份应已进入淡入窗口',
    );
    expect(cardDx(tester, dCard), greaterThan(20),
        reason: 'd 应落在右槽位而不是中心');

    // 走满行程：源侧新身份完全淡入。
    await gesture.moveBy(Offset(-(range * 0.2), 0));
    await tester.pump();
    expect(nearestOpacityOf(tester, dCard), closeTo(0.85, 0.02));

    await gesture.up();
    await tester.pump();
    expect(nextCalls(), 1);
    await tester.pump(const Duration(milliseconds: 400));
    expect(dCard, findsOneWidget, reason: '提交等待期间源侧身份应保持');
    expect(nearestOpacityOf(tester, dCard), closeTo(0.85, 0.02));

    emitFor('c'); // 对账到预览目标：新快照的 next 正是 d
    await tester.pump();
    expect(dCard, findsOneWidget, reason: '对账切换帧不能让 d 消失');
    expect(nearestOpacityOf(tester, dCard), closeTo(0.85, 0.02),
        reason: '预览已渲染同一身份，不应重放 180ms 淡入');

    await tester.pump(const Duration(milliseconds: 300));
    expect(dCard, findsOneWidget);
    expect(nearestOpacityOf(tester, dCard), closeTo(0.85, 0.02));
    expect(tester.takeException(), isNull);
  });

  testWidgets('右滑到上一首：再上一首在拖动中进入左槽，落位后不重放淡入', (tester) async {
    emitFor('c'); // 队列 a,b,c,d：当前 c，左槽 b，再上一首 a
    await pumpPlayer(tester);

    final double range = dragFor(tester, 1.0);
    final gesture =
        await tester.startGesture(tester.getCenter(coverSwipeHost()));
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.moveBy(Offset(range * 0.8 - 30, 0));
    await tester.pump();

    final aCard = find.byKey(
      PlayerCoverDeck.sideCoverCardKey(left: true, id: a.id),
    );
    expect(aCard, findsOneWidget, reason: '向后拖动预览应提前渲染再上一首 a');
    expect(nearestOpacityOf(tester, aCard), greaterThan(0.1));
    expect(cardDx(tester, aCard), lessThan(-20),
        reason: 'a 应落在左槽位而不是中心');

    await gesture.moveBy(Offset(range * 0.2, 0));
    await tester.pump();
    expect(nearestOpacityOf(tester, aCard), closeTo(0.85, 0.02));

    await gesture.up();
    await tester.pump();
    expect(previousCalls(), 1);
    await tester.pump(const Duration(milliseconds: 400));
    expect(aCard, findsOneWidget);
    expect(nearestOpacityOf(tester, aCard), closeTo(0.85, 0.02));

    emitFor('b'); // 对账到预览目标：新快照的 previous 正是 a
    await tester.pump();
    expect(aCard, findsOneWidget, reason: '对账切换帧不能让 a 消失');
    expect(nearestOpacityOf(tester, aCard), closeTo(0.85, 0.02),
        reason: '预览已渲染同一身份，不应重放 180ms 淡入');

    await tester.pump(const Duration(milliseconds: 300));
    expect(aCard, findsOneWidget);
    expect(
      find.byKey(PlayerCoverDeck.centerCoverTrackKey(b.id)),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('左滑后回拖：当前封面压住下一首，松手回弹期间也不翻回上层', (tester) async {
    emitFor('b');
    await pumpPlayer(tester);

    final double range = dragFor(tester, 1.0);
    final gesture =
        await tester.startGesture(tester.getCenter(coverSwipeHost()));
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump();
    await gesture.moveBy(Offset(-(range * 0.5 - 30), 0));
    await tester.pump();

    final outgoing = find.byKey(PlayerCoverDeck.outgoingCoverCardKey);
    final center = find.byKey(PlayerCoverDeck.centerCoverCardKey);
    expect(outgoing, findsOneWidget);
    expect(center, findsOneWidget);
    expect(
      cardPaintIndex(tester, PlayerCoverDeck.outgoingCoverCardKey),
      lessThan(cardPaintIndex(tester, PlayerCoverDeck.centerCoverCardKey)),
      reason: '正向拖动时目标封面在上层',
    );

    // 不松手回拖到 p≈0.2：当前封面必须压住仍在回退的下一首封面。
    await gesture.moveBy(Offset(range * 0.3, 0));
    await tester.pump();
    expect(
      cardPaintIndex(tester, PlayerCoverDeck.outgoingCoverCardKey),
      greaterThan(cardPaintIndex(tester, PlayerCoverDeck.centerCoverCardKey)),
      reason: '回拖时当前封面应置顶，不能看到下一首盖在当前封面上',
    );
    await tester.pump(const Duration(milliseconds: 300)); // 清掉速度

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(
      cardPaintIndex(tester, PlayerCoverDeck.outgoingCoverCardKey),
      greaterThan(cardPaintIndex(tester, PlayerCoverDeck.centerCoverCardKey)),
      reason: '松手回弹期间当前封面继续保持置顶',
    );

    await tester.pump(const Duration(milliseconds: 700));
    expect(outgoing, findsNothing);
    expect(
      find.byKey(PlayerCoverDeck.centerCoverTrackKey(b.id)),
      findsOneWidget,
    );
    expect(
      cardPaintIndex(tester, PlayerCoverDeck.centerCoverCardKey),
      greaterThan(cardPaintIndex(
        tester,
        PlayerCoverDeck.sideCoverCardKey(left: false, id: c.id),
      )),
      reason: '回弹落位后恢复稳态层级：中心封面在上',
    );
    expect(nextCalls(), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('右滑后回拖：当前封面压住上一首，左右方向层级一致', (tester) async {
    emitFor('c');
    await pumpPlayer(tester);

    final double range = dragFor(tester, 1.0);
    final gesture =
        await tester.startGesture(tester.getCenter(coverSwipeHost()));
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.moveBy(Offset(range * 0.5 - 30, 0));
    await tester.pump();

    final outgoing = find.byKey(PlayerCoverDeck.outgoingCoverCardKey);
    final center = find.byKey(PlayerCoverDeck.centerCoverCardKey);
    expect(outgoing, findsOneWidget);
    expect(center, findsOneWidget);
    expect(
      cardPaintIndex(tester, PlayerCoverDeck.outgoingCoverCardKey),
      lessThan(cardPaintIndex(tester, PlayerCoverDeck.centerCoverCardKey)),
      reason: '正向（向上一首）拖动时目标封面在上层',
    );

    await gesture.moveBy(Offset(-range * 0.3, 0));
    await tester.pump();
    expect(
      cardPaintIndex(tester, PlayerCoverDeck.outgoingCoverCardKey),
      greaterThan(cardPaintIndex(tester, PlayerCoverDeck.centerCoverCardKey)),
      reason: '回拖时当前封面应置顶',
    );
    await tester.pump(const Duration(milliseconds: 300));

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(
      cardPaintIndex(tester, PlayerCoverDeck.outgoingCoverCardKey),
      greaterThan(cardPaintIndex(tester, PlayerCoverDeck.centerCoverCardKey)),
      reason: '松手回弹期间当前封面继续保持置顶',
    );

    await tester.pump(const Duration(milliseconds: 700));
    expect(outgoing, findsNothing);
    expect(
      find.byKey(PlayerCoverDeck.centerCoverTrackKey(c.id)),
      findsOneWidget,
    );
    expect(
      cardPaintIndex(tester, PlayerCoverDeck.centerCoverCardKey),
      greaterThan(cardPaintIndex(
        tester,
        PlayerCoverDeck.sideCoverCardKey(left: true, id: b.id),
      )),
      reason: '回弹落位后恢复稳态层级：中心封面在上',
    );
    expect(previousCalls(), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('队列到头：硬边界不回弹也不提交', (tester) async {
    emitFor('d');
    await pumpPlayer(tester);

    await tester.timedDrag(
      coverSwipeHost(),
      const Offset(-160, 0),
      const Duration(milliseconds: 300),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(nextCalls(), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('提交等待期间的新拖动被忽略（不叠加切歌）', (tester) async {
    emitFor('b');
    await pumpPlayer(tester);

    await tester.timedDrag(
      coverSwipeHost(),
      const Offset(-160, 0),
      const Duration(milliseconds: 300),
    );
    expect(nextCalls(), 1);

    // 动画尾部立即再滑：提交等待期间的新拖动被拒绝，中心不得闪回旧曲目。
    final centerPreviewC =
        find.byKey(PlayerCoverDeck.centerCoverTrackKey(c.id));
    expect(centerPreviewC, findsOneWidget);
    await tester.timedDrag(
      coverSwipeHost(),
      const Offset(-160, 0),
      const Duration(milliseconds: 300),
    );
    expect(nextCalls(), 1);
    expect(centerPreviewC, findsOneWidget,
        reason: '动画尾部的新拖动不得把中心闪回旧曲目');

    // 让提交过渡落位（仍等待后端对账）：再次拖动仍应被会话拒绝，且画面
    // 不能因第二次手势出现旧中心卡/位置跳变。
    await tester.pump(const Duration(milliseconds: 600));
    final center = find.byKey(PlayerCoverDeck.centerCoverCardKey);
    final double beforeDx = cardDx(tester, center);
    expect(
      find.byKey(PlayerCoverDeck.centerCoverTrackKey(c.id)),
      findsOneWidget,
      reason: '提交等待期间中心仍是预览目标 c',
    );

    // 后端尚未切换：第二次拖动不应再次提交。
    await tester.timedDrag(
      coverSwipeHost(),
      const Offset(-160, 0),
      const Duration(milliseconds: 300),
    );
    expect(nextCalls(), 1);
    expect(cardDx(tester, center), closeTo(beforeDx, 0.5),
        reason: '第二次拖动被拒绝，中心卡位置不得跳变');
    expect(
      find.byKey(PlayerCoverDeck.centerCoverTrackKey(c.id)),
      findsOneWidget,
      reason: '第二次拖动不得把中心闪回旧曲目或再下一首',
    );

    emitFor('c');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(tester.takeException(), isNull);
  });

  testWidgets('手势取消：撤下预览回弹，不切歌', (tester) async {
    emitFor('b');
    await pumpPlayer(tester);

    final gesture =
        await tester.startGesture(tester.getCenter(coverSwipeHost()));
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-70, 0));
    await tester.pump();
    await gesture.cancel();
    await tester.pump(const Duration(milliseconds: 400));

    expect(nextCalls(), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖动中列表变化（next 变空）：预览保持中间态，不被打断', (tester) async {
    emitFor('b');
    await pumpPlayer(tester);

    // 左滑进入预览：-90px 超过 80 阈值但未走完行程，中心偏离稳态。
    final gesture =
        await tester.startGesture(tester.getCenter(coverSwipeHost()));
    await gesture.moveBy(const Offset(-60, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump();

    final center = find.byKey(PlayerCoverDeck.centerCoverCardKey);
    final double midDx = cardDx(tester, center);
    expect(midDx, greaterThan(4), reason: '拖动应已进入预览（中心偏离稳态）');

    // 拖动中「下一首」变空（播放列表变化）。
    backend.emit(BackendSnapshot(
      current: b,
      queue: [a, b],
      currentIndex: 1,
      next: null,
      previous: a,
      isPlaying: true,
      position: const Duration(seconds: 5),
      duration: const Duration(seconds: 30),
    ));
    await tester.pump(const Duration(milliseconds: 50)); // 通知检测帧

    // 继续拖动并等待：预览必须保持中间态，不撤下回弹。
    // （先泵一帧零时长：若实现错误地撤下预览，这一帧建立回弹 ticker 起点，
    // 下一帧才采样到回弹中间态。）
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(cardDx(tester, center), closeTo(midDx, 1),
        reason: '预览已激活时列表变化不应打断预览（中间态不回落）');

    // 松手未达提交阈值：回弹到稳态，不提交切歌。
    await gesture.moveBy(const Offset(90, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(nextCalls(), 0);
    expect(previousCalls(), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('提交后 6 秒无对账：兜底回弹到稳态，不卡在预览', (tester) async {
    emitFor('b');
    await pumpPlayer(tester);

    await tester.timedDrag(
      coverSwipeHost(),
      const Offset(-160, 0),
      const Duration(milliseconds: 300),
    );
    expect(nextCalls(), 1);
    await tester.pump(const Duration(milliseconds: 400)); // 提交过渡走完，预览保持

    final center = find.byKey(PlayerCoverDeck.centerCoverCardKey);
    expect(cardDx(tester, center), closeTo(0, 1), reason: '提交等待期间预览应保持落位（不回落）');

    // 后端迟迟不推快照：6 秒兜底计时器触发回弹。
    await tester.pump(const Duration(milliseconds: 6500));
    // expressive spatial 弹簧回弹到 0（含容差拖尾）约 0.5s。
    await tester.pump(const Duration(milliseconds: 700));

    expect(
        find.byKey(PlayerCoverDeck.centerCoverTrackKey(b.id)), findsOneWidget,
        reason: '兜底回弹后中心应回到实际曲目 b');
    expect(find.byKey(PlayerCoverDeck.outgoingCoverCardKey), findsNothing,
        reason: '回弹后滑出卡应撤下');
    expect(cardDx(tester, center), closeTo(0, 1));
    expect(tester.takeException(), isNull);
  });
}
