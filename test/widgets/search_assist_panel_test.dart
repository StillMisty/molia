import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/domain/models/catalog.dart';
import 'package:molia/domain/models/source.dart' show SourceCapabilities;
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/channel_selection.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/search_assist_controller.dart';
import 'package:molia/providers/search_provider.dart';
import 'package:molia/services/search_history_store.dart';
import 'package:molia/widgets/search_assist_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_music_source.dart';
import '../support/fakes.dart';

/// 共享辅助面板：两种版式共用、最多 6 条、清空后完全消失。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Track track(String id) => Track(
    id: TrackId('kw', id),
    title: 'Title $id',
    artists: const [],
    album: 'Album',
    duration: const Duration(seconds: 30),
    origin: TrackOrigin.lx,
    qualities: const [],
    payload: {'songmid': id},
  );

  Future<
    ({
      SearchAssistController assist,
      SearchHistoryStore history,
      SearchProvider provider,
      ChannelSelection selection,
      FakeMusicSource source,
      PlaybackProvider playback,
    })
  >
  setUpAssist() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final history = SearchHistoryStore(preferences: prefs);
    await history.ready();
    for (var index = 0; index < 6; index++) {
      await history.record('kw', '历史$index');
    }
    final source = FakeMusicSource(
      'kw',
      capabilities: const SourceCapabilities(search: true, pagination: true),
    )..onSearch = (query) async => SearchResult(items: [track(query.keyword)]);
    final registry = FakeSourceRegistry({'kw': source});
    final selection = ChannelSelection(
      validKeys: () => ['kw'],
      defaultKey: () => 'kw',
    );
    final playback = buildTestPlaybackProvider();
    final provider = SearchProvider(
      playback,
      selection: selection,
      catalogService: CatalogService(registry: registry),
      sourceRegistry: registry,
      historyStore: history,
    );
    final assist = SearchAssistController(
      search: provider,
      history: history,
      hotKeywords: () => const ['热搜1', '热搜2', '热搜3'],
    )..setFocused(true);
    return (
      assist: assist,
      history: history,
      provider: provider,
      selection: selection,
      source: source,
      playback: playback,
    );
  }

  void tearDownAssist(
    ({
      SearchAssistController assist,
      SearchHistoryStore history,
      SearchProvider provider,
      ChannelSelection selection,
      FakeMusicSource source,
      PlaybackProvider playback,
    })
    setup,
  ) {
    setup.assist.dispose();
    setup.provider.dispose();
    setup.playback.dispose();
    setup.selection.dispose();
    setup.history.dispose();
  }

  Future<void> pumpPanel(
    WidgetTester tester,
    SearchAssistController assist,
    SearchAssistVariant variant,
  ) async {
    await tester.pumpWidget(
      M3EMaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: const [Locale('zh')],
        data: M3EThemeData.fromMaterial(ThemeData.light()),
        theme: ThemeData.light(),
        home: Scaffold(
          body: SearchAssistPanel(controller: assist, variant: variant),
        ),
      ),
    );
    await tester.pump();
  }

  /// 宿主键盘契约（与两个真实宿主同形）：建议可见时 ↑↓ / Enter 归辅助面板。
  Future<void> pumpKeyboardHost(
    WidgetTester tester,
    SearchAssistController assist,
  ) async {
    await tester.pumpWidget(
      M3EMaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: const [Locale('zh')],
        data: M3EThemeData.fromMaterial(ThemeData.light()),
        theme: ThemeData.light(),
        home: Scaffold(
          body: Focus(
            autofocus: true,
            onKeyEvent: (node, event) {
              if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                return KeyEventResult.ignored;
              }
              if (!assist.value.showSuggestions) {
                return KeyEventResult.ignored;
              }
              if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                assist.moveHighlight(1);
                return KeyEventResult.handled;
              }
              if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                assist.moveHighlight(-1);
                return KeyEventResult.handled;
              }
              if (event.logicalKey == LogicalKeyboardKey.enter) {
                if (assist.selectHighlighted()) {
                  return KeyEventResult.handled;
                }
              }
              return KeyEventResult.ignored;
            },
            child: SearchAssistPanel(
              controller: assist,
              variant: SearchAssistVariant.page,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  for (final variant in SearchAssistVariant.values) {
    testWidgets('${variant.name}: 历史最多 4 条 + 热搜最多 2 条', (tester) async {
      final setup = await setUpAssist();
      addTearDown(() => tearDownAssist(setup));
      await pumpPanel(tester, setup.assist, variant);
      expect(find.text('最近搜索'), findsOneWidget);
      expect(find.text('历史5'), findsOneWidget);
      expect(find.text('历史1'), findsNothing);
      expect(find.text('热搜1'), findsOneWidget);
      expect(find.text('热搜3'), findsNothing);
    });

    testWidgets('${variant.name}: 清空后整块消失', (tester) async {
      final setup = await setUpAssist();
      addTearDown(() => tearDownAssist(setup));
      await pumpPanel(tester, setup.assist, variant);
      await tester.tap(find.text('清除'));
      await tester.pump();
      expect(find.text('最近搜索'), findsNothing);
      expect(find.text('历史5'), findsNothing);
    });
  }

  testWidgets('失焦时整块隐藏', (tester) async {
    final setup = await setUpAssist();
    addTearDown(() => tearDownAssist(setup));
    await pumpPanel(tester, setup.assist, SearchAssistVariant.page);
    expect(find.text('最近搜索'), findsOneWidget);
    setup.assist.setFocused(false);
    await tester.pump();
    expect(find.text('最近搜索'), findsNothing);
  });

  testWidgets('历史芯片删除不发起搜索', (tester) async {
    final setup = await setUpAssist();
    addTearDown(() => tearDownAssist(setup));
    await pumpPanel(tester, setup.assist, SearchAssistVariant.page);
    final chip = find.ancestor(
      of: find.text('历史5'),
      matching: find.byType(M3EChip),
    );
    await tester.tap(
      find.descendant(of: chip, matching: find.byIcon(M3EIcons.close)),
    );
    await tester.pump();
    expect(setup.history.entriesFor('kw'), isNot(contains('历史5')));
    expect(setup.source.searchCalls, 0);
  });

  testWidgets('↑↓ + Enter 选中建议，结果到达后面板消失', (tester) async {
    final setup = await setUpAssist();
    addTearDown(() => tearDownAssist(setup));
    await pumpKeyboardHost(tester, setup.assist);
    setup.provider.updateSearchQuery('历史5');
    await tester.pump();
    expect(setup.assist.value.showSuggestions, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(setup.assist.value.highlightedIndex, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    for (var index = 0; index < 100 && setup.provider.isSearchBusy; index++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(setup.source.searchCalls, greaterThan(0));
    expect(setup.provider.songResults.items, isNotEmpty);
    await tester.pump();
    expect(setup.assist.value.showSuggestions, isFalse);
    expect(find.byType(SearchAssistPanel), findsOneWidget);
    expect(find.byType(M3EListItem), findsNothing);
  });
}
