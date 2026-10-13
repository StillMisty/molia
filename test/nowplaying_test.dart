import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/nowplaying.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/lyrics_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/source_swap_provider.dart';
import 'package:molia/services/lyrics_display/lyrics_display_settings.dart';
import 'package:molia/services/notification_service.dart';
import 'package:molia/widgets/mdtab.dart';
import 'package:molia/widgets/player.dart';
import 'package:molia/widgets/track_info_view.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_library_repository.dart';
import 'support/fake_music_source.dart';
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

  Future<void> pumpNowPlaying(
    WidgetTester tester, {
    List<SingleChildWidget> extraProviders = const [],
  }) async {
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
          // 歌词页扩展行开关：组合根在 main.dart 提供。
          ChangeNotifierProvider(create: (_) => LyricsDisplaySettings()),
          ...extraProviders,
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
    // 图标切换器/收起按钮不应出现。
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

  testWidgets('内容页到顶继续下拉：收缩→展开、展开→收起（队列/歌词都生效）', (tester) async {
    await pumpNowPlaying(tester);

    // 先收起（播放器区域下拉），默认在歌词页。
    await dragPlayer(tester, 300);
    expect(playerHeight(tester), lessThan(100));

    // 上滑（内容滚动方向）不参与切换。
    await tester.dragFrom(
      tester.getCenter(find.byType(PageView)),
      const Offset(0, -160),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(playerHeight(tester), lessThan(100), reason: '上滑滚动不触发展开');

    // 歌词页已到顶，继续下拉 = 展开。
    await tester.dragFrom(
      tester.getCenter(find.byType(PageView)),
      const Offset(0, 140),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(playerHeight(tester), greaterThan(300), reason: '歌词页到顶下拉应展开');

    // 展开态：歌词页到顶继续下拉 = 收起。
    await tester.dragFrom(
      tester.getCenter(find.byType(PageView)),
      const Offset(0, 140),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(playerHeight(tester), lessThan(100), reason: '歌词页到顶下拉应收起');

    // 切到队列页：收缩态到顶下拉 = 展开。
    await selectQueuePage(tester);
    await tester.dragFrom(
      tester.getCenter(find.byType(PageView)),
      const Offset(0, 140),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(playerHeight(tester), greaterThan(300), reason: '队列到顶下拉应展开');

    // 展开态：队列页到顶下拉 = 收起。
    await tester.dragFrom(
      tester.getCenter(find.byType(PageView)),
      const Offset(0, 140),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(playerHeight(tester), lessThan(100), reason: '队列到顶下拉应收起');

    // 通知节流计时器跑完，避免 pending timer 报错。
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('点已激活圆点：收缩↔展开切换', (tester) async {
    await pumpNowPlaying(tester);
    expect(playerHeight(tester), greaterThan(300));

    final dots = find.descendant(
      of: find.byType(LyricsQueueDots),
      matching: find.byType(GestureDetector),
    );
    // 默认激活歌词圆点（第二个）：再点一次 = 收起。
    await tester.tap(dots.at(1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(playerHeight(tester), lessThan(100), reason: '点激活圆点应收起');

    // 再点 = 展开。
    await tester.tap(dots.at(1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(playerHeight(tester), greaterThan(300), reason: '再点激活圆点应展开');

    // 通知节流计时器跑完，避免 pending timer 报错。
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('第三个圆点：切到歌曲信息页（信息可见 + 到顶下拉切换播放器）', (tester) async {
    await pumpNowPlaying(tester);

    final dots = find.descendant(
      of: find.byType(LyricsQueueDots),
      matching: find.byType(GestureDetector),
    );
    expect(dots, findsNWidgets(3), reason: '队列 / 歌词 / 歌曲信息三页');

    final info = find.byType(TrackInfoView);
    // 点第三个圆点切到信息页（默认在歌词页）。
    await tester.tap(dots.at(2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(info, findsOneWidget);
    expect(find.text('本次播放音质'), findsOneWidget);
    // 无音源列表注入：渠道回退 track.id.sourceKey。
    expect(find.text('fake'), findsOneWidget);

    // 信息页与队列/歌词共用「到顶继续下拉」手势：收起态下拉 = 展开。
    await dragPlayer(tester, 300);
    expect(playerHeight(tester), lessThan(100));
    await tester.dragFrom(
      tester.getCenter(find.byType(PageView)),
      const Offset(0, 140),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(playerHeight(tester), greaterThan(300), reason: '信息页到顶下拉应展开');

    // 通知节流计时器跑完，避免 pending timer 报错。
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('歌词快捷操作栏「换源」：打开换源页（歌词 / 音频双 tab）', (tester) async {
    final repository = FakeLibraryRepository();
    addTearDown(repository.dispose);
    final library = LibraryProvider(
      repository: repository,
      playbackProvider: playback,
    );
    addTearDown(library.dispose);
    final kg = FakeMusicSource('kg');
    kg.items = [
      Track(
        id: const TrackId('kg', '100'),
        title: 'Title kg',
        artists: const [Artist(name: 'Artist')],
        origin: TrackOrigin.builtin,
        payload: const {'hash': 'h100'},
      ),
    ];
    final registry = FakeSourceRegistry({'kg': kg});
    final swap = SourceSwapProvider(
      catalogService: CatalogService(registry: registry),
      sourceRegistry: registry,
      libraryProvider: library,
      playbackProvider: playback,
    );
    addTearDown(swap.dispose);

    await pumpNowPlaying(
      tester,
      extraProviders: [
        ChangeNotifierProvider<LibraryProvider>.value(value: library),
        ChangeNotifierProvider<SourceSwapProvider>.value(value: swap),
        Provider<NotificationService>.value(
          value: NotificationService(GlobalKey<ScaffoldMessengerState>()),
        ),
      ],
    );

    // 进度排不再有换源按钮（换源入口在歌词快捷操作栏）。
    expect(
      find.descendant(
        of: find.byType(Player),
        matching: find.byIcon(Icons.swap_horiz_rounded),
      ),
      findsNothing,
    );

    // 收起播放器（歌词区展开）→ 快捷操作栏出现 → 点「换源」。
    await dragPlayer(tester, 300);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.swap_horiz_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.swap_horiz_rounded));
    await tester.pumpAndSettle();

    // 打开换源页：歌词 / 音频双 tab，默认歌词（音频会话尚未发起）。
    expect(find.byType(M3ETabs), findsOneWidget);
    expect(find.text('歌词'), findsWidgets);
    expect(find.text('音频'), findsWidgets);
    expect(swap.hasSession, isFalse);

    // 通知节流计时器跑完，避免 pending timer 报错。
    await tester.pump(const Duration(milliseconds: 50));
  });
}
