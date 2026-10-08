import 'package:just_audio/just_audio.dart';

/// Web：无文件系统，不支持边播边缓存。
AudioSource? createCachingAudioSource(Uri uri, String cacheFilePath) => null;

/// Web 不落盘；保留签名以便调用方无平台分支。
String audioCacheFilePath(String directory, String fileName) => fileName;
