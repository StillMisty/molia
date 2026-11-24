import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/data/settings/device_settings.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/downloads_and_cache_page.dart';
import 'package:molia/services/cache_service.dart';
import 'package:molia/widgets/settings/settings_tiles.dart';

import '../support/memory_cache_storage.dart';
import '../support/provider_test_scope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pump(
    WidgetTester tester,
    Widget page, {
    required void Function(ProviderTestScope scope) configure,
  }) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final scope = ProviderTestScope();
    configure(scope);
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
          home: page,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('缓存单清是行尾图标按钮，全清是唯一整宽按钮', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final cache = CacheService(
      settings: DeviceSettings(preferences: prefs),
      storage: MemoryCacheStorage(),
    );
    await pump(
      tester,
      const DownloadsAndCachePage(),
      configure: (scope) => scope.put<CacheService>(cache),
    );

    for (final key in const [
      'cacheClearAudioItem',
      'cacheClearLyricsItem',
      'cacheClearArtworkItem',
    ]) {
      final row = find.byKey(Key(key));
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.byType(M3EIconButton)),
        findsOneWidget,
        reason: '$key 的清理动作在行尾',
      );
    }
    expect(find.byType(SettingsNavTile), findsNothing);

    final clearAll = find.text('清理全部缓存');
    expect(clearAll, findsOneWidget);
    final clearAllButton = find.widgetWithText(M3EButton, '清理全部缓存');
    expect(clearAllButton, findsOneWidget);
    expect(tester.getSize(clearAllButton).width, greaterThan(300));
  });
}
