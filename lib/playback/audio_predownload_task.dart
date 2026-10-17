import 'dart:async';

/// 音频预取任务句柄：取消 + 完成通知。
///
/// [done] 在下载完成、失败或被取消后都会 complete（预取永远不该影响
/// 播放主流程，调用方不需要区分结果）。
class AudioPredownloadTask {
  AudioPredownloadTask({
    required this.done,
    required void Function() onCancel,
  }) : _onCancel = onCancel;

  final Future<void> done;
  final void Function() _onCancel;

  void cancel() => _onCancel();
}

/// 启动一次音频预取；
/// 目标文件已存在完整缓存时返回 null。
typedef AudioPredownloadStarter = AudioPredownloadTask? Function({
  required Uri uri,
  required String targetPath,
});
