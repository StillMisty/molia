import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/nowplaying.dart';
import 'package:molia/providers/lyrics_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/mdtab.dart';
import 'package:molia/widgets/player.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// 播放页 smoke 测试：圆点切换行常显 + Apple Music 式跟手拖拽展开/收起。
Track _track(String id) => Track(
      id: TrackId('fake', id),
      title: 'Title $id',
      artists: [Artist(name: 'Artist $id')],
      album: 'Album',
      duration: const Duration(seconds: 30),
      // 不带封面：避免测试触发网络预取/取色。
      origin: TrackOrigin.lx,
      payload: {'id': id},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlaybackBackend backend;
  late PlaybackProvider playback;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    backend = FakePlaybackBackend();
    playback = buildTestPlaybackProvider(backend: backend);
  });

  tearDown(() => playback.dispose());

  Future<void> pumpNowPlaying(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    backend.emit(BackendSnapshot(
      current: _track('a'),
      queue: [_track('a')],
      currentIndex: 0,
      isPlaying: false,
      position: Duration.zero,
      duration: const Duration(seconds: 30),
    ));

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
          // 播放页内嵌 LyricsWidget：歌词会话模块由 composition root 提供，
          // 测试同样注入（真实 LyricsService 在测试 HTTP mock 下快速失败）。
          ChangeNotifierProvider(create: (_) => LyricsProvider()),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: const NowPlaying(),
        ),
      ),
    );
    await tester.pump();
    // 等首帧切歌入场动画结束（封面堆叠 460ms）。
    await tester.pump(const Duration(milliseconds: 600));
  }

  double playerHeight(WidgetTester tester) =>
      tester.getSize(find.byType(Player)).height;

  /// 点第一个圆点切到队列页（默认在歌词页）。
  Future<void> selectQueuePage(WidgetTester tester) async {
    final dots = find.descendant(
      of: find.byType(LyricsQueueDots),
      matching: find.byType(GestureDetector),
    );
    await tester.tap(dots.first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// 播放器区域慢速跟手拖拽（timedDrag 速度低，判定由位置决定）。
  Future<void> dragPlayer(WidgetTester tester, double dy) async {
    await tester.timedDrag(
      find.byType(Player),
      Offset(0, dy),
      const Duration(milliseconds: 500),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('切换行：小圆点常显，无收起/展开按钮', (tester) async {
    await pumpNowPlaying(tester);

    expect(tester.takeException(), isNull);
    expect(find.byType(LyricsQueueDots), findsOneWidget);
    // 旧版图标切换器/收起按钮不应再出现。
    expect(find.byIcon(Icons.queue_music_rounded), findsNothing);
    expect(find.byIcon(Icons.lyrics_rounded), findsNothing);
    expect(find.byIcon(Icons.expand_more_rounded), findsNothing);
    expect(find.byIcon(Icons.expand_less_rounded), findsNothing);
  });

  testWidgets('播放器区域跟手拖拽：上拉展开、下拉收起', (tester) async {
    await pumpNowPlaying(tester);

    expect(playerHeight(tester), greaterThan(300), reason: '默认完整态');

    // 展开态：播放器区域下拉超过一半行程 = 收起。
    await dragPlayer(tester, 300);
    expect(playerHeight(tester), lessThan(100), reason: '下拉应收起为迷你条');

    // 收起态：播放器区域上拉超过一半行程 = 展开。
    await dragPlayer(tester, -240);
    expect(playerHeight(tester), greaterThan(300), reason: '上拉应展开');

    // 通知节流计时器跑完，避免 pending timer 报错。
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('展开只在播放器区域；队列列表滑到顶下拉收起', (tester) async {
    await pumpNowPlaying(tester);

    // 先收起。
    await dragPlayer(tester, 300);
    expect(playerHeight(tester), lessThan(100));

    // 歌词页上滑只滚动歌词，不展开。
    await tester.dragFrom(
      tester.getCenter(find.byType(PageView)),
      const Offset(0, -160),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(playerHeight(tester), lessThan(100), reason: '歌词页不参与展开');

    // 切到队列页：列表上滑同样不展开（展开只在播放器区域）。
    await selectQueuePage(tester);
    await tester.dragFrom(
      tester.getCenter(find.byType(PageView)),
      const Offset(0, -160),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(playerHeight(tester), lessThan(100), reason: '队列列表不再触发展开');

    // 展开后：队列列表已到顶，继续下滑 = 收起。
    await dragPlayer(tester, -240);
    expect(playerHeight(tester), greaterThan(300));
    await tester.dragFrom(
      tester.getCenter(find.byType(PageView)),
      const Offset(0, 140),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(playerHeight(tester), lessThan(100), reason: '列表滑到顶下拉应收起');

    // 通知节流计时器跑完，避免 pending timer 报错。
    await tester.pump(const Duration(milliseconds: 50));
  });
}
