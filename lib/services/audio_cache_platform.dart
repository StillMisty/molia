/// 音频边播边缓存（含下一首字节预取）的平台可用性判定。
///
/// 唯一实现：`LocalPlaybackService`（起播写入）与 `CacheAudioPredownloader`
/// （预取）共用，UI（歌曲信息页 / 单曲缓存子页）也据此如实提示
/// 「当前平台不缓存音频」，而不是把「平台不支持」显示成「没有缓存」。
library;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

/// 平台是否支持音频边播边缓存：Android / iOS / macOS。
///
/// 桌面（Windows / Linux）的 media_kit 后端把 `StreamAudioSource` 当普通 URI
/// 交给 mpv 走 just_audio 本地代理，遇到开放式 Range 请求会触发 just_audio
/// 内部空值错误；Web 无持久文件系统。这些平台不写音频缓存。
bool platformSupportsAudioCaching({
  TargetPlatform? platform,
  bool isWeb = kIsWeb,
}) {
  if (isWeb) return false;
  final target = platform ?? defaultTargetPlatform;
  return target == TargetPlatform.android ||
      target == TargetPlatform.iOS ||
      target == TargetPlatform.macOS;
}
