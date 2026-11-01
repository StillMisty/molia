/// 换源页（歌词 tab）：页面级曲目条 / 搜索栏 / 来源 chips、两步确认与
/// PageView keep-alive（切到音频再回来不重搜、不丢选中）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/domain/models/source.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/source_swap_page.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/lyrics_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/source_swap_provider.dart';
import 'package:molia/services/lyrics/lyric_provider.dart';
import 'package:molia/services/lyrics/lyrics_source_strategy.dart';
import 'package:molia/services/lyrics_service.dart';
import 'package:molia/services/notification_service.dart';
import 'package:molia/widgets/app_search_bar.dart';
import 'package:molia/widgets/source_swap/source_swap_chrome.dart';

import 'support/fake_library_repository.dart';
import 'support/fake_music_source.dart';
import 'support/fakes.dart';
import 'support/cover_test_support.dart';

class _FakeLyricsService extends LyricsService {
  _FakeLyricsService() : super(providers: const []);

  final List<({String trackId, String provider})> saved = [];

  @override
  Future<void> saveLyrics(
    String trackId,
    String lyric,
    String providerName, {
    String? translation,
    String? roma,
    String? lxlyric,
  }) async {
    saved.add((trackId: trackId, provider: providerName));
  }
}

class _FakeLyricProvider extends LyricProvider {
  _FakeLyricProvider(this.name, {this.matches = const [], this.payload});

  @override
  final String name;

  final List<SongMatch> matches;
  LyricsPayload? payload;
  int searchCalls = 0;
  int? lastSearchLimit;

  @override
  Future<SongMatch?> search(String title, String artist) async {
    final results = await searchMultiple(title, artist, limit: 1);
    return results.isEmpty ? null : results.first;
  }

  @override
  Future<List<SongMatch>> searchMultiple(
    String title,
    String artist, {
    int limit = 3,
  }) async {
    searchCalls++;
    lastSearchLimit = limit;
    return matches.take(limit).toList();
  }

  @override
  Future<LyricsPayload?> fetchForMatch(SongMatch match) async => payload;

  @override
  Future<String?> fetchLyric(String songId) async => payload?.lyric;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeLibraryRepository repository;
  late FakePlaybackBackend backend;
  late PlaybackProvider playback;
  late LibraryProvider library;
  late FakeMusicSource kg;
  late FakeMusicSource tx;
  late FakeMusicSource wy;
  late SourceSwapProvider swap;
  late _FakeLyricsService lyricsService;
  late LyricsProvider lyricsProvider;
  late _FakeLyricProvider qq;

