import 'dart:io';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';

final logger = Logger();

class LanguageService {
  static const String _languageKey = 'selected_language';
  static const MethodChannel _channel = MethodChannel('language_channel');

  /// 应用界面语言的运行时通知源。
  ///
  /// null 表示跟随系统；MyThemedApp 订阅它，设置页切换语言后立即生效。
  static final ValueNotifier<Locale?> localeNotifier = ValueNotifier<Locale?>(null);

  static const List<Locale> supportedLocales = [
    Locale('en'),
    Locale('zh'),
  ];
  
  /// 获取当前保存的语言设置
  static Future<Locale?> getSavedLocale() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final languageCode = prefs.getString(_languageKey);
      
      if (languageCode == null) return null;
      
      final parts = languageCode.split('_');
      if (parts.length == 1) {
        return Locale(parts[0]);
      } else if (parts.length == 2) {
        return Locale(parts[0], parts[1]);
      }
      
      return null;
    } catch (e) {
      logger.d('Error getting saved locale: $e');
      return null;
    }
  }
  
  /// 保存语言设置
  static Future<void> saveLocale(Locale locale) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final languageCode = locale.countryCode != null 
          ? '${locale.languageCode}_${locale.countryCode}'
          : locale.languageCode;
      
      await prefs.setString(_languageKey, languageCode);
      localeNotifier.value = locale;
    } catch (e) {
      logger.d('Error saving locale: $e');
    }
  }
  
  /// 清除语言设置（跟随系统）
  static Future<void> clearSavedLocale() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_languageKey);
      localeNotifier.value = null;
    } catch (e) {
      logger.d('Error clearing saved locale: $e');
    }
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

          await _channel.invokeMethod(
              'setAppLocale', {'languageTag': languageTag});
        }
      } catch (e) {
        logger.d('Error setting app locale: $e');
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
      logger.d('Error opening system language settings: $e');
    }
  }
  
  /// 检查是否支持系统级语言设置（Android 13+）
  static Future<bool> supportsSystemLanguageSettings() async {
    if (!Platform.isAndroid) return false;
    
    try {
      final result = await _channel.invokeMethod('supportsSystemLanguageSettings');
      return result as bool? ?? false;
    } catch (e) {
      logger.d('Error checking system language support: $e');
      return false;
    }
  }
  
}