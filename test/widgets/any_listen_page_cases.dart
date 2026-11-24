import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/any_listen_page.dart';
import 'package:molia/providers/sources_backend.dart';
import 'package:molia/providers/sources_provider.dart';
import 'package:molia/sources/source_manager.dart';

import '../support/provider_test_scope.dart';
import '../support/settings_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SourceManager manager;
  late SourcesProvider sources;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    manager = SourceManager(settings: testSettingsRegistry());
    await manager.init();
    sources = SourcesProvider(SourceManagerBackend(manager));
  });

  tearDown(() => sources.dispose());

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(700, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final scope = ProviderTestScope()..put<SourcesProvider>(sources);
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
          home: AnyListenPage(provider: sources),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('没有保存按钮，地址输入停顿后立即写入', (tester) async {
    await pumpPage(tester);

    expect(find.text('保存'), findsNothing);
    expect(find.text('改动即时生效'), findsOneWidget);

    await tester.enterText(
      find.byType(M3ETextField).first,
      'http://127.0.0.1:9500',
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(manager.anyListenConfig.serverUrl, 'http://127.0.0.1:9500');
  });

  testWidgets('非法地址只显示行内错误，不写入', (tester) async {
    await pumpPage(tester);

    await tester.enterText(
      find.byType(M3ETextField).first,
      'ftp://example.com',
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('服务器地址必须以 http:// 或 https:// 开头'),
      findsOneWidget,
    );
    expect(manager.anyListenConfig.serverUrl, isEmpty);
  });

  testWidgets('非法地址开启开关：错误同时出现在开关副标题', (tester) async {
    await pumpPage(tester);

    await tester.enterText(
      find.byType(M3ETextField).first,
      'ftp://example.com',
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('anyListenEnableSwitch')));
    await tester.pumpAndSettle();

    // 输入框 errorText + 开关副标题各一处：从开关方向看过来也知道为什么没开。
    expect(
      find.textContaining('服务器地址必须以 http:// 或 https:// 开头'),
      findsNWidgets(2),
    );
    expect(manager.anyListenConfig.enabled, isFalse);
  });

  testWidgets('启用开关先校验地址，合法时立即写入', (tester) async {
    await pumpPage(tester);

    await tester.enterText(
      find.byType(M3ETextField).first,
      'http://127.0.0.1:9500',
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('anyListenEnableSwitch')));
    await tester.pumpAndSettle();

    expect(manager.anyListenConfig.enabled, isTrue);
  });
}
