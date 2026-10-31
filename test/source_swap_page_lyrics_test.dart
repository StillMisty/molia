/// 换源页（歌词 tab）：页面级曲目条 / 搜索栏 / 来源 chips、两步确认与
/// PageView keep-alive（切到音频再回来不重搜、不丢选中）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/data/catalog/catalog_service.dart';
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

import 'support/fake_library_repository.dart';
import 'support/fake_music_source.dart';
import 'support/fakes.dart';

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
  final LyricsPayload? payload;
  int searchCalls = 0;

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
    final sources = {'kg': kg, 'tx': tx};
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
    expect(find.byKey(const Key('sourceSwapSearchField')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('sourceSwapSourceChip-all')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('sourceSwapSourceChip-tx')),
      findsOneWidget,
    );
    expect(find.text('晴天'), findsOneWidget);
    expect(find.text('点选一项后确认'), findsOneWidget);

    await tester.tap(find.text('晴天'));
    await tester.pumpAndSettle();

    expect(lyricsService.saved, isEmpty, reason: '点结果只选中，不取词不写缓存');
    expect(find.text('已选：晴天 · QQ音乐'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);

    await tester.tap(find.text('使用此歌词'));
    await tester.pumpAndSettle();

    expect(lyricsService.saved, hasLength(1));
    expect(lyricsService.saved.single.trackId, 'wy:1');
    expect(lyricsService.saved.single.provider, 'qq');
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

    expect(find.text('晴天'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    expect(find.text('已选：晴天 · QQ音乐'), findsOneWidget);
    expect(qq.searchCalls, 1, reason: '离屏页保持存活，回来不重搜');
    expect(lyricsService.saved, isEmpty, reason: '切 tab 不会顺手取词');
  });
}
