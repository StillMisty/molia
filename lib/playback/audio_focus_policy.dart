/// 音频焦点策略的纯决策：平台 ×「与其他应用同时播放」开关 × 中断事件。
///
/// 与事件判读（`AudioFocusGuard`）和真实会话配置（`AudioSessionLifecycle`）
/// 分开，便于单测覆盖平台差异，不依赖插件通道。决策表见 ADR-0035。
library;

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

/// 一个中断事件应该引起的动作。
///
/// - [none]：什么都不做（混播时另一播放器永久夺焦等）。
/// - [pause]：暂停并记住「这次暂停是本应用造成的」。
/// - [duck]：压低音量并记住「当前 duck 是本应用造成的」。
/// - [resume]：只有本应用为这次中断暂停过才续播。
/// - [restore]：只有本应用为这次中断压过音量才恢复。
enum AudioFocusAction { none, pause, duck, resume, restore }

/// 是否按「混播」语义处理 Android 中断。
bool _mixingOnAndroid({
  required bool playWithOtherApps,
  required TargetPlatform platform,
}) => playWithOtherApps && platform == TargetPlatform.android;

/// 单个中断事件 → 动作（ADR-0035 的完整决策表）。
///
/// 开启「与其他应用同时播放」且平台是 Android 时：其他播放器开始出声
/// （`pause`）暂停、系统语音提示（`duck`）压低音量、永久失焦（`unknown`）
/// 忽略继续播放；结束事件只在本应用做过对应动作时恢复。
///
/// 关闭混播 / Apple 平台 / 其它平台：任何 `begin` 都暂停（Apple 的混播由
/// `mixWithOthers` 在会话层完成，能收到的中断只剩来电 / Siri 等系统级事件）。
AudioFocusAction audioFocusActionFor({
  required AudioInterruptionEvent event,
  required bool playWithOtherApps,
  required TargetPlatform platform,
  required bool pausedForFocus,
  required bool duckedForFocus,
}) {
  if (event.begin) {
    if (_mixingOnAndroid(
      playWithOtherApps: playWithOtherApps,
      platform: platform,
    )) {
      return switch (event.type) {
        // 另一个播放器拿走了永久焦点：用户希望两边同时出声，继续播放。
        AudioInterruptionType.unknown => AudioFocusAction.none,
        AudioInterruptionType.pause => AudioFocusAction.pause,
        AudioInterruptionType.duck => AudioFocusAction.duck,
      };
    }
    return AudioFocusAction.pause;
  }

  if (pausedForFocus && event.type == AudioInterruptionType.pause) {
    return AudioFocusAction.resume;
  }
  if (duckedForFocus && event.type == AudioInterruptionType.duck) {
    return AudioFocusAction.restore;
  }
  return AudioFocusAction.none;
}

/// 音乐会话配置：把「与其他应用同时播放」翻译成平台会话语义。
///
/// - Android 开启混播：`gainTransientMayDuck` + `willPauseWhenDucked: false`
///   让其他播放器压低 / 继续，系统语音提示以 duck 事件到达；
/// - Android 关闭混播：普通 `gain` + `willPauseWhenDucked: true`，保持独占；
/// - Apple 平台开启混播：`mixWithOthers`（系统声音直接混播）。
AudioSessionConfiguration audioSessionConfigurationFor({
  required bool playWithOtherApps,
  required TargetPlatform platform,
}) {
  final base = const AudioSessionConfiguration.music();
  if (playWithOtherApps &&
      (platform == TargetPlatform.iOS || platform == TargetPlatform.macOS)) {
    return base.copyWith(
      avAudioSessionCategoryOptions:
          AVAudioSessionCategoryOptions.mixWithOthers,
    );
  }
  if (platform == TargetPlatform.android) {
    return base.copyWith(
      androidAudioFocusGainType: playWithOtherApps
          ? AndroidAudioFocusGainType.gainTransientMayDuck
          : AndroidAudioFocusGainType.gain,
      androidWillPauseWhenDucked: !playWithOtherApps,
    );
  }
  return base;
}
