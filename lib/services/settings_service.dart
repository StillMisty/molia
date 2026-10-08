import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 应用设置（纯播放器）：仅保留歌词复制格式。
class SettingsService {
  final _secureStorage = FlutterSecureStorage();

  static const _copyLyricsAsSingleLineKey = 'copy_lyrics_single_line';

  Future<void> saveCopyLyricsAsSingleLine(bool value) async {
    await _secureStorage.write(
        key: _copyLyricsAsSingleLineKey, value: value.toString());
  }

  Future<bool> getCopyLyricsAsSingleLine() async {
    final valueString =
        await _secureStorage.read(key: _copyLyricsAsSingleLineKey);
    // 解析字符串为 bool；null 时默认 false。
    return valueString?.toLowerCase() == 'true';
  }

  Future<void> clearSettings() async {
    await _secureStorage.delete(key: _copyLyricsAsSingleLineKey);
  }
}
