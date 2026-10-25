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
///
/// macOS 走 just_audio 自带的 AVPlayer 实现（`just_audio` 的 darwin 平台声明
/// 包含 macOS）：不引 `media_kit_libs_macos_audio`，也不装 libmpv。取链请求头
/// 由 `UriAudioSource` 经 `AVURLAssetHTTPHeaderFieldsKey` 透传（B 站直链的
/// Referer / UA 仍有效，见 `docs/media_kit_native_libs.md`）。
///
/// 这里的 media_kit 初始化会在主 isolate 上同步 `dlopen` libmpv（本机实测
/// 39–48ms，见 `docs/performance.md`）：试过在后台 isolate 里预热，但两次
/// dlopen 争用进程级的动态加载器锁，与建窗阶段互相串行、总时长不变，故保留
/// 现在这版直白实现。
void initDesktopAudioIfNeeded() {
  if (Platform.isWindows || Platform.isLinux) {
    try {
      // mpv 解复用缓存上限：just_audio_media_kit 把同一个值同时设给
      // `demuxer-max-bytes` 与 `demuxer-max-back-bytes`，缺省 32 MiB 意味着
      // 一首流播曲目最多占 ~64 MiB 内存。音乐场景 16 MiB（320kbps ≈ 6.7
      // 分钟、无损 ≈ 2 分钟）已足够抗抖动，且只影响「当前流播」的内存缓冲：
      // 下载 / 下一首预取走独立 HTTP 直写磁盘，不受此值影响（见
      // docs/memory.md）。
      JustAudioMediaKit.bufferSize = 16 * 1024 * 1024;
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
