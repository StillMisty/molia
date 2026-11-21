import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/app/bootstrap/catalog_stack.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/services/language_service.dart';
import 'package:molia/services/poster/poster_style_settings.dart';
import 'package:molia/services/shortcut_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全静态设置服务的接线契约：未 `attachSettings` 就访问存储必须立刻失败，
/// 组合根装配后读写落到同一个设置注册表。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LanguageService.resetSettingsForTest();
    PosterStyleSettings.resetSettingsForTest();
    ShortcutSettings.resetSettingsForTest();
  });

  tearDown(() {
    LanguageService.resetSettingsForTest();
    PosterStyleSettings.resetSettingsForTest();
    ShortcutSettings.resetSettingsForTest();
  });

  test('未 attachSettings：三个服务的读写都抛 StateError', () async {
    expect(
      () => PosterStyleSettings.ensureLoaded(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('PosterStyleSettings.attachSettings'),
        ),
      ),
    );
    await expectLater(
      PosterStyleSettings.setSeed(0xFF010203),
      throwsA(isA<StateError>()),
    );

    await expectLater(
      ShortcutSettings.load(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('ShortcutSettings.attachSettings'),
        ),
      ),
    );
    await expectLater(
      ShortcutSettings.instance.setInAppEnabled(false),
      throwsA(isA<StateError>()),
    );

    await expectLater(
      LanguageService.getSavedLocale(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('LanguageService.attachSettings'),
        ),
      ),
    );
    await expectLater(
      LanguageService.saveLocale(const Locale('en')),
      throwsA(isA<StateError>()),
    );
  });

  test('组合根 attach 全部三个服务，读写走同一注册表', () async {
    final stack = buildCatalogStack();

    await ShortcutSettings.load();
    await PosterStyleSettings.ensureLoaded();
    expect(await LanguageService.getSavedLocale(), isNull);

    await LanguageService.saveLocale(const Locale('en'));
    await PosterStyleSettings.setSeed(0xFF010203);
    await ShortcutSettings.instance.setInAppEnabled(false);

    expect(await stack.settings.read(kSelectedLanguage), 'en');
    expect(await stack.settings.read(kPosterSeedColor), 0xFF010203);
    expect(await stack.settings.read(kShortcutsEnabled), isFalse);
  });
}
