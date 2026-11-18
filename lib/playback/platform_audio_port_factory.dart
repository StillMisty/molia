/// 平台音频端口的生产选择：Android / iOS 走 `audio_session`，桌面走输出监听，
/// 其余 no-op。
///
/// macOS 没有 `AVAudioSession` 语义，Darwin 媒体会话后端的激活代码也只在
/// iOS 生效；Windows / Linux 没有 `audio_session` 实现。三者的会话行为保持
/// 改动前现状，只由桌面输出监听端口补 `outputLost`（ADR-0036）。
library;

import 'package:flutter/foundation.dart';

import 'desktop_audio_output_port.dart';
import 'mobile_audio_session_port.dart';
import 'platform_audio_port.dart';

PlatformAudioPort createPlatformAudioPort() {
  return switch (defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS => MobileAudioSessionPort(),
    TargetPlatform.windows ||
    TargetPlatform.linux ||
    TargetPlatform.macOS => createDesktopAudioOutputPort(),
    _ => const NoopPlatformAudioPort(),
  };
}
