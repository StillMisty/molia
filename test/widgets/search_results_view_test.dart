import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/domain/models/catalog.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/source.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/search_provider.dart';
import 'package:molia/widgets/search_results_view.dart';
import 'package:molia/widgets/track_table_header.dart';
import 'package:molia/widgets/track_row.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_library_repository.dart';
import '../support/fake_music_source.dart';
import '../support/fakes.dart';

/// 统一搜索结果面（`SearchResultsView`）的两种版式：
///
/// - 页面版式的行映射：歌手链接、未知歌手兜底、触摸端行尾操作菜单；
/// - 遮罩版式的行映射与版式：同样的未知歌手兜底 / 桌面右键菜单、8 行预览
///   上限与「查看全部结果」底部出口。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final l10n = lookupAppLocalizations(const Locale('zh'));

  late FakeMusicSource source;
  late FakeSourceRegistry registry;
  late FakePlaybackBackend backend;
  late FakeLibraryRepository repository;
  late PlaybackProvider playback;
  late LibraryProvider library;
  late SearchProvider search;

  Track track(
    String id, {
    String sourceKey = 'kw',
    List<Artist>? artists,
    Map<String, Object?>? payload,
  }) => Track(
    id: TrackId(sourceKey, id),
    title: 'Title $id',
    artists: artists ?? [Artist(name: 'Artist $id')],
    duration: const Duration(minutes: 3, seconds: 5),
    origin: TrackOrigin.builtin,
    payload: payload ?? {'songmid': id},
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    source = FakeMusicSource(
      'kw',
      capabilities: const SourceCapabilities(
        search: true,
        pagination: true,
        artist: true,
      ),
    );
    registry = FakeSourceRegistry({'kw': source});
    backend = FakePlaybackBackend();
    repository = FakeLibraryRepository();
    final catalog = CatalogService(registry: registry);
    playback = buildTestPlaybackProvider(
      backend: backend,
      catalogService: catalog,
      libraryRepository: repository,
    );
    library = LibraryProvider(
      repository: repository,
      playbackProvider: playback,
    );
    search = SearchProvider(
      playback,
      catalogService: catalog,
      sourceRegistry: registry,
    );
  });

  tearDown(() async {
    search.dispose();
    library.dispose();
    playback.dispose();
    await repository.dispose();
  });

  Future<void> pumpView(
    WidgetTester tester,
    Widget view, {
    double width = 1200,
    SearchProvider? provider,
  }) async {
    tester.view.physicalSize = Size(width, 1200);
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
          ChangeNotifierProvider<SearchProvider>.value(
            value: provider ?? search,
          ),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: Scaffold(body: view),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 多来源搜索结果面：每个 FakeMusicSource 一条渠道（顺序 = map 插入顺序）。
  SearchProvider buildMultiSourceSearch(Map<String, FakeMusicSource> sources) {
    final registry = FakeSourceRegistry(sources);
    final provider = SearchProvider(
      playback,
      catalogService: CatalogService(registry: registry),
      sourceRegistry: registry,
    );
    addTearDown(provider.dispose);
    return provider;
  }

  testWidgets('来源 chips：键盘焦点落到可视区外时自动滚入视野', (tester) async {
    final sources = <String, FakeMusicSource>{
      for (var i = 0; i < 8; i++)
        's$i': FakeMusicSource('s$i')
          ..onSearch = (query) => Future.value(
            SearchResult(items: [track('x$i', sourceKey: 's$i')]),
          ),
    };
    final provider = buildMultiSourceSearch(sources);
    await pumpView(
      tester,
      SearchResultsView(
        variant: SearchResultsVariant.page,
        onPlay: (_) {},
        onOpenArtist: (sourceKey, artistId, {fallbackName}) async {},
      ),
      width: 400,
      provider: provider,
    );

    // chips 横向溢出；Tab 到最后一个 chip，焦点变化应触发 ensureVisible。
    for (var i = 0; i < 9; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    await tester.pumpAndSettle();
    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const Key('searchSourceChipsScroll')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(scrollable.position.pixels, greaterThan(0));
  });

  testWidgets('多分组页面：chips 顺序跟渠道、无表格列、分组标题 + 每组加载更多', (tester) async {
    final kw = FakeMusicSource('kw')
      ..onSearch = (query) => Future.value(
        SearchResult(items: [track('a'), track('b')], hasMore: true, total: 12),
      );
    final tx = FakeMusicSource('tx')
      ..onSearch = (query) => Future.value(
        SearchResult(
          items: [track('x', sourceKey: 'tx')],
          hasMore: false,
          total: 1,
        ),
      );
    final provider = buildMultiSourceSearch({'kw': kw, 'tx': tx});
    await pumpView(
      tester,
      SearchResultsView(
        variant: SearchResultsVariant.page,
        onPlay: (_) {},
        onOpenArtist: (sourceKey, artistId, {fallbackName}) async {},
      ),
      width: 1400,
      provider: provider,
    );
    provider.submitSearch('hello');
    await tester.pumpAndSettle();

    expect(find.byType(TrackTableHeader), findsNothing, reason: '多分组关闭表格列');
    expect(find.text('kw'), findsWidgets, reason: '分组标题');
    expect(find.text('tx'), findsWidgets);
    expect(find.byType(TrackRow), findsNWidgets(3));

    // 来源 chips 顺序严格跟 registry.descriptors；「全部」固定第一。
    final all = tester.getTopLeft(
      find.byKey(const ValueKey<String>('searchSourceChip-all')),
    );
    final kwChip = tester.getTopLeft(
      find.byKey(const ValueKey<String>('searchSourceChip-kw')),
    );
    final txChip = tester.getTopLeft(
      find.byKey(const ValueKey<String>('searchSourceChip-tx')),
    );
    expect(all.dx, lessThan(kwChip.dx));
    expect(kwChip.dx, lessThan(txChip.dx));

    // 两个分组都有「加载更多」：kw 还有下一页，tx 到底不显示。
    expect(find.text(l10n.searchLoadMore), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('searchSourceChip-tx')));
    await tester.pumpAndSettle();
    expect(find.text('Title a'), findsNothing);
    expect(find.text('Title x'), findsOneWidget);
    expect(kw.searchCalls, 1, reason: '过滤不重发请求');
    expect(tx.searchCalls, 1);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('多分组遮罩：每组最多 2 行、总计 8 行；失败分组显示重试', (tester) async {
    final sources = <String, FakeMusicSource>{};
    for (final key in ['a', 'b', 'c', 'd', 'e']) {
      sources[key] = FakeMusicSource(key)
        ..onSearch = (query) => Future.value(
          SearchResult(
            items: [
              for (var i = 0; i < 5; i++) track('$key$i', sourceKey: key),
            ],
          ),
        );
    }
    var aFails = true;
    sources['a']!.onSearch = (query) async {
      if (aFails) {
        throw const SourceFailure(kind: FailureKind.network, message: 'a boom');
      }
      return SearchResult(
        items: [for (var i = 0; i < 5; i++) track('a$i', sourceKey: 'a')],
      );
    };
    final provider = buildMultiSourceSearch(sources);
    await pumpView(
      tester,
      SearchResultsView(
        variant: SearchResultsVariant.docked,
        onPlay: (_) {},
        onOpenAllResults: () {},
      ),
      width: 900,
      provider: provider,
    );
    provider.submitSearch('hello');
    await tester.pumpAndSettle();

    // a 失败无行；b/c/d/e 各 2 行，总数 8 行上限。
    expect(find.byType(TrackRow), findsNWidgets(8));
    expect(find.text(l10n.searchFailed), findsOneWidget);
    expect(find.text(l10n.retry), findsOneWidget);
    expect(find.text(l10n.viewAllResults), findsOneWidget);
    // 失败来源仍占一个分组标题。
    expect(find.text('a'), findsWidgets);

    aFails = false;
    await tester.tap(find.text(l10n.retry));
    await tester.pumpAndSettle();
    expect(find.text('Title a0'), findsOneWidget, reason: '失败分组独立重试');
  });

  testWidgets('遮罩高亮：selected 行按 highlightedKey 渲染', (tester) async {
    source.onSearch = (query) async =>
        SearchResult(items: [track('a'), track('b')], total: 2);
    await pumpView(
      tester,
      SearchResultsView(
        variant: SearchResultsVariant.docked,
        highlightedKey: 'track:kw:b',
        onPlay: (_) {},
        onOpenAllResults: () {},
      ),
      width: 900,
    );
    search.submitSearch('hello');
    await tester.pumpAndSettle();

    final rows = tester.widgetList<TrackRow>(find.byType(TrackRow)).toList();
    expect(rows.map((row) => row.model.selected), [false, true]);
  });

  testWidgets('遮罩高亮变化自动滚入视野', (tester) async {
    source.onSearch = (query) async => SearchResult(
      items: [for (var i = 0; i < 8; i++) track('$i')],
      total: 8,
    );
    await pumpView(
      tester,
      SizedBox(
        height: 180,
        child: SearchResultsView(
          variant: SearchResultsVariant.docked,
          // 第 8 行在面板视口外：结果发布后要滚到它。
          highlightedKey: 'track:kw:7',
          onPlay: (_) {},
          onOpenAllResults: () {},
        ),
      ),
      width: 900,
    );
    search.submitSearch('hello');
    await tester.pumpAndSettle();

    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(SearchResultsView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(scrollable.position.pixels, greaterThan(0), reason: '高亮行自动滚入视野');
    final rowRect = tester.getRect(find.byType(TrackRow).last);
    final viewRect = tester.getRect(find.byType(SearchResultsView));
    expect(rowRect.top, greaterThanOrEqualTo(viewRect.top));
    expect(rowRect.bottom, lessThanOrEqualTo(viewRect.bottom));
  });

  testWidgets('页面版式：歌手链接 / 未知歌手兜底 / 触摸端行尾操作菜单', (tester) async {
    source.onSearch = (query) async => SearchResult(
      items: [
        track(
          'a',
          artists: const [Artist(name: '周杰伦', id: '336')],
          // 领域 Track 经 SourceTrack 往返后，歌手 id 只保留在 raw 的
          // `_artists`（与真实平台解析同一口径）。
          payload: const {
            'songmid': 'a',
            '_artists': [
              {'name': '周杰伦', 'id': '336'},
            ],
          },
        ),
        track('b', artists: const []),
      ],
      total: 2,
    );
    final openedArtists = <(String, String, String?)>[];
    final played = <String>[];
    await pumpView(
      tester,
      SearchResultsView(
        variant: SearchResultsVariant.page,
        onPlay: (row) => played.add(row.id.uri),
        onOpenArtist: (sourceKey, artistId, {fallbackName}) async {
          openedArtists.add((sourceKey, artistId, fallbackName));
        },
      ),
    );
    search.submitSearch('hello');
    await tester.pumpAndSettle();

    // 行内歌手名是链接（渠道有歌手能力位 + 条目带平台内 id）。
    expect(find.text('周杰伦'), findsOneWidget);
    // 无歌手信息的行回退 l10n「未知歌手」。
    expect(find.text('未知歌手'), findsOneWidget);
    // Text.rich 的点击要落在 span 的字形上（盒子中心可能是行尾空白）。
    await tester.tapOnText(find.textRange.ofSubstring('周杰伦'));
    await tester.pump();
    expect(openedArtists, [('kw', '336', '周杰伦')]);

    await tester.tap(find.text('Title b'));
    await tester.pump();
    expect(played, ['kw:b'], reason: '点击行交给宿主的播放语义');

    // 触摸端：每行常显 ⋮，菜单动作与其它曲目行同一份定义。
    expect(find.byIcon(Icons.more_vert_rounded), findsNWidgets(2));
    await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
    await tester.pumpAndSettle();
    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('加入列表'), findsOneWidget);
  });

  testWidgets('遮罩版式：行映射 + 桌面右键菜单 + 8 行上限 + 查看全部结果出口', (tester) async {
    source.onSearch = (query) async => SearchResult(
      items: [
        // 第 1 行没有歌手：遮罩也要有「未知歌手」兜底。
        track('0', artists: const []),
        for (var i = 1; i < 12; i++) track('$i'),
      ],
      total: 12,
    );
    final played = <String>[];
    var openedAll = 0;
    await pumpView(
      tester,
      SearchResultsView(
        variant: SearchResultsVariant.docked,
        onPlay: (row) => played.add(row.id.uri),
        onOpenAllResults: () => openedAll++,
      ),
      width: 800,
    );
    search.submitSearch('hello');
    await tester.pumpAndSettle();

    expect(find.byType(TrackRow), findsNWidgets(8), reason: '遮罩只就地预览前 8 行');
    expect(find.text('未知歌手'), findsOneWidget);
    expect(find.text(l10n.viewAllResults), findsOneWidget);

    // 桌面端：行尾没有 ⋮，行表面右键在落点弹同一份操作菜单。
    expect(find.byIcon(Icons.more_vert_rounded), findsNothing);
    final rowRect = tester.getRect(find.byType(TrackRow).first);
    await tester.tapAt(
      Offset(rowRect.left + 40, rowRect.center.dy),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('加入列表'), findsOneWidget);
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Title 0'));
    await tester.pump();
    expect(played, ['kw:0']);

    await tester.tap(find.text(l10n.viewAllResults));
    await tester.pump();
    expect(openedAll, 1, reason: '底部出口交给宿主的「查看全部结果」');
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
