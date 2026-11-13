/// 最近失败的纯内存环形缓冲（无 Flutter / I/O，进程重启即清空）。
///
/// 只保留类型化字段：时间、渠道 key / 展示名、失败类别、可选 l10n key、
/// 是否可重试。**刻意不保存** [SourceFailure.message]、cause、响应正文、
/// URL、请求头或任何自由文本，避免把 Cookie / 签名地址带进设置页或诊断包。
library;

import 'dart:async';
import 'dart:collection';

import '../../domain/models/failure.dart';

/// 一条最近失败记录（不可变快照）。
class DiagnosticFailureRecord {
  const DiagnosticFailureRecord({
    required this.at,
    required this.channelKey,
    required this.channelDisplayName,
    required this.kind,
    this.l10nKey,
    this.retryable = false,
  });

  final DateTime at;
  final String channelKey;

  /// 记录当时的渠道展示名（渠道改名后历史记录不跟着变）。
  final String channelDisplayName;
  final FailureKind kind;
  final String? l10nKey;
  final bool retryable;

  @override
  String toString() =>
      'DiagnosticFailureRecord(${kind.name}, $channelKey, $at)';
}

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

  /// 清空（仅测试 / 内存守卫使用）。
  void clear() {
    if (_records.isEmpty) return;
    _records.clear();
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> dispose() async {
    await _changes.close();
  }
}
