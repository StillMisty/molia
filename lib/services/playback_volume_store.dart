import 'package:shared_preferences/shared_preferences.dart';

/// 应用内音量 / 静音状态的**设备本地**持久化。
///
/// 为什么是设备本地键（不登记 `SettingsRegistry`）：音量是设备能力——手机
/// 扬声器与桌面音箱响度不同，跟账号同步只会把 A 设备的响度带到 B 设备上，
/// 产生「什么都没动音量却变了」的错误状态；与省流 / 托盘行为同一取舍，
/// 键名只出现在本文件。
///
/// 读写失败静默（读取回默认、写入不打断交互）：音量是尽力而为的体验设置，
/// 存储不可用（测试 / 平台异常）时播放照常。
class PlaybackVolumeStore {
  /// [_preferences] 仅测试注入；生产走 SharedPreferences 单例。
  PlaybackVolumeStore({this._preferences});

  /// 设备本地键。
  static const String keyVolume = 'playback_volume';
  static const String keyMuted = 'playback_muted';

  /// 默认满音量、未静音：应用内音量完全由用户显式调整。
  static const double defaultVolume = 1.0;
  static const bool defaultMuted = false;

  final SharedPreferences? _preferences;

  /// 读取已保存的音量与静音状态；无记录 / 读取失败回默认值。
  Future<({double volume, bool muted})> load() async {
    try {
      final prefs = _preferences ?? await SharedPreferences.getInstance();
      return (
        // 越界值（手工改偏好 / 异常存储）收进合法区间，避免滑块与后端不一致。
        volume: (prefs.getDouble(keyVolume) ?? defaultVolume).clamp(0.0, 1.0),
        muted: prefs.getBool(keyMuted) ?? defaultMuted,
      );
    } catch (_) {
      return (volume: defaultVolume, muted: defaultMuted);
    }
  }

  /// 保存音量与静音状态：本次会话已生效，写失败只影响下次启动。
  Future<void> save({required double volume, required bool muted}) async {
    try {
      final prefs = _preferences ?? await SharedPreferences.getInstance();
      await prefs.setDouble(keyVolume, volume);
      await prefs.setBool(keyMuted, muted);
    } catch (_) {
      // 静默：持久化失败不值得打断用户操作。
    }
  }
}
