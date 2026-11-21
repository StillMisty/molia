/// 设备本地设置键总表：迁移到 [DeviceSettings] 的键只在这里声明。
///
/// 键名字符串与迁移前逐字一致（无数据迁移）；默认值也集中在此，store 的
/// 公开常量引用这里，避免同一默认值出现两份。
///
/// 这些键**不**进入 `settings_keys.dart` / `kAllSettingsKeys`：设备本地
/// 状态（听感、音量、首次引导）不跟人走，也不进完整备份。
library;

import 'device_settings.dart';

/// 播放手感（淡入淡出 / 智能随机）合并键。
const String kPlaybackFeelStateKeyName = 'playback_feel_state_v1';

/// 音量与静音合并键。
const String kPlaybackVolumeStateKeyName = 'playback_volume_state_v1';

/// 旧版音量两键：只读兜底，新键缺失时才读。
const String kPlaybackVolumeKeyName = 'playback_volume';
const String kPlaybackMutedKeyName = 'playback_muted';

/// 首次引导完成标记。
const String kOnboardingCompletedKeyName = 'onboarding_completed_v1';

/// 播放手感的默认值（store 的公开常量引用这里）。
const bool kDefaultSmartShuffle = true;

/// 音量的默认值（store 的公开常量引用这里）。
const double kDefaultPlaybackVolume = 1.0;
const bool kDefaultPlaybackMuted = false;

const DeviceSettingKey<String> kPlaybackFeelStateKey = DeviceSettingKey(
  kPlaybackFeelStateKeyName,
  '',
  kind: DeviceSettingKind.text,
);
const DeviceSettingKey<String> kPlaybackVolumeStateKey = DeviceSettingKey(
  kPlaybackVolumeStateKeyName,
  '',
  kind: DeviceSettingKind.text,
);
const DeviceSettingKey<double> kPlaybackVolumeKey = DeviceSettingKey(
  kPlaybackVolumeKeyName,
  kDefaultPlaybackVolume,
  kind: DeviceSettingKind.decimal,
);
const DeviceSettingKey<bool> kPlaybackMutedKey = DeviceSettingKey(
  kPlaybackMutedKeyName,
  kDefaultPlaybackMuted,
  kind: DeviceSettingKind.boolean,
);
const DeviceSettingKey<bool> kOnboardingCompletedKey = DeviceSettingKey(
  kOnboardingCompletedKeyName,
  false,
  kind: DeviceSettingKind.boolean,
);

/// 已迁移的设备本地键（顺序即登记顺序；唯一性由测试核对）。
const List<DeviceSettingKey<Object>> kDeviceSettingsKeys = [
  kPlaybackFeelStateKey,
  kPlaybackVolumeStateKey,
  kPlaybackVolumeKey,
  kPlaybackMutedKey,
  kOnboardingCompletedKey,
];
