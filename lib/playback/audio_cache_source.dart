/// 音频边播边缓存源：`just_audio` 的 `LockCachingAudioSource`
/// （实现见 `audio_cache_source_io.dart`）。
library;

import 'package:just_audio/just_audio.dart';

import 'audio_cache_source_io.dart' as platform;

/// 创建边播边缓存音频源；创建失败（目录不可写等）时返回 null（调用方回退
/// 直接流播）。
///
/// [headers] 原样交给 `LockCachingAudioSource`：B 站等平台的直链离开
/// `Referer` / `UA` 会 403；为空时传 null（不启用转发代理）。
AudioSource? createCachingAudioSource(
  Uri uri,
  String cacheFilePath, {
  Map<String, String> headers = const {},
}) =>
    platform.createCachingAudioSource(uri, cacheFilePath, headers: headers);

/// 拼接音频缓存文件路径（各平台分隔符差异由实现处理）。
String audioCacheFilePath(String directory, String fileName) =>
    platform.audioCacheFilePath(directory, fileName);
