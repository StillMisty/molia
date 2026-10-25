/// 下载设置（设备本地项：保存位置 / 文件名格式 / 标签嵌入 / 公共目录发布 /
/// 下载通知）。
///
/// 为什么**不登记**进 `SettingsRegistry`：保存位置是设备相关路径、文件名
/// 模板是设备偏好、公共目录发布是 Android 平台能力，跨设备同步过去只会
/// 互相打架（与缓存策略键同一取舍）。
/// 键名只出现在本文件（`settings_keys_test` 只约束登记键）。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 默认文件名模板：`{artist} - {title}`（无歌手时只留歌名）。
const String kDefaultFilenameTemplate = '{artist} - {title}';

/// 模板可用占位符（设置页提示文案用）。
const List<String> kFilenameTemplatePlaceholders = [
  '{artist}',
  '{title}',
  '{album}',
];

/// 下载设置：读写 `SharedPreferences`，变更即时生效（服务每次下载读取）。
class DownloadSettings extends ChangeNotifier {
  DownloadSettings({this._prefs});

  static const String keySaveDir = 'download_save_dir';
  static const String keyFilenameTemplate = 'download_filename_template';
  static const String keyEmbedTags = 'download_embed_tags';
  static const String keyPublishToPublicDir = 'download_publish_public_dir';
  static const String keyNotifications = 'download_notifications';

  SharedPreferences? _prefs;

  /// 自定义保存目录（空 = 平台默认：桌面系统下载目录下 `Molia/`）。
  String _saveDir = '';

  String _filenameTemplate = kDefaultFilenameTemplate;

  bool _embedTags = true;

  /// 发布公共 Downloads 副本（仅 Android 生效；默认开）。
  bool _publishToPublicDir = true;

  /// 下载进度通知（仅 Android 生效：前台服务 + 通知栏进度；默认开）。
  bool _notifications = true;

  String get saveDir => _saveDir;
  String get filenameTemplate => _filenameTemplate;
  bool get embedTags => _embedTags;
  bool get publishToPublicDir => _publishToPublicDir;
  bool get notifications => _notifications;

  /// 绑定 prefs 并加载已保存值（组合根 / 测试调用一次）。
  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
    final prefs = _prefs;
    _saveDir = prefs?.getString(keySaveDir) ?? '';
    _filenameTemplate =
        prefs?.getString(keyFilenameTemplate) ?? kDefaultFilenameTemplate;
    _embedTags = prefs?.getBool(keyEmbedTags) ?? true;
    _publishToPublicDir = prefs?.getBool(keyPublishToPublicDir) ?? true;
    _notifications = prefs?.getBool(keyNotifications) ?? true;
    notifyListeners();
  }

  Future<void> setSaveDir(String value) async {
    final next = value.trim();
    if (next == _saveDir) return;
    _saveDir = next;
    await _prefs?.setString(keySaveDir, next);
    notifyListeners();
  }

  Future<void> setFilenameTemplate(String value) async {
    final next = value.trim().isEmpty ? kDefaultFilenameTemplate : value.trim();
    if (next == _filenameTemplate) return;
    _filenameTemplate = next;
    await _prefs?.setString(keyFilenameTemplate, next);
    notifyListeners();
  }

  Future<void> setEmbedTags(bool value) async {
    if (value == _embedTags) return;
    _embedTags = value;
    await _prefs?.setBool(keyEmbedTags, value);
    notifyListeners();
  }

  /// 公共目录发布开关（只影响之后的下载；已有下载用管理页「补发布」）。
  Future<void> setPublishToPublicDir(bool value) async {
    if (value == _publishToPublicDir) return;
    _publishToPublicDir = value;
    await _prefs?.setBool(keyPublishToPublicDir, value);
    notifyListeners();
  }

  /// 下载进度通知开关（只影响之后的下载；进行中的任务保持原状）。
  Future<void> setNotifications(bool value) async {
    if (value == _notifications) return;
    _notifications = value;
    await _prefs?.setBool(keyNotifications, value);
    notifyListeners();
  }

  /// 按模板生成文件名基名（未做非法字符清洗，由下载服务统一 sanitize）。
  ///
  /// 未知占位符原样保留（用户可能想要字面量 `{}` 文本）。
  static String applyTemplate(
    String template,
    Map<String, String> values,
  ) {
    var result = template;
    for (final entry in values.entries) {
      result = result.replaceAll('{${entry.key}}', entry.value);
    }
    return result.trim();
  }
}
