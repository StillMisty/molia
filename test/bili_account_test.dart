import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/data/settings/settings_registry.dart';
import 'package:molia/data/settings/settings_secret_store.dart';
import 'package:molia/domain/models/bili_account.dart';
import 'package:molia/services/bili_account_service.dart';
import 'package:molia/sources/builtin/bili_account.dart';
import 'package:molia/sources/builtin/bili_client.dart';
import 'package:molia/sources/builtin/bili_login.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';

import 'support/mock_dio.dart';
import 'support/settings_test_support.dart';

/// B 站扫码登录协议 + 账号服务（本地 / 同步凭据的生命周期）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => BiliAccountStore.instance.reset());
  tearDown(() => BiliAccountStore.instance.reset());

  group('BiliQrLogin', () {
    BiliQrLogin loginWith(
      FutureOr<ResponseBody> Function(RequestOptions options) handler,
    ) => BiliQrLogin(
      client: BiliClient(transport: BuiltinTransport(dio: mockDio(handler))),
    );

    test('生成二维码并用 key 轮询；未扫码 / 已扫码 / 过期', () async {
      final requests = <RequestOptions>[];
      final qr = loginWith((options) async {
        requests.add(options);
        if (options.uri.path.endsWith('/qrcode/generate')) {
          return textResponse(
            jsonEncode({
              'code': 0,
              'data': {
                'url': 'https://account.bilibili.com/scan?qrcode_key=key-1',
                'qrcode_key': 'key-1',
              },
            }),
          );
        }
        if (options.uri.path.endsWith('/qrcode/poll')) {
          final state = requests
              .where((r) => r.uri.path.endsWith('/poll'))
              .length;
          return textResponse(
            jsonEncode({
              'code': 0,
              'data': {
                'code': state == 1 ? 86101 : (state == 2 ? 86090 : 86038),
              },
            }),
          );
        }
        return textResponse('{}', statusCode: 500);
      });

      final code = await qr.generate();
      expect(code.url, contains('scan'));
      expect(code.key, 'key-1');
      expect(requests.single.headers.containsKey('Cookie'), isFalse);

      expect((await qr.poll(code.key)).status, BiliQrPollStatus.waiting);
      expect((await qr.poll(code.key)).status, BiliQrPollStatus.scanned);
      expect((await qr.poll(code.key)).status, BiliQrPollStatus.expired);
      final poll = requests.last;
      expect(poll.uri.host, 'passport.bilibili.com');
      expect(poll.uri.queryParameters['qrcode_key'], 'key-1');
    });

    test('成功：Set-Cookie 提取 SESSDATA（保留编码）+ 账号 UID', () async {
      final qr = loginWith((options) async {
        if (options.uri.path.endsWith('/qrcode/generate')) {
          return textResponse(
            jsonEncode({
              'code': 0,
              'data': {
                'url': 'https://account.bilibili.com/scan',
                'qrcode_key': 'k',
              },
            }),
          );
        }
        if (options.uri.path.endsWith('/qrcode/poll')) {
          return textResponse(
            jsonEncode({
              'code': 0,
              'data': {'code': 0, 'url': ''},
            }),
            headers: {
              'set-cookie': [
                'SESSDATA=test%2C123; Path=/; Domain=.bilibili.com; HttpOnly',
                'bili_jct=jct-1; Path=/',
                'DedeUserID=42; Path=/',
              ],
            },
          );
        }
        return textResponse('{}', statusCode: 500);
      });

      final outcome = await qr.poll('k');
      expect(outcome.status, BiliQrPollStatus.confirmed);
      expect(
        outcome.credentials?.cookieHeader,
        contains('SESSDATA=test%2C123'),
      );
      expect(outcome.credentials?.cookieHeader, contains('bili_jct=jct-1'));
      expect(outcome.credentials?.userId, '42');
      expect(outcome.credentials?.cookieHeader, isNot(contains('Path=')));
    });

    test('成功：旧格式 data.url 里的 Cookie 也能读', () async {
      final qr = loginWith((options) async {
        if (options.uri.path.endsWith('/qrcode/generate')) {
          return textResponse(
            jsonEncode({
              'code': 0,
              'data': {
                'url': 'https://account.bilibili.com/scan',
                'qrcode_key': 'k',
              },
            }),
          );
        }
        return textResponse(
          jsonEncode({
            'code': 0,
            'data': {
              'code': 0,
              'url':
                  'https://passport.biligame.com/crossDomain?'
                  'SESSDATA=old%2Cdata&bili_jct=jct-old&DedeUserID=7',
            },
          }),
        );
      });

      final outcome = await qr.poll('k');
      expect(outcome.status, BiliQrPollStatus.confirmed);
      expect(
        outcome.credentials?.cookieHeader,
        contains('SESSDATA=old%2Cdata'),
      );
      expect(outcome.credentials?.userId, '7');
    });

    test('成功：crossDomain ticket 跟跳并从 Set-Cookie 提取', () async {
      final qr = loginWith((options) async {
        switch (options.uri.path) {
          case '/x/passport-login/web/qrcode/generate':
            return textResponse(
              jsonEncode({
                'code': 0,
                'data': {
                  'url': 'https://account.bilibili.com/scan',
                  'qrcode_key': 'k',
                },
              }),
            );
          case '/x/passport-login/web/qrcode/poll':
            return textResponse(
              jsonEncode({
                'code': 0,
                'data': {
                  'code': 0,
                  'url': 'https://passport.biligame.com/crossDomain?ticket=t',
                },
              }),
            );
          case '/crossDomain':
            return textResponse(
              '',
              statusCode: 302,
              headers: {
                'location': ['https://www.bilibili.com/'],
                'set-cookie': [
                  'SESSDATA=ticket-sess; Path=/; Domain=.bilibili.com',
                  'DedeUserID=99; Path=/',
                ],
              },
            );
          default:
            return textResponse('{}', statusCode: 500);
        }
      });

      final outcome = await qr.poll('k');
      expect(outcome.status, BiliQrPollStatus.confirmed);
      expect(
        outcome.credentials?.cookieHeader,
        contains('SESSDATA=ticket-sess'),
      );
      expect(outcome.credentials?.userId, '99');
    });

    test('资料：nav isLogin + 昵称；-101 视为登录失效', () async {
      BiliAccountStore.instance.update(cookieHeader: 'SESSDATA=test');
      var code = 0;
      final qr = loginWith((options) async {
        if (options.uri.path == '/x/web-interface/nav') {
          return textResponse(
            jsonEncode({
              'code': code,
              'data': code == 0
                  ? {'isLogin': true, 'mid': 42, 'uname': '测试账号'}
                  : null,
            }),
          );
        }
        return textResponse('{}', statusCode: 500);
      });

      final profile = await qr.fetchProfile();
      expect(profile?.userId, '42');
      expect(profile?.userName, '测试账号');

      code = -101;
      expect(await qr.fetchProfile(), isNull);
    });
  });

  group('BiliAccountService', () {
    late MemorySettingsSecretStore secrets;
    late SettingsRegistry settings;

    setUp(() {
      secrets = MemorySettingsSecretStore();
      settings = testSettingsRegistry(
        keys: [kBiliAccountCookie],
        secrets: secrets,
      );
    });

    BiliAccountService serviceWith(BiliQrLogin login) => BiliAccountService(
      settings: settings.scope([kBiliAccountCookie]),
      login: login,
    );

    test('初始化恢复已存凭据；同步到达的登录 / 清空', () async {
      await settings.write(kBiliAccountCookie, 'SESSDATA=stored; DedeUserID=5');
      final login = _FakeBiliQrLogin();
      final service = serviceWith(login);
      var loggedInCount = 0;
      service.onLoggedIn = () => loggedInCount++;
      await service.init();
      expect(service.status, BiliAccountStatus.loggedIn);
      expect(service.account?.userId, '5');
      expect(BiliAccountStore.instance.isLoggedIn, isTrue);

      await settings.clear(kBiliAccountCookie);
      await service.reloadFromSettings();
      expect(service.status, BiliAccountStatus.loggedOut);
      expect(BiliAccountStore.instance.isLoggedIn, isFalse);
      expect(loggedInCount, 0, reason: '初始化恢复不算新登录');

      await settings.write(kBiliAccountCookie, 'SESSDATA=remote; DedeUserID=6');
      login.profileResult = const BiliAccount(userId: '6');
      await service.reloadFromSettings();
      expect(service.status, BiliAccountStatus.loggedIn);
      expect(service.account?.userId, '6');
      expect(loggedInCount, 1);
    });

    test('扫码成功：写凭据、更新状态、触发 onLoggedIn', () async {
      final login = _FakeBiliQrLogin()
        ..profileResult = const BiliAccount(userId: '8')
        ..generateResult = const BiliQrCode(
          url: 'https://account.bilibili.com/scan',
          key: 'key',
        )
        ..pollResults = [
          const BiliQrPollOutcome(status: BiliQrPollStatus.waiting),
          BiliQrPollOutcome(
            status: BiliQrPollStatus.confirmed,
            credentials: const BiliLoginCredentials(
              cookieHeader: 'SESSDATA=login; bili_jct=jct; DedeUserID=8',
              userId: '8',
            ),
          ),
        ];
      final service = serviceWith(login);
      var loggedInCount = 0;
      service.onLoggedIn = () => loggedInCount++;
      await service.init();

      final session = await service.startQrLogin();
      expect(session.url, contains('scan'));
      expect((await service.pollQrLogin()).status, BiliQrPollStatus.waiting);
      final result = await service.pollQrLogin();
      expect(result.status, BiliQrPollStatus.confirmed);
      expect(result.persisted, isTrue);
      expect(service.status, BiliAccountStatus.loggedIn);
      expect(service.account?.userId, '8');
      expect(service.lastLoginPersisted, isTrue);
      expect(
        await settings.read(kBiliAccountCookie),
        contains('SESSDATA=login'),
      );
      expect(loggedInCount, 1);
    });

    test('扫码成功但保存失败：本次会话可用，标记未持久化', () async {
      final login = _FakeBiliQrLogin()
        ..profileResult = const BiliAccount(userId: '9')
        ..generateResult = const BiliQrCode(url: 'u', key: 'k')
        ..pollResults = [
          BiliQrPollOutcome(
            status: BiliQrPollStatus.confirmed,
            credentials: const BiliLoginCredentials(
              cookieHeader: 'SESSDATA=fail; DedeUserID=9',
              userId: '9',
            ),
          ),
        ];
      final failing = _FailingSecretStore();
      final registry = testSettingsRegistry(
        keys: [kBiliAccountCookie],
        secrets: failing,
      );
      final service = BiliAccountService(
        settings: registry.scope([kBiliAccountCookie]),
        login: login,
      );
      await service.init();
      await service.startQrLogin();
      final result = await service.pollQrLogin();
      expect(result.status, BiliQrPollStatus.confirmed);
      expect(result.persisted, isFalse);
      expect(service.lastLoginPersisted, isFalse);
      expect(service.status, BiliAccountStatus.loggedIn);
      expect(BiliAccountStore.instance.isLoggedIn, isTrue);
    });

    test('退出：清空凭据与内存态', () async {
      await settings.write(kBiliAccountCookie, 'SESSDATA=bye; DedeUserID=3');
      final service = serviceWith(_FakeBiliQrLogin());
      await service.init();
      expect(service.status, BiliAccountStatus.loggedIn);

      await service.logout();
      expect(service.status, BiliAccountStatus.loggedOut);
      expect(BiliAccountStore.instance.isLoggedIn, isFalse);
      expect(secrets.data.containsKey(kBiliAccountCookie.name), isFalse);
    });

    test('资料 -101：清凭据并标记登录过期', () async {
      await settings.write(
        kBiliAccountCookie,
        'SESSDATA=expired; DedeUserID=4',
      );
      final login = _FakeBiliQrLogin()..profileResult = null;
      final service = serviceWith(login);
      await service.init();
      expect(service.status, BiliAccountStatus.loggedIn);

      await service.refreshProfile(force: true);
      expect(service.status, BiliAccountStatus.loggedOut);
      expect(service.sessionExpired, isTrue);
      expect(BiliAccountStore.instance.isLoggedIn, isFalse);
      expect(secrets.data.containsKey(kBiliAccountCookie.name), isFalse);
    });

    test('cancel 后迟到的确认不写凭据', () async {
      final login = _FakeBiliQrLogin()
        ..generateResult = const BiliQrCode(url: 'u', key: 'k')
        ..pollResults = [
          BiliQrPollOutcome(
            status: BiliQrPollStatus.confirmed,
            credentials: const BiliLoginCredentials(
              cookieHeader: 'SESSDATA=late; DedeUserID=1',
              userId: '1',
            ),
          ),
        ];
      final service = serviceWith(login);
      await service.init();
      await service.startQrLogin();
      service.cancelQrLogin();
      final result = await service.pollQrLogin();
      expect(result.status, BiliQrPollStatus.failed);
      expect(service.status, BiliAccountStatus.loggedOut);
      expect(secrets.data.containsKey(kBiliAccountCookie.name), isFalse);
    });
  });
}

class _FakeBiliQrLogin extends BiliQrLogin {
  BiliQrCode? generateResult;
  List<BiliQrPollOutcome> pollResults = [];
  BiliAccount? profileResult;
  Object? profileError;

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
  Future<BiliAccount?> fetchProfile() async {
    if (profileError != null) throw profileError!;
    return profileResult;
  }
}

class _FailingSecretStore implements SettingsSecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {
    throw StateError('secure storage unavailable');
  }

  @override
  Future<void> delete(String key) async {}
}
