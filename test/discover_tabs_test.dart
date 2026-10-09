import 'package:flutter_test/flutter_test.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/discover_provider.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/discover_leaderboards_tab.dart';
import 'package:molia/widgets/discover_playlists_tab.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_discover_api.dart';
import 'support/fake_library_repository.dart';
import 'support/fakes.dart';

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
    );
  });

  tearDown(() async {
    discover.dispose();
    library.dispose();
    playback.dispose();
    await repository.dispose();
  });

  Future<void> pumpTab(WidgetTester tester, Widget tab) async {
    tester.view.physicalSize = const Size(1200, 2400);
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

    expect(find.text('网易音乐'), findsNothing); // tab 内不再有平台选择
    expect(find.text('歌单'), findsOneWidget); // 区块标题
    expect(find.text('测试歌单'), findsOneWidget); // 歌单卡片
    // 列表不再提供直接导入：导入入口只在详情页。
    expect(find.byIcon(Icons.download_rounded), findsNothing);
    expect(find.text('华语'), findsWidgets); // 热门标签
    expect(find.text('全部'), findsOneWidget);
    expect(wy.tagCalls, 1);
  });

  testWidgets('歌单 tab：点击卡片进入详情页并可播放', (tester) async {
    await pumpTab(tester, const DiscoverPlaylistsTab());

    await tester.tap(find.text('测试歌单'));
    await tester.pumpAndSettle();

    // 详情页：头部 + 曲目
    expect(find.text('歌单详情'), findsOneWidget);
    expect(find.text('歌曲A'), findsOneWidget);
    expect(find.text('播放全部'), findsOneWidget);
    // 「播放全部」只在头部出现一次：顶栏不再有重复的播放图标。
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

  testWidgets('热榜 tab：榜单 chips；点击进入榜单详情', (tester) async {
    await pumpTab(tester, const DiscoverLeaderboardsTab());

    expect(find.text('热榜'), findsWidgets); // 区块标题
    expect(find.text('热歌榜'), findsOneWidget);

    await tester.tap(find.text('热歌榜'));
    await tester.pumpAndSettle();

    expect(find.text('歌曲A'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget); // 榜单详情同样只保留头部「播放全部」
    expect(wy.leaderboardCalls, greaterThan(0));
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
