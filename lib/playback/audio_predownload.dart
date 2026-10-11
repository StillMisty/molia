/// 音频预取启动器门面：IO 平台流式下载到缓存文件，Web 恒为 null。
library;

import 'audio_predownload_stub.dart'
    if (dart.library.io) 'audio_predownload_io.dart' as platform;
import 'audio_predownload_task.dart';

export 'audio_predownload_task.dart'
    show AudioPredownloadStarter, AudioPredownloadTask;

/// 启动预取；平台不支持 / 目标已缓存时返回 null。
AudioPredownloadTask? startAudioPredownload({
  required Uri uri,
  required String targetPath,
}) =>
    platform.startAudioPredownload(uri: uri, targetPath: targetPath);
