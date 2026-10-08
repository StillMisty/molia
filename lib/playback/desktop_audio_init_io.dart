import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

/// 桌面音频后端是否可用（media_kit / libmpv）。
bool desktopAudioAvailable = true;

/// 初始化失败原因（用于自测与 UI 提示）。
String? desktopAudioInitError;

/// Windows / Linux 使用 media_kit 作为 just_audio 的后端。
///
/// Linux 需要系统提供 libmpv（如 `pacman -S mpv` / `apt install libmpv-dev`）；
/// 缺失时不阻塞启动，但本地播放功能不可用。
void initDesktopAudioIfNeeded() {
  if (Platform.isWindows || Platform.isLinux) {
    try {
      JustAudioMediaKit.ensureInitialized();
      desktopAudioAvailable = true;
      desktopAudioInitError = null;
    } catch (e) {
      desktopAudioAvailable = false;
      desktopAudioInitError = e.toString();
      debugPrint('[Molia] media_kit 初始化失败: $e');
    }
  }
}
