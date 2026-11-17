import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../domain/ports/music_source.dart' show PlayableStream;
import '../services/audio_cache_store.dart';
import '../services/cache_service.dart';
import '../sources/source_track.dart';
import 'audio_cache_source.dart' show audioCacheFilePath;
import 'audio_predownload.dart';

/// 音频字节预取端口：把直链预取到本地音频缓存（测试可注入 fake）。
abstract interface class AudioPredownloader {
  /// 预取 [track] 的播放流；返回任务，跳过（策略/平台/已缓存）时 null。
  ///
  /// 传 [PlayableStream] 而不是 URL + headers：两者是不可分离的一对
  /// （B 站缺 `Referer` 就 403），拆开传容易在调用链里丢一半。
  Future<AudioPredownloadTask?> predownload({
    required SourceTrack track,
    required PlayableStream stream,
    String? quality,
  });
}

/// 默认实现：写入 `CacheService` 音频缓存分区，供 `LockCachingAudioSource`
/// 直接命中。
///
/// 跳过的情形（都返回 null，静默）：
/// - 直链非法（非 http/https）或 `.m3u8`（缓存源不接管的分片流）；
/// - 策略不允许（`allowed`，组合根按省流生效判定）；
/// - 音频缓存被用户关闭 / 缓存目录不可用 / 目标文件已存在。
///
/// 下载完成（且真的开始过下载）后触发一次 LRU 淘汰。
class CacheAudioPredownloader implements AudioPredownloader {
  CacheAudioPredownloader({
    CacheService? cacheService,
    this._allowed,
    this._platformSupported,
    AudioPredownloadStarter? starter,
    this._onCompleted,
  }) : _cache = cacheService ?? CacheService.instance,
       _starter = starter ?? startAudioPredownload;

  final CacheService _cache;
  final bool Function()? _allowed;
  final bool Function()? _platformSupported;
  final AudioPredownloadStarter _starter;

  /// 缓存**成功写入最终文件**后的上报口（组合根接本地缓存索引）。
  ///
  /// 任务在成功 / 失败 / 取消时都会完成，因此这里必须在完成后确认
  /// `targetPath` 真的存在；半成品 `.predl` 或失败清理不会触发。
  final void Function(SourceTrack track)? _onCompleted;

  @override
  Future<AudioPredownloadTask?> predownload({
    required SourceTrack track,
    required PlayableStream stream,
    String? quality,
  }) async {
    final uri = stream.uri;
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return null;
    }
    if (uri.path.toLowerCase().endsWith('.m3u8')) return null;
    if (!(_allowed?.call() ?? true)) return null;
    if (!(_platformSupported?.call() ?? true)) return null;
    if (!await _cache.audioEnabled()) return null;
    final directory = await _cache.audioCacheDirPath();
    if (directory == null) return null;

    final fileName = AudioCacheStore.keyForSource(
      track,
      quality: quality ?? '',
    );
    final task = _starter(
      uri: uri,
      targetPath: audioCacheFilePath(directory, fileName),
      headers: stream.headers.isEmpty ? null : stream.headers,
    );
    if (task == null) return null;
    // LRU 淘汰与完成上报分开监听：淘汰保持原有「任务完成即触发」的时序，
    // 不等待异步文件确认 / 数据库写入（全量测试负载下也稳定）。
    unawaited(task.done.whenComplete(() => _cache.enforceAudioLimit()));
    // 只有最终缓存文件确认写完（`.predl` 原子改名成功）才上报索引。
    unawaited(
      task.succeeded
          .then((succeeded) {
            if (succeeded) _onCompleted?.call(track);
          })
          .catchError((Object e) {
            debugPrint('[AudioPredownload] 缓存完成上报失败: $e');
          }),
    );
    return task;
  }
}
