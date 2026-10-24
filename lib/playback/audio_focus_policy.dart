/// 音频焦点策略的纯决策：平台 ×「与其他应用同时播放」开关。
///
/// 与事件判读（`AudioFocusGuard`）和真实会话配置（`LocalPlaybackService`）
/// 分开，便于单测覆盖平台差异，不依赖插件通道。
library;

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

/// 收到音频中断 `begin` 时是否暂停。
///
/// - 关闭「与其他应用同时播放」：任何中断都暂停（原行为）。
/// - 开启：Android 忽略焦点丢失（其他应用的声音与音乐叠着播）；iOS / macOS
///   仍暂停——这两端的其他应用音频由会话的 `mixWithOthers` 直接混播，能收到的
///   中断只剩来电 / Siri 等系统级事件，理应暂停并在结束后续播。
bool shouldPauseForAudioFocus({
  required bool playWithOtherApps,
  required TargetPlatform platform,
}) {
  if (!playWithOtherApps) return true;
  return platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
}

/// 音乐会话配置：保持 duck 的暂停语义；开启同时播放时给 Apple 平台加混播。
///
/// `androidWillPauseWhenDucked: true` 始终保留：关闭同时播放时导航 / 语音提示
/// 会被系统升级为 transient 暂停事件；开启时本应用忽略这些事件，值不影响结果，
/// 但保持与会话层文档一致。
AudioSessionConfiguration audioSessionConfigurationFor({
  required bool playWithOtherApps,
  required TargetPlatform platform,
}) {
  final base = const AudioSessionConfiguration.music().copyWith(
    androidWillPauseWhenDucked: true,
  );
  if (!playWithOtherApps) return base;
  if (platform != TargetPlatform.iOS && platform != TargetPlatform.macOS) {
    return base;
  }
  return base.copyWith(
    avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.mixWithOthers,
  );
}
