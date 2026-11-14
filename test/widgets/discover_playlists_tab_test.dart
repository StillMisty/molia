import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/channel_selection.dart';
import 'package:molia/providers/discover_provider.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/discover_playlists_tab.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/cover_test_support.dart';
import '../support/fake_discover_api.dart';
import '../support/fake_library_repository.dart';
import '../support/fakes.dart';

/// 发现 › 歌单：搜索栏不再挂「打开歌单」，「全部 / 全部标签」合并成一个
/// 「标签」入口（清空筛选在弹层里的「全部」）。
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

  Widget host() {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<DiscoverProvider>.value(value: discover),
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
        home: const Scaffold(body: DiscoverPlaylistsTab()),
      ),
    );
  }

  testWidgets('打开歌单移出搜索栏，收进标签行溢出', (tester) async {
    final l10n = lookupAppLocalizations(const Locale('zh'));
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    // 搜索栏尾部不再有链接图标。
    expect(find.byIcon(Icons.link_rounded), findsNothing);
    expect(find.byKey(const Key('discoverPlaylistsOverflow')), findsOneWidget);

    await tester.tap(find.byKey(const Key('discoverPlaylistsOverflow')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.discoverOpenPlaylist), findsOneWidget);
  });

  testWidgets('全部 / 全部标签合并为一个标签 chip', (tester) async {
    final l10n = lookupAppLocalizations(const Locale('zh'));
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('discoverTagFilter')), findsOneWidget);
    expect(find.text(l10n.discoverTags), findsOneWidget);
    expect(find.text(l10n.discoverAll), findsNothing);
    expect(find.text(l10n.discoverAllTags), findsNothing);

    await tester.tap(find.byKey(const Key('discoverTagFilter')));
    await tester.pumpAndSettle();
    // 弹层标题仍是「全部标签」，「全部」清空筛选也在里面。
    expect(find.text(l10n.discoverAllTags), findsOneWidget);
    expect(find.byKey(const Key('discoverAllTagsChip')), findsOneWidget);
  });
}
