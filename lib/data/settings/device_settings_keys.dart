/// 设备本地设置键总表：迁移到 [DeviceSettings] 的键只在这里声明。
///
/// 键名字符串与迁移前逐字一致（无数据迁移）；默认值也集中在此，store 的
/// 公开常量引用这里，避免同一默认值出现两份。JSON 键在这里同时声明字段
/// 形状（decode / encode），store 不再各自解析原始 Map。
///
/// 这些键**不**进入 `settings_keys.dart` / `kAllSettingsKeys`：设备本地
/// 状态（听感、音量、首次引导）不跟人走，也不进完整备份。
library;

import '../../domain/models/playback_feel.dart';
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

/// 播放手感 JSON 的字段解释：非有限毫秒值视为损坏（`1e999` 会解码成
/// Infinity，直接 `toInt()` 会抛 `UnsupportedError`）。
({PlaybackFadePreset fade, bool smartShuffle})? _decodePlaybackFeel(
  Map<String, dynamic> json,
) {
  final fadeMs = json['fadeMs'];
  final smartShuffle = json['smartShuffle'];
  if (fadeMs is! num || smartShuffle is! bool) return null;
  final milliseconds = fadeMs.toDouble();
  if (!milliseconds.isFinite) return null;
  return (
    fade: PlaybackFadePreset.fromMilliseconds(milliseconds.toInt()),
    smartShuffle: smartShuffle,
  );
}

Map<String, Object?> _encodePlaybackFeel(
  ({PlaybackFadePreset fade, bool smartShuffle}) value,
) => {
  'fadeMs': value.fade.duration.inMilliseconds,
  'smartShuffle': value.smartShuffle,
};

/// 音量 JSON 的字段解释：非有限值视为损坏，越界值仍收进 0..1。
({double volume, bool muted})? _decodePlaybackVolume(
  Map<String, dynamic> json,
) {
  final volume = json['volume'];
  final muted = json['muted'];
  if (volume is! num || muted is! bool) return null;
  final value = volume.toDouble();
  if (!value.isFinite) return null;
  return (volume: value.clamp(0.0, 1.0), muted: muted);
}

Map<String, Object?> _encodePlaybackVolume(
  ({double volume, bool muted}) value,
) => {'volume': value.volume, 'muted': value.muted};

const DeviceJsonSettingKey<({PlaybackFadePreset fade, bool smartShuffle})>
kPlaybackFeelStateKey = DeviceJsonSettingKey(
  kPlaybackFeelStateKeyName,
  (fade: PlaybackFadePreset.ms200, smartShuffle: kDefaultSmartShuffle),
  decode: _decodePlaybackFeel,
  encode: _encodePlaybackFeel,
);

const DeviceJsonSettingKey<({double volume, bool muted})>
kPlaybackVolumeStateKey = DeviceJsonSettingKey(
  kPlaybackVolumeStateKeyName,
  (volume: kDefaultPlaybackVolume, muted: kDefaultPlaybackMuted),
  decode: _decodePlaybackVolume,
  encode: _encodePlaybackVolume,
);

const DeviceSettingKey<double> kPlaybackVolumeKey = DeviceSettingKey(
  kPlaybackVolumeKeyName,
  kDefaultPlaybackVolume,
);
const DeviceSettingKey<bool> kPlaybackMutedKey = DeviceSettingKey(
  kPlaybackMutedKeyName,
  kDefaultPlaybackMuted,
);
const DeviceSettingKey<bool> kOnboardingCompletedKey = DeviceSettingKey(
  kOnboardingCompletedKeyName,
  false,
);

/// 已迁移的设备本地键（顺序即登记顺序；唯一性由测试核对）。
const List<DeviceSettingEntry> kDeviceSettingsKeys = [
  kPlaybackFeelStateKey,
  kPlaybackVolumeStateKey,
  kPlaybackVolumeKey,
  kPlaybackMutedKey,
  kOnboardingCompletedKey,
];
