import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/domain/models/playback_feel.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/nav_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/widgets/settings/playback_details_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

import '../support/provider_test_scope.dart';
import '../support/settings_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PlaybackProvider playback;
  late NavProvider nav;
  late ProviderTestScope scope;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final registry = testSettingsRegistry();
    playback = buildTestPlaybackProvider(
      settings: registry,
      facade: FakePlaybackFacade(),
    );
    await playback.preferencesReady;
    scope = ProviderTestScope(registry: registry);
    nav = scope.container.read(navProvider.notifier);
    await nav.preferencesReady;
    scope.put<PlaybackProvider>(playback);
  });

  tearDown(() {
    playback.dispose();
  });

  Future<void> pumpSection(WidgetTester tester) async {
    await tester.pumpWidget(
      scope.wrap(
        M3EMaterialApp(
          data: M3EThemeData.fromMaterial(ThemeData.light()),
          theme: ThemeData.light(),
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: const Scaffold(body: PlaybackDetailsSection()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('切换档位与开关立即写回 provider', (tester) async {
    await pumpSection(tester);

    // 宽屏四段放得下：仍是分段（窄屏才会降级为下拉，见下一条用例）。
    await tester.tap(find.text('0.15 秒'));
    await tester.pumpAndSettle();
    expect(playback.fadePreset, PlaybackFadePreset.ms150);

    await tester.tap(find.byKey(const Key('settingsSmartShuffleSwitch')));
    await tester.pumpAndSettle();
    expect(playback.smartShuffleEnabled, isFalse);

    await tester.tap(
      find.byKey(const Key('settingsReturnToPlayerLyricsSwitch')),
    );
    await tester.pumpAndSettle();
    expect(nav.showLyricsOnEnter, isFalse);
  });
}
