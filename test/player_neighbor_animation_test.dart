import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/player.dart';
import 'package:molia/widgets/player_morph.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// 侧边（上一首/下一首）封面入场动效：0 = 藏在中心封面背后，1 = 稳态。
///
/// 三处触发都要验证「存在中间态」：从 0 连续走到 0.85，而不是直接出现在
/// 槽位（pop）。
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
    await tester.pump(const Duration(milliseconds: 600));
  }

  /// 侧边封面的透明度（入场值乘 0.85）。只看封面堆叠内部，避开完整层
  /// 淡入自身的 Opacity（展开过程中它也是中间值，会干扰判断）。
  Iterable<double> sideOpacities(WidgetTester tester) => tester
      .widgetList<Opacity>(find.descendant(
        of: find.byKey(Player.artworkSwipeHostKey),
        matching: find.byType(Opacity),
      ))
      .map((widget) => widget.opacity);

  bool hasIntermediateSideOpacity(WidgetTester tester) =>
      sideOpacities(tester).any((opacity) => opacity > 0 && opacity < 0.8);

  bool hasSettledSideOpacity(WidgetTester tester) =>
      sideOpacities(tester).any((opacity) => (opacity - 0.85).abs() < 0.01);

  testWidgets('滑动提交对账：新的再下一首从中心背后入场', (tester) async {
    emitFor('b');
    final expand = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 360),
      value: 1.0,
    );
    addTearDown(expand.dispose);
    await pumpPlayer(tester, expand: expand);

    await tester.timedDrag(
      find.byKey(Player.artworkSwipeHostKey),
      const Offset(-160, 0),
      const Duration(milliseconds: 300),
    );
    // 让提交过渡走完（后端还没确认），此时是对账的后半条路径。
    await tester.pump(const Duration(milliseconds: 700));

    emitFor('c');
    await tester.pump();
    // 入场在 post-frame 启动：先过一帧（首 tick elapsed=0），再推进到中间态。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(hasIntermediateSideOpacity(tester), isTrue,
        reason: '落位时应看到新邻位淡入的中间态，而不是直接 0.85');

    await tester.pump(const Duration(milliseconds: 400));
    expect(hasSettledSideOpacity(tester), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('顶栏→播放页飞行：侧边封面在落位后从中心背后展开', (tester) async {
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

    // 飞行开始：侧边封面先藏起来（页面淡入阶段只有中心飞行）。
    morph.setPageHeaderHidden(true);
    await tester.pump();
    expect(hasIntermediateSideOpacity(tester), isFalse);

    // 飞行落位：侧边封面从中心背后展开。
    morph.setPageHeaderHidden(false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(hasIntermediateSideOpacity(tester), isTrue);

    await tester.pump(const Duration(milliseconds: 400));
    expect(hasSettledSideOpacity(tester), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('展开迷你→完整：侧边封面在飞行落位后展开', (tester) async {
    emitFor('b');
    final expand = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 360),
    );
    addTearDown(expand.dispose);
    await pumpPlayer(tester, expand: expand);

    // 迷你态起步：展开过程侧边封面藏在中心背后。
    expand.forward();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(hasIntermediateSideOpacity(tester), isFalse);

    // 展开完成 = 中心封面飞行落位：侧边封面展开。
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(hasIntermediateSideOpacity(tester), isTrue);

    await tester.pump(const Duration(milliseconds: 400));
    expect(hasSettledSideOpacity(tester), isTrue);
    expect(tester.takeException(), isNull);
  });
}
