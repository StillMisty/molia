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
import 'package:molia/widgets/app_search_bar.dart';
import 'package:molia/widgets/source_swap/source_swap_chrome.dart';
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

  Future<int> seedPlaylist(
    WidgetTester tester, {
    bool withDuplicate = false,
  }) async {
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

    // 曲目条 + 全部/音源 chip（tx 无结果不产生分组）+ 候选行。
    expect(find.text('换源'), findsWidgets);
    expect(find.byType(M3EChip), findsNWidgets(3), reason: '全部 + kg + tx');
    expect(
      find.byKey(const ValueKey('sourceSwapSourceChip-all')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('sourceSwapSourceChip-kg')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('sourceSwapSourceChip-tx')),
      findsOneWidget,
      reason: '没有结果的来源仍可筛选',
    );
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

  testWidgets('库内写失败：提示操作失败，留在弹层且不跟队列', (tester) async {
    final playlistId = await seedPlaylist(tester);
    final seed = library.trackFromPlaylistTrack(
      (await repository.listPlaylistTracks(playlistId)).single,
    );
    kg.items = [sourceTrack('kg', '100', title: 'Title（kg）')];

    await pumpHost(tester, seed: seed, playlistId: playlistId);
    await openPage(tester);
    await tester.tap(find.text('Title（kg）'));
    await tester.pumpAndSettle();

    repository.failTrackWrites = true;
    await tester.tap(find.widgetWithText(M3EButton, '换源'));
    await tester.pumpAndSettle();

    expect(find.text('操作失败'), findsOneWidget);
    expect(find.text('已换源'), findsNothing);
    expect(swap.hasSession, isTrue, reason: '失败留在换源页，可重试或改选');
    expect(find.text('Title（kg）'), findsOneWidget);
    expect(backend.lastReplacedTrackUri, isNull, reason: '库内写失败不跟随队列');
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
    // 确认按钮忙碌态是常驻 spinner：不能用 pumpAndSettle（永远不落定）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('曲目已存在'), findsOneWidget);

    // 确认流程（含去重追问）期间锁住搜索与来源切换。
    final field = tester.widget<AppSearchBar>(
      find.descendant(
        of: find.byKey(const Key('sourceSwapSearchFieldAudio')),
        matching: find.byType(AppSearchBar),
      ),
    );
    expect(field.enabled, isFalse);
    expect(
      tester
          .widget<M3EChip>(
            find.byKey(const ValueKey('sourceSwapSourceChip-kg')),
          )
          .onPressed,
      isNull,
    );

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

  testWidgets('没有任何可搜索音源：只留空态，搜索栏/chips/底栏都隐藏', (tester) async {
    final playlistId = await seedPlaylist(tester);
    final seed = library.trackFromPlaylistTrack(
      (await repository.listPlaylistTracks(playlistId)).single,
    );
    sources.clear();

    await pumpHost(tester, seed: seed, playlistId: playlistId);
    await openPage(tester);

    expect(find.text('没有可用的音源'), findsOneWidget);
    expect(find.text('启用音源后，这里会列出可搜索的平台'), findsOneWidget);
    expect(find.byKey(const Key('sourceSwapSearchFieldAudio')), findsNothing);
    expect(
      find.byKey(const ValueKey('sourceSwapSourceChip-all')),
      findsNothing,
    );
    expect(find.byType(SourceSwapActionBar), findsNothing);
    expect(find.widgetWithText(M3EButton, '换源'), findsNothing);
  });

  testWidgets('非 B 站种子：原渠道保留为候选 chip', (tester) async {
    final playlistId = await seedPlaylist(tester);
    final seed = library.trackFromPlaylistTrack(
      (await repository.listPlaylistTracks(playlistId)).single,
    );
    final wy = FakeMusicSource('wy')
      ..items = [sourceTrack('wy', '2', title: 'Title（wy 其它版本）')];
    sources['wy'] = wy;
    kg.items = [sourceTrack('kg', '100', title: 'Title（kg）')];

    await pumpHost(tester, seed: seed, playlistId: playlistId);
    await openPage(tester);

    expect(
      find.byKey(const ValueKey('sourceSwapSourceChip-wy')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('sourceSwapSourceChip-kg')),
      findsOneWidget,
    );
    // 默认全部：两组都展示；切到原渠道只看该组。
    expect(find.text('Title（kg）'), findsOneWidget);
    expect(find.text('Title（wy 其它版本）'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sourceSwapSourceChip-wy')));
    await tester.pumpAndSettle();
    expect(find.text('Title（wy 其它版本）'), findsOneWidget);
    expect(find.text('Title（kg）'), findsNothing);
  });

  testWidgets('全部模式按来源分组，单源筛选只留该组', (tester) async {
    final playlistId = await seedPlaylist(tester);
    final seed = library.trackFromPlaylistTrack(
      (await repository.listPlaylistTracks(playlistId)).single,
    );
    kg.items = [sourceTrack('kg', '100', title: 'Title（kg）')];
    tx.items = [sourceTrack('tx', '200', title: 'Title（tx）')];

    await pumpHost(tester, seed: seed, playlistId: playlistId);
    await openPage(tester);

    expect(find.byKey(const ValueKey('sourceSwapSection-kg')), findsOneWidget);
    expect(find.byKey(const ValueKey('sourceSwapSection-tx')), findsOneWidget);
    expect(find.text('Title（kg）'), findsOneWidget);
    expect(find.text('Title（tx）'), findsOneWidget);
    expect(
      tester
          .widget<M3EChip>(
            find.byKey(const ValueKey('sourceSwapSourceChip-all')),
          )
          .selected,
      isTrue,
    );

    await tester.tap(find.byKey(const ValueKey('sourceSwapSourceChip-kg')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('sourceSwapSection-kg')), findsNothing);
    expect(find.text('Title（kg）'), findsOneWidget);
    expect(find.text('Title（tx）'), findsNothing);
    expect(swap.activeSourceKey, 'kg');
  });

  testWidgets('搜索栏预填默认关键词，提交后按新关键词重搜', (tester) async {
    final playlistId = await seedPlaylist(tester);
    final seed = library.trackFromPlaylistTrack(
      (await repository.listPlaylistTracks(playlistId)).single,
    );
    kg.items = [sourceTrack('kg', '100', title: 'Title（kg）')];

    await pumpHost(tester, seed: seed, playlistId: playlistId);
    await openPage(tester);

    final audioField = find.descendant(
      of: find.byKey(const Key('sourceSwapSearchFieldAudio')),
      matching: find.byType(AppSearchBar),
    );
    final field = tester.widget<AppSearchBar>(audioField);
    expect(field.controller.text, 'Title Artist');
    expect(kg.lastQuery?.keyword, 'Title Artist');

    await tester.enterText(
      find.byKey(const Key('sourceSwapSearchFieldAudio')),
      '晴天 周杰伦',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(swap.keyword, '晴天 周杰伦');
    expect(kg.lastQuery?.keyword, '晴天 周杰伦');
    expect(kg.searchCalls, 2);

    // 清空关键词：回到「输入后开始搜索」，不再显示「没有找到」。
    await tester.enterText(
      find.byKey(const Key('sourceSwapSearchFieldAudio')),
      '',
    );
    await tester.pumpAndSettle();
    expect(swap.keyword, isEmpty);
    expect(swap.groups, isEmpty);
    expect(find.text('输入歌名或歌手开始搜索'), findsOneWidget);
    expect(
      find.byKey(const Key('sourceSwapSearchFieldAudio')),
      findsOneWidget,
      reason: '关键词为空时搜索框仍可重新输入',
    );
    expect(
      find.byKey(const ValueKey('sourceSwapSourceChip-all')),
      findsNothing,
      reason: '无关键词时隐藏来源 chips',
    );
    expect(
      find.byType(SourceSwapActionBar),
      findsNothing,
      reason: '无关键词时隐藏底部操作条',
    );
  });

  testWidgets('全部无结果：空态提示；失败源可重试', (tester) async {
    final playlistId = await seedPlaylist(tester);
    final seed = library.trackFromPlaylistTrack(
      (await repository.listPlaylistTracks(playlistId)).single,
    );
    kg.fail = true;

    await pumpHost(tester, seed: seed, playlistId: playlistId);
    await openPage(tester);

    expect(find.text('没有找到这首歌'), findsOneWidget);
    expect(find.text('kg 搜索失败'), findsOneWidget);
    expect(
      find.byType(SourceSwapActionBar),
      findsNothing,
      reason: '有可见结果前不显示「点选一项后确认」',
    );
    expect(find.byKey(const Key('sourceSwapSearchFieldAudio')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('sourceSwapSourceChip-all')),
      findsOneWidget,
    );

    // 重试：失败源恢复后候选出现。
    kg.fail = false;
    kg.items = [sourceTrack('kg', '100', title: 'Title（kg）')];
    await tester.tap(find.byKey(const Key('sourceSwapRetryFailedAudio')));
    await tester.pumpAndSettle();
    expect(find.text('Title（kg）'), findsOneWidget);
    expect(find.text('kg 搜索失败'), findsNothing);
    expect(find.byType(SourceSwapActionBar), findsOneWidget);
  });

  testWidgets('6 个音源 chip 全部渲染（Wrap 换行，不用横向滚动）', (tester) async {
    final bili = FakeMusicSource('bili');
    sources
      ..clear()
      ..addAll({
        'kg': kg,
        'tx': tx,
        'kw': FakeMusicSource('kw'),
        'wy': FakeMusicSource('wy'),
        'mg': FakeMusicSource('mg'),
        'bili': bili,
      });
    for (final source in sources.values) {
      source.items = [sourceTrack(source.key, '1', title: 'T-${source.key}')];
    }
    // B 站种子允许同源候选，但要排除种子自身：返回另一条投稿。
    final seed = sourceTrack('bili', 'seed');
    bili.items = [sourceTrack('bili', '2', title: 'T-bili')];

    await pumpHost(tester, seed: seed);
    await openPage(tester);

    expect(find.byType(M3EChip), findsNWidgets(7), reason: '全部 + 6 个来源');
    for (final key in ['all', 'kg', 'tx', 'kw', 'wy', 'mg', 'bili']) {
      expect(
        find.byKey(ValueKey('sourceSwapSourceChip-$key')),
        findsOneWidget,
        reason: '$key 的音源 chip 应可见',
      );
    }
    // chip 行是换行布局（不是横向 ScrollView）。
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('sourceSwapSourceChip-bili')),
        matching: find.byType(Wrap),
      ),
      findsWidgets,
    );
  });
}
