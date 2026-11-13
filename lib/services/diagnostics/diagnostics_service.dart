/// 诊断服务：最近失败环形缓冲 + 健康检查运行 + 文件日志 sink 的唯一持有者。
///
/// 组合根在 catalog / playback 栈之前构造它（构造无 I/O、无 await），把
/// [failureRecorder] 注入失败归一化边界；健康检查在 catalog 建好后挂上
/// （探针依赖目录服务），页面只通过 provider 读快照。
library;

import 'dart:async';

import '../../domain/models/diagnostics.dart';
import '../../domain/models/failure.dart';
import 'failure_ring_buffer.dart';
import 'log_file_sink.dart';
import 'source_health_checker.dart';

class DiagnosticsService implements FailureRecorder {
  DiagnosticsService({FailureRingBuffer? failures, this.logSink})
    : failures = failures ?? FailureRingBuffer() {
    _failureSubscription = this.failures.changes.listen((_) => _notify());
  }

  final FailureRingBuffer failures;
  final RotatingFileLogSink? logSink;

  final StreamController<void> _changes = StreamController<void>.broadcast();
  StreamSubscription<void>? _failureSubscription;
  StreamSubscription<void>? _healthSubscription;
  SourceHealthChecker? _health;

  Stream<void> get changes => _changes.stream;

  SourceHealthChecker? get health => _health;

  List<HealthRun> get healthRuns => _health?.runs ?? const [];

  HealthRun? get currentHealthRun => _health?.current;

  bool get isChecking => _health?.running ?? false;

  int get healthTargetCount => _health?.targetCount ?? 0;

  DiagnosticLogStatus get logStatus =>
      logSink?.status ?? DiagnosticLogStatus.stopped;

  /// catalog 建好后挂上健康检查器（同一个 provider 实例继续使用）。
  void attachHealth(SourceHealthChecker checker) {
    if (identical(checker, _health)) return;
    unawaited(_healthSubscription?.cancel());
    _health = checker;
    _healthSubscription = checker.changes.listen((_) => _notify());
    _notify();
  }

  @override
  void recordFailure({
    required SourceFailure failure,
    required String channelKey,
    required String channelDisplayName,
  }) => failures.recordFailure(
    failure: failure,
    channelKey: channelKey,
    channelDisplayName: channelDisplayName,
  );

  Future<bool> startHealthCheck() => _health?.start() ?? Future.value(false);

  void stopHealthCheck() => _health?.cancel();

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> dispose() async {
    await _health?.dispose();
    await _healthSubscription?.cancel();
    await _failureSubscription?.cancel();
    await failures.dispose();
    await logSink?.close();
    await _changes.close();
  }
}
