import 'audio_predownload_task.dart';

/// Web：无持久文件系统，不预取。
AudioPredownloadTask? startAudioPredownload({
  required Uri uri,
  required String targetPath,
}) =>
    null;
