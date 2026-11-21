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
/// 偏好文件，两次写入就是两次整文件 I/O。字段形状（含非有限数值校验）由
/// `device_settings_keys.dart` 的 JSON 键定义，本类只负责选择键与暴露默认值。
class PlaybackFeelStore {
  /// [settings] 仅测试注入；生产构造自己的设备本地入口。
  PlaybackFeelStore({DeviceSettings? settings})
    : _settings = settings ?? DeviceSettings();

  static const String keyState = kPlaybackFeelStateKeyName;

  static PlaybackFadePreset get defaultFade => PlaybackFadePreset.defaultPreset;
  static const bool defaultSmartShuffle = kDefaultSmartShuffle;

  final DeviceSettings _settings;

  /// 读取已保存的手感设置；无记录 / 读取失败 / 字段损坏回默认值。
  Future<({PlaybackFadePreset fade, bool smartShuffle})> load() async {
    final state = await _settings.readJson(kPlaybackFeelStateKey);
    return state ?? kPlaybackFeelStateKey.defaultValue;
  }

  /// 保存手感设置：写失败只影响下次启动，不打断当前交互。
  Future<void> save({
    required PlaybackFadePreset fade,
    required bool smartShuffle,
  }) => _settings.writeJson(kPlaybackFeelStateKey, (
    fade: fade,
    smartShuffle: smartShuffle,
  ));
}
