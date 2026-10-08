import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/cache_management_page.dart';
import 'package:molia/services/cache_service.dart';
import 'package:molia/services/cache_storage_io.dart';

/// 缓存管理页：四项数值策略支持任意自定义值（点击行内数值弹层输入）。
///
/// 0 = 不限制 / 永不过期；越界时显示范围错误且保存置灰。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late CacheService service;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    tempRoot = await Directory.systemTemp.createTemp('cache_page_test_');
    service = CacheService(
      prefs: prefs,
      storage: IoCacheStorage(
        audioDirOverride: '${tempRoot.path}/audio_cache',
        artworkDirOverride: '${tempRoot.path}/artwork_cache',
      ),
      audioProtectAge: Duration.zero,
    );
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      Provider<CacheService>.value(
        value: service,
        child: M3EMaterialApp(
          data: M3EThemeData.fromMaterial(ThemeData()),
          theme: ThemeData(),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('en'), Locale('zh')],
          home: const CacheManagementPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('音频容量：点击行内数值可输入任意值并持久化', (tester) async {
    await pumpPage(tester);

    expect(find.text('1024 MB'), findsOneWidget);
    await tester.tap(find.text('Size limit'));
    await tester.pumpAndSettle();

    expect(find.byType(M3EDialog), findsOneWidget);
    expect(find.text('0 = Unlimited · Range 16–102400'), findsOneWidget);

    await tester.enterText(find.byType(M3ETextField), '333');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.byType(M3EDialog), findsNothing);
    expect(prefs.getInt(CacheService.keyAudioMaxMb), 333);
    expect(find.text('333 MB'), findsOneWidget);
  });

  testWidgets('音频容量：输入 0 表示不限制', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('Size limit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(M3ETextField), '0');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(prefs.getInt(CacheService.keyAudioMaxMb), 0);
    expect(find.text('Unlimited'), findsOneWidget);
  });

  testWidgets('越界输入：范围错误提示且保存禁用，取消不写入', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('Size limit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(M3ETextField), '5');
    await tester.pump();

    expect(find.text('Enter an integer between 16 and 102400'), findsOneWidget);
    final save = tester.widget<M3EButton>(
      find.widgetWithText(M3EButton, 'Save'),
    );
    expect(save.onPressed, isNull);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(M3EDialog), findsNothing);
    expect(prefs.getInt(CacheService.keyAudioMaxMb), isNull);
    expect(find.text('1024 MB'), findsOneWidget);
  });

  testWidgets('歌词保留时长与封面数量上限同样支持自定义', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('Keep lyrics for'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(M3ETextField), '45');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(prefs.getInt(CacheService.keyLyricsTtlDays), 45);
    expect(find.text('45 days'), findsOneWidget);

    await tester.tap(find.text('Max artwork objects'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(M3ETextField), '4200');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(prefs.getInt(CacheService.keyArtworkMaxObjects), 4200);
    expect(find.text('4200'), findsOneWidget);
  });
}
