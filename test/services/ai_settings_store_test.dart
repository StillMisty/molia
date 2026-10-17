import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/domain/models/ai_dj.dart';
import 'package:molia/services/ai/ai_settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/settings_test_support.dart';

/// 内存密钥存储替身（不触碰 flutter_secure_storage 平台通道）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemorySettingsSecretStore secrets;
  late SharedPreferences prefs;
  late AiSettingsStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    secrets = MemorySettingsSecretStore();
    store = AiSettingsStore(
            settings: testSettingsRegistry(
                preferences: prefs, secrets: secrets));
  });

  test('配置保存 / 读取 / 清空往返（去首尾空白）', () async {
    await store.saveConfig(const LlmConfig(
      baseUrl: ' https://api.deepseek.com ',
      apiKey: ' sk-abc ',
      model: ' deepseek-chat ',
    ));

    final config = await store.readConfig();
    expect(config!.baseUrl, 'https://api.deepseek.com');
    expect(config.apiKey, 'sk-abc');
    expect(config.model, 'deepseek-chat');

    await store.clearConfig();
    expect(await store.readConfig(), isNull);
  });

  test('缺项返回 null（页面据此引导配置）', () async {
    await secrets.write(kAiDjBaseUrl.name, 'https://x.example');
    expect(await store.readConfig(), isNull);
  });

  test('隐私确认标记持久化（默认未确认）', () async {
    expect(await store.hasConsent(), isFalse);

    await store.grantConsent();

    expect(await store.hasConsent(), isTrue);
    final fresh = AiSettingsStore(
            settings: testSettingsRegistry(
                preferences: prefs, secrets: secrets));
    expect(await fresh.hasConsent(), isTrue);

    await store.revokeConsent();
    expect(await store.hasConsent(), isFalse);
  });

  test('maskedApiKey 脱敏展示', () {
    const config = LlmConfig(
      baseUrl: 'https://x.example',
      apiKey: 'sk-1234567890',
      model: 'm',
    );
    expect(config.maskedApiKey, 'sk-1••••7890');
    expect(config.maskedApiKey.contains('2345'), isFalse);

    const short = LlmConfig(baseUrl: 'u', apiKey: '12345678', model: 'm');
    expect(short.maskedApiKey, '••••');
  });
}
