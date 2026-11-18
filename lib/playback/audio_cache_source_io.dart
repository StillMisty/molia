import 'dart:io';

import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;

import '../services/cache_types.dart';
import 'audio_cache_completion.dart';

/// IO 平台：`LockCachingAudioSource`（边播边缓存到持久目录）。
///
/// 目录需先创建；同 key 复用即命中缓存文件。[headers] 为空时传 null：
/// just_audio 只在有请求头时才启用本地转发代理。
CachingAudioSourceHandle? createCachingAudioSource(
  Uri uri,
  String cacheFilePath, {
  Map<String, String> headers = const {},
}) {
  try {
    final file = File(cacheFilePath);
    file.parent.createSync(recursive: true);
    // LockCachingAudioSource 在 just_audio 中标记为 experimental；这里依赖
    // 其“边播边缓存”能力，失败时上层回退直接流播。
    // ignore: experimental_member_use
    final source = LockCachingAudioSource(
      uri,
      headers: headers.isEmpty ? null : headers,
      cacheFile: file,
    );
    // 完成信号在这里收口：进度 100% 后必须确认最终文件存在，避免把仍在
    // `.part` 里的半成品写成索引行。
    return watchCachingAudioSource(
      source: source,
      progress: source.downloadProgressStream,
      fileExists: file.existsSync,
    );
  } catch (_) {
    return null;
  }
}

/// 供调用方拼路径（避免直接依赖 dart:io 的路径分隔符差异）。
String audioCacheFilePath(String directory, String fileName) =>
    p.join(directory, fileName);

/// 音频缓存文件的落位状态（播放侧据此决定还要不要新建 writer）。
enum AudioCacheFileState {
  /// 既没有完整文件也没有半成品：需要 writer 边播边写。
  missing,

  /// 只有 `.part` 半成品（上次写入中断的遗留）：新 writer 会截断重写，
  /// 可以安全接管。
  partial,

  /// 完整文件已在位：直接 `file://` 播放，**不能**再建 writer（否则会在
  /// 完整缓存旁边写出第二个 `.part`，见 issue #60）。
  complete,
}

/// 探测缓存文件落位状态；读失败按 [AudioCacheFileState.missing] 处理
/// （保守：宁可多一次边播边写，也不能让播放因为探测失败而少缓存）。
AudioCacheFileState audioCacheFileState(String cacheFilePath) {
  try {
    if (File(cacheFilePath).existsSync()) return AudioCacheFileState.complete;
    if (File('$cacheFilePath$audioCachePartSuffix').existsSync()) {
      return AudioCacheFileState.partial;
    }
  } catch (_) {
    // 目录不可读 / 权限异常：交给后续创建 writer 时的回退分支。
  }
  return AudioCacheFileState.missing;
}

/// 清掉完整缓存旁边的 `.part` 残留。
///
/// 只有调用方确认同一路径**没有**本进程 writer 时才能调用：完整文件已落位
/// 说明那份半成品只可能是中断 / 崩溃的遗留。留着会让
/// `AudioCacheStore.hitPathForTrack` 永远判定「还在写」，此后每次播放都绕开
/// `file://` 重新走网络。
void discardAudioCachePartial(String cacheFilePath) {
  try {
    final part = File('$cacheFilePath$audioCachePartSuffix');
    if (part.existsSync()) part.deleteSync();
  } catch (_) {
    // 清理失败不阻塞播放：下次启动 `CacheService.cleanupAudioPartials()` 兜底。
  }
}
