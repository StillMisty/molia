/// 播放恢复链的有界内存记录（最多 20 条）。
///
/// 只保存阶段、渠道 key、成败与类型化失败；不保存曲目标题、payload、URL
/// 或异常原文。进程重启即清空——恢复链属于「本次运行」观测面。
library;

import 'dart:async';
import 'dart:collection';

import '../../domain/models/diagnostics.dart';

class PlaybackAttemptLog implements PlaybackAttemptRecorder {
  PlaybackAttemptLog({this.capacity = 20, DateTime Function()? now})
    : assert(capacity > 0),
      _now = now ?? DateTime.now;

  final int capacity;
  final DateTime Function() _now;
  final ListQueue<PlaybackAttempt> _attempts = ListQueue();
  final StreamController<void> _changes = StreamController<void>.broadcast();

  Stream<void> get changes => _changes.stream;

  /// 旧 → 新；调用方不能修改内部队列。
  List<PlaybackAttempt> get attempts =>
      List<PlaybackAttempt>.unmodifiable(_attempts);

  @override
  void recordPlaybackAttempt({
    required PlaybackAttemptPhase phase,
    required String sourceKey,
    required bool succeeded,
    HealthFailure? failure,
  }) {
    if (_changes.isClosed) return;
    _attempts.addLast(
      PlaybackAttempt(
        at: _now(),
        phase: phase,
        sourceKey: sourceKey,
        succeeded: succeeded,
        failure: failure,
      ),
    );
    while (_attempts.length > capacity) {
      _attempts.removeFirst();
    }
    _changes.add(null);
  }

  Future<void> dispose() async {
    await _changes.close();
  }
}
