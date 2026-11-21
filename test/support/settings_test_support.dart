/// 设置注册表的测试支撑：内存密钥盒与常规构造。
library;

import 'package:molia/data/settings/settings_key.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/data/settings/settings_registry.dart';
import 'package:molia/data/settings/settings_secret_store.dart';
import 'package:molia/services/language_service.dart';
import 'package:molia/services/poster/poster_style_settings.dart';
import 'package:molia/services/shortcut_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 测试用内存密钥盒（替代生产凭据库）。
class MemorySettingsSecretStore implements SettingsSecretStore {
  final Map<String, String> data = {};

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// 用真实登记键表构造注册表（测试可注入 prefs / 密钥盒）。
SettingsRegistry testSettingsRegistry({
  Iterable<SettingsKey<Object?>>? keys,
  SharedPreferences? preferences,
  SettingsSecretStore? secrets,
}) => SettingsRegistry(
  keys: List.of(keys ?? kAllSettingsKeys),
  preferences: preferences,
  secrets: secrets ?? MemorySettingsSecretStore(),
);

/// 装配全静态设置服务（语言 / 快捷键 / 海报样式）。
///
/// 生产由 `catalog_stack.dart` 统一 attach；测试挂载设置页或调用这些服务的
/// 读写入口前必须接线，否则会按设计抛 [StateError]。
void attachStaticSettingsForTest(SettingsRegistry registry) {
  LanguageService.attachSettings(registry);
  ShortcutSettings.attachSettings(registry);
  PosterStyleSettings.attachSettings(registry);
}
