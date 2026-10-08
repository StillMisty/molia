import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:molia/sources/any_listen/any_listen_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('AnyListenConfig', () {
    test('默认未配置且不可用', () {
      const config = AnyListenConfig();
      expect(config.isConfigured, isFalse);
      expect(config.isUsable, isFalse);
      expect(config.serverUrl, isEmpty);
      expect(config.token, isEmpty);
      expect(config.enabled, isFalse);
    });

    test('isUsable 需要同时「已配置」与「已启用」', () {
      const configuredOnly =
          AnyListenConfig(serverUrl: 'http://127.0.0.1:9500', enabled: false);
      expect(configuredOnly.isConfigured, isTrue);
      expect(configuredOnly.isUsable, isFalse);

      const enabledOnly = AnyListenConfig(enabled: true);
      expect(enabledOnly.isConfigured, isFalse);
      expect(enabledOnly.isUsable, isFalse);

      const usable =
          AnyListenConfig(serverUrl: 'http://127.0.0.1:9500', enabled: true);
      expect(usable.isUsable, isTrue);
    });

    test('normalizeServerUrl：去空白、去尾部斜杠、缺协议补 http://', () {
      expect(
        AnyListenConfig.normalizeServerUrl('  http://127.0.0.1:9500/  '),
        'http://127.0.0.1:9500',
      );
      expect(
        AnyListenConfig.normalizeServerUrl('https://music.example.com///'),
        'https://music.example.com',
      );
      expect(
        AnyListenConfig.normalizeServerUrl('127.0.0.1:9500'),
        'http://127.0.0.1:9500',
      );
      expect(AnyListenConfig.normalizeServerUrl('   '), isEmpty);
    });

    test('validateServerUrl：非法地址给出可读错误', () {
      expect(AnyListenConfig.validateServerUrl(''), isNotNull);
      expect(AnyListenConfig.validateServerUrl('ftp://host'), isNotNull);
      expect(AnyListenConfig.validateServerUrl('http://'), isNotNull);
      expect(
        AnyListenConfig.validateServerUrl('http://127.0.0.1:9500'),
        isNull,
      );
      expect(
        AnyListenConfig.validateServerUrl('music.example.com'),
        isNull,
      );
    });

    test('copyWith 归一化地址并保留其它字段', () {
      const base = AnyListenConfig(token: 'tk', enabled: true);
      final copy = base.copyWith(serverUrl: 'http://host:9500/');
      expect(copy.serverUrl, 'http://host:9500');
      expect(copy.token, 'tk');
      expect(copy.enabled, isTrue);

      final same = base.copyWith();
      expect(same, base);
    });

    test('相等性：地址归一化后相同则相等', () {
      final a = AnyListenConfig(
        serverUrl: AnyListenConfig.normalizeServerUrl('http://host:9500/'),
        token: 'x',
        enabled: true,
      );
      const b = AnyListenConfig(
        serverUrl: 'http://host:9500',
        token: 'x',
        enabled: true,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == b.copyWith(enabled: false), isFalse);
    });
  });

  group('AnyListenConfigStore', () {
    test('空 prefs 返回默认配置（不抛异常）', () async {
      final loaded = await AnyListenConfigStore().load();
      expect(loaded, AnyListenConfig.empty);
    });

    test('save/load 往返，键名带 any_listen_ 前缀', () async {
      final store = AnyListenConfigStore();
      const config = AnyListenConfig(
        serverUrl: 'http://127.0.0.1:9500',
        token: 'secret-token',
        enabled: true,
      );
      expect(await store.save(config), isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('any_listen_server_url'), 'http://127.0.0.1:9500');
      expect(prefs.getString('any_listen_token'), 'secret-token');
      expect(prefs.getBool('any_listen_enabled'), isTrue);

      expect(await store.load(), config);
    });

    test('save 时归一化地址；clear 后恢复默认', () async {
      final store = AnyListenConfigStore();
      await store.save(const AnyListenConfig(
        serverUrl: 'http://host:9500///',
        enabled: true,
      ));
      expect((await store.load()).serverUrl, 'http://host:9500');

      expect(await store.clear(), isTrue);
      expect(await store.load(), AnyListenConfig.empty);
    });
  });
}
