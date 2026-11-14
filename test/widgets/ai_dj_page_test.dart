import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/domain/models/ai_dj.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/ai_dj_page.dart';
import 'package:molia/providers/ai_dj_provider.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/ai/ai_settings_store.dart';

import '../support/ai_dj_test_support.dart';
import '../support/fake_ai_generator.dart';
import '../support/fake_library_repository.dart';
import '../support/fakes.dart';
import '../support/settings_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PlaybackProvider playback;
  late LibraryProvider library;
  late AiDjProvider provider;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final registry = testSettingsRegistry();
    await AiSettingsStore(settings: registry).saveConfig(
      const LlmConfig(
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'sk-test',
        model: 'model-a',
      ),
    );
    playback = buildTestPlaybackProvider(
      settings: registry,
      facade: FakePlaybackFacade(),
    );
    await playback.preferencesReady;
    library = LibraryProvider(
      repository: FakeLibraryRepository(),
      playbackProvider: playback,
    );
    provider = AiDjProvider(
      playbackProvider: playback,
      libraryProvider: library,
      recommendationService: FakeAiDjGenerator(),
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

  testWidgets('配置没有保存按钮，输入停顿后写回 provider', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
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
          home: const AiDjPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('aiDjSaveConfigButton')), findsNothing);

    await tester.tap(find.byKey(const Key('aiDjManageConfigButton')));
    await tester.pumpAndSettle();

    expect(find.text('改动即时生效'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('aiDjModelField')), 'model-b');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(provider.config?.model, 'model-b');
  });
}
