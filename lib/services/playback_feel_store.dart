import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/models/playback_feel.dart';

/// 播放手感（淡入淡出 / 智能随机）的**设备本地**持久化。
///
/// 为什么不登记 `SettingsRegistry`：与音量同一条理由——听感是设备能力，
/// 手机扬声器与桌面音箱对淡变的感受不同；跟账号走只会让另一台设备莫名
/// 变了手感。协议 / 会话也都不该出现这两个值。
///
/// 两个值合并成一个 JSON 键：桌面 `shared_preferences` 每次写都会重写整个
/// 偏好文件，两次写入就是两次整文件 I/O。
class PlaybackFeelStore {
  /// [_preferences] 仅测试注入；生产走 SharedPreferences 单例。
  PlaybackFeelStore({this._preferences});

  static const String keyState = 'playback_feel_state_v1';

  static PlaybackFadePreset get defaultFade => PlaybackFadePreset.defaultPreset;
  static const bool defaultSmartShuffle = true;

  final SharedPreferences? _preferences;

  /// 读取已保存的手感设置；无记录 / 读取失败 / 字段损坏回默认值。
  Future<({PlaybackFadePreset fade, bool smartShuffle})> load() async {
    try {
      final prefs = _preferences ?? await SharedPreferences.getInstance();
      final decoded = _decode(prefs.getString(keyState));
      if (decoded == null) {
        return (fade: defaultFade, smartShuffle: defaultSmartShuffle);
      }
      return (
        fade: PlaybackFadePreset.fromMilliseconds(decoded.fadeMs),
        smartShuffle: decoded.smartShuffle,
      );
    } catch (_) {
      return (fade: defaultFade, smartShuffle: defaultSmartShuffle);
    }
  }

  /// 保存手感设置：写失败只影响下次启动，不打断当前交互。
  Future<void> save({
    required PlaybackFadePreset fade,
    required bool smartShuffle,
  }) async {
    try {
      final prefs = _preferences ?? await SharedPreferences.getInstance();
      await prefs.setString(
        keyState,
        jsonEncode({
          'fadeMs': fade.duration.inMilliseconds,
          'smartShuffle': smartShuffle,
        }),
      );
    } catch (_) {
      // 静默：持久化失败不值得打断用户操作。
    }
  }

  static ({int? fadeMs, bool smartShuffle})? _decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final fadeMs = decoded['fadeMs'];
      final smartShuffle = decoded['smartShuffle'];
      if (fadeMs is! num || smartShuffle is! bool) return null;
      return (fadeMs: fadeMs.toInt(), smartShuffle: smartShuffle);
    } on FormatException {
      return null;
    }
  }
}
