/// SettingsRegistry 的契约：整表驱动的读写、默认值、宽容转换、reload 钩子。
///
/// 这些测试故意按 [kAllSettingsKeys] 整表遍历：任何新登记键的类型 / 存放盒
/// 写错都会在这里红（比逐个键的单元测试更早发现漂移）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/settings_key.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/data/settings/settings_registry.dart';
import 'package:molia/data/settings/settings_secret_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemorySecrets implements SettingsSecretStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// 按键的静态类型造一个与默认值不同的样本值。
Object? _sampleFor(SettingsKey<Object?> key) {
  if (key is SettingsKey<bool>) return !key.defaultValue;
  if (key is SettingsKey<int>) return key.defaultValue + 1;
  if (key is SettingsKey<List<String>>) return ['a', 'b'];
  return key.defaultValue == null ? 'value' : '${key.defaultValue}-value';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  SettingsRegistry build({
    Map<String, Object> initial = const {},
    SettingsSecretStore? secrets,
  }) {
    SharedPreferences.setMockInitialValues(initial);
    return SettingsRegistry(
      keys: kAllSettingsKeys,
      secrets: secrets ?? _MemorySecrets(),
    );
  }

  test('整表：写样本值读回一致（类型推导）', () async {
    final registry = build();
    for (final key in kAllSettingsKeys) {
      final sample = _sampleFor(key);
      await registry.write(key, sample);
      expect(await registry.read(key), sample, reason: key.name);
      expect(await registry.readRaw(key), sample, reason: key.name);
    }
  });

  test('整表：写 null 回退默认值', () async {
    final registry = build();
    for (final key in kAllSettingsKeys) {
      await registry.write(key, _sampleFor(key));
      await registry.write(key, null);
      expect(await registry.read(key), key.defaultValue, reason: key.name);
    }
  });

  test('整表：未写入时读回默认值，且不写回 prefs', () async {
    final registry = build();
    for (final key in kAllSettingsKeys) {
      expect(await registry.read(key), key.defaultValue, reason: key.name);
    }
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), isEmpty);
  });

  test('writeRaw 宽容转换：字符串布尔 / 数字字符串 / 非法值删除', () async {
    final registry = build();
    await registry.writeRaw(kFollowArtworkEnabled, 'false');
    expect(await registry.read(kFollowArtworkEnabled), false);

    await registry.writeRaw(kSeedColor, '16711680');
    expect(await registry.read(kSeedColor), 16711680);

    await registry.writeRaw(kSeedColor, 'not-a-number');
    expect(await registry.read(kSeedColor), kSeedColor.defaultValue);

    await registry.writeRaw(kShellNavOrder, ['a', 1, 'b']);
    expect(await registry.read(kShellNavOrder), ['a', 'b']);

    await registry.writeRaw(kShellNavOrder, 'oops');
    expect(await registry.read(kShellNavOrder), kShellNavOrder.defaultValue);
  });

  test('secure 盒：只进 secret store；空串与 null 删除', () async {
    final secrets = _MemorySecrets();
    final registry = build(secrets: secrets);

    await registry.write(kAiDjApiKey, 'sk-1');
    expect(secrets.values[kAiDjApiKey.name], 'sk-1');
    expect(await registry.read(kAiDjApiKey), 'sk-1');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(kAiDjApiKey.name), isFalse);

    await registry.write(kAiDjApiKey, '');
    expect(secrets.values.containsKey(kAiDjApiKey.name), isFalse);
    expect(await registry.read(kAiDjApiKey), kAiDjApiKey.defaultValue);
  });

  test('reload：按变化的键触发，同一钩子绑多个键只跑一次', () async {
    final registry = build();
    var themeReloads = 0;
    Future<void> themeReload() async => themeReloads++;
    registry.bindReload(kThemeMode, themeReload);
    registry.bindReload(kColorBase, themeReload);
    registry.bindReload(kSeedColor, themeReload);
    var sourceReloads = 0;
    registry.bindReload(kLxSourceOrder, () async => sourceReloads++);

    await registry.reloadKeys(['theme_mode', 'color_base', 'unknown_key']);
    expect(themeReloads, 1, reason: '三个键共用同一钩子 → 只跑一次');
    expect(sourceReloads, 0);

    await registry.reloadKeys(['lx_source_order']);
    expect(sourceReloads, 1);
    expect(themeReloads, 1);
  });

  test('重复键名在构造时被拦下', () {
    expect(
      () => SettingsRegistry(keys: [kThemeMode, kThemeMode]),
      throwsA(isA<AssertionError>()),
    );
  });

  test('写入回调：每次写入（含删除与安全盒）都通知，带上键', () async {
    final written = <String>[];
    final secrets = _MemorySecrets();
    final registry = build(secrets: secrets)
      ..onWrite = (key) => written.add(key.name);

    await registry.write(kThemeMode, 'dark');
    await registry.clear(kSeedColor);
    await registry.write(kAiDjApiKey, 'sk-1');
    await registry.writeRaw(kThemeMode, null);

    expect(written, [
      kThemeMode.name,
      kSeedColor.name,
      kAiDjApiKey.name,
      kThemeMode.name,
    ]);
  });
}
