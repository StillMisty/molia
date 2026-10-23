import 'dart:io';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import '../data/settings/settings_access.dart';
import '../data/settings/settings_keys.dart';

final logger = Logger('molia.language_service');

class LanguageService {
  static const MethodChannel _channel = MethodChannel('language_channel');

  /// 设置注册表（组合根启动时注入；本服务全静态，reload 也由组合根代绑）。
  static late final SettingsAccess _settings;

  static void attachSettings(SettingsAccess settings) => _settings = settings;

  /// 应用界面语言的运行时通知源。
  ///
  /// null 表示跟随系统；MyThemedApp 订阅它，设置页切换语言后立即生效。
  static final ValueNotifier<Locale?> localeNotifier =
      ValueNotifier<Locale?>(null);

  static const List<Locale> supportedLocales = [
    Locale('en'),
    Locale('zh'),
  ];

  /// 当前生效的界面语言：用户选择优先，否则跟随系统；不支持的语言回退
  /// 支持列表首个（与媒体通知/托盘同一解析口径）。
  static Locale get effectiveLocale {
    final selected = localeNotifier.value;
    final effective =
        selected ?? WidgetsBinding.instance.platformDispatcher.locale;
    return supportedLocales.any(
      (supported) => supported.languageCode == effective.languageCode,
    )
        ? effective
        : supportedLocales.first;
  }

  /// 获取当前保存的语言设置
  static Future<Locale?> getSavedLocale() async {
    try {
      final languageCode = await _settings.read(kSelectedLanguage);

      if (languageCode == null) return null;

      final parts = languageCode.split('_');
      if (parts.length == 1) {
        return Locale(parts[0]);
      } else if (parts.length == 2) {
        return Locale(parts[0], parts[1]);
      }

      return null;
    } catch (e) {
      logger.fine('Error getting saved locale: $e');
      return null;
    }
  }

  /// 保存语言设置
  static Future<void> saveLocale(Locale locale) async {
    try {
      final languageCode = locale.countryCode != null
          ? '${locale.languageCode}_${locale.countryCode}'
          : locale.languageCode;

      await _settings.write(kSelectedLanguage, languageCode);
      localeNotifier.value = locale;
    } catch (e) {
      logger.fine('Error saving locale: $e');
    }
  }

  /// 清除语言设置（跟随系统）
  static Future<void> clearSavedLocale() async {
    try {
      await _settings.clear(kSelectedLanguage);
      localeNotifier.value = null;
    } catch (e) {
      logger.fine('Error clearing saved locale: $e');
    }
  }

  /// 重新读取已保存语言并通知（跨设备同步应用远端设置后由组合根调用；
  /// Android 系统级语言设置需用户下次进入设置页切换，此处只影响应用内）。
  static Future<void> reloadFromPreferences() async {
    localeNotifier.value = await getSavedLocale();
  }

  /// 设置应用语言（Android 13+ 使用系统API，其余平台仅应用内切换）
  static Future<void> setAppLocale(Locale? locale) async {
    if (Platform.isAndroid) {
      try {
        if (locale == null) {
          // 清除设置，跟随系统
          await _channel.invokeMethod('clearAppLocale');
        } else {
          final languageTag = locale.countryCode != null
              ? '${locale.languageCode}-${locale.countryCode}'
              : locale.languageCode;

          await _channel
              .invokeMethod('setAppLocale', {'languageTag': languageTag});
        }
      } catch (e) {
        logger.fine('Error setting app locale: $e');
        // 降级到仅保存偏好设置
      }
    }

    if (locale != null) {
      await saveLocale(locale);
    } else {
      await clearSavedLocale();
    }
  }

  /// 打开系统语言设置页面（Android 13+）
  static Future<void> openSystemLanguageSettings() async {
    if (!Platform.isAndroid) return;

    try {
      await _channel.invokeMethod('openSystemLanguageSettings');
    } catch (e) {
      logger.fine('Error opening system language settings: $e');
    }
  }

  /// 检查是否支持系统级语言设置（Android 13+）
  static Future<bool> supportsSystemLanguageSettings() async {
    if (!Platform.isAndroid) return false;

    try {
      final result =
          await _channel.invokeMethod('supportsSystemLanguageSettings');
      return result as bool? ?? false;
    } catch (e) {
      logger.fine('Error checking system language support: $e');
      return false;
    }
  }
}
