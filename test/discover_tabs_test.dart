import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/discover.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/discover_provider.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/app_search_bar.dart';
import 'package:molia/widgets/discover_leaderboards_tab.dart';
import 'package:molia/widgets/discover_playlists_tab.dart';
import 'package:molia/widgets/empty_state.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_discover_api.dart';
import 'support/fake_library_repository.dart';
import 'support/fakes.dart';

/// 已渲染 chip 占了几行（按 chip 顶边 y 去重）：断言全量渲染（超过两行）用。
int _chipRows(WidgetTester tester) {
  final chips = find.byType(M3EChip);
  final rows = <double>{};
  for (var i = 0; i < chips.evaluate().length; i++) {
    rows.add(tester.getTopLeft(chips.at(i)).dy);
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

  Future<void> pumpTab(WidgetTester tester, Widget tab,
      {double width = 1200}) async {
    tester.view.physicalSize = Size(width, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
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
          home: Scaffold(body: tab),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('歌单 tab：歌单卡片 + 热门标签（渠道选择已上移到资料页）', (tester) async {
    await pumpTab(tester, const DiscoverPlaylistsTab());

    expect(find.text('网易音乐'), findsNothing); // tab 内无平台选择
    expect(find.text('歌单'), findsNothing); // tab 名即标题：分区标题不重复出现
    expect(find.text('测试歌单'), findsOneWidget); // 歌单卡片
    // 导入入口只在详情页（列表不提供直接导入）。
    expect(find.byIcon(Icons.download_rounded), findsNothing);
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

    await tester.tap(find.byIcon(Icons.download_rounded));
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
    expect(find.byIcon(Icons.play_arrow_rounded),
        findsOneWidget); // 榜单详情同样只保留头部「播放全部」
    expect(wy.leaderboardCalls, greaterThan(0));
  });

  testWidgets('热榜 tab：30 条榜单全部直接显示，没有折叠入口', (tester) async {
    final many = [
      for (var i = 0; i < 30; i++)
        DiscoverLeaderboard(id: 'b$i', name: '榜单 $i', bangid: '$i'),
    ];
    wy.leaderboards = many;
    await pumpTab(tester, const DiscoverLeaderboardsTab());

    // 全量渲染：首尾都在树里，行数超过两行也不收起。
    expect(find.text('榜单 0'), findsOneWidget);
    expect(find.text('榜单 29'), findsOneWidget);
    expect(find.text('展开全部'), findsNothing);
    expect(find.text('收起'), findsNothing);
    expect(_chipRows(tester), greaterThan(2), reason: '不再截断到两行');

    // 换渠道：新渠道的榜单同样直接全量显示。
    tx.leaderboards = many;
    discover.selectChannel('tx');
    await tester.pumpAndSettle();
    expect(find.text('榜单 29'), findsOneWidget);
    expect(find.text('展开全部'), findsNothing);
    expect(_chipRows(tester), greaterThan(2));
  });

  testWidgets('热榜 tab：窄窗 + 长榜单名自然换行、不溢出', (tester) async {
    wy.leaderboards = const [
      DiscoverLeaderboard(id: 'b0', name: '飙升榜', bangid: '0'),
      DiscoverLeaderboard(
        id: 'b1',
        name: '编辑推荐榜VOL.44 天才女子摇滚乐队boygenius',
        bangid: '1',
      ),
      DiscoverLeaderboard(id: 'b2', name: '日本Oricon榜', bangid: '2'),
      DiscoverLeaderboard(id: 'b3', name: '黑胶VIP爱听榜', bangid: '3'),
      DiscoverLeaderboard(id: 'b4', name: 'LOOK直播歌曲榜', bangid: '4'),
      DiscoverLeaderboard(id: 'b5', name: '中国新乡村音乐排行榜', bangid: '5'),
    ];
    await pumpTab(tester, const DiscoverLeaderboardsTab(), width: 420);

    expect(find.text('展开全部'), findsNothing);
    expect(_chipRows(tester), greaterThan(1), reason: '窄窗按行自然换行');
    // 全部 chip 都在 chip 云右缘内（`Wrap` 换行；单条过长由 chip 自身截断）。
    final cloudRight = tester.getRect(find.byType(Wrap)).right;
    final chips = find.byType(M3EChip);
    for (var i = 0; i < chips.evaluate().length; i++) {
      expect(
        tester.getRect(chips.at(i)).right,
        lessThanOrEqualTo(cloudRight + 0.5),
        reason: '第 $i 个 chip 溢出 chip 云右缘',
      );
    }
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

  testWidgets('歌单 tab：固定行高懒加载 + 触底自动加载下一页', (tester) async {
    wy.playlistPages = 3;
    wy.playlistsPerPage = 40;
    await pumpTab(tester, const DiscoverPlaylistsTab());

    // 固定 extent：滚动条拇指尺寸/拖动定位精确。
    final sliver = tester.widget<SliverFixedExtentList>(
      find.byType(SliverFixedExtentList),
    );
    expect(sliver.itemExtent, 80);

    // 懒加载：2400 高视口只构建视口附近的卡片（一页 40 张不会全部构建）。
    final cards = tester.widgetList<M3ECard>(find.byType(M3ECard)).length;
    expect(cards, greaterThan(0));
    expect(cards, lessThan(60));
    expect(find.text('歌单 3-39'), findsNothing);

    // 触底自动加载第 2 页（无需点按钮）。
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -4000));
    await tester.pumpAndSettle();
    expect(wy.playlistPageCalls, contains(2));
  });

  testWidgets('歌单 tab：滚动条常显且可手拖', (tester) async {
    wy.playlistPages = 3;
    wy.playlistsPerPage = 40;
    await pumpTab(tester, const DiscoverPlaylistsTab());

    final scrollbar = tester.widget<Scrollbar>(find.byType(Scrollbar));
    expect(scrollbar.thumbVisibility, isTrue);
    expect(scrollbar.interactive, isTrue);
    final controller = scrollbar.controller!;

    final rect = tester.getRect(find.byType(Scrollbar));
    final gesture = await tester.startGesture(
      Offset(rect.right - 3, rect.top + 10),
    );
    await tester.pump();
    await gesture.moveBy(const Offset(0, 120));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(controller.offset, greaterThan(0));
  });
}
