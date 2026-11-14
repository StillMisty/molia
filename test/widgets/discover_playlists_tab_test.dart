import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/domain/models/discover.dart';
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

/// 发现 › 歌单：打开歌单在搜索栏尾部，有文本时让位给清除键；标签行首 chip
/// 展示当前筛选并可一键清空，空分类不渲染标题。
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

  testWidgets('搜索栏尾部：空输入打开歌单，有文本换成清除键', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('discoverOpenPlaylist')), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsNothing);

    await tester.enterText(find.byType(M3ESearchBar), '华语');
    await tester.pump();
    expect(find.byKey(const Key('discoverOpenPlaylist')), findsNothing);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('discoverOpenPlaylist')), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsNothing);
  });

  testWidgets('选中标签显性化并可一键清除', (tester) async {
    final l10n = lookupAppLocalizations(const Locale('zh'));
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.text(l10n.discoverTags), findsOneWidget);
    expect(find.text('华语'), findsOneWidget);

    await tester.tap(find.text('华语'));
    await tester.pumpAndSettle();

    // 行首 chip 换成当前标签名，热门行不再重复同一个标签。
    final chip = find.byKey(const Key('discoverTagFilter'));
    expect(find.text(l10n.discoverTags), findsNothing);
    expect(find.text('华语'), findsOneWidget);
    expect(
      find.descendant(of: chip, matching: find.text('华语')),
      findsOneWidget,
    );

    final remove = find.descendant(
      of: chip,
      matching: find.byIcon(M3EIcons.close),
    );
    expect(remove, findsOneWidget);
    await tester.tap(remove);
    await tester.pumpAndSettle();

    expect(find.text(l10n.discoverTags), findsOneWidget);
    expect(find.text('华语'), findsOneWidget);
    expect(find.byIcon(M3EIcons.close), findsNothing);
  });

  testWidgets('标签弹层不渲染空分类', (tester) async {
    source.tagsOverride = const DiscoverTags(
      hotTags: [],
      categories: [
        DiscoverTagCategory(name: '语种', tags: []),
        DiscoverTagCategory(
          name: '风格',
          tags: [DiscoverTag(id: '流行', name: '流行')],
        ),
      ],
    );
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('discoverTagFilter')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('discoverAllTagsChip')), findsOneWidget);
    expect(find.text('语种'), findsNothing);
    expect(find.text('风格'), findsOneWidget);
    expect(find.text('流行'), findsOneWidget);
  });

  testWidgets('没有任何标签时隐藏标签行', (tester) async {
    source.tagsOverride = const DiscoverTags();
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('discoverTagFilter')), findsNothing);
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
