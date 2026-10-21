import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/domain/models/ai_dj.dart';
import 'package:molia/services/ai/ai_settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:convert';

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
        settings: testSettingsRegistry(preferences: prefs, secrets: secrets));
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
        settings: testSettingsRegistry(preferences: prefs, secrets: secrets));
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

  test('推荐偏好 JSON 往返与默认值（非法值回退）', () async {
    expect((await store.readPreferences()).batchSize, 20);
    expect((await store.readPreferences()).autoFeed, isTrue);
    expect(
        (await store.readPreferences()).sections, kAiDefaultUpstreamSections);

    const preferences = AiPreferences(
      batchSize: 30,
      autoFeed: false,
      styles: ['pop', 'jazz'],
      scenes: ['commute'],
      languages: ['mandarin'],
      era: kAiEra2010s,
      exploration: kAiExplorationSurprise,
      onlyUnheard: false,
      extraPrompt: '想听女声',
      sections: {
        AiUpstreamSection.summary,
        AiUpstreamSection.favorites,
      },
      sourceKeys: ['wy', 'tx'],
      seeds: ['晴天 - 周杰伦'],
    );
    await store.savePreferences(preferences);

    final loaded = await store.readPreferences();
    expect(loaded.batchSize, 30);
    expect(loaded.autoFeed, isFalse);
    expect(loaded.styles, ['pop', 'jazz']);
    expect(loaded.scenes, ['commute']);
    expect(loaded.languages, ['mandarin']);
    expect(loaded.era, kAiEra2010s);
    expect(loaded.exploration, kAiExplorationSurprise);
    expect(loaded.onlyUnheard, isFalse);
    expect(loaded.extraPrompt, '想听女声');
    expect(loaded.sections, {
      AiUpstreamSection.summary,
      AiUpstreamSection.favorites,
    });
    expect(loaded.sourceKeys, ['wy', 'tx']);
    expect(loaded.seeds, ['晴天 - 周杰伦']);

    await prefs.setString(kAiDjPreferences.name, jsonEncode({'batchSize': 7}));
    expect((await store.readPreferences()).batchSize, 20);
    await prefs.setString(kAiDjPreferences.name, 'not-json{{{');
    expect((await store.readPreferences()).batchSize, 20);
  });

  test('反馈记忆 JSON 往返、去重与上限', () async {
    expect((await store.readFeedbackMemory()).skipped, isEmpty);

    await store.saveFeedbackMemory(const AiFeedbackMemory(
      skipped: ['A', 'A', 'B'],
      liked: ['C'],
      seeds: ['D'],
    ));

    final loaded = await store.readFeedbackMemory();
    expect(loaded.skipped, ['A', 'B']);
    expect(loaded.liked, ['C']);
    expect(loaded.seeds, ['D']);

    final many = AiFeedbackMemory(
      skipped: [for (var i = 0; i < 250; i++) 'S$i'],
      liked: [for (var i = 0; i < 250; i++) 'L$i'],
      seeds: [for (var i = 0; i < 30; i++) 'D$i'],
    );
    await store.saveFeedbackMemory(many);
    final trimmed = await store.readFeedbackMemory();
    expect(trimmed.skipped, hasLength(AiFeedbackMemory.skippedLimit));
    expect(trimmed.liked, hasLength(AiFeedbackMemory.likedLimit));
    expect(trimmed.seeds, hasLength(AiFeedbackMemory.seedLimit));

    await prefs.setString(kAiDjFeedbackMemory.name, 'not-json{{{');
    expect((await store.readFeedbackMemory()).skipped, isEmpty);
  });
}
