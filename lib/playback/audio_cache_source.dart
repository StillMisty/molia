/// 音频边播边缓存源：IO 平台返回 `LockCachingAudioSource`，其它平台返回 null。
library;

import 'package:just_audio/just_audio.dart';

import 'audio_cache_source_stub.dart'
    if (dart.library.io) 'audio_cache_source_io.dart' as platform;

/// 创建边播边缓存音频源；平台不支持 / 创建失败时返回 null（调用方回退直接流播）。
AudioSource? createCachingAudioSource(Uri uri, String cacheFilePath) =>
    platform.createCachingAudioSource(uri, cacheFilePath);

/// 拼接音频缓存文件路径（各平台分隔符差异由实现处理）。
String audioCacheFilePath(String directory, String fileName) =>
    platform.audioCacheFilePath(directory, fileName);
