/// 音频预取启动器门面：流式下载到缓存文件
/// （实现见 `audio_predownload_io.dart`）。
library;

import 'audio_predownload_io.dart' as platform;
import 'audio_predownload_task.dart';

export 'audio_predownload_task.dart'
    show AudioPredownloadStarter, AudioPredownloadTask;

/// 启动预取；目标已缓存时返回 null。
///
/// [headers] 原样带到下载请求（B 站直链需要 `Referer`）；null / 空表示不加。
AudioPredownloadTask? startAudioPredownload({
  required Uri uri,
  required String targetPath,
  Map<String, String>? headers,
}) =>
    platform.startAudioPredownload(
      uri: uri,
      targetPath: targetPath,
      headers: headers,
    );
