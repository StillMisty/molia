/// 边播边缓存源的完成信号与文件确认。
library;

import 'dart:async';

import 'package:just_audio/just_audio.dart';

/// 边播边缓存源句柄：音频源 + 一次性完成信号 + 取消入口。
///
/// [completed] 只在下载进度到达 100% **且最终缓存文件存在**（不是 `.part`）
/// 时完成为 true；失败 / 被取消 / 文件始终没落位为 false。切歌 / 停止时必须
/// 调用 [cancel]，避免订阅长期挂着。
class CachingAudioSourceHandle {
  const CachingAudioSourceHandle({
    required this.source,
    required this.completed,
    required this.cancel,
  });

  final AudioSource source;
  final Future<bool> completed;
  final void Function() cancel;
}

/// 观察缓存源下载进度，并在进度 100% 后确认最终文件存在。
///
/// `LockCachingAudioSource` 在 `onDone` 里先发 100% 再原子改名 `.part` →
/// 最终文件，所以 100% 时文件可能还差一个事件循环；这里做有限次短重试，
/// 仍然不存在按未完成处理（不会写入本地缓存索引）。
CachingAudioSourceHandle watchCachingAudioSource({
  required AudioSource source,
  required Stream<double> progress,
  required bool Function() fileExists,
  Duration retryDelay = const Duration(milliseconds: 25),
  int retries = 20,
}) {
  final completer = Completer<bool>();
  StreamSubscription<double>? subscription;
  var settled = false;
  var verifying = false;

  void finish(bool completed) {
    if (settled) return;
    settled = true;
    unawaited(subscription?.cancel());
    subscription = null;
    if (!completer.isCompleted) completer.complete(completed);
  }

  Future<void> verify() async {
    if (settled || verifying) return;
    verifying = true;
    for (var attempt = 0; attempt <= retries; attempt++) {
      if (settled) break;
      if (fileExists()) {
        finish(true);
        verifying = false;
        return;
      }
      if (attempt < retries) await Future<void>.delayed(retryDelay);
    }
    verifying = false;
    finish(false);
  }

  subscription = progress.listen(
    (value) {
      if (value >= 1) unawaited(verify());
    },
    onError: (Object _) => finish(false),
    onDone: () => unawaited(verify()),
  );

  return CachingAudioSourceHandle(
    source: source,
    completed: completer.future,
    cancel: () => finish(false),
  );
}
