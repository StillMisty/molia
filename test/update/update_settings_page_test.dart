import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/update_settings_page.dart';
import 'package:molia/providers/update_provider.dart';
import 'package:molia/services/language_service.dart';
import 'package:molia/services/update/update_installer_types.dart';

import '../support/update_test_support.dart';

/// 「关于与更新」页面冒烟：初始行、检查 → 发布卡片 → 下载安装、
/// Android 授权分支。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeUpdateService service;
  late FakeUpdatePreferences preferences;
  late UpdateProvider provider;

  setUp(() async {
    service = FakeUpdateService();
    preferences = FakeUpdatePreferences();
    provider = UpdateProvider(
      service: service,
      preferences: preferences,
      currentVersion: '1.2.2',
      currentBuild: 41,
    );
    await provider.init();
  });

  tearDown(() => provider.dispose());

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<UpdateProvider>.value(
        value: provider,
        child: M3EMaterialApp(
          data: M3EThemeData.fromMaterial(ThemeData.light()),
          theme: ThemeData.light(),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: LanguageService.supportedLocales,
          locale: const Locale('zh'),
          home: const UpdateSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(
    WidgetTester tester,
    Key key, {
    bool settle = true,
  }) async {
    final finder = find.byKey(key);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      // 安装中会出现无限循环的进度指示器，不能 pumpAndSettle。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('初始渲染：渠道 / 自动检查默认关 / 未检查 / 当前版本', (tester) async {
    await pumpPage(tester);

    expect(find.byKey(const Key('settingsUpdateChannelItem')), findsOneWidget);
    expect(find.text('稳定版'), findsOneWidget);
    expect(find.text('测试版'), findsOneWidget);

    final autoCheck = find.byKey(const Key('settingsUpdateAutoCheckSwitch'));
    expect(autoCheck, findsOneWidget);
    expect(
      tester.widget<M3ESwitch>(autoCheck).value,
      isFalse,
      reason: '自动检查默认关闭',
    );

    expect(find.text('尚未检查'), findsOneWidget);
    expect(find.text('1.2.2+41'), findsOneWidget);
    // 关于：项目主页行（跳转 GitHub）。
    expect(find.byKey(const Key('settingsAboutGithubItem')), findsOneWidget);
    expect(find.text('GitHub 项目主页'), findsOneWidget);
    expect(find.text('StillMisty/molia'), findsOneWidget);
    // 未检查前没有发布卡片。
    expect(find.text('新版本'), findsNothing);
    expect(find.text('下载并安装'), findsNothing);
  });

  testWidgets('发布卡：打开发布页收进主操作的尾部菜单', (tester) async {
    await pumpPage(tester);

    await tapKey(tester, const Key('settingsUpdateCheckItem'));

    final primary = find.byKey(const Key('settingsUpdateDownloadButton'));
    expect(primary, findsOneWidget);
    // 未展开菜单时次要出口不可见。
    expect(find.text('打开下载页'), findsNothing);

    final rect = tester.getRect(primary);
    await tester.tapAt(Offset(rect.right - 16, rect.center.dy));
    await tester.pumpAndSettle();
    expect(find.text('打开下载页'), findsOneWidget);
  });

  testWidgets('检查更新 → 发布卡片 → 下载安装', (tester) async {
    await pumpPage(tester);

    await tapKey(tester, const Key('settingsUpdateCheckItem'));

    expect(find.text('发现新版本 1.2.3'), findsOneWidget);
    expect(find.text('Molia 1.2.3'), findsOneWidget);
    expect(find.byKey(const Key('settingsUpdateDownloadButton')),
        findsOneWidget);

    await tapKey(
      tester,
      const Key('settingsUpdateDownloadButton'),
      settle: false,
    );

    // 桌面替换脚本已启动 → 安装中提示；provider 记录进度完成。
    expect(find.textContaining('已交给安装程序'), findsOneWidget);
    expect(provider.progress.value.received, 10);
  });

  testWidgets('Android 缺少安装权限：去授权按钮可点', (tester) async {
    service.platform =
        const UpdatePlatformInfo(platform: 'android', arch: 'arm64');
    service.installPermission = false;
    await pumpPage(tester);

    await tapKey(tester, const Key('settingsUpdateCheckItem'));
    await tapKey(tester, const Key('settingsUpdateDownloadButton'));

    expect(provider.failure, isNotNull);
    final grant = find.byKey(const Key('settingsUpdatePermissionButton'));
    expect(grant, findsOneWidget);
    await tapKey(tester, const Key('settingsUpdatePermissionButton'));
    expect(service.openPermissionCalls, 1);
  });

  testWidgets('高级：清单地址与镜像前缀默认展示', (tester) async {
    await pumpPage(tester);

    expect(find.text('更新清单地址'), findsOneWidget);
    expect(find.text('默认（官方 GitHub Release）'), findsOneWidget);
    expect(find.text('下载镜像前缀'), findsOneWidget);
    expect(find.text('默认（GitHub 直连）'), findsOneWidget);
  });

  testWidgets('检查进行中：隐藏上一次的发布卡片（不显示旧下载版本）', (tester) async {
    await pumpPage(tester);
    await tapKey(tester, const Key('settingsUpdateCheckItem'));
    expect(find.text('Molia 1.2.3'), findsOneWidget);

    // 第二次检查挂起在网关后：期间只应看到「正在检查…」。
    service.checkGate = Completer<void>();
    await tester.tap(find.byKey(const Key('settingsUpdateCheckItem')));
    await tester.pump();

    expect(find.text('正在检查…'), findsOneWidget);
    expect(find.text('Molia 1.2.3'), findsNothing);
    expect(find.byKey(const Key('settingsUpdateDownloadButton')), findsNothing);

    service.checkGate!.complete();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('settingsUpdateDownloadButton')),
      findsOneWidget,
    );
  });

  testWidgets('缺少权限：先提示去授权，授权返回后回到可下载态', (tester) async {
    service.platform =
        const UpdatePlatformInfo(platform: 'android', arch: 'arm64');
    service.installPermission = false;
    await pumpPage(tester);

    await tapKey(tester, const Key('settingsUpdateCheckItem'));
    await tapKey(tester, const Key('settingsUpdateDownloadButton'));

    expect(
      find.byKey(const Key('settingsUpdatePermissionButton')),
      findsOneWidget,
    );
    expect(service.downloadCalls, 0, reason: '无权限时不先下载');

    // 模拟用户去系统设置授权后回到前台（组合根在 onResume 复查）。
    service.installPermission = true;
    await provider.handleAppResumed();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('settingsUpdateDownloadButton')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('settingsUpdatePermissionButton')),
      findsNothing,
    );
  });
}
