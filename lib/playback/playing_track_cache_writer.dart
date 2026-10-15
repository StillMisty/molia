/// 当前曲目的后台缓存写入：把正在播放的直链字节写进音频缓存目录。
///
/// 只用于**播放侧不能边播边缓存的平台**（桌面 media_kit 后端）或播放侧
/// 后退到直接流播的会话（`LocalPlaybackService._audioCacheUnsupported`）：
/// 移动端正常路径由 `LockCachingAudioSource` 自己写同一文件，重复写会互相
/// 破坏（见 `AudioCacheStore.keyForSource`）。
///
/// 播放仍走网络；整个文件落成（`.predl` → 原子改名）后，下一次播放经
/// `DownloadService.localUriFor` 命中 `file://` —— 桌面同样「听过就有缓存、
/// 重播离线」。切歌 / 停止 / 销毁时取消未完成的写入。
library;

import 'package:flutter/foundation.dart';

import '../sources/source_track.dart';
import 'audio_predownload.dart';
import 'audio_predownloader.dart';

class PlayingTrackCacheWriter {
  PlayingTrackCacheWriter({AudioPredownloader? predownloader})
      : _predownloader = predownloader;

  final AudioPredownloader? _predownloader;

  /// 进行中的写入任务（同一时刻最多一个）。
  AudioPredownloadTask? _task;

  /// 开始写 [track]（自动取消上一首未完成的写入）。
  ///
  /// 不触网条件（非法直链 / 省流 / 平台 / 开关 / 已有完整缓存）由
  /// [AudioPredownloader] 内部判定，命中时静默跳过。
  Future<void> start(
    SourceTrack track, {
    required String url,
    String? quality,
  }) async {
    cancel();
    final predownloader = _predownloader;
    if (predownloader == null) return;
    try {
      _task = await predownloader.predownload(
        track: track,
        url: url,
        quality: quality,
      );
    } catch (e) {
      // 缓存写入不能影响播放：失败只记录。
      debugPrint('[PlayingTrackCache] 后台缓存写入启动失败: $e');
    }
  }

  /// 取消进行中的写入（切歌 / 停止 / 销毁）。
  void cancel() {
    _task?.cancel();
    _task = null;
  }
}
