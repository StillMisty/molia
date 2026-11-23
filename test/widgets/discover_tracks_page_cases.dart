import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/domain/models/discover.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/discover_tracks_page.dart';
import 'package:molia/providers/channel_selection.dart';
import 'package:molia/providers/discover_provider.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/paged_track_collection.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/cover_test_support.dart';
import '../support/provider_test_scope.dart';
import '../support/fake_discover_api.dart';
import '../support/fake_library_repository.dart';
import '../support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlaybackFacade backend;
  late PlaybackProvider playback;
  late LibraryProvider library;
  late ChannelSelection selection;
  late DiscoverProvider discover;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    backend = FakePlaybackFacade();
    final repository = FakeLibraryRepository();
    playback = buildTestPlaybackProvider(
      facade: backend,
      libraryRepository: repository,
    );
    library = LibraryProvider(
      repository: repository,
      playbackProvider: playback,
    );
    selection = ChannelSelection(
      validKeys: () => const ['wy'],
      defaultKey: () => 'wy',
    );
    discover = DiscoverProvider(
      playbackProvider: playback,
      libraryProvider: library,
      selection: selection,
      sources: {'wy': FakeDiscoverSource()},
    );
  });

  tearDown(() {
    discover.dispose();
    selection.dispose();
    library.dispose();
    playback.dispose();
  });

  Future<void> pumpPage(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final scope = ProviderTestScope();
    scope.put<DiscoverProvider>(discover);
    putCoverStore(scope);
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
          home: DiscoverTracksPage(
            title: '测试歌单',
            loader: (page) async => const DiscoverDetail(
              info: DiscoverPlaylist(
                id: 'p1',
                name: '测试歌单',
                author: '作者',
                trackCount: 1,
              ),
              tracks: [
                DiscoverTrack(
                  sourceKey: 'wy',
                  songId: '1',
                  title: '歌曲A',
                  artist: '歌手',
                  album: '专辑',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('1600 宽正文按 detail 上限收口', (tester) async {
    await pumpPage(tester, 1600);

    final body = find.byType(PagedTrackCollectionBody<DiscoverTrack>);
    expect(body, findsOneWidget);
    expect(
      tester.getSize(body).width,
      lessThanOrEqualTo(1080.0),
      reason: 'detail 版式桌面档上限是 1080，正文不应横跨整窗',
    );
  });

  testWidgets('窄屏保持全宽', (tester) async {
    await pumpPage(tester, 500);

    final body = find.byType(PagedTrackCollectionBody<DiscoverTrack>);
    expect(tester.getSize(body).width, 500.0);
  });
}
