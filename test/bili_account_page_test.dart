import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/domain/models/bili_account.dart';
import 'package:molia/pages/bili_account_page.dart';
import 'package:molia/services/bili_account_service.dart';
import 'package:molia/sources/builtin/bili_account.dart';
import 'package:molia/sources/builtin/bili_login.dart';
import 'package:provider/provider.dart';

import 'support/settings_test_support.dart';

/// 哔哩哔哩账号页：未登录扫码 → 已登录 → 退出。
void main() {
  setUp(() => BiliAccountStore.instance.reset());
  tearDown(() => BiliAccountStore.instance.reset());

  Future<(BiliAccountService, _FakeBiliQrLogin)> pumpPage(
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final registry = testSettingsRegistry(keys: [kBiliAccountCookie]);
    final login = _FakeBiliQrLogin();
    final service = BiliAccountService(
      settings: registry.scope([kBiliAccountCookie]),
      login: login,
    );
    addTearDown(service.dispose);
    await service.init();
    await tester.pumpWidget(
      ChangeNotifierProvider<BiliAccountService>.value(
        value: service,
        child: const MaterialApp(home: BiliAccountPage()),
      ),
    );
    await tester.pumpAndSettle();
    return (service, login);
  }

  testWidgets('未登录显示扫码入口，扫码成功进入已登录', (tester) async {
    final (service, login) = await pumpPage(tester);
    login
      ..generateResult = const BiliQrCode(
        url: 'https://account.bilibili.com/scan?qrcode_key=k',
        key: 'k',
      )
      ..pollResults = [
        const BiliQrPollOutcome(status: BiliQrPollStatus.waiting),
        const BiliQrPollOutcome(status: BiliQrPollStatus.scanned),
        BiliQrPollOutcome(
          status: BiliQrPollStatus.confirmed,
          credentials: const BiliLoginCredentials(
            cookieHeader: 'SESSDATA=ui; DedeUserID=12',
            userId: '12',
          ),
        ),
      ]
      ..profileResult = const BiliAccount(userId: '12', userName: '测试账号');

    expect(find.text('未登录'), findsOneWidget);
    await tester.tap(find.byKey(const Key('biliAccountLoginButton')));
    await tester.pump();
    expect(find.byKey(const Key('biliAccountQrImage')), findsOneWidget);
    expect(find.text('用哔哩哔哩 App 扫码登录'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('已扫码，请在手机上确认'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(service.status, BiliAccountStatus.loggedIn);
    expect(find.text('已登录：测试账号'), findsOneWidget);
    expect(find.byKey(const Key('biliAccountLogoutItem')), findsOneWidget);
  });

  testWidgets('退出登录：二次确认后回到未登录', (tester) async {
    final (service, login) = await pumpPage(tester);
    login
      ..generateResult = const BiliQrCode(url: 'u', key: 'k')
      ..pollResults = [
        BiliQrPollOutcome(
          status: BiliQrPollStatus.confirmed,
          credentials: const BiliLoginCredentials(
            cookieHeader: 'SESSDATA=logout; DedeUserID=13',
            userId: '13',
          ),
        ),
      ]
      ..profileResult = const BiliAccount(userId: '13', userName: '退出测试');
    await service.startQrLogin();
    await service.pollQrLogin();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('biliAccountLogoutItem')), findsOneWidget);

    await tester.tap(find.byKey(const Key('biliAccountLogoutItem')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(M3EButton, '退出登录'));
    await tester.pumpAndSettle();

    expect(service.status, BiliAccountStatus.loggedOut);
    expect(find.byKey(const Key('biliAccountLoginButton')), findsOneWidget);
  });
}

class _FakeBiliQrLogin extends BiliQrLogin {
  BiliQrCode? generateResult;
  List<BiliQrPollOutcome> pollResults = [];
  BiliAccount? profileResult;

  @override
  Future<BiliQrCode> generate() async =>
      generateResult ?? (throw StateError('generateResult not set'));

  @override
  Future<BiliQrPollOutcome> poll(String key) async {
    if (pollResults.isEmpty) {
      return const BiliQrPollOutcome(status: BiliQrPollStatus.waiting);
    }
    return pollResults.removeAt(0);
  }

  @override
  Future<BiliAccount?> fetchProfile() async => profileResult;
}
