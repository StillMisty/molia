import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/domain/models/discover.dart';
import 'package:molia/domain/models/source.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/library.dart';
import 'package:molia/providers/channel_selection.dart';
import 'package:molia/providers/discover_provider.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/sources_provider.dart';
import 'package:molia/sources/builtin/discover_source.dart';
import 'package:molia/sources/source_manager.dart' hide SourceKind;
import 'package:molia/widgets/adaptive_layout.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_library_repository.dart';
import '../support/fakes.dart';
import '../support/settings_test_support.dart';

class _FakeDiscoverSource extends DiscoverSource {
  @override
  String get sourceKey => 'kw';

  @override
  List<DiscoverLeaderboard> get leaderboards => const [
    DiscoverLeaderboard(id: 'kw__1', name: '飙升榜', bangid: '1'),
  ];

  @override
  Future<List<DiscoverTrack>> leaderboardTracks(String bangid) async =>
      const [];

  @override
  Future<DiscoverTags> tags() async => const DiscoverTags();

  @override
  Future<DiscoverPlaylistPage> playlists(String tagId, int page) async =>
      const DiscoverPlaylistPage(playlists: [], page: 1, limit: 20);

  @override
  Future<DiscoverPlaylistPage> searchPlaylists(
    String keyword,
    int page,
  ) async => const DiscoverPlaylistPage(playlists: [], page: 1, limit: 20);

  @override
  Future<DiscoverDetail> playlistDetail(String rawId, int page) async =>
      const DiscoverDetail(
        info: DiscoverPlaylist(
          id: '',
          name: '',
          author: '',
          playCount: 0,
          trackCount: 0,
        ),
        tracks: [],
      );

  @override
  Future<List<String>> hotSearches() async => const [];
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
    ),
  ];

  @override
  String get preferredQuality => '320k';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSources sources;
  late DiscoverProvider discover;
  late ChannelSelection selection;
  late PlaybackProvider playback;
  late LibraryProvider library;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sources = _FakeSources();
    selection = ChannelSelection(
      validKeys: () => const ['kw'],
      defaultKey: () => 'kw',
    );
    final repo = FakeLibraryRepository();
    playback = buildTestPlaybackProvider(
      facade: FakePlaybackFacade(),
      libraryRepository: repo,
    );
    library = LibraryProvider(repository: repo, playbackProvider: playback);
    discover = DiscoverProvider(
      playbackProvider: playback,
      libraryProvider: library,
      selection: selection,
      sources: {'kw': _FakeDiscoverSource()},
    );
  });

  tearDown(() {
    discover.dispose();
    library.dispose();
    playback.dispose();
    selection.dispose();
    sources.dispose();
  });

  Future<void> pump(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SourcesProvider>.value(value: sources),
          ChangeNotifierProvider<DiscoverProvider>.value(value: discover),
          ChangeNotifierProvider<ChannelSelection>.value(value: selection),
          ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
          ChangeNotifierProvider<LibraryProvider>.value(value: library),
        ],
        child: M3EMaterialApp(
          data: M3EThemeData.fromMaterial(ThemeData.light()),
          theme: ThemeData.light(),
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: AdaptiveLayoutScope(
            layout: AdaptiveLayout.fromWidth(width),
            child: const Scaffold(body: Library()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('expanded 浏览 tab 出左栏，选择只更新右栏', (tester) async {
    await pump(tester, 900);
    expect(find.byKey(const Key('libraryBrowseSplit')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('libraryBrowsePane-leaderboards')),
      findsOneWidget,
    );
    expect(find.text('飙升榜'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('libraryBrowsePane-playlists')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('libraryBrowseSplit')), findsOneWidget);
    expect(find.text('飙升榜'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('libraryBrowsePane-playlists')),
      findsOneWidget,
    );
  });

  testWidgets('medium 保持单栏', (tester) async {
    await pump(tester, 700);
    expect(find.byKey(const Key('libraryBrowseSplit')), findsNothing);
    expect(find.text('飙升榜'), findsOneWidget);
  });
}
