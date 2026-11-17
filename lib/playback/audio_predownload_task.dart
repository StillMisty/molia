import 'dart:async';

/// 音频预取任务句柄：取消 + 完成通知 + 成功信号。
///
/// [done] 在下载完成、失败或被取消后都会 complete（预取永远不该影响
/// 播放主流程，调用方不需要区分结果）。[succeeded] 只在半成品原子改名成
/// 最终文件且确认存在后完成为 true；失败 / 取消 / 半成品为 false。
class AudioPredownloadTask {
  AudioPredownloadTask({
    required this.done,
    required this._onCancel,
    Future<bool>? succeeded,
  }) : succeeded = succeeded ?? Future<bool>.value(false);

  final Future<void> done;
  final Future<bool> succeeded;
  final void Function() _onCancel;

  void cancel() => _onCancel();
}

/// 启动一次音频预取；
/// 目标文件已存在完整缓存时返回 null。
typedef AudioPredownloadStarter = AudioPredownloadTask? Function({
  required Uri uri,
  required String targetPath,
  Map<String, String>? headers,
});
