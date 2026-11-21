import 'package:shared_preferences/shared_preferences.dart';

import '../data/settings/device_settings.dart';
import '../data/settings/device_settings_keys.dart';
import '../domain/models/playback_feel.dart';

/// 播放手感（淡入淡出 / 智能随机）的**设备本地**持久化。
///
/// 为什么不登记 `SettingsRegistry`：与音量同一条理由——听感是设备能力，
/// 手机扬声器与桌面音箱对淡变的感受不同；跟账号走只会让另一台设备莫名
/// 变了手感。协议 / 会话也都不该出现这两个值。
///
/// 两个值合并成一个 JSON 键：桌面 `shared_preferences` 每次写都会重写整个
/// 偏好文件，两次写入就是两次整文件 I/O。键名 / 默认值 / 编解码与失败策略
/// 收在 `data/settings/device_settings.dart`，本类只做字段解释。
class PlaybackFeelStore {
  /// [preferences] 仅测试注入；生产走 SharedPreferences 单例。
  PlaybackFeelStore({SharedPreferences? preferences})
    : _settings = DeviceSettings(preferences: preferences);

  static const String keyState = kPlaybackFeelStateKeyName;

  static PlaybackFadePreset get defaultFade => PlaybackFadePreset.defaultPreset;
  static const bool defaultSmartShuffle = kDefaultSmartShuffle;

  final DeviceSettings _settings;

  /// 读取已保存的手感设置；无记录 / 读取失败 / 字段损坏回默认值。
  Future<({PlaybackFadePreset fade, bool smartShuffle})> load() async {
    final decoded = await _settings.readJson(kPlaybackFeelStateKey);
    final fadeMs = decoded?['fadeMs'];
    final smartShuffle = decoded?['smartShuffle'];
    if (fadeMs is! num || smartShuffle is! bool) {
      return (fade: defaultFade, smartShuffle: defaultSmartShuffle);
    }
    return (
      fade: PlaybackFadePreset.fromMilliseconds(fadeMs.toInt()),
      smartShuffle: smartShuffle,
    );
  }

  /// 保存手感设置：写失败只影响下次启动，不打断当前交互。
  Future<void> save({
    required PlaybackFadePreset fade,
    required bool smartShuffle,
  }) => _settings.writeJson(kPlaybackFeelStateKey, {
    'fadeMs': fade.duration.inMilliseconds,
    'smartShuffle': smartShuffle,
  });
}
