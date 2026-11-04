import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
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
import '../support/cover_test_support.dart';

/// 统一搜索结果面（`SearchResultsView`）的两种版式：
///
/// - 页面版式：单渠道行映射、歌手链接、未知歌手兜底、宽屏表格列；
/// - 遮罩版式：同样的行映射、8 行预览上限、「查看全部结果」出口与失败重试；
/// - 当前渠道不支持搜索时的专用空态（页面版 / 遮罩版）。
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
    TextScaler textScaler = TextScaler.noScaling,
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
          coverStoreProvider(),
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
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              child: Scaffold(body: view),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('页面版式：单源结果行 + 宽屏表格列，无来源分组标题', (tester) async {
    source.onSearch = (query) async =>
        SearchResult(items: [track('a'), track('b')], hasMore: true, total: 12);
    await pumpView(
      tester,
      SearchResultsView(
        variant: SearchResultsVariant.page,
        onPlay: (_) {},
        onOpenArtist: (sourceKey, artistId, {fallbackName}) async {},
      ),
    );
    search.submitSearch('hello');
    await tester.pumpAndSettle();

    expect(find.byType(TrackTableHeader), findsOneWidget, reason: '单源保留宽屏表格');
    expect(find.byType(TrackRow), findsNWidgets(2));
    expect(find.text('kw'), findsNothing, reason: '单源不再渲染分组标题');
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('遮罩版式：最多预览 8 行，超出仍显示「查看全部结果」', (tester) async {
    source.onSearch = (query) async => SearchResult(
      items: [for (var i = 0; i < 12; i++) track('$i')],
      total: 12,
    );
    await pumpView(
      tester,
      SearchResultsView(
        variant: SearchResultsVariant.docked,
        onPlay: (_) {},
        onOpenAllResults: () {},
      ),
      width: 900,
    );
    search.submitSearch('hello');
    await tester.pumpAndSettle();

    final preview = SearchResultsView.previewFor(search);
    expect(preview.items, hasLength(8));
    expect(preview.totalItems, 12);
    expect(find.byType(TrackRow), findsNWidgets(8));
    expect(find.text(l10n.viewAllResults), findsOneWidget);
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

  testWidgets('防抖等待期显示进度而不是空结果', (tester) async {
    final gate = Completer<SearchResult<Track>>();
    source.onSearch = (query) => gate.future;
    await pumpView(
      tester,
      SearchResultsView(
        variant: SearchResultsVariant.page,
        onPlay: (_) {},
        onOpenArtist: (sourceKey, artistId, {fallbackName}) async {},
      ),
    );
    search.updateSearchQuery('hello');
    await tester.pump(const Duration(milliseconds: 50));

    expect(search.isSearchBusy, isTrue);
    expect(find.text(l10n.noResultsFound), findsNothing, reason: '防抖中不能闪空态');
    expect(find.byType(M3EProgressIndicator), findsWidgets);

    gate.complete(SearchResult(items: [track('a'), track('b')], total: 2));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(search.isSearchBusy, isFalse);
    expect(find.text(l10n.noResultsFound), findsNothing);
    expect(find.byType(TrackRow), findsNWidgets(2));
  });

  testWidgets('加载更多失败：保留结果，底部页脚重试', (tester) async {
    var failPage2 = true;
    source.onSearch = (query) async {
      if (query.page == 1) {
        return SearchResult(items: [track('a1')], hasMore: true, total: 2);
      }
      if (failPage2) {
        throw const SourceFailure(
          kind: FailureKind.network,
          message: 'page2 boom',
        );
      }
      return SearchResult(items: [track('a2')], hasMore: false, total: 2);
    };
    await pumpView(
      tester,
      SearchResultsView(
        variant: SearchResultsVariant.page,
        onPlay: (_) {},
        onOpenArtist: (sourceKey, artistId, {fallbackName}) async {},
      ),
    );
    search.submitSearch('hello');
    await tester.pumpAndSettle();

    await search.loadMore('kw');
    await tester.pumpAndSettle();
    expect(search.songGroups.single.loadMoreFailed, isTrue);
    expect(search.songGroups.single.failure, isNull);
    expect(find.text(l10n.searchFailed), findsNothing, reason: '不是首屏失败');
    expect(find.text(l10n.searchLoadMoreFailed), findsOneWidget);

    failPage2 = false;
    await tester.tap(find.text(l10n.retry));
    await tester.pumpAndSettle();
    expect(search.songGroups.single.loadMoreFailed, isFalse);
    expect(find.text('Title a2'), findsOneWidget);
    expect(find.text(l10n.searchFailed), findsNothing);
  });

  testWidgets('首屏失败：错误条提供重试，恢复后渲染结果', (tester) async {
    var fail = true;
    source.onSearch = (query) async {
      if (fail) {
        throw const SourceFailure(kind: FailureKind.network, message: 'boom');
      }
      return SearchResult(items: [track('a')], total: 1);
    };
    await pumpView(
      tester,
      SearchResultsView(
        variant: SearchResultsVariant.docked,
        onPlay: (_) {},
        onOpenAllResults: () {},
      ),
      width: 900,
    );
    search.submitSearch('hello');
    await tester.pumpAndSettle();
    expect(find.text(l10n.searchFailed), findsOneWidget);

    fail = false;
    await tester.tap(find.text(l10n.retry));
    await tester.pumpAndSettle();
    expect(find.text('Title a'), findsOneWidget);
    expect(find.text(l10n.searchFailed), findsNothing);
  });

  testWidgets('歌手链接按当前渠道能力位', (tester) async {
    source.onSearch = (query) async => SearchResult(
      items: [
        track(
          'a',
          artists: const [Artist(name: 'KwArtist', id: '11')],
        ),
      ],
    );
    final opened = <(String, String)>[];
    await pumpView(
      tester,
      SearchResultsView(
        variant: SearchResultsVariant.page,
        onPlay: (_) {},
        onOpenArtist: (sourceKey, artistId, {fallbackName}) async {
          opened.add((sourceKey, artistId));
        },
      ),
    );
    search.submitSearch('hello');
    await tester.pumpAndSettle();

    await tester.tapOnText(find.textRange.ofSubstring('KwArtist'));
    await tester.pump();
    expect(opened, [('kw', '11')]);
  });

  testWidgets('页面版式：歌手链接 / 未知歌手兜底 / 触摸端行尾操作菜单', (tester) async {
    source.onSearch = (query) async => SearchResult(
      items: [
        track(
          'a',
          artists: const [Artist(name: '周杰伦', id: '336')],
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

    expect(find.text('周杰伦'), findsOneWidget);
    expect(find.text('未知歌手'), findsOneWidget);
    await tester.tapOnText(find.textRange.ofSubstring('周杰伦'));
    await tester.pump();
    expect(openedArtists, [('kw', '336', '周杰伦')]);

    await tester.tap(find.text('Title b'));
    await tester.pump();
    expect(played, ['kw:b'], reason: '点击行交给宿主的播放语义');

    expect(find.byIcon(Icons.more_vert_rounded), findsNWidgets(2));
    await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
    await tester.pumpAndSettle();
    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('加入列表'), findsOneWidget);
  });

  testWidgets('遮罩版式：行映射 + 桌面右键菜单 + 查看全部结果出口', (tester) async {
    source.onSearch = (query) async => SearchResult(
      items: [
        track('0', artists: const []),
        for (var i = 1; i < 3; i++) track('$i'),
      ],
      total: 3,
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

    expect(find.byType(TrackRow), findsNWidgets(3));
    expect(find.text('未知歌手'), findsOneWidget);
    expect(find.text(l10n.viewAllResults), findsOneWidget);
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

  testWidgets('已注册但无搜索能力：页面版 / 遮罩版都显示 unsupported', (tester) async {
    final script = FakeMusicSource(
      'script',
      capabilities: const SourceCapabilities(),
    );
    final scriptRegistry = FakeSourceRegistry({'script': script});
    final provider = SearchProvider(
      playback,
      catalogService: CatalogService(registry: scriptRegistry),
      sourceRegistry: scriptRegistry,
    );
    addTearDown(provider.dispose);
    expect(provider.activeSource, isNotNull);
    expect(provider.hasActiveSearchSource, isFalse);

    for (final variant in [
      SearchResultsVariant.page,
      SearchResultsVariant.docked,
    ]) {
      await pumpView(
        tester,
        SearchResultsView(
          variant: variant,
          onPlay: (_) {},
          onOpenArtist: variant == SearchResultsVariant.page
              ? (sourceKey, artistId, {fallbackName}) async {}
              : null,
          onOpenAllResults: variant == SearchResultsVariant.docked
              ? () {}
              : null,
        ),
        provider: provider,
      );
      expect(
        find.text(l10n.searchChannelUnsupported),
        findsOneWidget,
        reason: '$variant 必须命中 unsupported 空态',
      );
      expect(find.text(l10n.searchIdleHint), findsNothing);
      expect(find.text(l10n.searchNoSourcesTitle), findsNothing);
    }
  });

  testWidgets('页面版式：当前渠道不支持搜索显示专用空态', (tester) async {
    await pumpView(
      tester,
      SearchResultsView(
        variant: SearchResultsVariant.page,
        onPlay: (_) {},
        onOpenArtist: (sourceKey, artistId, {fallbackName}) async {},
      ),
    );
    search.setActiveSource('wy');
    await tester.pumpAndSettle();

    expect(find.text(l10n.searchChannelUnsupported), findsOneWidget);
    expect(find.text(l10n.searchIdleHint), findsNothing);
    expect(find.text(l10n.searchNoSourcesTitle), findsNothing);
  });

  testWidgets('有查询时切到不可搜索渠道：遮罩空态且不永久 loading', (tester) async {
    source.onSearch = (query) async =>
        SearchResult(items: [track('a')], total: 1);
    await pumpView(
      tester,
      SearchResultsView(
        variant: SearchResultsVariant.docked,
        onPlay: (_) {},
        onOpenAllResults: () {},
      ),
      width: 900,
    );
    search.submitSearch('hello');
    await tester.pumpAndSettle();
    expect(search.hasActiveSearchSource, isTrue);

    search.setActiveSource('wy');
    await tester.pumpAndSettle();

    expect(search.isSearchPending, isFalse);
    expect(search.isSearchBusy, isFalse);
    expect(find.text(l10n.searchChannelUnsupported), findsOneWidget);
    expect(find.byType(M3EProgressIndicator), findsNothing);
  });

  testWidgets('遮罩版式：无关键词也会显示当前渠道不支持搜索', (tester) async {
    await pumpView(
      tester,
      SearchResultsView(
        variant: SearchResultsVariant.docked,
        onPlay: (_) {},
        onOpenAllResults: () {},
      ),
      width: 900,
    );
    search.setActiveSource('wy');
    await tester.pumpAndSettle();

    expect(find.text(l10n.searchChannelUnsupported), findsOneWidget);
  });

  testWidgets('页面版式：当前渠道无结果时带渠道名提示', (tester) async {
    source.onSearch = (query) async => const SearchResult(items: []);
    await pumpView(
      tester,
      SearchResultsView(
        variant: SearchResultsVariant.page,
        onPlay: (_) {},
        onOpenArtist: (sourceKey, artistId, {fallbackName}) async {},
      ),
    );
    search.submitSearch('hello');
    await tester.pumpAndSettle();

    expect(find.text(l10n.noResultsFound), findsOneWidget);
    expect(find.text(l10n.searchNoResultsInSource('kw')), findsOneWidget);
  });
}
