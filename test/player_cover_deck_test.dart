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
    // 首帧切歌入场动画 460ms：等它结束再操作。
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
}
