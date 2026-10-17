import 'dart:math' as math;

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

/// 封面按压反馈：按下立即缩小（0.96）、抬起/取消回弹。
///
/// 按压反馈走原始指针事件（TapGestureRecognizer 的 onTapDown 与横滑识别器
/// 竞争时要等 100ms 判定或抬手才触发，给不了「按下即反馈」）。断言只读外部
/// 可观察行为：卡片相邻的 Transform 缩放矩阵（不读私有字段）；存在常驻波浪
/// 动画，不能 pumpAndSettle，按固定时长 pump 采样。
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
  final order = [a, b, c];

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
    // 首帧切歌入场动画：motor expressive spatial 弹簧（含容差拖尾约 0.7s）
    // 落定后才渲染稳态左右槽位，等它结束再操作。
    await tester.pump(const Duration(milliseconds: 900));
  }

  /// 卡片上下相邻的 Transform 里是否存在「按压缩放」量级：
  /// 中心卡的按压 Transform 是 card key 的后代，邻位卡的是祖先（结构不同）。
  /// 用矩阵 m00（X 轴缩放）而不是 getMaxScaleOnAxis——2D 缩放的 Z 轴恒为 1，
  /// 后者永远返回 1；上限 0.995 用于排除邻位卡 ±0.05rad 旋转的 cos 值。
  bool hasPressedScale(WidgetTester tester, Finder card) {
    final transforms = <Transform>[
      ...tester.widgetList<Transform>(
          find.ancestor(of: card, matching: find.byType(Transform))),
      ...tester.widgetList<Transform>(
          find.descendant(of: card, matching: find.byType(Transform))),
    ];
    return transforms.any((t) {
      final xScale = t.transform.entry(0, 0);
      return xScale > 0.9 && xScale < 0.995;
    });
  }

  testWidgets('按压中心与邻位封面：按下立即缩放，取消后回位', (tester) async {
    emitFor('b');
    await pumpPlayer(tester);

    final center = find.byKey(PlayerCoverDeck.centerCoverCardKey);
    expect(center, findsOneWidget);

    final centerGesture = await tester.startGesture(tester.getCenter(center));
    await tester.pump(); // 按压动画首 tick（elapsed 0）
    await tester.pump(const Duration(milliseconds: 80));
    expect(hasPressedScale(tester, center), isTrue,
        reason: '按下中心封面应立刻出现缩放反馈');

    await centerGesture.cancel();
    await tester.pump(); // 回弹首 tick（elapsed 0）
    await tester.pump(const Duration(milliseconds: 250));
    expect(hasPressedScale(tester, center), isFalse,
        reason: '取消按压后应回弹到 1.0');
    expect(tester.takeException(), isNull);

    final left =
        find.byKey(PlayerCoverDeck.sideCoverCardKey(left: true, id: a.id));
    expect(left, findsOneWidget);

    // 左卡外缘伸出屏幕：取屏内可见的左侧条带（中心卡覆盖不到的区域）。
    final rect = tester.getRect(left);
    final point = Offset(math.max(rect.left + 8, 8.0), rect.center.dy);
    final leftGesture = await tester.startGesture(point);
    await tester.pump(); // 按压动画首 tick（elapsed 0）
    await tester.pump(const Duration(milliseconds: 80));
    expect(hasPressedScale(tester, left), isTrue,
        reason: '按下邻位封面应立刻出现缩放反馈');

    await leftGesture.cancel();
    await tester.pump(); // 回弹首 tick（elapsed 0）
    await tester.pump(const Duration(milliseconds: 250));
    expect(hasPressedScale(tester, left), isFalse,
        reason: '取消按压后应回弹到 1.0');
    expect(tester.takeException(), isNull);
  });
}
