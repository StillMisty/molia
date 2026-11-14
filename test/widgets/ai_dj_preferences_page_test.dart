import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/domain/models/ai_dj.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/ai_dj_preferences_page.dart';
import 'package:molia/providers/ai_dj_provider.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/ai/ai_settings_store.dart';
import 'package:molia/widgets/settings/settings_subpage.dart';

import '../support/ai_dj_test_support.dart';
import '../support/fake_ai_generator.dart';
import '../support/fake_library_repository.dart';
import '../support/fakes.dart';
import '../support/settings_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PlaybackProvider playback;
  late LibraryProvider library;
  late FakeAiDjGenerator generator;
  late AiDjProvider provider;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final registry = testSettingsRegistry();
    playback = buildTestPlaybackProvider(
      settings: registry,
      facade: FakePlaybackFacade(),
    );
    await playback.preferencesReady;
    library = LibraryProvider(
      repository: FakeLibraryRepository(),
      playbackProvider: playback,
    );
    generator = FakeAiDjGenerator();
    provider = AiDjProvider(
      playbackProvider: playback,
      libraryProvider: library,
      recommendationService: generator,
      settingsStore: AiSettingsStore(settings: registry),
      recommendationStore: testAiRecommendationStore(),
    );
    await provider.init();
  });

  tearDown(() {
    provider.dispose();
    library.dispose();
    playback.dispose();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider<AiDjProvider>.value(
        value: provider,
        child: M3EMaterialApp(
          data: M3EThemeData.fromMaterial(ThemeData.light()),
          theme: ThemeData.light(),
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: const AiDjPreferencesPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('使用设置子页 chrome，发送范围收成一个入口', (tester) async {
    await pumpPage(tester);

    expect(find.byType(SettingsSubPage), findsOneWidget);
    expect(find.byKey(const Key('aiDjPrefScopeEntry')), findsOneWidget);
    expect(find.text('已发送 8 项'), findsOneWidget);
    // 八个开关不再平铺在页面上。
    expect(find.byKey(const Key('aiDjPrefScope_summary')), findsNothing);
    expect(find.byKey(const Key('aiDjPrefsResetButton')), findsOneWidget);
  });

  testWidgets('发送范围弹层里八个开关齐全，切换立即写偏好', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('aiDjPrefScopeEntry')));
    await tester.pumpAndSettle();

    for (final section in AiUpstreamSection.values) {
      expect(
        find.byKey(Key('aiDjPrefScope_${section.storageValue}')),
        findsOneWidget,
      );
    }

    await tester.tap(find.byKey(const Key('aiDjPrefScope_summary')));
    await tester.pumpAndSettle();

    expect(
      provider.preferences.sections.contains(AiUpstreamSection.summary),
      isFalse,
    );
    expect(find.text('已发送 7 项'), findsOneWidget);
  });
}
