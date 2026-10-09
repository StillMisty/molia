import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/player.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// 封面左右滑动切歌：必须用「move 之间 pump 帧」的拖动（timedDrag 或手动
/// 逐帧）来测——`tester.drag` 在同一次事件循环里发完 down/move/up，跳过了
/// 真机每帧重建的节奏，曾让「手势宿主被换型重建 → 识别器 dispose」的
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
  final order = [a, b, c];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    backend = FakePlaybackBackend();
    playback = buildTestPlaybackProvider(backend: backend);
  });

  tearDown(() => playback.dispose());

  /// 模拟后端切到指定曲目：next/upcoming/history 与队列保持一致。
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

  /// 封面区手势宿主（拖动期间 element 稳定，见 Player.artworkSwipeHostKey）。
  Finder coverSwipeHost() => find.byKey(Player.artworkSwipeHostKey);

  int nextCalls() => backend.calls.where((call) => call == 'next').length;
  int previousCalls() =>
      backend.calls.where((call) => call == 'previous').length;

  testWidgets('逐帧左滑提交下一首，后端到位后落位新曲目', (tester) async {
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
  });

  testWidgets('逐帧右滑提交上一首', (tester) async {
    emitFor('b');
    await pumpPlayer(tester);

    await tester.timedDrag(
      coverSwipeHost(),
      const Offset(160, 0),
      const Duration(milliseconds: 300),
    );
    expect(previousCalls(), 1);

    emitFor('a');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('Title a'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖动距离按真实按下位置计算（touch slop 不被吃掉）', (tester) async {
    emitFor('b');
    await pumpPlayer(tester);

    final gesture =
        await tester.startGesture(tester.getCenter(coverSwipeHost()));
    // 总计 100px：旧实现从「手势确认位置」起算只剩 70px，达不到 80 阈值。
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

  testWidgets('队列到头：硬边界不回弹也不提交', (tester) async {
    emitFor('c');
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

    // 后端尚未切换：第二次拖动不应再次提交。
    await tester.timedDrag(
      coverSwipeHost(),
      const Offset(-160, 0),
      const Duration(milliseconds: 300),
    );
    expect(nextCalls(), 1);

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
}
