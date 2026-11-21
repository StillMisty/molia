import 'package:shared_preferences/shared_preferences.dart';

import '../data/settings/device_settings.dart';
import '../data/settings/device_settings_keys.dart';

/// 应用内音量 / 静音状态的**设备本地**持久化。
///
/// 为什么是设备本地键（不登记 `SettingsRegistry`）：音量是设备能力——手机
/// 扬声器与桌面音箱响度不同，跟账号同步只会把 A 设备的响度带到 B 设备上，
/// 产生「什么都没动音量却变了」的错误状态；与省流 / 托盘行为同一取舍，
/// 键名只出现在 `device_settings_keys.dart`。
///
/// 键名 / 默认值 / JSON 编解码与失败策略由 `data/settings/device_settings.dart`
/// 统一提供，本类只解释字段并保留旧版两键的只读兜底。
class PlaybackVolumeStore {
  /// [preferences] 仅测试注入；生产走 SharedPreferences 单例。
  PlaybackVolumeStore({SharedPreferences? preferences})
    : _settings = DeviceSettings(preferences: preferences);

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
    if (state != null) {
      final volume = state['volume'];
      final muted = state['muted'];
      if (volume is num && muted is bool) {
        // 越界值（手工改偏好 / 异常存储）收进合法区间，避免滑块与后端不一致。
        return (volume: volume.toDouble().clamp(0.0, 1.0), muted: muted);
      }
      // 字段损坏：与旧实现一致，继续尝试旧版两键而不是直接回默认。
    }
    return (
      volume: (await _settings.read(kPlaybackVolumeKey)).clamp(0.0, 1.0),
      muted: await _settings.read(kPlaybackMutedKey),
    );
  }

  /// 保存音量与静音状态：本次会话已生效，写失败只影响下次启动。
  Future<void> save({required double volume, required bool muted}) => _settings
      .writeJson(kPlaybackVolumeStateKey, {'volume': volume, 'muted': muted});
}
