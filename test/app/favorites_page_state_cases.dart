import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/favorites/favorites_page.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/cover_test_support.dart';
import '../support/fake_library_repository.dart';
import '../support/fakes.dart';

/// 可门控的仓库：命中 `gatedPlaylistId` 的曲目读取会挂起到 [release]，
/// 用来观察「加载中」这一帧。
class _GatedRepository extends FakeLibraryRepository {
  int? gatedPlaylistId;
  Completer<void>? _gate;

  @override
  Future<List<PlaylistTrack>> listPlaylistTracks(
    int playlistId, {
    int? limit,
  }) async {
    if (playlistId == gatedPlaylistId) {
      _gate ??= Completer<void>();
      await _gate!.future;
    }
    return super.listPlaylistTracks(playlistId, limit: limit);
  }

  void release() {
    gatedPlaylistId = null;
    _gate?.complete();
    _gate = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _GatedRepository repository;
  late LibraryProvider library;
  late PlaybackProvider playback;
  late int favoritesId;
  late int otherId;

  PlaylistTrack track(int playlistId, String songId, String title) =>
      PlaylistTrack(
        playlistId: playlistId,
        sourceKey: 'test',
        songId: songId,
        title: title,
        artist: 'Artist',
        durationMs: 180000,
        addedAt: DateTime.now().millisecondsSinceEpoch,
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repository = _GatedRepository();
    favoritesId = await repository.createPlaylist('__favorites__');
    await repository.addTracksToPlaylist(favoritesId, [
      track(favoritesId, 'fav-0', 'Favorites Track 0'),
    ], favoriteChange: true);
    otherId = await repository.createPlaylist('Gated List');
    await repository.addTracksToPlaylist(otherId, [
      track(otherId, 'other-0', 'Other Track 0'),
    ]);

    playback = buildTestPlaybackProvider(facade: FakePlaybackFacade());
    library = LibraryProvider(
      repository: repository,
      playbackProvider: playback,
    );
    await playback.preferencesReady;
    await library.refreshPlaylists();
  });

  tearDown(() {
    library.dispose();
    playback.dispose();
    repository.dispose();
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    Size size = const Size(700, 1000),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          coverStoreProvider(),
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
          home: const Scaffold(body: FavoritesPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('同合集刷新：保留旧行 + 顶部细进度，不闪居中 spinner', (tester) async {
    await pumpPage(tester);
    expect(find.text('Favorites Track 0'), findsOneWidget);

    repository.gatedPlaylistId = favoritesId;
    library.ensurePlaylistTracks(favoritesId, force: true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.text('Favorites Track 0'), findsOneWidget);
    expect(find.byKey(const Key('favoritesRefreshProgress')), findsOneWidget);
    expect(find.byType(M3ELoadingIndicator), findsNothing);

    repository.release();
    await tester.pumpAndSettle();
    expect(find.text('Favorites Track 0'), findsOneWidget);
    expect(find.byKey(const Key('favoritesRefreshProgress')), findsNothing);
  });

  testWidgets('切到别的合集：不复用旧合集行，首帧给居中 spinner', (tester) async {
    await pumpPage(tester);
    expect(find.text('Favorites Track 0'), findsOneWidget);

    repository.gatedPlaylistId = otherId;
    await tester.tap(find.byKey(const Key('favoritesTitleSwitcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gated List'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Favorites Track 0'), findsNothing);
    expect(find.text('Other Track 0'), findsNothing);
    expect(find.byType(M3ELoadingIndicator), findsOneWidget);

    repository.release();
    await tester.pumpAndSettle();
    expect(find.text('Other Track 0'), findsOneWidget);
  });

  testWidgets('360 宽多选栏：三位数计数省略而不溢出', (tester) async {
    await repository.addTracksToPlaylist(favoritesId, [
      for (var i = 1; i < 120; i++)
        track(favoritesId, 'fav-$i', 'Favorites Track $i'),
    ], favoriteChange: true);
    library.ensurePlaylistTracks(favoritesId, force: true);
    await pumpPage(tester, size: const Size(360, 900));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Favorites Track 0'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('collectionSelectionSelectAll')));
    await tester.pump(const Duration(milliseconds: 300));

    final l10n = lookupAppLocalizations(const Locale('zh'));
    expect(find.text(l10n.selectionCountSelected(120)), findsOneWidget);
    expect(find.byKey(const Key('collectionSelectionCount')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
