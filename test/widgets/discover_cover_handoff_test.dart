import 'dart:async';

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
import 'package:molia/widgets/discover_leaderboards_tab.dart';
import 'package:molia/widgets/discover_playlists_tab.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/cover_test_support.dart';
import '../support/fake_discover_api.dart';
import '../support/fake_library_repository.dart';
import '../support/fakes.dart';

/// 发现详情页：加载骨架与封面共享元素（Hero）的端到端契约。
///
/// 只断言「骨架出现 / 消失」和「两端 tag 一致」这两条不变量，不锁帧、
/// 不依赖动画中间态：Hero 的几何 / 时长由框架负责，回归点是入口忘了传
/// tag、或加载态把目标端封面整个吞掉。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeLibraryRepository repository;
  late FakePlaybackFacade backend;
  late PlaybackProvider playback;
  late LibraryProvider library;
  late ChannelSelection selection;
  late FakeDiscoverSource source;
  late DiscoverProvider discover;

  setUp(() {
    // PlaybackProvider 启动后会从偏好恢复上次播放；widget 测试没有插件，
    // 给出内存实现避免异步 MissingPluginException 落到测试收尾之后。
    SharedPreferences.setMockInitialValues({});
    repository = FakeLibraryRepository();
    backend = FakePlaybackFacade();
    playback = buildTestPlaybackProvider(
      facade: backend,
      libraryRepository: repository,
    );
    library = LibraryProvider(
      repository: repository,
      playbackProvider: playback,
    );
    source = FakeDiscoverSource();
    selection = ChannelSelection(
      validKeys: () => const ['wy'],
      defaultKey: () => 'wy',
      initialKey: 'wy',
    );
    discover = DiscoverProvider(
      playbackProvider: playback,
      libraryProvider: library,
      selection: selection,
      sources: {'wy': source},
    );
  });

  tearDown(() async {
    discover.dispose();
    selection.dispose();
    library.dispose();
    playback.dispose();
    await repository.dispose();
  });

  Widget host(Widget home) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<DiscoverProvider>.value(value: discover),
        // 曲目行里的 TrackArtwork 从 Provider 取封面存储（组合根接线）；
        // widget 测试也要补上，否则加载完成后行构建直接抛 Provider 缺失。
        coverStoreProvider(),
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
        home: home,
      ),
    );
  }

  Finder heroWithTag(Object tag) =>
      find.byWidgetPredicate((widget) => widget is Hero && widget.tag == tag);

  const track = DiscoverTrack(
    sourceKey: 'wy',
    songId: '111',
    title: '歌曲A',
    artist: '歌手',
    album: '专辑',
    durationMs: 245000,
    raw: {'songmid': 111, 'source': 'wy'},
  );

  testWidgets('首屏显示骨架，加载完成后骨架消失且 Hero 标签保持', (tester) async {
    final loader = Completer<DiscoverDetail>();
    const tag = 'discover-test-cover';

    await tester.pumpWidget(
      host(
        DiscoverTracksPage(
          title: '热歌榜',
          coverHeroTag: tag,
          loader: (_) => loader.future,
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('discoverTracksSkeleton')), findsOneWidget);
    expect(heroWithTag(tag), findsOneWidget, reason: '骨架头部必须承担 Hero 目标端');
    expect(
      tester.widget<Hero>(heroWithTag(tag)).transitionOnUserGestures,
      isTrue,
      reason: 'Android 预测返回属于 user gesture，未开启则回退不飞封面',
    );

    loader.complete(
      const DiscoverDetail(
        info: DiscoverPlaylist(id: 'wy__3778678', name: '热歌榜'),
        tracks: [track],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('discoverTracksSkeleton')), findsNothing);
    expect(find.text('歌曲A'), findsOneWidget);
    expect(heroWithTag(tag), findsOneWidget, reason: '加载完成后同一 tag 落到详情头部');
  });

  testWidgets('歌单卡片与详情页使用同一个封面 Hero 标签', (tester) async {
    await tester.pumpWidget(host(const Scaffold(body: DiscoverPlaylistsTab())));
    await tester.pumpAndSettle();

    final sourceHero = tester
        .widgetList<Hero>(find.byType(Hero))
        .where(
          (hero) => hero.tag.toString().startsWith('discover-playlist-cover:'),
        )
        .single;
    expect(sourceHero.tag.toString(), contains('wy'));
    expect(sourceHero.transitionOnUserGestures, isTrue);

    await tester.tap(find.text('测试歌单'));
    await tester.pumpAndSettle();

    expect(find.byType(DiscoverTracksPage), findsOneWidget);
    expect(heroWithTag(sourceHero.tag), findsOneWidget);
    expect(
      tester.widget<Hero>(heroWithTag(sourceHero.tag)).transitionOnUserGestures,
      isTrue,
    );
  });

  testWidgets('榜单磁贴与详情页使用同一个封面 Hero 标签', (tester) async {
    source
      ..leaderboardCoverUrl = null
      ..coverlessLeaderboardTracks = true;

    await tester.pumpWidget(
      host(const Scaffold(body: DiscoverLeaderboardsTab())),
    );
    await tester.pumpAndSettle();

    final sourceHero = tester
        .widgetList<Hero>(find.byType(Hero))
        .where(
          (hero) =>
              hero.tag.toString().startsWith('discover-leaderboard-cover:'),
        )
        .single;
    expect(sourceHero.transitionOnUserGestures, isTrue);

    await tester.tap(find.text('热歌榜'));
    await tester.pumpAndSettle();

    expect(find.byType(DiscoverTracksPage), findsOneWidget);
    expect(heroWithTag(sourceHero.tag), findsOneWidget);
    expect(
      tester.widget<Hero>(heroWithTag(sourceHero.tag)).transitionOnUserGestures,
      isTrue,
    );
  });
}