  const seed = Track(
    id: TrackId('wy', '1'),
    title: '原曲',
    artists: [Artist(name: '周杰伦')],
    origin: TrackOrigin.builtin,
  );

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
    kg = FakeMusicSource('kg');
    // tx 必须存在：歌词来源跟随「已启用渠道」过滤，测试的 tx 策略才会留下。
    tx = FakeMusicSource('tx');
    // wy 启用但不可搜索：歌词来源仍应出现，chips 也要按渠道管理顺序
    // （map 顺序 = 这里的渠道顺序）排在 tx 前面。
    wy = FakeMusicSource(
      'wy',
      capabilities: const SourceCapabilities(search: false),
    );
    final sources = {'wy': wy, 'kg': kg, 'tx': tx};
    swap = SourceSwapProvider(
      catalogService: CatalogService(registry: FakeSourceRegistry(sources)),
      sourceRegistry: FakeSourceRegistry(sources),
      libraryProvider: library,
      playbackProvider: playback,
    );
    lyricsService = _FakeLyricsService();
    lyricsProvider = LyricsProvider(service: lyricsService);
    qq = _FakeLyricProvider(
      'qq',
      matches: [SongMatch(songId: '1', title: '晴天', artist: '周杰伦')],
      payload: const LyricsPayload(lyric: '[00:01.00]晴天'),
    );
  });

  tearDown(() async {
    lyricsProvider.dispose();
    swap.dispose();
    library.dispose();
    playback.dispose();
    await repository.dispose();
  });

  Future<void> pumpHost(
    WidgetTester tester, {
    required List<LyricsSourceStrategy> lyricsSources,
  }) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          coverStoreProvider(),
          ChangeNotifierProvider<SourceSwapProvider>.value(value: swap),
          ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
          ChangeNotifierProvider<LibraryProvider>.value(value: library),
          Provider<NotificationService>.value(value: NotificationService()),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: M3EButton.filled(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SourceSwapPage(
                        request: const SourceSwapRequest(
                          seed: seed,
                          placement: SourceSwapPlacement.queue,
                        ),
                        lyricsProvider: lyricsProvider,
                        initialTab: SourceSwapTab.lyrics,
                        lyricsSources: lyricsSources,
                      ),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  List<LyricsSourceStrategy> strategies() => [
    LyricsSourceStrategy(channelKey: 'tx', provider: qq),
  ];

  testWidgets('歌词 tab：曲目条 / 搜索栏 / 全部+来源 chips，选中后才写缓存', (tester) async {
    await pumpHost(tester, lyricsSources: strategies());

    expect(find.text('原曲'), findsOneWidget);
    expect(find.text('周杰伦 · 网易云音乐'), findsOneWidget);
    expect(
      find.byKey(const Key('sourceSwapSearchFieldLyrics')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('sourceSwapSourceChip-all')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('sourceSwapSourceChip-tx')),
      findsOneWidget,
    );
    expect(find.text('晴天'), findsOneWidget);
    expect(find.text('点选一项后确认'), findsNothing);
    expect(
      tester
          .widget<M3EButton>(find.widgetWithText(M3EButton, '使用此歌词'))
          .onPressed,
      isNull,
      reason: '未选中时确认按钮禁用',
    );

    await tester.tap(find.text('晴天'));
    await tester.pumpAndSettle();

    expect(lyricsService.saved, isEmpty, reason: '点结果只选中，不取词不写缓存');
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    expect(
      tester
          .widget<M3EButton>(find.widgetWithText(M3EButton, '使用此歌词'))
          .onPressed,
      isNotNull,
      reason: '选中后确认按钮可用',
    );

    await tester.tap(find.text('使用此歌词'));
    await tester.pumpAndSettle();

    expect(lyricsService.saved, hasLength(1));
    expect(lyricsService.saved.single.trackId, 'wy:1');
    expect(lyricsService.saved.single.provider, 'qq');
  });

  testWidgets('进入歌词 tab：不聚焦、不全选，光标停在预填关键词末尾', (tester) async {
    await pumpHost(tester, lyricsSources: strategies());

    final field = tester.widget<AppSearchBar>(
      find.descendant(
        of: find.byKey(const Key('sourceSwapSearchFieldLyrics')),
        matching: find.byType(AppSearchBar),
      ),
    );
    expect(field.controller.text, '原曲 周杰伦');
    expect(field.controller.selection.isCollapsed, isTrue, reason: '不再全选预填关键词');
    expect(field.controller.selection.baseOffset, '原曲 周杰伦'.length);
    expect(field.focusNode?.hasFocus, isFalse, reason: '进入歌词 tab 不抢键盘');
    expect(qq.searchCalls, 1, reason: '预填关键词仍自动搜索');
    expect(qq.lastSearchLimit, 10, reason: '每源抓 10 条');
  });

  testWidgets('chips 顺序走渠道管理顺序：启用但不可搜索的渠道不排到最后', (tester) async {
    final netease = _FakeLyricProvider('netease');
    final kugou = _FakeLyricProvider('kugou');
    await pumpHost(
      tester,
      lyricsSources: [
        ...strategies(),
        LyricsSourceStrategy(channelKey: 'wy', provider: netease),
        LyricsSourceStrategy(channelKey: 'kg', provider: kugou),
      ],
    );

    // 生产路径：wy 不可搜索，不会出现在 searchableSources / sourceDescriptors 中，
    // 但 orderedChannelKeys 仍保留渠道管理顺序（setUp 的 map 顺序 wy → kg → tx）。
    expect(
      swap.searchableSources.map((item) => item.key),
      isNot(contains('wy')),
    );
    expect(swap.orderedChannelKeys.take(2), ['wy', 'kg']);

    double xOf(String key) =>
        tester.getTopLeft(find.byKey(ValueKey('sourceSwapSourceChip-$key'))).dx;
    expect(xOf('wy'), lessThan(xOf('kg')), reason: '按渠道管理顺序：wy 在 kg 前');
    expect(xOf('kg'), lessThan(xOf('tx')), reason: '按渠道管理顺序：kg 在 tx 前');
    expect(xOf('wy'), lessThan(xOf('tx')), reason: '不可搜索渠道不能被排到最后');
    expect(netease.searchCalls, 1, reason: '启用渠道仍参与歌词搜索');
  });

  testWidgets('全部模式每源最多 3 条；查看全部切到该来源并展示完整 10 条', (tester) async {
    qq = _FakeLyricProvider(
      'qq',
      matches: [
        for (var index = 0; index < 12; index++)
          SongMatch(songId: '$index', title: '候选$index', artist: '周杰伦'),
      ],
    );
    await pumpHost(tester, lyricsSources: strategies());

    for (var index = 0; index < 3; index++) {
      expect(find.byKey(ValueKey('lyricsSourceRow-qq-$index')), findsOneWidget);
    }
    expect(
      find.byKey(const ValueKey('lyricsSourceRow-qq-3')),
      findsNothing,
      reason: '全部模式只预览前 3 条',
    );
    expect(find.byKey(const ValueKey('sourceSwapViewAll-tx')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('sourceSwapViewAll-tx')));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<M3EChip>(
            find.byKey(const ValueKey('sourceSwapSourceChip-tx')),
          )
          .selected,
      isTrue,
    );
    for (var index = 0; index < 10; index++) {
      expect(find.byKey(ValueKey('lyricsSourceRow-qq-$index')), findsOneWidget);
    }
    expect(
      find.byKey(const ValueKey('lyricsSourceRow-qq-10')),
      findsNothing,
      reason: '每源只抓 10 条',
    );
    expect(find.byKey(const ValueKey('lyricsSourceSection-tx')), findsNothing);
    expect(
      find.byKey(const ValueKey('sourceSwapViewAll-tx')),
      findsNothing,
      reason: '单源模式直接展示完整结果，不再需要查看全部',
    );
  });

  testWidgets('选中项跨筛选保留：不可见时预览/确认隐藏或禁用，切回恢复', (tester) async {
    final external = _FakeLyricProvider(
      'external',
      matches: [SongMatch(songId: 'ext-1', title: '外部结果', artist: '周杰伦')],
      payload: const LyricsPayload(lyric: '[00:01.00]外部歌词'),
    );
    final empty = _FakeLyricProvider('empty');
    qq.payload = const LyricsPayload(
      lyric: '[00:01.00]第一句\n[00:02.00]第二句\n[00:03.00]第三句',
    );
    await pumpHost(
      tester,
      lyricsSources: [
        ...strategies(),
        LyricsSourceStrategy(
          channelKey: 'external',
          provider: external,
          isChannel: false,
        ),
        LyricsSourceStrategy(
          channelKey: 'empty',
          provider: empty,
          isChannel: false,
        ),
      ],
    );

    await tester.tap(find.byKey(const ValueKey('lyricsSourceRow-qq-1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('lyricsSourcePreview')), findsOneWidget);
    expect(find.text('歌词预览'), findsOneWidget);
    expect(find.text('第一句\n第二句\n第三句'), findsOneWidget);
    expect(
      tester
          .widget<M3EButton>(find.widgetWithText(M3EButton, '使用此歌词'))
          .onPressed,
      isNotNull,
    );

    // 切到另一个有结果的来源：选中项还在，但不可见 → 底栏保留、确认禁用、
    // 预览隐藏。
    await tester.tap(
      find.byKey(const ValueKey('sourceSwapSourceChip-external')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lyricsSourceRow-qq-1')), findsNothing);
    expect(find.byKey(const Key('lyricsSourcePreview')), findsNothing);
    expect(find.byType(SourceSwapActionBar), findsOneWidget);
    expect(
      tester
          .widget<M3EButton>(find.widgetWithText(M3EButton, '使用此歌词'))
          .onPressed,
      isNull,
      reason: '看不到选中项时不能确认',
    );

    // 切到没有可见结果的来源：底栏整体隐藏。
    await tester.tap(find.byKey(const ValueKey('sourceSwapSourceChip-empty')));
    await tester.pumpAndSettle();
    expect(find.byType(SourceSwapActionBar), findsNothing);
    expect(find.byKey(const Key('lyricsSourcePreview')), findsNothing);

    // 切回原来源：选中项、预览与确认一起恢复。
    await tester.tap(find.byKey(const ValueKey('sourceSwapSourceChip-tx')));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    expect(find.byKey(const Key('lyricsSourcePreview')), findsOneWidget);
    expect(
      tester
          .widget<M3EButton>(find.widgetWithText(M3EButton, '使用此歌词'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('切到音频再切回歌词：结果与选中项保留（keep-alive）', (tester) async {
    kg.items = [
      const Track(
        id: TrackId('kg', '100'),
        title: 'Title（kg）',
        artists: [Artist(name: 'Artist')],
        origin: TrackOrigin.builtin,
      ),
    ];
    await pumpHost(tester, lyricsSources: strategies());

    await tester.tap(find.text('晴天'));
    await tester.pumpAndSettle();
    expect(lyricsService.saved, isEmpty);
    expect(qq.searchCalls, 1);

    await tester.tap(
      find.descendant(of: find.byType(M3ETabs), matching: find.text('音频')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Title（kg）'), findsOneWidget);

    await tester.tap(
      find.descendant(of: find.byType(M3ETabs), matching: find.text('歌词')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('lyricsSourceRow-qq-1')),
      findsOneWidget,
      reason: '歌词行与预览都可能显示歌名，用行 key 确认结果还在',
    );
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    expect(qq.searchCalls, 1, reason: '离屏页保持存活，回来不重搜');
    expect(lyricsService.saved, isEmpty, reason: '切 tab 不会顺手取词');
  });
}
