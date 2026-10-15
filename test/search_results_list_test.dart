import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/domain/models/catalog.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/search_provider.dart';
import 'package:molia/widgets/search_section.dart';
import 'package:molia/widgets/track_row.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_library_repository.dart';
import 'support/fake_music_source.dart';
import 'support/fakes.dart';

/// 发现页搜索结果列表（与收藏页同形曲目行）组件测试。
///
/// 覆盖：列表行渲染（标题 / 歌手 / 时长）、点按播放（结果整体进队列）、
/// 行尾 ⋮ 菜单（收藏写库 + 状态切换、加入列表弹层）、分页入口保留。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeMusicSource source;
  late CatalogService catalog;
  late FakePlaybackBackend backend;
  late FakeLibraryRepository repository;
  late PlaybackProvider playback;
  late LibraryProvider library;
  late SearchProvider search;

  Track track(String id) => Track(
        id: TrackId('kw', id),
        title: 'Title $id',
        artists: [Artist(name: 'Artist $id')],
        album: 'Album',
        duration: const Duration(minutes: 3, seconds: 5),
        artwork: Artwork(uri: Uri.parse('https://img.example/$id.jpg')),
        origin: TrackOrigin.builtin,
        // kw 的规范 id 字段（收藏 / 列表 songId 与 raw 取键口径一致）。
        payload: {'songmid': id},
      );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    source = FakeMusicSource('kw');
    source.onSearch = (query) => Future.value(
          SearchResult(
            items: [track('a'), track('b'), track('c')],
            hasMore: true,
            total: 42,
          ),
        );
    catalog = CatalogService(registry: FakeSourceRegistry({'kw': source}));
    backend = FakePlaybackBackend();
    repository = FakeLibraryRepository();
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
      sourceRegistry: FakeSourceRegistry({'kw': source}),
    );
  });

  tearDown(() async {
    search.dispose();
    library.dispose();
    playback.dispose();
    await repository.dispose();
  });

  Future<void> pumpSection(WidgetTester tester, {ScrollController? controller}) async {
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
          ChangeNotifierProvider<SearchProvider>.value(value: search),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: Scaffold(body: SearchSection(controller: controller)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 提交搜索并等结果落地（无真实 I/O，微任务即可完成）。
  Future<void> runSearch(WidgetTester tester) async {
    search.submitSearch('hello');
    await tester.pumpAndSettle();
    expect(search.filteredResults, hasLength(3), reason: '搜索结果应已落地');
  }

  testWidgets('结果列表滚动控制器可注入（底栏重复点击回顶的数据通路）', (tester) async {
    source.onSearch = (query) => Future.value(
          SearchResult(
            items: [for (var i = 0; i < 60; i++) track('$i')],
            hasMore: false,
            total: 60,
          ),
        );
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await pumpSection(tester, controller: controller);
    search.submitSearch('hello');
    await tester.pumpAndSettle();

    expect(controller.hasClients, isTrue, reason: '结果列表应挂在注入的控制器上');
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0), reason: '拖动应作用在注入的控制器上');
  });

  testWidgets('结果列表：收藏页同形曲目行（标题 / 歌手 / 时长）', (tester) async {
    await pumpSection(tester);
    await runSearch(tester);

    expect(find.byType(TrackRow), findsNWidgets(3));
    expect(find.text('Title a'), findsOneWidget);
    expect(find.text('Artist a'), findsOneWidget);
    expect(find.text('3:05'), findsNWidgets(3));
    // 分页入口保留：结果尾部「加载更多」按钮（带平台总数）。
    expect(find.text('加载更多（共 42 首）'), findsOneWidget);
  });

  testWidgets('点按行：结果整体进队列并从当前行开始播放', (tester) async {
    await pumpSection(tester);
    await runSearch(tester);

    await tester.tap(find.text('Title b'));
    await tester.pumpAndSettle();

    final request = backend.lastRequest;
    expect(request, isNotNull);
    expect(
      [for (final item in request!.tracks) item.title],
      ['Title a', 'Title b', 'Title c'],
    );
    expect(request.startIndex, 1);
  });

  testWidgets('行尾菜单：收藏写库，再开菜单变「取消收藏」', (tester) async {
    await pumpSection(tester);
    await runSearch(tester);

    await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
    await tester.pumpAndSettle();
    expect(find.text('收藏'), findsOneWidget);

    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    expect(library.isFavorite('kw', 'a'), isTrue);

    await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
    await tester.pumpAndSettle();
    expect(find.text('取消收藏'), findsOneWidget);
  });

  testWidgets('行尾菜单：加入列表走统一目标弹层（我的收藏）', (tester) async {
    await pumpSection(tester);
    await runSearch(tester);

    await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入列表'));
    await tester.pumpAndSettle();

    // 统一「加入列表」弹层：我的收藏 / 播放历史 / 自建列表。
    expect(find.text('我的收藏'), findsOneWidget);
    await tester.tap(find.text('我的收藏'));
    await tester.pumpAndSettle();
    expect(library.isFavorite('kw', 'a'), isTrue);
  });
}
