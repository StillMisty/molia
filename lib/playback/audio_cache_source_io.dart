import 'dart:io';

import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;

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
