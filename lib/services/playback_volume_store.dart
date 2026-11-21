import '../data/settings/device_settings.dart';
import '../data/settings/device_settings_keys.dart';

/// 应用内音量 / 静音状态的**设备本地**持久化。
///
/// 为什么是设备本地键（不登记 `SettingsRegistry`）：音量是设备能力——手机
/// 扬声器与桌面音箱响度不同，跟账号同步只会把 A 设备的响度带到 B 设备上，
/// 产生「什么都没动音量却变了」的错误状态；与省流 / 托盘行为同一取舍，
/// 键名只出现在 `device_settings_keys.dart`。
///
/// 字段形状（含非有限数值校验与 0..1 收拢）由 `device_settings_keys.dart`
/// 的 JSON 键定义；本类只负责选择键、旧版两键兜底与暴露默认值。
class PlaybackVolumeStore {
  /// [settings] 仅测试注入；生产构造自己的设备本地入口。
  PlaybackVolumeStore({DeviceSettings? settings})
    : _settings = settings ?? DeviceSettings();

  /// 音量与静音合并成一个 JSON 字符串：桌面 shared_preferences 每次 set*
  /// 都会重写整个偏好文件，两次写入就是两次整文件 I/O。
  static const String keyState = kPlaybackVolumeStateKeyName;

  // 旧版两键：只读兜底，新键缺失时读取。
  static const String keyVolume = kPlaybackVolumeKeyName;
  static const String keyMuted = kPlaybackMutedKeyName;

  /// 默认满音量、未静音：应用内音量完全由用户显式调整。
  static const double defaultVolume = kDefaultPlaybackVolume;
  static const bool defaultMuted = kDefaultPlaybackMuted;

  final DeviceSettings _settings;

  /// 读取已保存的音量与静音状态；无记录 / 读取失败回默认值。
  Future<({double volume, bool muted})> load() async {
    final state = await _settings.readJson(kPlaybackVolumeStateKey);
    if (state != null) return state;

    // 旧版两键整组回退：任一读取抛错（例如被手工改成字符串）时，音量与
    // 静音一起回默认，避免出现「默认音量 + 意外静音」的组合。缺键不算
    // 失败（两键各取默认），与旧版行为一致。
    final legacyVolume = await _settings.tryRead(kPlaybackVolumeKey);
    final legacyMuted = await _settings.tryRead(kPlaybackMutedKey);
    if (!legacyVolume.ok || !legacyMuted.ok) {
      return (volume: defaultVolume, muted: defaultMuted);
    }
    return (
      volume: legacyVolume.value.clamp(0.0, 1.0),
      muted: legacyMuted.value,
    );
  }

  /// 保存音量与静音状态：本次会话已生效，写失败只影响下次启动。
  Future<void> save({required double volume, required bool muted}) => _settings
      .writeJson(kPlaybackVolumeStateKey, (volume: volume, muted: muted));
}
