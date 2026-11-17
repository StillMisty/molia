import 'package:flutter/foundation.dart';

import 'flutter_media_session_backend.dart';
import 'media_session_backend.dart';

/// 按平台选择系统媒体会话后端。
///
/// - Android / iOS / macOS / Windows / Linux：`flutter_media_session`
///   （Linux 是其原生 MPRIS 2 实现，D-Bus 不可用时静默降级）；
/// - 其它：null（该平台没有实现，不激活媒体会话）。
///
/// 返回 null 只表示「该平台没有实现」，初始化失败由调用方按异常处理。
MediaSessionBackend? createSystemMediaSessionBackend() {
  return switch (defaultTargetPlatform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.macOS ||
    TargetPlatform.windows ||
    TargetPlatform.linux => FlutterMediaSessionBackend(),
    _ => null,
  };
}
