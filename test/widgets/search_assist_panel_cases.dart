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
import 'package:molia/widgets/search_assist_panel.dart';

import '../support/fake_music_source.dart';
import '../support/fakes.dart';

/// 共享辅助面板：两种版式共用、最多 6 条、无内容时完全消失。
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
      SearchProvider provider,
      ChannelSelection selection,
      FakeMusicSource source,
      PlaybackProvider playback,
    })
  >
  setUpAssist({List<String> hotKeywords = const ['热搜1', '热搜2', '热搜3']}) async {
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
    );
    final assist = SearchAssistController(
      search: provider,
      hotKeywords: () => hotKeywords,
    )..setFocused(true);
    return (
      assist: assist,
      provider: provider,
      selection: selection,
      source: source,
      playback: playback,
    );
  }

  void tearDownAssist(
    ({
      SearchAssistController assist,
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
    testWidgets('${variant.name}: 空词聚焦只显示热搜芯片', (tester) async {
      final setup = await setUpAssist();
      addTearDown(() => tearDownAssist(setup));
      await pumpPanel(tester, setup.assist, variant);
      expect(find.text('热搜'), findsOneWidget);
      expect(find.text('热搜1'), findsOneWidget);
      expect(find.text('热搜3'), findsOneWidget);
      expect(find.text('最近搜索'), findsNothing);
    });

    testWidgets('${variant.name}: 没有热搜时不占位', (tester) async {
      final setup = await setUpAssist(hotKeywords: const []);
      addTearDown(() => tearDownAssist(setup));
      await pumpPanel(tester, setup.assist, variant);
      expect(find.text('热搜'), findsNothing);
    });
  }

  testWidgets('失焦时整块隐藏', (tester) async {
    final setup = await setUpAssist();
    addTearDown(() => tearDownAssist(setup));
    await pumpPanel(tester, setup.assist, SearchAssistVariant.page);
    expect(find.text('热搜'), findsOneWidget);
    setup.assist.setFocused(false);
    await tester.pump();
    expect(find.text('热搜'), findsNothing);
  });

  testWidgets('↑↓ + Enter 选中建议，结果到达后面板消失', (tester) async {
    final setup = await setUpAssist();
    addTearDown(() => tearDownAssist(setup));
    await pumpKeyboardHost(tester, setup.assist);
    setup.provider.updateSearchQuery('热搜1');
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
