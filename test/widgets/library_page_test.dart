import 'package:flutter/rendering.dart';
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
import 'package:molia/providers/search_provider.dart';
import 'package:molia/providers/sources_provider.dart';
import 'package:molia/sources/builtin/discover_source.dart';
import 'package:molia/sources/source_manager.dart' hide SourceKind;
import 'package:molia/widgets/adaptive_layout.dart';
import 'package:molia/widgets/channel_search_bar.dart';
import 'package:molia/widgets/library_channel_selector.dart';
import 'package:molia/widgets/shell_reselect.dart';
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

/// 两个可搜索渠道：搜索 tab 常显，顶部渠道选择必须始终只有一个。
///
/// 名称刻意含 5 个汉字：窄屏下曾因下拉弹层继承触发框宽度只剩「前两个字」。
class _SearchSources extends _FakeSources {
  @override
  List<SourceDescriptor> get channels => const [
    SourceDescriptor(
      key: 'kw',
      displayName: '网易音乐',
      kind: SourceKind.builtin,
      discoverable: true,
      capabilities: SourceCapabilities(search: true),
    ),
    SourceDescriptor(
      key: 'tx',
      displayName: 'QQ音乐',
      kind: SourceKind.builtin,
      capabilities: SourceCapabilities(search: true),
    ),
    SourceDescriptor(
      key: 'bili',
      displayName: '哔哩哔哩',
      kind: SourceKind.builtin,
      capabilities: SourceCapabilities(search: true),
    ),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSources sources;
  late DiscoverProvider discover;
  late ChannelSelection selection;
  late PlaybackProvider playback;
  late LibraryProvider library;
  late SearchProvider search;

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
    search = SearchProvider(playback, selection: selection);
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
    search.dispose();
    playback.dispose();
    selection.dispose();
    sources.dispose();
  });

  Future<void> pump(
    WidgetTester tester,
    double width, {
    SourcesProvider? sourcesOverride,
    ShellReselectSignal? reselect,
  }) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SourcesProvider>.value(
            value: sourcesOverride ?? sources,
          ),
          ChangeNotifierProvider<DiscoverProvider>.value(value: discover),
          ChangeNotifierProvider<ChannelSelection>.value(value: selection),
          ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
          ChangeNotifierProvider<LibraryProvider>.value(value: library),
          ChangeNotifierProvider<SearchProvider>.value(value: search),
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
            child: Scaffold(body: Library(reselect: reselect)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('expanded 浏览 tab 仍用顶部 tab，不再有侧栏', (tester) async {
    await pump(tester, 900);
    expect(find.byKey(const Key('libraryBrowseSplit')), findsNothing);
    expect(find.byType(M3ETabs), findsOneWidget);
    expect(find.text('飙升榜'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byType(M3ETabs),
        matching: find.byIcon(Icons.queue_music_rounded),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('飙升榜'), findsNothing);
    expect(find.byKey(const Key('libraryBrowseSplit')), findsNothing);
  });

  group('搜索入口', () {
    Finder tabIcon(IconData icon) =>
        find.descendant(of: find.byType(M3ETabs), matching: find.byIcon(icon));

    testWidgets('搜索条 hint 与胶囊垂直居中', (tester) async {
      final searchSources = _SearchSources();
      addTearDown(searchSources.dispose);
      await pump(tester, 900, sourcesOverride: searchSources);

      final hint = find.text('搜索歌曲、歌手或歌词');
      expect(hint, findsOneWidget);
      final bar = find.ancestor(of: hint, matching: find.byType(M3ECard)).first;
      final barRect = tester.getRect(bar);
      final hintRect = tester.getRect(hint);
      expect(
        (hintRect.center.dy - barRect.center.dy).abs(),
        lessThanOrEqualTo(1.0),
        reason: 'hint 必须在搜索胶囊内垂直居中',
      );
    });

    testWidgets('无 chip 搜索条：多渠道也不渲染条内下拉，清除键保留焦点', (tester) async {
      final controller = TextEditingController();
      final focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);
      await tester.pumpWidget(
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
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: ChannelSearchBar(
                controller: controller,
                focusNode: focusNode,
                hintText: '搜索歌曲、歌手或歌词',
                channels: const [
                  SourceDescriptor(
                    key: 'kw',
                    displayName: '酷我音乐',
                    kind: SourceKind.builtin,
                  ),
                  SourceDescriptor(
                    key: 'tx',
                    displayName: 'QQ音乐',
                    kind: SourceKind.builtin,
                  ),
                ],
                showChannelChip: false,
              ),
            ),
          ),
        ),
      );

      expect(find.byKey(ChannelSearchBar.channelPickerKey), findsNothing);
      expect(find.byType(M3ESearchBar), findsNothing);
      expect(find.byType(EditableText), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ChannelSearchBar),
          matching: find.byIcon(Icons.search_rounded),
        ),
        findsOneWidget,
        reason: '资料库搜索条保留搜索图标',
      );

      await tester.enterText(find.byType(EditableText), '晴天');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump();
      expect(controller.text, isEmpty);
      expect(focusNode.hasFocus, isTrue);
    });

    testWidgets('搜索 tab：顶部渠道选择常显，条内不重复，tab 宽度不跳', (tester) async {
      final searchSources = _SearchSources();
      addTearDown(searchSources.dispose);
      await pump(tester, 900, sourcesOverride: searchSources);

      // 默认就是搜索 tab：顶部下拉在，搜索条内没有第二个渠道控件。
      expect(find.byType(LibraryChannelSelector), findsOneWidget);
      expect(find.byKey(ChannelSearchBar.channelPickerKey), findsNothing);
      expect(find.byType(M3ESearchBar), findsNothing);

      final selectorRect = tester.getRect(find.byType(LibraryChannelSelector));
      final tabsRect = tester.getRect(find.byType(M3ETabs));

      await tester.tap(tabIcon(Icons.leaderboard_rounded));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(LibraryChannelSelector)), selectorRect);
      expect(tester.getRect(find.byType(M3ETabs)), tabsRect);

      await tester.tap(tabIcon(Icons.search_rounded));
      await tester.pumpAndSettle();
      expect(find.byType(LibraryChannelSelector), findsOneWidget);
      expect(find.byKey(ChannelSearchBar.channelPickerKey), findsNothing);
    });

    testWidgets('窄屏：渠道名在触发框与下拉弹层里都完整显示', (tester) async {
      final searchSources = _SearchSources();
      addTearDown(searchSources.dispose);
      await pump(tester, 360, sourcesOverride: searchSources);

      final trigger = find.byKey(LibraryChannelSelector.triggerKey);
      expect(trigger, findsOneWidget);

      final triggerText = find.descendant(
        of: trigger,
        matching: find.text('网易音乐'),
      );
      expect(
        tester.renderObject<RenderParagraph>(triggerText).didExceedMaxLines,
        isFalse,
        reason: '触发框不能再只剩「前两个字 + 省略号」',
      );

      await tester.tap(trigger);
      await tester.pumpAndSettle();

      for (final name in ['网易音乐', '哔哩哔哩', 'QQ音乐']) {
        final itemText = find.text(name).last;
        expect(
          tester.renderObject<RenderParagraph>(itemText).didExceedMaxLines,
          isFalse,
          reason: '$name 在下拉弹层里应完整显示',
        );
      }

      expect(
        find.byIcon(Icons.check_rounded),
        findsOneWidget,
        reason: '只有选中行显示勾，未选中行不预留右侧槽位',
      );

      await tester.tap(find.text('哔哩哔哩').last);
      await tester.pumpAndSettle();

      final selectedText = find.descendant(
        of: find.byKey(LibraryChannelSelector.triggerKey),
        matching: find.text('哔哩哔哩'),
      );
      expect(selectedText, findsOneWidget);
      expect(
        tester.renderObject<RenderParagraph>(selectedText).didExceedMaxLines,
        isFalse,
        reason: '切换后的渠道名也要完整显示',
      );
    });

    testWidgets('重复点击资料库：切回搜索 tab 并聚焦搜索框', (tester) async {
      final searchSources = _SearchSources();
      addTearDown(searchSources.dispose);
      final reselect = ShellReselectSignal();
      addTearDown(reselect.dispose);
      await pump(
        tester,
        900,
        sourcesOverride: searchSources,
        reselect: reselect,
      );

      await tester.tap(tabIcon(Icons.leaderboard_rounded));
      await tester.pumpAndSettle();
      expect(find.byType(EditableText), findsNothing);

      reselect.trigger();
      await tester.pumpAndSettle();

      final field = tester.widget<EditableText>(find.byType(EditableText));
      expect(field.focusNode.hasFocus, isTrue);
    });

    testWidgets('重复点击资料库：没有搜索 tab 时保持原语义（不聚焦）', (tester) async {
      final reselect = ShellReselectSignal();
      addTearDown(reselect.dispose);
      await pump(tester, 900, reselect: reselect);

      // 当前渠道不可搜索：搜索 tab 隐藏，仍停在浏览 tab。
      expect(find.byType(EditableText), findsNothing);
      reselect.trigger();
      await tester.pumpAndSettle();
      expect(find.byType(EditableText), findsNothing);
      expect(find.text('飙升榜'), findsOneWidget);
    });
  });
}
