import 'dart:io';

import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;

/// IO 平台：`LockCachingAudioSource`（边播边缓存到持久目录）。
///
/// 目录需先创建；同 key 复用即命中缓存文件。
AudioSource? createCachingAudioSource(Uri uri, String cacheFilePath) {
  try {
    final file = File(cacheFilePath);
    file.parent.createSync(recursive: true);
    // LockCachingAudioSource 在 just_audio 中标记为 experimental；这里依赖
    // 其“边播边缓存”能力，失败时上层回退直接流播。
    // ignore: experimental_member_use
    return LockCachingAudioSource(uri, cacheFile: file);
  } catch (_) {
    return null;
  }
}

/// 供调用方拼路径（避免直接依赖 dart:io 的路径分隔符差异）。
String audioCacheFilePath(String directory, String fileName) =>
    p.join(directory, fileName);
