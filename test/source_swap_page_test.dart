import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/source_swap_provider.dart';
import 'package:molia/pages/source_swap_page.dart';
import 'package:molia/providers/lyrics_provider.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_library_repository.dart';
import 'support/fake_music_source.dart';
import 'support/fakes.dart';

/// 换源页（音频 tab）：候选渲染 / 试听 / 原位替换 / 重复确认 / 空态与失败重试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeLibraryRepository repository;
  late FakePlaybackBackend backend;
  late PlaybackProvider playback;
  late LibraryProvider library;
  late FakeMusicSource kg;
  late FakeMusicSource tx;
  late Map<String, FakeMusicSource> sources;
  late SourceSwapProvider swap;
  late LyricsProvider lyricsProvider;

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
    tx = FakeMusicSource('tx');
    sources = {'kg': kg, 'tx': tx};
    swap = SourceSwapProvider(
      catalogService: CatalogService(registry: FakeSourceRegistry(sources)),
      sourceRegistry: FakeSourceRegistry(sources),
      libraryProvider: library,
      playbackProvider: playback,
    );
    lyricsProvider = LyricsProvider();
  });

  tearDown(() async {
    lyricsProvider.dispose();
    swap.dispose();
    library.dispose();
    playback.dispose();
    await repository.dispose();
  });

  Track sourceTrack(String sourceKey, String id, {String title = 'Title'}) =>
      Track(
        id: TrackId(sourceKey, id),
        title: title,
        artists: [Artist(name: 'Artist')],
        album: 'Album',
        duration: const Duration(minutes: 3),
        origin: TrackOrigin.builtin,
        payload: {'songmid': id, 'source': sourceKey},
      );

  Future<int> seedPlaylist(WidgetTester tester, {bool withDuplicate = false}) async {
    final playlistId = await repository.createPlaylist('L');
    await repository.addTrackToPlaylist(
      playlistId,
      PlaylistTrack(
        playlistId: playlistId,
        sourceKey: 'wy',
        songId: '1',
        title: 'Title',
        artist: 'Artist',
        raw: const {'songmid': 1},
        addedAt: 1,
      ),
    );
    if (withDuplicate) {
      await repository.addTrackToPlaylist(
        playlistId,
        PlaylistTrack(
          playlistId: playlistId,
          sourceKey: 'kg',
          songId: '100',
          title: 'Title（kg）',
          artist: 'Artist',
          raw: const {'hash': 'h100'},
          addedAt: 2,
        ),
      );
    }
    return playlistId;
  }

  Future<void> pumpHost(
    WidgetTester tester, {
    required Track seed,
    int? playlistId,
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
                  onPressed: () => showSourceSwapPage(
                    context,
                    seed: seed,
                    lyricsProvider: lyricsProvider,
                    playlistId: playlistId,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openPage(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> flushLibraryReloads(WidgetTester tester) async {
    await tester.runAsync(() async {
      await library.pendingReload;
    });
    await tester.pumpAndSettle();
  }

  testWidgets('渲染候选 → 试听 → 确认：列表原位替换并提示', (tester) async {
    final playlistId = await seedPlaylist(tester);
    final seed = library.trackFromPlaylistTrack(
      (await repository.listPlaylistTracks(playlistId)).single,
    );
    kg.items = [sourceTrack('kg', '100', title: 'Title（kg）')];

    await pumpHost(tester, seed: seed, playlistId: playlistId);
    await openPage(tester);

    // 头部 + 音源 chip（tx 无结果不产生分组）+ 候选行。
    expect(find.text('换源'), findsWidgets);
    expect(find.byType(M3EChip), findsOneWidget);
    expect(find.text('kg'), findsOneWidget);
    expect(find.text('Title（kg）'), findsOneWidget);

    // 点候选 = 选中 + 立即试听（单曲「换源试听」上下文）。
    await tester.tap(find.text('Title（kg）'));
    await tester.pumpAndSettle();
    expect(backend.calls, contains('load'));
    expect(backend.lastRequest?.context?.name, '换源试听');
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);

    await tester.tap(find.widgetWithText(M3EButton, '换源'));
    await tester.pumpAndSettle();
    expect(find.text('已换源'), findsOneWidget);
    expect(swap.hasSession, isFalse);

    await flushLibraryReloads(tester);
    final tracks = await repository.listPlaylistTracks(playlistId);
    expect(tracks.single.sourceKey, 'kg');
    expect(tracks.single.songId, '100');
  });

  testWidgets('目标已存在：先弹重复确认，确认后去重替换', (tester) async {
    final playlistId = await seedPlaylist(tester, withDuplicate: true);
    final seed = library.trackFromPlaylistTrack(
      (await repository.listPlaylistTracks(playlistId)).first,
    );
    kg.items = [sourceTrack('kg', '100', title: 'Title（kg）')];

    await pumpHost(tester, seed: seed, playlistId: playlistId);
    await openPage(tester);
    await tester.tap(find.text('Title（kg）'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(M3EButton, '换源'));
    await tester.pumpAndSettle();
    expect(find.text('曲目已存在'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byType(M3EDialog),
        matching: find.widgetWithText(M3EButton, '换源'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已换源'), findsOneWidget);

    await flushLibraryReloads(tester);
    final tracks = await repository.listPlaylistTracks(playlistId);
    expect(tracks.map((t) => '${t.sourceKey}:${t.songId}'), ['kg:100']);
  });

  testWidgets('没有其它可搜索音源：空态 + 确认禁用', (tester) async {
    final playlistId = await seedPlaylist(tester);
    final seed = library.trackFromPlaylistTrack(
      (await repository.listPlaylistTracks(playlistId)).single,
    );
    sources
      ..clear()
      ..['wy'] = FakeMusicSource('wy');

    await pumpHost(tester, seed: seed, playlistId: playlistId);
    await openPage(tester);

    expect(find.text('没有可用的其它音源'), findsOneWidget);
    final confirm = tester.widget<M3EButton>(
      find.widgetWithText(M3EButton, '换源'),
    );
    expect(confirm.onPressed, isNull);
  });

  testWidgets('全部无结果：空态提示；失败源可重试', (tester) async {
    final playlistId = await seedPlaylist(tester);
    final seed = library.trackFromPlaylistTrack(
      (await repository.listPlaylistTracks(playlistId)).single,
    );
    kg.fail = true;

    await pumpHost(tester, seed: seed, playlistId: playlistId);
    await openPage(tester);

    expect(find.text('其它音源没有找到这首歌'), findsOneWidget);
    expect(find.text('1 个音源搜索失败'), findsOneWidget);

    // 重试：失败源恢复后候选出现。
    kg.fail = false;
    kg.items = [sourceTrack('kg', '100', title: 'Title（kg）')];
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('Title（kg）'), findsOneWidget);
    expect(find.text('1 个音源搜索失败'), findsNothing);
  });
}
