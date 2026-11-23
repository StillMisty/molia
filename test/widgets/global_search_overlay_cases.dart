import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/domain/models/artist.dart';
import 'package:molia/domain/models/catalog.dart';
import 'package:molia/domain/models/comment.dart';
import 'package:molia/domain/models/source.dart';
import 'package:molia/domain/models/source.dart' as domain;
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/artist_repository.dart';
import 'package:molia/domain/ports/music_source.dart';
import 'package:molia/domain/ports/source_registry.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/artist_page.dart';
import 'package:molia/providers/channel_selection.dart';
import 'package:molia/providers/search_provider.dart';
import 'package:molia/providers/sources_provider.dart';
import 'package:molia/sources/source_manager.dart' hide SourceKind;
import 'package:molia/widgets/channel_search_bar.dart';
import 'package:molia/widgets/global_search_overlay.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';
import '../support/provider_test_scope.dart';
import '../support/settings_test_support.dart';

/// 只实现搜索所需表面的假音源。
class _FakeMusicSource implements MusicSource {
  _FakeMusicSource(this.key);

  @override
  final String key;

  @override
  final domain.SourceCapabilities capabilities =
      const domain.SourceCapabilities(search: true, artist: true);

  @override
  String get displayName => '酷我音乐';

  @override
  Future<void> init() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<SearchResult<Track>> search(
    SearchQuery query, {
    CancelToken? cancel,
  }) async => const SearchResult(items: []);

  @override
  Future<SearchResult<ArtistSummary>> searchArtists(
    SearchQuery query, {
    CancelToken? cancel,
  }) async => SearchResult(
    items: [ArtistSummary(id: 'artist-1', name: '歌手一号')],
    total: 1,
  );

  @override
  Future<SearchResult<LyricHit>> searchLyrics(
    SearchQuery query, {
    CancelToken? cancel,
  }) async => const SearchResult(items: []);

  @override
  Future<PlayableStream> resolve(
    Track track, {
    AudioQuality? preferredQuality,
    Duration? timeout,
  }) async => PlayableStream(Uri.parse('https://cdn.example/${track.id.uri}'));

  @override
  Future<LyricsDoc?> lyrics(Track track) async => null;

  @override
  Future<Artwork?> artwork(Track track) async => null;

  @override
  Future<CommentPage> comments(
    Track track, {
    required CommentKind kind,
    int page = 1,
    int limit = 20,
  }) async => CommentPage.fromPage(
    kind: kind,
    items: const [],
    page: page,
    limit: limit,
    total: 0,
  );

  @override
  Future<CollectionPage> collection(
    CollectionRef ref, {
    int page = 1,
    int limit = 50,
  }) async => const CollectionPage();

  @override
  Track? adopt(Track track) => null;
}

class _FakeRegistry implements SourceRegistry {
  _FakeRegistry(this._sources, this.descriptors);

  final Map<String, MusicSource> _sources;

  @override
  final List<domain.SourceDescriptor> descriptors;

  @override
  Set<String> get enabledChannelKeys => {
    for (final descriptor in descriptors)
      if (descriptor.enabled) descriptor.key,
  };

  @override
  List<String> get orderedChannelKeys => [
    for (final descriptor in descriptors) descriptor.key,
  ];

  @override
  MusicSource? byKey(String key) => _sources[key];

  @override
  MusicSource? forTrack(Track track) => _sources[track.id.sourceKey];

  @override
  Future<void> refresh() async {}

  @override
  Future<void> setOrder(List<String> keys) async {}

  @override
  Stream<void> get changes => const Stream.empty();
}

class _FakeArtistRepository implements ArtistRepository {
  @override
  Future<ArtistDetail> loadArtistPage(
    String sourceKey,
    String artistId, {
    int page = 1,
    int limit = kArtistPageSize,
  }) async => const ArtistDetail(id: 'artist-1', name: '歌手一号');
}

class _FakeSources extends SourcesProvider {
  _FakeSources() : super(SourceManager(settings: testSettingsRegistry()));

  @override
  bool get initialized => true;

  @override
  List<SourceDescriptor> get channels => const [
    SourceDescriptor(
      key: 'kw',
      displayName: '酷我音乐',
      kind: SourceKind.builtin,
      discoverable: true,
      capabilities: SourceCapabilities(search: true, artist: true),
    ),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('遮罩歌手行打开歌手页，不再落到「查看全部结果」', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final playback = buildTestPlaybackProvider(facade: FakePlaybackFacade());
    addTearDown(playback.dispose);
    final selection = ChannelSelection(
      validKeys: () => const ['kw'],
      defaultKey: () => 'kw',
    );
    addTearDown(selection.dispose);
    final registry = _FakeRegistry(
      {'kw': _FakeMusicSource('kw')},
      const [
        SourceDescriptor(
          key: 'kw',
          displayName: '酷我音乐',
          kind: SourceKind.builtin,
          capabilities: SourceCapabilities(search: true, artist: true),
        ),
      ],
    );
    final search = SearchProvider(
      playback,
      selection: selection,
      catalogService: CatalogService(registry: registry),
      sourceRegistry: registry,
    );
    addTearDown(search.dispose);
    final sources = _FakeSources();
    addTearDown(sources.dispose);
    final controller = GlobalSearchController();
    addTearDown(controller.dispose);
    var viewAllCalls = 0;

    final scope = ProviderTestScope();
    scope.put<SearchProvider>(search);
    scope.put<SourcesProvider>(sources);
    scope.put<ChannelSelection>(selection);
    scope.put<ArtistRepository>(_FakeArtistRepository());
    await tester.pumpWidget(
      scope.wrap(
        M3EMaterialApp(
          data: M3EThemeData.fromMaterial(ThemeData.light()),
          theme: ThemeData.light(),
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: Scaffold(
            body: Center(
              child: GlobalSearchOverlay(
                controller: controller,
                onViewAllResults: () => viewAllCalls++,
              ),
            ),
          ),
        ),
      ),
    );

    controller.focus();
    await tester.pumpAndSettle();
    expect(find.byType(ChannelSearchBar), findsOneWidget);

    await tester.enterText(find.byType(EditableText), '周杰伦');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    final l10n = lookupAppLocalizations(const Locale('zh'));
    await tester.tap(find.text(l10n.searchKindArtists));
    await tester.pumpAndSettle();
    expect(find.text('歌手一号'), findsOneWidget);

    await tester.tap(find.text('歌手一号'));
    await tester.pumpAndSettle();

    expect(viewAllCalls, 0, reason: '歌手行不应再走「查看全部结果」');
    expect(find.byType(ArtistPage), findsOneWidget);
    expect(
      find.byType(ChannelSearchBar),
      findsNothing,
      reason: '歌手页出现时遮罩必须已经关闭',
    );
  });
}
