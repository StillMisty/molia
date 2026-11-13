/// 最近失败的纯内存环形缓冲（无 Flutter / I/O，进程重启即清空）。
///
/// 只保留类型化字段：时间、渠道 key / 展示名、失败类别、可选 l10n key、
/// 是否可重试。**刻意不保存** [SourceFailure.message]、cause、响应正文、
/// URL、请求头或任何自由文本，避免把 Cookie / 签名地址带进设置页或诊断包。
library;

import 'dart:async';
import 'dart:collection';

import '../../domain/models/diagnostics.dart';
import '../../domain/models/failure.dart';

export '../../domain/models/diagnostics.dart' show DiagnosticFailureRecord;

/// 失败归一化边界的统一记录端口（catalog / 分页详情 / 播放恢复注入）。
abstract interface class FailureRecorder {
  void recordFailure({
    required SourceFailure failure,
    required String channelKey,
    required String channelDisplayName,
  });
}

/// 固定容量（默认 20）的 FIFO 环形缓冲。
class FailureRingBuffer implements FailureRecorder {
  FailureRingBuffer({this.capacity = 20}) : assert(capacity > 0);

  final int capacity;
  final ListQueue<DiagnosticFailureRecord> _records = ListQueue();
  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// 记录变化通知（页面打开时刷新；无人订阅时不产生额外工作）。
  Stream<void> get changes => _changes.stream;

  /// 最近记录的快照（旧 → 新）；调用方不能修改内部队列。
  List<DiagnosticFailureRecord> get records =>
      List<DiagnosticFailureRecord>.unmodifiable(_records);

  @override
  void recordFailure({
    required SourceFailure failure,
    required String channelKey,
    required String channelDisplayName,
  }) {
    if (_changes.isClosed) return;
    _records.addLast(
      DiagnosticFailureRecord(
        at: DateTime.now(),
        channelKey: channelKey,
        channelDisplayName: channelDisplayName,
        kind: failure.kind,
        l10nKey: failure.l10nKey,
        retryable: failure.retryable,
      ),
    );
    while (_records.length > capacity) {
      _records.removeFirst();
    }
    _changes.add(null);
  }

  Future<void> dispose() async {
    await _changes.close();
  }
}
