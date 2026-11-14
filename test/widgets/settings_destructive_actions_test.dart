import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/cache_management_page.dart';
import 'package:molia/pages/downloads_manage_page.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/cache_service.dart';
import 'package:molia/widgets/settings/settings_tiles.dart';

import '../support/fakes.dart';
import '../support/memory_cache_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pump(
    WidgetTester tester,
    Widget page, {
    required List<SingleChildWidget> providers,
  }) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiProvider(
        providers: providers,
        child: M3EMaterialApp(
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
    final cache = CacheService(prefs: prefs, storage: MemoryCacheStorage());
    await pump(
      tester,
      const CacheManagementPage(),
      providers: [Provider<CacheService>.value(value: cache)],
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

  testWidgets('下载管理的批量破坏动作只在顶栏 ⋮ 里', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final playback = buildTestPlaybackProvider(facade: FakePlaybackFacade());
    addTearDown(playback.dispose);
    await playback.preferencesReady;

    await pump(
      tester,
      const DownloadsManagePage(),
      providers: [
        ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
      ],
    );

    expect(find.byKey(const Key('downloadsCancelAllItem')), findsNothing);
    expect(find.byKey(const Key('downloadsCleanupOrphansItem')), findsNothing);
    expect(find.byKey(const Key('downloadsOverflowButton')), findsOneWidget);

    await tester.tap(find.byKey(const Key('downloadsOverflowButton')));
    await tester.pumpAndSettle();
    expect(find.text('取消全部'), findsOneWidget);
    expect(find.text('清理残留文件'), findsOneWidget);
  });
}
