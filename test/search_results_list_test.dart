import 'package:flutter/gestures.dart';
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
import 'package:molia/widgets/track_table_header.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_library_repository.dart';
import 'support/fake_music_source.dart';
import 'support/fakes.dart';

/// 发现页搜索结果列表（与收藏页同形曲目行）组件测试。
///
/// 覆盖：列表行渲染（标题 / 歌手 / 时长）、点按播放（结果整体进队列）、
/// 操作菜单（触摸端行尾 ⋮ 收藏写库 + 状态切换、加入列表弹层；桌面端行表面
/// 右键在落点弹菜单）、分页入口保留、桌面宽屏表格列（表头 + 三列，与行内列
/// 左缘对齐）。
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

  Future<void> pumpSection(
    WidgetTester tester, {
    ScrollController? controller,
    double width = 1200,
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

  testWidgets('非桌面平台：不渲染表头，行保持单列布局', (tester) async {
    // 测试环境默认平台为 android：窗口够宽也不进表格模式。
    await pumpSection(tester);
    await runSearch(tester);

    expect(find.byType(TrackTableHeader), findsNothing);
    expect(find.text('专辑'), findsNothing);
    expect(find.text('Album'), findsNothing, reason: '单列行不展示专辑');
    expect(find.text('Artist a'), findsOneWidget, reason: '副标题仍是歌手');
    expect(find.text('3:05'), findsNWidgets(3), reason: '时长仍在行尾');
  });

  testWidgets(
    '桌面窄窗口（内容宽 < 720）：不渲染表头，行高回落双行档',
    (tester) async {
      await pumpSection(tester, width: 800);
      await runSearch(tester);

      expect(find.byType(TrackTableHeader), findsNothing);
      expect(find.text('Artist a'), findsOneWidget);

      // 非表格档：双行行高（M3E twoLineHeight 72），itemExtent 同源。
      final rowContext = tester.element(find.byType(TrackRow).first);
      expect(tester.getSize(find.byType(TrackRow).first).height, 72);
      expect(
        tester
            .widget<SliverFixedExtentList>(
              find.byType(SliverFixedExtentList),
            )
            .itemExtent,
        TrackRow.extentOf(rowContext, tableColumns: false) +
            TrackRow.gapOf(rowContext),
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets(
    '桌面：宽屏表格 / 窄屏单列行内都无 ⋮，右键在落点弹菜单',
    (tester) async {
      await pumpSection(tester);
      await runSearch(tester);
      expect(find.byType(TrackTableHeader), findsOneWidget, reason: '宽屏走表格行');
      expect(
        find.byIcon(Icons.more_vert_rounded),
        findsNothing,
        reason: '桌面入口是行表面右键，不再有行尾 ⋮',
      );

      // 右键落到第一行内的一个非中心点：菜单在落点展开（收藏 / 加入列表）。
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

      // 窄屏（内容宽 < 720）走单列行：同一份右键接线仍然生效。
      await pumpSection(tester, width: 800);
      expect(find.byType(TrackTableHeader), findsNothing, reason: '窄屏走单列行');
      expect(
        find.byIcon(Icons.more_vert_rounded),
        findsNothing,
        reason: '桌面入口是行表面右键，不再有行尾 ⋮',
      );
      await tester.tap(
        find.byType(TrackRow).first,
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(find.text('收藏'), findsOneWidget);
      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );
}
