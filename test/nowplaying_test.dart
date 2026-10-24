import 'dart:math' as math;

import 'package:flutter/services.dart' show LogicalKeyboardKey;
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
import 'package:molia/widgets/cover_appearance.dart';
import 'package:molia/widgets/mdtab.dart';
import 'package:molia/widgets/lyrics.dart';
import 'package:molia/widgets/now_playing_controller.dart';
import 'package:molia/widgets/now_playing_summary.dart';
import 'package:molia/widgets/player.dart';
import 'package:molia/widgets/player_cover_deck.dart';
import 'package:molia/widgets/queue.dart';
import 'package:molia/widgets/shell_reselect.dart';
import 'package:molia/widgets/track_info_view.dart';
import 'package:molia/widgets/track_row.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_library_repository.dart';
import 'support/fake_music_source.dart';
import 'support/fakes.dart';
import 'support/settings_test_support.dart';

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
    ShellReselectSignal? reselect,
    NowPlayingController? controller,
    List<Track>? queue,
    Size size = const Size(420, 900),
    bool desktopLayout = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // 默认单曲；给队列时停在中段，两侧邻位封面都有身份（越界断言需要）。
    final tracks = queue ?? [_track('a')];
    final int index = tracks.length > 1 ? 1 : 0;
    backend.emit(BackendSnapshot(
      current: tracks[index],
      queue: tracks,
      currentIndex: index,
      previous: index > 0 ? tracks[index - 1] : null,
      next: index + 1 < tracks.length ? tracks[index + 1] : null,
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
          ChangeNotifierProvider(
              create: (_) =>
                  LyricsDisplaySettings(settings: testSettingsRegistry())),
          ...extraProviders,
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: NowPlaying(
            reselect: reselect,
            controller: controller,
            desktopLayout: desktopLayout,
          ),
        ),
      ),
    );
    await tester.pump();
    // 等首帧落定（冷启动恢复态首帧不再播封面入场）。
    await tester.pump(const Duration(milliseconds: 600));
  }

  double playerHeight(WidgetTester tester) =>
      tester.getSize(find.byType(Player)).height;

  /// 点第一个圆点切到队列页（默认在歌词页）。
  Future<void> selectQueuePage(WidgetTester tester) async {
    final dots = find.descendant(
      of: find.byType(LyricsQueueDots),
      // M3ETooltip 自身也包一层 GestureDetector（长按提示），只认圆点自己的
      // 点击手势，避免把提示层的 detector 算进序号。
      matching: find.byWidgetPredicate(
        (widget) => widget is GestureDetector && widget.onTap != null,
      ),
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

  testWidgets('收藏按钮：写失败提示操作失败，图标保持原状态', (tester) async {
    final repository = FakeLibraryRepository();
    addTearDown(repository.dispose);
    final library = LibraryProvider(
      repository: repository,
      playbackProvider: playback,
    );
    addTearDown(library.dispose);

    final track = _track('fav');
    backend.emit(BackendSnapshot(
      current: track,
      queue: [track],
      currentIndex: 0,
      isPlaying: false,
      position: Duration.zero,
      duration: const Duration(seconds: 30),
    ));

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
          ChangeNotifierProvider<LibraryProvider>.value(value: library),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: const Scaffold(
            body: Center(child: NowPlayingFavoriteButton()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);

    repository.failFavoriteWrites = true;
    await tester.tap(find.byType(M3EIconButton));
    await tester.pumpAndSettle();

    expect(find.text('操作失败'), findsOneWidget);
    expect(
      library.isFavorite(track.id.sourceKey, track.id.id),
      isFalse,
      reason: '写失败不改收藏缓存',
    );
    expect(
      find.byIcon(Icons.favorite_border_rounded),
      findsOneWidget,
      reason: '图标不因失败翻转',
    );
  });

  testWidgets('切换行：小圆点常显，无收起/展开按钮', (tester) async {
    await pumpNowPlaying(tester);

    expect(tester.takeException(), isNull);
    expect(find.byType(LyricsQueueDots), findsOneWidget);
    // 图标切换器/收起按钮不应出现（桌面版式的 icon tab 也不在移动版式里）。
    expect(find.byIcon(M3EIcons.queue_music_rounded), findsNothing);
    expect(find.byIcon(M3EIcons.lyrics_rounded), findsNothing);
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
      // M3ETooltip 自身也包一层 GestureDetector（长按提示），只认圆点自己的
      // 点击手势，避免把提示层的 detector 算进序号。
      matching: find.byWidgetPredicate(
        (widget) => widget is GestureDetector && widget.onTap != null,
      ),
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

  testWidgets('底栏重复点击（壳层请求）：迷你 ⇄ 完整切换', (tester) async {
    final reselect = ShellReselectSignal();
    addTearDown(reselect.dispose);
    await pumpNowPlaying(tester, reselect: reselect);
    expect(playerHeight(tester), greaterThan(300), reason: '默认完整态');

    // 完整 → 迷你。
    reselect.trigger();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(playerHeight(tester), lessThan(100), reason: '壳层重复点击应收起为迷你条');

    // 迷你 → 完整。
    reselect.trigger();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(playerHeight(tester), greaterThan(300), reason: '再点应展开');

    // 通知节流计时器跑完，避免 pending timer 报错。
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('快速连点底栏「播放」：拖尾内反向仍重新起封面飞行', (tester) async {
    final reselect = ShellReselectSignal();
    addTearDown(reselect.dispose);
    await pumpNowPlaying(tester, reselect: reselect);

    final Animation<double> expand =
        tester.widget<Player>(find.byType(Player)).expandAnimation!;
    expect(expand.value, 1.0);
    expect(find.byType(MorphCover), findsNothing);

    // 收起：推进到「视觉落定」（副本已按阈值撤下），但弹簧仍在 forward
    // 容差拖尾里——此时再点会在 motor 中保持同一状态，没有新的 status 事件。
    reselect.trigger();
    await tester.pump();
    for (var i = 0; i < 200 && expand.value > 0.005; i++) {
      await tester.pump(const Duration(milliseconds: 8));
    }
    expect(expand.value, lessThanOrEqualTo(0.005));
    expect(
      expand.status,
      AnimationStatus.forward,
      reason: '应仍处在弹簧容差拖尾内（落定状态晚于视觉落定）',
    );
    expect(find.byType(MorphCover), findsNothing, reason: '视觉落定后副本已撤下');

    // 拖尾内反向展开：必须由值监听补起新飞行，不能只靠 status 变化。
    reselect.trigger();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump();
    expect(find.byType(MorphCover), findsOneWidget, reason: '拖尾内反向切换必须重新起飞行副本');

    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
  });

  testWidgets('底栏重复点击：大屏（两栏）忽略，不进入迷你态', (tester) async {
    final reselect = ShellReselectSignal();
    addTearDown(reselect.dispose);
    // 大屏：播放器 + 内容两栏，播放器始终完整、没有迷你态。
    await pumpNowPlaying(
      tester,
      reselect: reselect,
      size: const Size(1400, 900),
    );
    expect(
      tester
          .widget<LyricsWidget>(find.byType(LyricsWidget))
          .quickActionsEnabled,
      isFalse,
      reason: '大屏没有迷你态：歌词页快捷操作应保持关闭',
    );

    reselect.trigger();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 误响应会让 `_isMini` 翻转 → 歌词页快捷操作被启用（页面实例重建）。
    expect(
      tester
          .widget<LyricsWidget>(find.byType(LyricsWidget))
          .quickActionsEnabled,
      isFalse,
      reason: '大屏应忽略重复点击',
    );

    await tester.pump(const Duration(milliseconds: 50));
  });

  /// 桌面版式右侧 tab 的当前页（M3ETabs 的 selectedIndex）。
  int desktopTabIndex(WidgetTester tester) =>
      tester.widget<M3ETabs>(find.byType(M3ETabs)).selectedIndex;

  /// 组件的实际绘制包围盒：本地四角经完整变换（含邻位封面的旋转）映射到
  /// 全局——`getRect` 只用两角，旋转卡片的包围盒会被低估。
  Rect paintedBounds(WidgetTester tester, Finder finder) {
    final box = tester.renderObject<RenderBox>(finder);
    final Rect local = Offset.zero & box.size;
    final corners = <Offset>[
      local.topLeft,
      local.topRight,
      local.bottomLeft,
      local.bottomRight,
    ].map(box.localToGlobal).toList();
    return Rect.fromLTRB(
      corners.map((point) => point.dx).reduce(math.min),
      corners.map((point) => point.dy).reduce(math.min),
      corners.map((point) => point.dx).reduce(math.max),
      corners.map((point) => point.dy).reduce(math.max),
    );
  }

  testWidgets('桌面版式：左播放器列 + 右「队列/歌词/详细」三 tab（默认歌词）', (tester) async {
    await pumpNowPlaying(
      tester,
      desktopLayout: true,
      size: const Size(1400, 900),
    );

    expect(tester.takeException(), isNull);
    // 播放器列始终完整（大屏布局），没有迷你态。
    expect(tester.widget<Player>(find.byType(Player)).isLargeScreen, isTrue);
    // 右侧三 tab：次 tab（图标 + 文案一行，不叠展开按钮），文案与移动端圆点
    // 同一套词表，默认激活歌词。
    final tabs = tester.widget<M3ETabs>(find.byType(M3ETabs));
    expect(tabs.variant, M3ETabsVariant.secondary);
    expect(
      tabs.tabs.map((tab) => tab.label).toList(),
      ['队列', '歌词', '详细'],
    );
    expect(
      tabs.tabs
          .map((tab) => tab.icon)
          .map((icon) => icon is Icon ? icon.icon : null)
          .toList(),
      [
        M3EIcons.queue_music_rounded,
        M3EIcons.lyrics_rounded,
        M3EIcons.info_rounded,
      ],
      reason: 'tab 图标统一走 M3E 图标集（与 M3E 组件同一套字形）',
    );
    expect(tabs.selectedIndex, nowPlayingLyricsTabIndex);
    expect(find.byType(LyricsWidget), findsOneWidget);
    // 桌面没有圆点与迷你态。
    expect(find.byType(LyricsQueueDots), findsNothing);

    // 切到队列 tab：队列页用 QueueDisplay，当前曲目由左侧播放器承载
    // （includeCurrent = false，不重复展示）。
    await tester.tap(find.byIcon(M3EIcons.queue_music_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final queue = tester.widget<QueueDisplay>(find.byType(QueueDisplay));
    expect(queue.includeCurrent, isFalse);

    // 切到歌曲信息页：分页内容与移动版式的信息页一致。
    await tester.tap(find.byIcon(M3EIcons.info_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(TrackInfoView), findsOneWidget);
    expect(find.text('本次播放音质'), findsOneWidget);

    // 通知节流计时器跑完，避免 pending timer 报错。
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('桌面版式：tab 行高按次 tab token（48）', (tester) async {
    await pumpNowPlaying(
      tester,
      desktopLayout: true,
      size: const Size(1400, 900),
    );

    final bar = find.byType(M3ETabs);
    expect(
      tester.getSize(bar).height,
      M3ETabTheme.defaults.height,
      reason: '次 tab（图标 + 文案一行）行高 = M3ETabTheme.height（48），不叠自拟内边距',
    );

    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('桌面版式：tab 内容与 tab 栏同一内容边距（16），队列无分组小标题', (tester) async {
    await pumpNowPlaying(
      tester,
      desktopLayout: true,
      size: const Size(1400, 900),
    );

    // 队列里给出后续曲目（pump 助手的默认快照不带 upNext）。
    backend.emit(BackendSnapshot(
      current: _track('a'),
      queue: [_track('a'), _track('b')],
      currentIndex: 0,
      next: _track('b'),
      upNext: [_track('b')],
      isPlaying: false,
      position: Duration.zero,
      duration: const Duration(seconds: 30),
    ));
    // 队列通知走节流（300ms），等它落地再切 tab。
    await tester.pump(const Duration(milliseconds: 400));

    // 默认歌词页 → 切队列。
    await tester.tap(find.byIcon(M3EIcons.queue_music_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 内容左缘与 tab 栏左缘同为「栏 + 16」：M3E 内容边距口径。
    expect(
      tester.getRect(find.byType(TrackRow).first).left,
      tester.getRect(find.byType(M3ETabs)).left,
      reason: '队列行与 tab 栏对齐（内容边距 16）',
    );
    // 「接下来」小标题已去除：首行就是队列条目。
    expect(find.text('接下来'), findsNothing);
    final queue = tester.widget<QueueDisplay>(find.byType(QueueDisplay));
    expect(
      queue.topPadding,
      greaterThan(0),
      reason: 'tab 栏与内容之间留内容间距',
    );

    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('桌面版式：封面堆叠不越出播放器列（480）', (tester) async {
    await pumpNowPlaying(
      tester,
      desktopLayout: true,
      queue: [_track('a'), _track('b'), _track('c')],
      size: const Size(1400, 900),
    );
    final column = tester.getRect(find.byType(Player));
    expect(column.width, 480, reason: '桌面播放器列宽');

    // 预算口径：两侧各留一个内容内边距（24）→ 可用宽 432 → 封面边 ≈288。
    final centerRect =
        tester.getRect(find.byKey(PlayerCoverDeck.centerCoverCardKey));
    expect(centerRect.width, closeTo(288, 0.5), reason: '视觉几乎不变（≈300）');

    // 布局口径：堆叠容器自身不许比列宽（否则容器被父级夹小、内层 Stack
    // 仍按未夹取的尺寸绘制）。
    final deck = tester.getRect(find.byKey(PlayerCoverDeck.stackKey));
    expect(deck.width, lessThanOrEqualTo(column.width));
    expect(deck.height, lessThanOrEqualTo(column.height));

    // 绘制口径：三张卡（含邻位旋转包围盒）必须落在列内，不压进侧栏 /
    // 歌词列。
    final painted = [
      find.byKey(PlayerCoverDeck.centerCoverCardKey),
      find.byKey(
        PlayerCoverDeck.sideCoverCardKey(
          left: true,
          id: const TrackId('fake', 'a'),
        ),
      ),
      find.byKey(
        PlayerCoverDeck.sideCoverCardKey(
          left: false,
          id: const TrackId('fake', 'c'),
        ),
      ),
    ]
        .map((finder) => paintedBounds(tester, finder))
        .reduce((a, b) => a.expandToInclude(b));
    expect(painted.left, greaterThanOrEqualTo(column.left));
    expect(painted.right, lessThanOrEqualTo(column.right));
    expect(painted.top, greaterThanOrEqualTo(column.top));
    expect(painted.bottom, lessThanOrEqualTo(column.bottom));

    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('NowPlayingController：请求切页（重复触发也生效）', (tester) async {
    final controller = NowPlayingController();
    addTearDown(controller.dispose);
    await pumpNowPlaying(
      tester,
      desktopLayout: true,
      controller: controller,
      size: const Size(1400, 900),
    );
    expect(desktopTabIndex(tester), nowPlayingLyricsTabIndex);

    controller.showQueueTab();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(desktopTabIndex(tester), nowPlayingQueueTabIndex);
    expect(find.byType(QueueDisplay), findsOneWidget);

    // 用户手动切回歌词后再请求：仍然生效（请求是动作不是状态）。
    await tester.tap(find.byIcon(M3EIcons.lyrics_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(desktopTabIndex(tester), nowPlayingLyricsTabIndex);

    controller.showQueueTab();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(desktopTabIndex(tester), nowPlayingQueueTabIndex);

    controller.showInfoTab();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(desktopTabIndex(tester), nowPlayingInfoTabIndex);

    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('NowPlayingController：挂载前发出的请求在挂载时消费（默认页 = 请求页）', (tester) async {
    final controller = NowPlayingController()..showQueueTab();
    addTearDown(controller.dispose);

    await pumpNowPlaying(
      tester,
      desktopLayout: true,
      controller: controller,
      size: const Size(1400, 900),
    );

    expect(desktopTabIndex(tester), nowPlayingQueueTabIndex);
    expect(find.byType(QueueDisplay), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('移动版式：外部请求同样切到对应页', (tester) async {
    final controller = NowPlayingController();
    addTearDown(controller.dispose);
    await pumpNowPlaying(tester, controller: controller);
    expect(find.byType(LyricsWidget), findsOneWidget);

    controller.showQueueTab();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(QueueDisplay), findsOneWidget);
    expect(find.byType(LyricsWidget), findsNothing);

    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('桌面版式：传输排带音量入口（面板改音量 / 百分比读数 / Esc 关闭）', (tester) async {
    await pumpNowPlaying(
      tester,
      desktopLayout: true,
      size: const Size(1400, 900),
    );

    // 底栏进播放页会整条隐藏，音量必须在这一排可达。
    final button = find.byKey(Player.volumeButtonKey);
    expect(button, findsOneWidget);
    await tester.tap(button);
    await tester.pumpAndSettle();

    final panel = find.byKey(Player.volumePanelKey);
    expect(panel, findsOneWidget);
    // 面板落在窗口内（列中段的锚点也要夹进宿主可绘制区）。
    final panelRect = tester.getRect(panel);
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(panelRect.left, greaterThanOrEqualTo(0));
    expect(panelRect.right, lessThanOrEqualTo(screen.width));
    // 百分比读数（默认音量 1.0 → 100%）。
    expect(find.descendant(of: panel, matching: find.text('100%')),
        findsOneWidget);

    // 方向键调音量：面板一出现滑杆就持有焦点。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(playback.volume, lessThan(1.0));
    expect(backend.volumes, isNotEmpty);

    // Esc 关闭面板（占用登记，不依赖焦点位置）。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(panel, findsNothing);

    // 通知节流计时器跑完，避免 pending timer 报错。
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('第三个圆点：切到歌曲信息页（信息可见 + 到顶下拉切换播放器）', (tester) async {
    await pumpNowPlaying(tester);

    final dots = find.descendant(
      of: find.byType(LyricsQueueDots),
      matching: find.byWidgetPredicate(
        (widget) => widget is GestureDetector && widget.onTap != null,
      ),
    );
    expect(dots, findsNWidgets(3), reason: '队列 / 歌词 / 歌曲信息三页');

    final info = find.byType(TrackInfoView);
    // 点第三个圆点切到信息页（默认在歌词页）。
    await tester.tap(dots.at(2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(info, findsOneWidget);
    expect(find.text('本次播放音质'), findsOneWidget);
    // 无音源列表注入：来源行回退 key（渠道名 · 曲目 ID）。
    expect(find.text('fake · fake:a'), findsOneWidget);

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

    // 换源入口在歌词页 FAB menu / 信息页；进度排内无换源按钮。
    expect(
      find.descendant(
        of: find.byType(Player),
        matching: find.byIcon(Icons.swap_horiz_rounded),
      ),
      findsNothing,
    );

    // 收起播放器（歌词区展开）→ FAB 出现 → 展开菜单 → 点「换歌词」。
    await dragPlayer(tester, 300);
    await tester.pumpAndSettle();
    final fab = find.byKey(const Key('lyricsQuickActions'));
    expect(fab, findsOneWidget);
    await tester.tap(fab);
    await tester.pumpAndSettle();
    expect(find.text('换歌词'), findsOneWidget);
    await tester.tap(find.text('换歌词'));
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
