import '../data/settings/settings_keys.dart';
import '../data/settings/settings_registry.dart';

/// 应用设置（纯播放器）：仅保留歌词复制格式。
///
/// 值存 secure 盒（历史原因，不进明文备份）；读写经设置注册表。
class SettingsService {
  SettingsService({SettingsRegistry? settings})
      : _settings = settings ?? SettingsRegistry(keys: kAllSettingsKeys);

  final SettingsRegistry _settings;

  Future<void> saveCopyLyricsAsSingleLine(bool value) =>
      _settings.write(kCopyLyricsSingleLine, value.toString());

  Future<bool> getCopyLyricsAsSingleLine() async =>
      (await _settings.read(kCopyLyricsSingleLine))?.toLowerCase() == 'true';

  Future<void> clearSettings() => _settings.clear(kCopyLyricsSingleLine);
}
