import 'dart:async';

import '../services/audio_cache_platform.dart';
import '../services/cache_service.dart';
import '../sources/source_track.dart';
import 'audio_cache_source.dart' show audioCacheFilePath;
import 'audio_predownload.dart';

/// 音频字节预取端口：把直链预取到本地音频缓存（测试可注入 fake）。
abstract interface class AudioPredownloader {
  /// 预取 [track] 的直链 [url]；返回任务，跳过（策略/平台/已缓存）时 null。
  Future<AudioPredownloadTask?> predownload({
    required SourceTrack track,
    required String url,
    String? quality,
  });
}

/// 默认实现：写入 `CacheService` 音频缓存分区，供 `LockCachingAudioSource`
/// 直接命中。
///
/// 跳过的情形（都返回 null，静默）：
/// - 直链非法（非 http/https）或 `.m3u8`（缓存源不接管的分片流）；
/// - 策略不允许（`allowed`，组合根按省流生效判定）；
/// - 平台不支持写缓存目录（Web；见 [platformSupportsAudioPrefetch]）；
/// - 音频缓存被用户关闭 / 缓存目录不可用 / 目标文件已存在。
///
/// 下载完成（且真的开始过下载）后触发一次 LRU 淘汰。
class CacheAudioPredownloader implements AudioPredownloader {
  CacheAudioPredownloader({
    CacheService? cacheService,
    bool Function()? allowed,
    bool Function()? platformSupported,
    AudioPredownloadStarter? starter,
  })  : _cache = cacheService ?? CacheService.instance,
        _allowed = allowed,
        _platformSupported = platformSupported,
        _starter = starter ?? startAudioPredownload;

  final CacheService _cache;
  final bool Function()? _allowed;
  final bool Function()? _platformSupported;
  final AudioPredownloadStarter _starter;

  @override
  Future<AudioPredownloadTask?> predownload({
    required SourceTrack track,
    required String url,
    String? quality,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    if (uri.path.toLowerCase().endsWith('.m3u8')) return null;
    if (!(_allowed?.call() ?? true)) return null;
    if (!(_platformSupported?.call() ?? _platformSupportsAudioPrefetch)) {
      return null;
    }
    if (!await _cache.audioEnabled()) return null;
    final directory = await _cache.audioCacheDirPath();
    if (directory == null) return null;

    final fileName = CacheService.audioCacheKeyForSource(
      track,
      quality: quality ?? '',
    );
    final task = _starter(
      uri: uri,
      targetPath: audioCacheFilePath(directory, fileName),
    );
    if (task == null) return null;
    // 预取写入后执行一次 LRU 淘汰（与边播边缓存的策略一致）。
    unawaited(task.done.whenComplete(() => _cache.enforceAudioLimit()));
    return task;
  }

  /// 与 [platformSupportsAudioPrefetch] 同一判定（唯一实现在
  /// `audio_cache_platform.dart`）。
  static bool get _platformSupportsAudioPrefetch =>
      platformSupportsAudioPrefetch();
}
