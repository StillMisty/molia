import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/cover_deck_metrics.dart';
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

/// 切歌检测的快照监听路径：deck 不在自己的 build 里检测曲目变化，
/// 而是监听 [PlaybackProvider] 通知、比较当前曲目 id 后开启切歌会话。
///
/// 这里把 [PlayerCoverDeck] 直接挂在根上且 `displayTrack` 固定不变：
/// 父级不会因通知重建，deck 也不可能通过「displayTrack 变化」察觉切歌，
/// 唯一能启动动画/触发联动的只有快照监听本身；本测试即锁定该契约。
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
      previous: index > 0 ? order[index - 1] : null,
      isPlaying: true,
      position: const Duration(seconds: 5),
      duration: const Duration(seconds: 30),
    ));
  }

  /// 指定封面卡相对堆叠中心的横向偏移：0 = 稳态；切歌入场期间非 0
  /// （向前从右侧入场 = 正值）。
  double offsetOf(WidgetTester tester, Finder finder) =>
      tester.getCenter(finder).dx -
      tester.getCenter(find.byKey(PlayerCoverDeck.swipeHostKey)).dx;

  double centerOffset(WidgetTester tester) =>
      offsetOf(tester, find.byKey(PlayerCoverDeck.centerCoverCardKey));

  /// 指定卡片最近一层 Opacity 的值（侧槽窗口 / 中心接管透明度）。
  double opacityOf(WidgetTester tester, Finder finder) {
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

  /// 挂载 deck，等首帧落定，返回切歌联动回调的记录列表（已清掉首帧入场
  /// 留下的调用）。
  ///
  /// 默认 `displayTrack = A` 固定不变：锁定「切歌检测完全由快照监听驱动、
  /// 不依赖父级重建」。连续接管用例需要生产口径（父级随快照把 displayTrack
  /// 换成新 current），此时传 [reactiveDisplayTrack]。
  Future<List<bool>> pumpDeck(
    WidgetTester tester, {
    bool reactiveDisplayTrack = false,
  }) async {
    final swaps = <bool>[];
    final fullCoverKey = GlobalKey();
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
              child: reactiveDisplayTrack
                  ? Consumer<PlaybackProvider>(
                      builder: (context, provider, _) => PlayerCoverDeck(
                        displayTrack: provider.snapshot.current ?? a,
                        artDimension: _deck.artDimension,
                        stackDimension: _deck.stackWidth,
                        stackHeight: _deck.stackHeight,
                        fullCoverKey: fullCoverKey,
                        onTrackSwapped: swaps.add,
                      ),
                    )
                  : PlayerCoverDeck(
                      displayTrack: a,
                      artDimension: _deck.artDimension,
                      stackDimension: _deck.stackWidth,
                      stackHeight: _deck.stackHeight,
                      fullCoverKey: fullCoverKey,
                      onTrackSwapped: swaps.add,
                    ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // 等首帧落定（冷启动恢复态首帧已是稳态）。
    await tester.pump(const Duration(milliseconds: 600));
    swaps.clear();
    return swaps;
  }

  testWidgets('快照通知即切歌检测：不依赖父级重建，动画照常开始', (tester) async {
    emitFor('a');
    final swaps = await pumpDeck(tester);
    expect(swaps, isEmpty);

    emitFor('b');
    // 通知（可能是节流后补发）→ 微任务对账 → 检测帧末尾触发联动。
    await tester.pump(const Duration(milliseconds: 50));
    expect(swaps, [false], reason: '快照通知应在本帧触发 onTrackSwapped（无需父级重建）');

    await tester.pump(); // 动画首 tick
    await tester.pump(const Duration(milliseconds: 100)); // 中间态
    expect(centerOffset(tester), greaterThan(4),
        reason: '切歌动画应由快照通知驱动启动（中心封面从右侧入场）');
    expect(tester.takeException(), isNull);
    // 让 provider 的通知节流计时器（queue 300ms）跑完，避免残留 pending timer。
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('同一批多条通知只对账一次，不重复触发', (tester) async {
    emitFor('a');
    final swaps = await pumpDeck(tester);

    // 同一同步批次内连续两条快照（b → c）：微任务合并后只应处理最终曲目。
    emitFor('b');
    emitFor('c');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(swaps, hasLength(1), reason: '同一批通知只应触发一次切歌联动，而不是每帧每条都触发');
    expect(tester.takeException(), isNull);
    // 让 provider 的通知节流计时器（queue 300ms）跑完，避免残留 pending timer。
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('快速连切：从当前进度连续接管，不回到起点重放', (tester) async {
    emitFor('a');
    final swaps = await pumpDeck(tester);

    emitFor('b');
    await tester.pump(const Duration(milliseconds: 50)); // 检测帧
    await tester.pump(); // 动画首 tick
    await tester.pump(const Duration(milliseconds: 100)); // 动画中段（弹簧 ~0.66）
    expect(centerOffset(tester), greaterThan(4));

    // 动画尚未结束就切到 c：应从当前进度续走。
    emitFor('c');
    await tester.pump(const Duration(milliseconds: 50)); // 第二次检测帧
    await tester.pump(); // 检测 post-frame 之后一帧
    expect(centerOffset(tester), lessThan(40),
        reason: '连切应从当前进度续走；若回到起点重放会跳回满偏移（约 72）');
    expect(swaps, hasLength(2));

    await tester.pump(const Duration(milliseconds: 600));
    expect(centerOffset(tester), closeTo(0, 1));
    expect(tester.takeException(), isNull);
    // 让 provider 的通知节流计时器（queue 300ms）跑完，避免残留 pending timer。
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('连切接管：弹簧途中再切歌，滑出卡从上一帧中心卡位置连续接管，不跳侧槽', (tester) async {
    emitFor('a');
    final swaps = await pumpDeck(tester, reactiveDisplayTrack: true);

    emitFor('b');
    await tester.pump(const Duration(milliseconds: 50)); // 第一次检测帧
    await tester.pump(); // 动画首 tick
    await tester.pump(const Duration(milliseconds: 90)); // 弹簧中段
    final centerB = find.byKey(PlayerCoverDeck.centerCoverTrackKey(b.id));
    final double before = offsetOf(tester, centerB);
    expect(before, greaterThan(4), reason: '前提：第一次切歌中心卡仍在侧槽入场途中');

    // 弹簧途中切到 c：新会话的滑出卡就是上一段的中位卡 b，必须以它当前
    // 位置为起点（旧实现按新会话 -offset*p 重画，会瞬移约一个侧槽宽）。
    emitFor('c');
    // 让 provider 的 track 通知节流（16ms）落地；只推进这一小段，让接管帧
    // 的滑出卡仍应落在上一帧中心卡附近（旧实现会瞬移约一个侧槽宽）。
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();
    final outgoing = find.byKey(PlayerCoverDeck.outgoingCoverCardKey);
    expect(outgoing, findsOneWidget);
    final double sideOffset = _deck.artDimension * 0.30;
    final double after = offsetOf(tester, outgoing);
    expect(
      (after - before).abs(),
      lessThan(sideOffset * 0.5),
      reason: '接管帧滑出卡位置应连续（前 $before → 后 $after，侧槽宽 $sideOffset）',
    );

    // 再逐帧采样：接管后的滑出卡不允许出现约一个侧槽宽的跳变。
    var previous = after;
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (outgoing.evaluate().isEmpty) break;
      final double current = offsetOf(tester, outgoing);
      expect(
        (current - previous).abs(),
        lessThan(sideOffset * 0.5),
        reason: '接管后逐帧位移不应跳变（$previous → $current）',
      );
      previous = current;
    }

    // 第二次动画仍在途中再切到 d：链式接管，最终中心只留 d，没有上一首残影。
    emitFor('d');
    await tester.pump(const Duration(milliseconds: 20)); // track 通知节流
    await tester.pump(); // 接管首帧
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byKey(PlayerCoverDeck.outgoingCoverCardKey), findsOneWidget,
        reason: '链式接管仍应渲染当前滑出卡');

    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byKey(PlayerCoverDeck.centerCoverTrackKey(d.id)), findsOneWidget);
    expect(find.byKey(PlayerCoverDeck.centerCoverTrackKey(b.id)), findsNothing,
        reason: '连续切多首后中心不残留更早的封面');
    expect(find.byKey(PlayerCoverDeck.centerCoverTrackKey(c.id)), findsNothing,
        reason: '连续切多首后中心不残留上一首');
    expect(find.byKey(PlayerCoverDeck.outgoingCoverCardKey), findsNothing);
    expect(swaps, hasLength(3));
    expect(tester.takeException(), isNull);
    // 通知节流计时器跑完，避免测试结束时报 pending timer。
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('方向反转接管：旧中心 B 与新中心 A 都从捕获位置连续接管', (tester) async {
    emitFor('a');
    final swaps = await pumpDeck(tester, reactiveDisplayTrack: true);

    emitFor('b');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    final centerB = find.byKey(PlayerCoverDeck.centerCoverTrackKey(b.id));
    final oldOutgoingA = find.byKey(PlayerCoverDeck.outgoingCoverCardKey);
    final double beforeB = offsetOf(tester, centerB);
    final double beforeA = offsetOf(tester, oldOutgoingA);
    expect(beforeB, greaterThan(4), reason: '前提：B 从右侧入场途中');
    expect(beforeA, lessThan(-4), reason: '前提：A 正滑向左槽');

    // 弹簧途中反向切回 A：A 是上一段旧 outgoing，restart 接管时新中心 A
    // 从 A 的捕获位置起，B 从中心捕获位置继续滑向右槽。
    emitFor('a');
    await tester.pump(const Duration(milliseconds: 20)); // track 通知节流
    await tester.pump();
    final newCenterA = find.byKey(PlayerCoverDeck.centerCoverTrackKey(a.id));
    final newOutgoingB = find.byKey(PlayerCoverDeck.outgoingCoverCardKey);
    expect(newCenterA, findsOneWidget);
    expect(newOutgoingB, findsOneWidget);
    final double afterA = offsetOf(tester, newCenterA);
    final double afterB = offsetOf(tester, newOutgoingB);
    final double sideOffset = _deck.artDimension * 0.30;
    expect(
      (afterA - beforeA).abs(),
      lessThan(sideOffset * 0.35),
      reason: '新中心 A 应接住旧 outgoing A 的位置（$beforeA → $afterA）',
    );
    expect(
      (afterB - beforeB).abs(),
      lessThan(sideOffset * 0.35),
      reason: '旧中心 B 应接住自己上一帧中心位置（$beforeB → $afterB）',
    );

    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byKey(PlayerCoverDeck.centerCoverTrackKey(a.id)),
        findsOneWidget);
    expect(find.byKey(PlayerCoverDeck.outgoingCoverCardKey), findsNothing);
    expect(swaps, hasLength(2));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('p0 ≥ 0.75 接管：旧中心从接近中心的位置续滑，不落位重播', (tester) async {
    emitFor('a');
    await pumpDeck(tester, reactiveDisplayTrack: true);

    emitFor('b');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120)); // 接近落位
    final centerB = find.byKey(PlayerCoverDeck.centerCoverTrackKey(b.id));
    final double before = offsetOf(tester, centerB);
    final double sideOffset = _deck.artDimension * 0.30;
    expect(before, greaterThan(0), reason: '前提：B 已接近中心但尚未落位');
    expect(before, lessThan(sideOffset * 0.25),
        reason: '前提必须真的越过 p0≥0.75（中心偏移 < 0.25 侧槽宽）');
    final sourceC =
        find.byKey(PlayerCoverDeck.sideCoverCardKey(left: false, id: c.id));
    expect(sourceC, findsOneWidget);
    final double beforeCOpacity = opacityOf(tester, sourceC);
    expect(beforeCOpacity, greaterThan(0.01),
        reason: '前提：C 已作为 source neighbor 半透明出现');

    // 同方向继续切 c：restart 从 B 的捕获位置起滑向左槽，不能把 p 归零后
    // 从中心重新起跳（旧实现的落位式跳变）；新中心 C 也应接住 source
    // neighbor 的低透明度，而不是直接跳到 0.85。
    emitFor('c');
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();
    final outgoing = find.byKey(PlayerCoverDeck.outgoingCoverCardKey);
    expect(outgoing, findsOneWidget);
    final double after = offsetOf(tester, outgoing);
    expect(after, greaterThan(0),
        reason: '滑出卡起点应保留捕获时仍在中心右侧的位置（不是 p=0 的中心）');
    expect(
      (after - before).abs(),
      lessThan(sideOffset * 0.25),
      reason: '接近落位接管也不应有落位式跳变（$before → $after）',
    );
    final centerC = find.byKey(PlayerCoverDeck.centerCoverTrackKey(c.id));
    expect(centerC, findsOneWidget);
    final double afterCOpacity = opacityOf(tester, centerC);
    expect(afterCOpacity, lessThan(0.8),
        reason: '新中心 C 不应直接以 0.85 全亮出现');
    expect((afterCOpacity - beforeCOpacity).abs(), lessThan(0.25),
        reason:
            '新中心 C 应接住 source neighbor 的透明度（$beforeCOpacity → $afterCOpacity）');

    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byKey(PlayerCoverDeck.centerCoverTrackKey(c.id)),
        findsOneWidget);
    expect(find.byKey(PlayerCoverDeck.outgoingCoverCardKey), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('p0 0.6~0.75：新中心从 source neighbor 的实际视觉接管', (tester) async {
    emitFor('a');
    await pumpDeck(tester, reactiveDisplayTrack: true);

    emitFor('b');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100)); // p0 已进入源侧淡入窗口
    final sourceC =
        find.byKey(PlayerCoverDeck.sideCoverCardKey(left: false, id: c.id));
    expect(sourceC, findsOneWidget);
    final double beforeDx = offsetOf(tester, sourceC);
    final double beforeOpacity = opacityOf(tester, sourceC);
    expect(beforeOpacity, greaterThan(0.01),
        reason: '前提：C 已作为 source neighbor 半透明出现');

    // 同方向继续切 c：新中心 C 应接住 source neighbor 的位置/透明度，而不是
    // 从全局 p 公式的中途位置突然出现。
    emitFor('c');
    await tester.pump(const Duration(milliseconds: 17)); // 刚过 track 节流
    await tester.pump();
    final centerC = find.byKey(PlayerCoverDeck.centerCoverTrackKey(c.id));
    expect(centerC, findsOneWidget);
    final double afterDx = offsetOf(tester, centerC);
    final double afterOpacity = opacityOf(tester, centerC);
    final double sideOffset = _deck.artDimension * 0.30;
    // 捕获帧可能已经自然滑动了一小段：仍应明显靠近右槽，而不是按全局 p
    // 公式跳到接近中心；透明度也应从 source neighbor 的低窗口值起步。
    expect(afterDx, greaterThan(sideOffset * 0.5),
        reason: '新中心 C 应从 source neighbor 的槽位附近接管');
    expect(beforeDx - afterDx, lessThan(sideOffset * 0.4),
        reason: '一帧内自然滑动，不应出现公式中途位置的大跳');
    expect(afterOpacity, lessThan(0.6),
        reason: '新中心 C 透明度应从 source neighbor 窗口值起步，而不是硬跳满值');

    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byKey(PlayerCoverDeck.centerCoverTrackKey(c.id)), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('restart 链式接管：A 的中心实际视觉被下一次接管捕获', (tester) async {
    emitFor('a');
    await pumpDeck(tester, reactiveDisplayTrack: true);

    // A→B 中段。
    emitFor('b');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));

    // 反向 B→A restart；等它从 A 的捕获视觉走向中心一段。
    emitFor('a');
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final centerA = find.byKey(PlayerCoverDeck.centerCoverTrackKey(a.id));
    final double beforeA = offsetOf(tester, centerA);

    // 再反向 A→B restart：新滑出卡 A 必须接住刚才 restart 中心 A 的实际
    // 视觉（旧实现会退回公式位置，跳一下）。
    emitFor('b');
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();
    final outgoingA = find.byKey(PlayerCoverDeck.outgoingCoverCardKey);
    expect(outgoingA, findsOneWidget);
    final double afterA = offsetOf(tester, outgoingA);
    final double sideOffset = _deck.artDimension * 0.30;
    expect(
      (afterA - beforeA).abs(),
      lessThan(sideOffset * 0.2),
      reason: '链式 restart 的新 outgoing A 应接住上一段中心 A（$beforeA → $afterA）',
    );

    int tailLayers() => find
        .byWidgetPredicate(
          (widget) =>
              widget is Positioned &&
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>)
                  .value
                  .startsWith('coverHandoffTail:'),
        )
        .evaluate()
        .length;
    expect(tailLayers(), lessThanOrEqualTo(2), reason: 'tail 同身份去重后最多两层');
    expect(tester.takeException(), isNull,
        reason: 'tail 稳定 key 去重后不应出现重复 key');

    // 第三次继续 B→C（同方向 continuous），验证 restart 链后再接管不崩。
    await tester.pump(const Duration(milliseconds: 40));
    emitFor('c');
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byKey(PlayerCoverDeck.centerCoverTrackKey(c.id)), findsOneWidget);
    expect(find.byKey(PlayerCoverDeck.outgoingCoverCardKey), findsNothing);
    expect(tailLayers(), 0);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('回绕连切：新中心身份不会同时留在 tail', (tester) async {
    void emitCyclic(Track track, int index) {
      final int nextIndex = (index + 1) % order.length;
      final int previousIndex = (index - 1 + order.length) % order.length;
      backend.emit(BackendSnapshot(
        current: track,
        queue: order,
        currentIndex: index,
        next: order[nextIndex],
        previous: order[previousIndex],
        previousOfPrevious:
            order[(index - 2 + order.length) % order.length],
        upNext: [
          order[nextIndex],
          order[(index + 2) % order.length],
          order[(index + 3) % order.length],
        ],
        isPlaying: true,
        position: const Duration(seconds: 5),
        duration: const Duration(seconds: 30),
      ));
    }

    emitCyclic(a, 0);
    await pumpDeck(tester, reactiveDisplayTrack: true);
    emitCyclic(b, 1);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    emitCyclic(c, 2);
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();
    // 回绕前 A 已经是上一段的 tail。
    final tailA = ValueKey('coverHandoffTail:${a.id.uri}');
    expect(find.byKey(tailA), findsOneWidget);

    // C→A（next 提示命中 → 同方向 continuous）。新中心 A 必须先从 tail 移除，
    // 不能 tail + center 同曲两张卡。
    emitCyclic(a, 0);
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();
    expect(find.byKey(PlayerCoverDeck.centerCoverTrackKey(a.id)),
        findsOneWidget);
    expect(find.byKey(tailA), findsNothing,
        reason: '新中心 A 不得同时留在 tail 列表');
    expect(tester.takeException(), isNull,
        reason: '同身份 tail 若重复会触发重复 key');

    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byKey(PlayerCoverDeck.centerCoverTrackKey(a.id)),
        findsOneWidget);
    expect(find.byKey(PlayerCoverDeck.outgoingCoverCardKey), findsNothing);
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('current 变为 null：不触发切歌、不崩，随后切歌仍正常', (tester) async {
    emitFor('a');
    final swaps = await pumpDeck(tester);

    // 停止/清空：快照 current 为 null。
    backend.emit(BackendSnapshot.empty);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(swaps, isEmpty, reason: 'current 清空不应触发切歌联动');
    expect(tester.takeException(), isNull);

    // 清空后再出现另一首：动画身份仍从 A 比较，正常触发。
    emitFor('c');
    await tester.pump(const Duration(milliseconds: 50));
    expect(swaps, [false]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(centerOffset(tester), greaterThan(4));
    expect(tester.takeException(), isNull);
    // 让 provider 的通知节流计时器（queue 300ms）跑完，避免残留 pending timer。
    await tester.pump(const Duration(milliseconds: 400));
  });
}
