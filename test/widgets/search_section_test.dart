import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/artist_service.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/domain/models/artist.dart';
import 'package:molia/domain/models/catalog.dart';
import 'package:molia/domain/models/source.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/artist_page.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/search_provider.dart';
import 'package:molia/widgets/search_section.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_music_source.dart';
import '../support/fakes.dart';

/// 搜索结果区：类型分段（单曲 / 歌手）按能力位显隐；歌手条目进歌手页。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlaybackBackend backend;
  late PlaybackProvider playback;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    backend = FakePlaybackBackend();
    playback = buildTestPlaybackProvider(backend: backend);
  });

  tearDown(() => playback.dispose());

  Track track() => const Track(
        id: TrackId('kw', 'a'),
        title: '曲目 a',
        artists: [Artist(name: '周杰伦', id: '336')],
        origin: TrackOrigin.builtin,
      );

  FakeMusicSource source({bool artist = false, bool lyric = false}) =>
      FakeMusicSource(
        'kw',
        capabilities: SourceCapabilities(
          search: true,
          pagination: true,
          artist: artist,
          lyricSearch: lyric,
        ),
      )
        ..onSearch = ((query) async => SearchResult(
              items: [track()],
              hasMore: false,
              total: 1,
            ))
        ..onSearchArtists =
            ((query) async => SearchResult(
                  items: const [
                    ArtistSummary(id: '336', name: '周杰伦', songCount: 581),
                  ],
                  hasMore: false,
                  total: 1,
                ));

  Future<SearchProvider> pumpSection(
    WidgetTester tester, {
    required FakeMusicSource musicSource,
    ArtistService? artistService,
  }) async {
    final registry = FakeSourceRegistry({musicSource.key: musicSource});
    final provider = SearchProvider(
      playback,
      catalogService: CatalogService(registry: registry),
      sourceRegistry: registry,
    );
    addTearDown(provider.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SearchProvider>.value(value: provider),
          Provider<ArtistService>.value(
            value: artistService ??
                ArtistService(
                  fetch: (sourceKey, artistId,
                          {required page, required limit}) async =>
                      const ArtistDetail(id: '336', name: '周杰伦'),
                ),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: const Scaffold(body: SearchSection()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return provider;
  }

  testWidgets('无歌手能力：不显示类型分段，结果仍是单曲行', (tester) async {
    final provider = await pumpSection(
      tester,
      musicSource: source(artist: false),
    );
    provider.submitSearch('周杰伦');
    await tester.pumpAndSettle();

    expect(find.text('单曲'), findsNothing);
    expect(find.text('歌手'), findsNothing);
    expect(find.text('曲目 a'), findsOneWidget);
  });

  testWidgets('有歌手能力：分段出现；切到歌手渲染歌手行并可进歌手页', (tester) async {
    final musicSource = source(artist: true);
    final provider = await pumpSection(tester, musicSource: musicSource);
    provider.submitSearch('周杰伦');
    await tester.pumpAndSettle();

    expect(find.text('单曲'), findsOneWidget);
    expect(find.text('歌手'), findsOneWidget);
    expect(find.text('曲目 a'), findsOneWidget);

    await tester.tap(find.text('歌手'));
    await tester.pumpAndSettle();

    expect(musicSource.artistSearchCalls, 1);
    expect(find.text('周杰伦'), findsWidgets);
    expect(find.text('581 首歌曲'), findsOneWidget);
    // 单曲行让位给歌手行。
    expect(find.text('曲目 a'), findsNothing);

    await tester.tap(find.text('581 首歌曲'));
    await tester.pumpAndSettle();
    expect(find.byType(ArtistPage), findsOneWidget);
  });

  testWidgets('歌词类型：条目副标题显示命中片段；点击播放歌词结果', (tester) async {
    final musicSource = source(lyric: true)
      ..onSearchLyrics = ((query) async => SearchResult(
            items: const [
              LyricHit(
                track: Track(
                  id: TrackId('kw', 'l1'),
                  title: '七里香',
                  origin: TrackOrigin.builtin,
                  payload: {'songmid': 'l1'},
                ),
                snippet: '雨下整夜 我的爱溢出就像雨水',
              ),
            ],
            total: 1,
          ));
    final provider = await pumpSection(tester, musicSource: musicSource);
    provider.submitSearch('雨下整夜');
    await tester.pumpAndSettle();
    expect(find.text('歌词'), findsOneWidget);

    await tester.tap(find.text('歌词'));
    await tester.pumpAndSettle();

    expect(musicSource.lyricSearchCalls, 1);
    expect(find.text('七里香'), findsOneWidget);
    expect(find.text('雨下整夜 我的爱溢出就像雨水'), findsOneWidget);

    await tester.tap(find.text('七里香'));
    await tester.pump();
    expect(backend.lastRequest?.tracks.single.id.uri, 'kw:l1');
  });

  testWidgets('歌手条目无歌曲数：不显示计数副标题', (tester) async {
    final musicSource = source(artist: true)
      ..onSearchArtists = ((query) async => SearchResult(
            items: const [ArtistSummary(id: '336', name: '周杰伦')],
            hasMore: false,
            total: 1,
          ));
    final provider = await pumpSection(tester, musicSource: musicSource);
    provider.submitSearch('周杰伦');
    await tester.pumpAndSettle();

    await tester.tap(find.text('歌手'));
    await tester.pumpAndSettle();

    expect(find.text('周杰伦'), findsWidgets);
    expect(find.textContaining('首歌曲'), findsNothing);
  });
}
