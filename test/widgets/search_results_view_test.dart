import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/domain/models/catalog.dart';
import 'package:molia/domain/models/source.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/search_provider.dart';
import 'package:molia/widgets/search_results_view.dart';
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
    List<Artist>? artists,
    Map<String, Object?>? payload,
  }) => Track(
    id: TrackId('kw', id),
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
          ChangeNotifierProvider<SearchProvider>.value(value: search),
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
