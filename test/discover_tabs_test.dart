import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/discover.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/discover_provider.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/app_search_bar.dart';
import 'package:molia/widgets/discover_layout.dart';
import 'package:molia/widgets/discover_leaderboards_tab.dart';
import 'package:molia/widgets/discover_playlists_tab.dart';
import 'package:molia/widgets/empty_state.dart';
import 'package:molia/widgets/library_cover.dart';
import 'package:molia/widgets/row_extent.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_discover_api.dart';
import 'support/fake_library_repository.dart';
import 'support/fakes.dart';
import 'support/cover_test_support.dart';

/// 网格当前的实际列数（从 SliverGrid 的 delegate 读，不猜布局）。
int _gridColumns(WidgetTester tester, Key key) {
  final grid = tester.widget<SliverGrid>(find.byKey(key));
  final delegate =
      grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
  return delegate.crossAxisCount;
}

/// 已渲染卡片占了几行（按卡片顶边 y 去重）：断言全量渲染（超过两行）用。
int _cardRows(WidgetTester tester, Finder cards) {
  final rows = <double>{};
  for (var i = 0; i < cards.evaluate().length; i++) {
    rows.add(tester.getTopLeft(cards.at(i)).dy);
  }
  return rows.length;
}

/// 资料页发现 tab widget 测试（fake 数据源 + 内存仓库，避免真实网络/DB）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeLibraryRepository repository;
  late FakePlaybackBackend backend;
  late PlaybackProvider playback;
  late LibraryProvider library;
  late FakeDiscoverSource wy;
  late FakeDiscoverSource tx;
  late DiscoverProvider discover;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repository = FakeLibraryRepository();
    backend = FakePlaybackBackend();
    playback = buildTestPlaybackProvider(
      backend: backend,
      libraryRepository: repository,
    );
    library = LibraryProvider(
      repository: repository,
      playbackProvider: playback,
    );
    wy = FakeDiscoverSource();
    tx = FakeDiscoverSource(sourceKey: 'tx');
    discover = DiscoverProvider(
      playbackProvider: playback,
      libraryProvider: library,
      sources: {'wy': wy, 'tx': tx},
      // 这一组 widget 用例聚焦 wy 的展示细节；默认平台切换由
      // discover_provider_test 覆盖，这里显式指定 wy。
      initialChannelKey: 'wy',
    );
  });

  tearDown(() async {
    discover.dispose();
    library.dispose();
    playback.dispose();
    await repository.dispose();
  });

  Future<void> pumpTab(
    WidgetTester tester,
    Widget tab, {
    double width = 1200,
    TextScaler textScaler = TextScaler.noScaling,
  }) async {
    tester.view.physicalSize = Size(width, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          coverStoreProvider(),
          ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
          ChangeNotifierProvider<LibraryProvider>.value(value: library),
          ChangeNotifierProvider<DiscoverProvider>.value(value: discover),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              child: Scaffold(body: tab),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('发现页内容栏：宽屏左对齐限宽 960，手机整行铺满', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    Future<void> pump(double width) async {
      tester.view.physicalSize = Size(width, 800);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DiscoverContentFrame(
              child: SizedBox.expand(key: Key('discoverContent')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pump(1200);
    final wide = tester.getRect(find.byKey(const Key('discoverContent')));
    expect(
      wide.width,
      discoverContentMaxWidth + 48,
      reason: '960 + 两侧 24 gutter',
    );
    expect(wide.left, 0, reason: '宽屏左对齐，不再居中');

    await pump(400);
    final phone = tester.getRect(find.byKey(const Key('discoverContent')));
    expect(phone.width, 400, reason: '手机保持整行铺满');
  });

  testWidgets('歌单 tab：歌单卡片 + 热门标签（渠道选择已上移到资料页）', (tester) async {
    await pumpTab(tester, const DiscoverPlaylistsTab(), width: 400);

    expect(find.text('网易音乐'), findsNothing); // tab 内无平台选择
    expect(find.text('歌单'), findsNothing); // tab 名即标题：分区标题不重复出现
    expect(find.text('测试歌单'), findsOneWidget); // 歌单卡片
    // 导入入口只在详情页（列表不提供直接导入）。
    expect(find.byIcon(Icons.playlist_add_rounded), findsNothing);
    expect(find.text('华语'), findsWidgets); // 热门标签
    expect(find.text('全部'), findsOneWidget);
    expect(wy.tagCalls, 1);
  });

  testWidgets('歌单 tab：「打开歌单」收进搜索行栏尾，仍可打开链接弹窗', (tester) async {
    await pumpTab(tester, const DiscoverPlaylistsTab());

    // 入口是搜索栏的尾部动作（不另占一行标题）。
    expect(
      find.descendant(
        of: find.byType(AppSearchBar),
        matching: find.byIcon(Icons.link_rounded),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byIcon(Icons.link_rounded));
    await tester.pumpAndSettle();

    expect(find.text('打开歌单'), findsOneWidget); // 弹窗标题
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('打开歌单'), findsNothing);
  });

  testWidgets('歌单 tab：点击卡片进入详情页并可播放', (tester) async {
    await pumpTab(tester, const DiscoverPlaylistsTab());

    await tester.tap(find.text('测试歌单'));
    await tester.pumpAndSettle();

    expect(find.text('歌单详情'), findsOneWidget);
    expect(find.text('歌曲A'), findsOneWidget);
    expect(find.text('播放全部'), findsOneWidget);
    // 「播放全部」只在头部出现一次：顶栏无重复播放图标。
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

    await tester.tap(find.text('歌曲A'));
    await tester.pumpAndSettle();

    final request = backend.lastRequest;
    expect(request, isNotNull);
    expect(request!.tracks.single.title, '歌曲A');
    expect(request.tracks.single.payload['songmid'], 111);
  });

  testWidgets('歌单 tab：详情页可导入到我的列表', (tester) async {
    await pumpTab(tester, const DiscoverPlaylistsTab());

    await tester.tap(find.text('测试歌单'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('discoverImportPlaylistButton')));
    await tester.pumpAndSettle();

    expect(find.text('已导入 1 首'), findsOneWidget);
    expect(await repository.findPlaylistByName('歌单详情'), isNotNull);
  });

  testWidgets('歌单 tab：切换渠道后重新加载数据源', (tester) async {
    await pumpTab(tester, const DiscoverPlaylistsTab());
    expect(tx.tagCalls, 0);

    discover.selectChannel('tx');
    await tester.pumpAndSettle();

    expect(discover.channelKey, 'tx');
    expect(tx.tagCalls, 1);
    expect(find.text('测试歌单'), findsOneWidget); // tx 数据源同样返回
  });

  testWidgets('歌单 tab：渠道无发现能力时整体隐藏（资料页降级兜底）', (tester) async {
    await pumpTab(tester, const DiscoverPlaylistsTab());

    discover.selectChannel('script-only');
    await tester.pumpAndSettle();

    expect(find.text('歌单'), findsNothing);
    expect(find.text('测试歌单'), findsNothing);
  });

  testWidgets('列表滚动控制器可注入（宿主页面重复点击回顶的数据通路）', (tester) async {
    final leaderboards = ScrollController();
    final playlists = ScrollController();
    addTearDown(leaderboards.dispose);
    addTearDown(playlists.dispose);

    await pumpTab(tester, DiscoverLeaderboardsTab(controller: leaderboards));
    expect(leaderboards.hasClients, isTrue, reason: '热榜内容应挂在注入的控制器上');

    await pumpTab(tester, DiscoverPlaylistsTab(controller: playlists));
    expect(playlists.hasClients, isTrue, reason: '歌单列表应挂在注入的控制器上');
  });

  testWidgets('热榜 tab：榜单 chips；点击进入榜单详情', (tester) async {
    await pumpTab(tester, const DiscoverLeaderboardsTab());

    expect(find.text('热榜'), findsNothing); // tab 名即标题：分区标题不重复出现
    expect(find.text('热歌榜'), findsOneWidget);
    // 不做折叠：没有展开 / 收起入口。
    expect(find.text('展开全部'), findsNothing);
    expect(find.text('收起'), findsNothing);

    await tester.tap(find.text('热歌榜'));
    await tester.pumpAndSettle();

    expect(find.text('歌曲A'), findsOneWidget);
    expect(
      find.byIcon(Icons.play_arrow_rounded),
      findsOneWidget,
    ); // 榜单详情同样只保留头部「播放全部」
    expect(wy.leaderboardCalls, greaterThan(0));
  });

  testWidgets('热榜 tab：手机 2 列、宽屏多列磁贴（不伪造排名数字）', (tester) async {
    wy.leaderboards = [
      for (var i = 0; i < 6; i++)
        DiscoverLeaderboard(id: 'b$i', name: '榜单 $i', bangid: '$i'),
    ];

    await pumpTab(tester, const DiscoverLeaderboardsTab(), width: 400);
    expect(
      _gridColumns(tester, const Key('discoverLeaderboardGrid')),
      2,
      reason: '手机固定 2 列',
    );
    expect(find.byType(M3EChip), findsNothing, reason: '不再渲染 chip 云');
    expect(find.text('榜单 0'), findsOneWidget);
    expect(find.byIcon(Icons.leaderboard_rounded), findsNWidgets(6));
    expect(tester.widget<Text>(find.text('榜单 0')).maxLines, 2);
    // 序号由网格位置表达，不在磁贴上伪造排名。
    expect(find.text('1'), findsNothing);

    await pumpTab(tester, const DiscoverLeaderboardsTab());
    expect(
      _gridColumns(tester, const Key('discoverLeaderboardGrid')),
      discoverLeaderboardColumns(discoverContentMaxWidth),
    );
    expect(
      _gridColumns(tester, const Key('discoverLeaderboardGrid')),
      greaterThan(2),
    );
  });

  testWidgets('热榜 tab：30 条榜单全部直接显示，磁贴网格不折叠', (tester) async {
    final many = [
      for (var i = 0; i < 30; i++)
        DiscoverLeaderboard(id: 'b$i', name: '榜单 $i', bangid: '$i'),
    ];
    wy.leaderboards = many;
    await pumpTab(tester, const DiscoverLeaderboardsTab());

    // 全量渲染：首尾都在树里，超过两行也不收起。
    expect(find.text('榜单 0'), findsOneWidget);
    expect(find.text('榜单 29'), findsOneWidget);
    expect(find.text('展开全部'), findsNothing);
    expect(find.text('收起'), findsNothing);
    expect(
      _gridColumns(tester, const Key('discoverLeaderboardGrid')),
      discoverLeaderboardColumns(discoverContentMaxWidth),
      reason: '宽屏按内容宽加列，不再等宽铺 chip',
    );
    final cards = find.descendant(
      of: find.byKey(const Key('discoverLeaderboardGrid')),
      matching: find.byType(M3ECard),
    );
    expect(cards, findsNWidgets(30));
    expect(_cardRows(tester, cards), greaterThan(2), reason: '不再截断到两行');

    // 换渠道：新渠道的榜单同样直接全量显示。
    tx.leaderboards = many;
    discover.selectChannel('tx');
    await tester.pumpAndSettle();
    expect(find.text('榜单 29'), findsOneWidget);
    expect(find.text('展开全部'), findsNothing);
    expect(_cardRows(tester, cards), greaterThan(2));
  });

  testWidgets('歌单 tab：空态用共享 EmptyState + 文案 + 主行动', (tester) async {
    wy.playlistsPerPage = 0;
    await pumpTab(tester, const DiscoverPlaylistsTab());

    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text('暂无内容'), findsOneWidget);
    expect(find.byIcon(Icons.queue_music_rounded), findsOneWidget);
    // 未加筛选时没有可执行的主行动。
    expect(find.widgetWithText(M3EButton, '全部'), findsNothing);

    // 标签筛选下空结果：主行动 = 回「全部」标签。
    await tester.tap(find.text('华语'));
    await tester.pumpAndSettle();
    final action = find.widgetWithText(M3EButton, '全部');
    expect(action, findsOneWidget);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(
      tester.widget<M3EChip>(find.widgetWithText(M3EChip, '全部')).selected,
      isTrue,
      reason: '主行动把筛选清回「全部」',
    );
  });

  testWidgets('歌单 tab：手机固定行高懒加载 + 触底自动加载下一页', (tester) async {
    wy.playlistPages = 3;
    wy.playlistsPerPage = 40;
    await pumpTab(tester, const DiscoverPlaylistsTab(), width: 400);

    // 动态 extent（1.0× 下 = 卡片 72 + 间距 8）：滚动条拇指尺寸/拖动定位精确。
    final sliver = tester.widget<SliverFixedExtentList>(
      find.byKey(const Key('discoverPlaylistList')),
    );
    final context = tester.element(
      find.byKey(const Key('discoverPlaylistList')),
    );
    final m3e = M3ETheme.of(context);
    final cardHeight = scaledRowExtentOf(
      context,
      minExtent: 56,
      styles: [m3e.typeScale.titleSmall, m3e.typeScale.bodySmall],
      stacked: true,
      extra: 2,
      allowance: 4,
      padding: 16,
    );
    expect(sliver.itemExtent, cardHeight + 8);
    expect(sliver.itemExtent, 80, reason: '1.0× 默认视觉不变');

    // 懒加载：2400 高视口只构建视口附近的卡片（一页 40 张不会全部构建）。
    final cards = tester.widgetList<M3ECard>(find.byType(M3ECard)).length;
    expect(cards, greaterThan(0));
    expect(cards, lessThan(60));
    expect(find.text('歌单 3-39'), findsNothing);
    expect(find.text('加载更多'), findsNothing, reason: '不再提供手动加载按钮');

    // 触底自动加载第 2 页（无需点按钮）。
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -4000));
    await tester.pumpAndSettle();
    expect(wy.playlistPageCalls, contains(2));
    expect(find.text('加载更多'), findsNothing);
  });

  testWidgets('歌单 tab：宽屏封面网格，搜索栏与内容同 gutter；手机保持列表', (tester) async {
    await pumpTab(tester, const DiscoverPlaylistsTab());

    final grid = find.byKey(const Key('discoverPlaylistGrid'));
    expect(grid, findsOneWidget);
    expect(find.byKey(const Key('discoverPlaylistList')), findsNothing);
    expect(
      _gridColumns(tester, const Key('discoverPlaylistGrid')),
      greaterThan(2),
      reason: '宽屏不再只有单列',
    );
    final gridContext = tester.element(grid);
    final gutter = discoverGutterOf(gridContext);
    expect(gutter, 24);
    expect(
      tester.getTopLeft(find.byType(AppSearchBar)).dx,
      gutter,
      reason: '搜索栏与内容栏共用 gutter',
    );

    final delegate =
        tester.widget<SliverGrid>(grid).gridDelegate
            as SliverGridDelegateWithFixedCrossAxisCount;
    final contentWidth = discoverContentMaxWidth;
    final tileWidth =
        (contentWidth - discoverGridGap * (delegate.crossAxisCount - 1)) /
        delegate.crossAxisCount;
    // 封面是卡片宽 − 16 的方形。
    expect(
      tester.getSize(
        find.descendant(of: grid, matching: find.byType(LibraryCoverThumb)),
      ),
      Size.square(tileWidth - 16),
    );
    expect(tester.widget<Text>(find.text('测试歌单')).maxLines, 2);
    expect(tester.widget<Text>(find.text('作者 · 2 首')).maxLines, 1);

    // 手机宽度：回到 56dp 封面的紧凑列表，搜索栏与卡片仍从同一 gutter 起排。
    await pumpTab(tester, const DiscoverPlaylistsTab(), width: 400);
    expect(find.byKey(const Key('discoverPlaylistList')), findsOneWidget);
    expect(find.byKey(const Key('discoverPlaylistGrid')), findsNothing);
    expect(tester.getTopLeft(find.byType(AppSearchBar)).dx, 16);
    expect(tester.getTopLeft(find.byType(M3ECard)).dx, 16);
  });

  testWidgets('歌单 tab：1.3× / 1.5× 大字体列表与网格都不裁切', (tester) async {
    for (final scale in [1.3, 1.5]) {
      // 手机紧凑列表：固定行高跟着文字缩放增长。
      await pumpTab(
        tester,
        const DiscoverPlaylistsTab(),
        width: 400,
        textScaler: TextScaler.linear(scale),
      );
      expect(tester.takeException(), isNull, reason: '$scale× 列表不应布局溢出');
      final list = tester.widget<SliverFixedExtentList>(
        find.byKey(const Key('discoverPlaylistList')),
      );
      final listContext = tester.element(
        find.byKey(const Key('discoverPlaylistList')),
      );
      final m3e = M3ETheme.of(listContext);
      final cardHeight = scaledRowExtentOf(
        listContext,
        minExtent: 56,
        styles: [m3e.typeScale.titleSmall, m3e.typeScale.bodySmall],
        stacked: true,
        extra: 2,
        allowance: 4,
        padding: 16,
      );
      expect(list.itemExtent, cardHeight + 8);
      expect(list.itemExtent, greaterThanOrEqualTo(80));

      // 宽屏封面网格：行高按卡片宽度（封面）+ 标题 / 副标题行高计算。
      await pumpTab(
        tester,
        const DiscoverPlaylistsTab(),
        textScaler: TextScaler.linear(scale),
      );
      expect(tester.takeException(), isNull, reason: '$scale× 网格不应布局溢出');
      final grid = tester.widget<SliverGrid>(
        find.byKey(const Key('discoverPlaylistGrid')),
      );
      final delegate =
          grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      final gridContext = tester.element(
        find.byKey(const Key('discoverPlaylistGrid')),
      );
      final gutter = discoverGutterOf(gridContext);
      final contentWidth = discoverContentMaxWidth;
      final tileWidth =
          (contentWidth - discoverGridGap * (delegate.crossAxisCount - 1)) /
          delegate.crossAxisCount;
      expect(
        delegate.crossAxisCount,
        discoverPlaylistColumns(contentWidth),
        reason: '宽屏列数按内容宽度计算',
      );
      expect(
        delegate.mainAxisExtent,
        discoverPlaylistTileExtentOf(gridContext, tileWidth),
        reason: '$scale× 网格高度与标题 / 副标题行高同源',
      );
      expect(gutter, 24, reason: '桌面 gutter 由响应式页边距统一给出');
    }
  });

  testWidgets('歌单 tab：加载更多失败停在当前页，底部重试恢复', (tester) async {
    wy.playlistPages = 2;
    wy.playlistsPerPage = 40;
    await pumpTab(tester, const DiscoverPlaylistsTab());
    expect(wy.playlistPageCalls, [1]);

    // 第 2 页失败：保留已加载的 40 张卡片，之后滚动不再自动重试。
    wy.fail = true;
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -4000));
    await tester.pumpAndSettle();
    expect(wy.playlistPageCalls, [1, 2]);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(wy.playlistPageCalls, [1, 2], reason: '失败后不自动重试');

    final retry = find.text('重试', skipOffstage: false);
    expect(retry, findsOneWidget);
    wy.fail = false;
    await tester.ensureVisible(retry);
    await tester.pumpAndSettle();
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(wy.playlistPageCalls, [1, 2, 2]);
    expect(find.text('歌单 2-0'), findsOneWidget);
  });
}
