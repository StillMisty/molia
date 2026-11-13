/// 播放手感（淡入淡出 / 智能随机）的设备本地选择。
///
/// 与音量同一取舍：不同设备的听感偏好不同，这些值不随账号同步，也不写入
/// 播放会话；具体持久化在 `services/playback_feel_store.dart`。
library;

/// 淡入淡出档位：关闭 / 0.15 秒 / 0.2 秒 / 0.3 秒。
///
/// 200ms 是显式预设（默认值），不是另外两个档位的隐藏中点。
enum PlaybackFadePreset {
  off(Duration.zero),
  ms150(Duration(milliseconds: 150)),
  ms200(Duration(milliseconds: 200)),
  ms300(Duration(milliseconds: 300));

  const PlaybackFadePreset(this.duration);

  final Duration duration;

  /// 默认淡入淡出：200ms。
  static PlaybackFadePreset get defaultPreset => PlaybackFadePreset.ms200;

  /// 从持久化毫秒值还原；未知值回默认（手工改偏好 / 旧版本不抛错）。
  static PlaybackFadePreset fromMilliseconds(int? milliseconds) {
    for (final preset in values) {
      if (preset.duration.inMilliseconds == milliseconds) return preset;
    }
    return defaultPreset;
  }
}
