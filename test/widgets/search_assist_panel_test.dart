import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/domain/models/source.dart' show SourceCapabilities;
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/channel_selection.dart';
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

  Future<
    ({
      SearchAssistController assist,
      SearchHistoryStore history,
      SearchProvider provider,
      ChannelSelection selection,
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
    );
    final registry = FakeSourceRegistry({'kw': source});
    final selection = ChannelSelection(
      validKeys: () => ['kw'],
      defaultKey: () => 'kw',
    );
    final provider = SearchProvider(
      buildTestPlaybackProvider(),
      selection: selection,
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
    );
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

  for (final variant in SearchAssistVariant.values) {
    testWidgets('${variant.name}: 历史最多 4 条 + 热搜最多 2 条', (tester) async {
      final setup = await setUpAssist();
      addTearDown(() {
        setup.assist.dispose();
        setup.provider.dispose();
        setup.selection.dispose();
        setup.history.dispose();
      });
      await pumpPanel(tester, setup.assist, variant);
      expect(find.text('最近搜索'), findsOneWidget);
      expect(find.text('历史5'), findsOneWidget);
      expect(find.text('历史1'), findsNothing);
      expect(find.text('热搜1'), findsOneWidget);
      expect(find.text('热搜3'), findsNothing);
    });

    testWidgets('${variant.name}: 清空后整块消失', (tester) async {
      final setup = await setUpAssist();
      addTearDown(() {
        setup.assist.dispose();
        setup.provider.dispose();
        setup.selection.dispose();
        setup.history.dispose();
      });
      await pumpPanel(tester, setup.assist, variant);
      await tester.tap(find.text('清除'));
      await tester.pump();
      expect(find.text('最近搜索'), findsNothing);
      expect(find.text('历史5'), findsNothing);
    });
  }

  testWidgets('失焦时整块隐藏', (tester) async {
    final setup = await setUpAssist();
    addTearDown(() {
      setup.assist.dispose();
      setup.provider.dispose();
      setup.selection.dispose();
      setup.history.dispose();
    });
    await pumpPanel(tester, setup.assist, SearchAssistVariant.page);
    expect(find.text('最近搜索'), findsOneWidget);
    setup.assist.setFocused(false);
    await tester.pump();
    expect(find.text('最近搜索'), findsNothing);
  });
}
