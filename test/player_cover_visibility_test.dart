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

/// 页面可见性（TickerMode）与切歌动画的边界：页面不可见时动画 ticker 被
/// 静音，若让会话冻结在中间进度，回到播放页会重播动画（或跳到结尾），而
/// 顶栏⇄播放页飞行在点击那一刻抓取的封面锚点正是这个中间布局——飞行会先
/// 落在错误位置再被动画带走。断言：隐藏期间切歌、离开时进行中的动画都立即
/// 落位，恢复可见后不存在中间态。
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
      upcoming: index + 1 < order.length ? order.sublist(index + 1) : const [],
      history: index > 0 ? order.sublist(0, index) : const [],
      isPlaying: true,
      position: const Duration(seconds: 5),
      duration: const Duration(seconds: 30),
    ));
  }

  /// 把播放器挂在可控的 TickerMode 下，模拟 tab 页的可见/隐藏切换。
  Future<void> pumpPlayer(
    WidgetTester tester,
    ValueNotifier<bool> tickers,
  ) async {
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
              child: ValueListenableBuilder<bool>(
                valueListenable: tickers,
                builder: (context, enabled, child) =>
                    TickerMode(enabled: enabled, child: child!),
                child: Player(
                  expandAnimation: expand,
                  onToggleExpand: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // 首帧切歌入场动画（320ms）：等它结束再操作。
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets('隐藏期间切歌：直接落位，恢复可见不重播', (tester) async {
    emitFor('b');
    final tickers = ValueNotifier<bool>(true);
    addTearDown(tickers.dispose);
    await pumpPlayer(tester, tickers);

    tickers.value = false;
    await tester.pump();

    emitFor('c');
    await tester.pump();
    await tester.pump();

    // 隐藏期间就应落位：morph 飞行在点击那一刻同步抓取封面锚点，
    // 等不到「恢复可见」那一帧的兜底落位。
    expect(find.byKey(PlayerCoverDeck.outgoingCoverCardKey), findsNothing,
        reason: '隐藏期间切歌应立即落位，不能留下待播的滑出卡');
    expect(
        find.byKey(PlayerCoverDeck.centerCoverTrackKey(c.id)), findsOneWidget,
        reason: '隐藏期间就应显示新曲目稳态');

    tickers.value = true;
    await tester.pump();
    expect(find.byKey(PlayerCoverDeck.outgoingCoverCardKey), findsNothing,
        reason: '恢复可见不应重播切歌动画');
    expect(
        find.byKey(PlayerCoverDeck.centerCoverTrackKey(c.id)), findsOneWidget,
        reason: '恢复可见应立即是稳态新曲目');
    expect(find.text('Title c'), findsWidgets);

    // 推进 400ms：不应有动画补播（滑出卡始终不出现）。
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(PlayerCoverDeck.outgoingCoverCardKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('离开播放页时进行中的切歌动画立即落位，返回不重播', (tester) async {
    emitFor('b');
    final tickers = ValueNotifier<bool>(true);
    addTearDown(tickers.dispose);
    await pumpPlayer(tester, tickers);

    emitFor('c');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(PlayerCoverDeck.outgoingCoverCardKey), findsOneWidget,
        reason: '切歌动画中滑出卡应在渲染');

    tickers.value = false;
    await tester.pump();
    expect(find.byKey(PlayerCoverDeck.outgoingCoverCardKey), findsNothing,
        reason: '离开播放页应立即落位，不留冻结的中间进度');

    tickers.value = true;
    await tester.pump();
    expect(find.byKey(PlayerCoverDeck.outgoingCoverCardKey), findsNothing);
    expect(
        find.byKey(PlayerCoverDeck.centerCoverTrackKey(c.id)), findsOneWidget);
    // 通知节流计时器跑完，避免测试结束时报 pending timer。
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(PlayerCoverDeck.outgoingCoverCardKey), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
