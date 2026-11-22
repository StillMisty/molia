/// 诊断服务：最近失败、取链指标、健康检查、会话、历史、播放尝试与统一
/// 检查执行器的唯一持有者。
///
/// 组合根在 catalog / playback 栈之前构造它（构造无 I/O、无 await），把
/// 失败记录端口注入失败归一化边界；健康检查 / 统一检查器在对应依赖
/// 建好后挂上，页面只通过 provider 读只读快照。持久化状态（会话标记、
/// 问题历史）默认不会在构造时读取：接线方调用 [initialize] 完成启动加载。
library;

import 'dart:async';

import 'package:logging/logging.dart';

import '../../domain/models/diagnostics.dart';
import '../../domain/models/failure.dart';
import 'diagnostics_history_store.dart';
import 'diagnostics_runner.dart';
import 'diagnostics_session_store.dart';
import 'failure_ring_buffer.dart';
import 'log_file_sink.dart';
import 'playback_attempt_log.dart';
import 'resolve_metrics.dart';
import 'source_health_checker.dart';

final _logger = Logger('molia.diagnostics.service');

class DiagnosticsService implements FailureRecorder {
  DiagnosticsService({
    FailureRingBuffer? failures,
    ResolveMetrics? metrics,
    this.logSink,
    DiagnosticSessionTracker? session,
    DiagnosticsHistoryStore? history,
    PlaybackAttemptLog? attempts,
    DiagnosticsRunner? runner,
  }) : failures = failures ?? FailureRingBuffer(),
       metrics = metrics ?? ResolveMetrics.session,
       session = session ?? DiagnosticSessionTracker(),
       history = history ?? DiagnosticsHistoryStore(),
       attempts = attempts ?? PlaybackAttemptLog(),
       _autoInitialize = session != null || history != null {
    _failureSubscription = this.failures.changes.listen((_) {
      // catalog / playback 直接持有 FailureRingBuffer（不经本服务），所以
      // 持久化挂在缓冲变化上，覆盖所有失败归一化边界。
      this.history.persist(this.failures.records);
      _notify();
    });
    _attemptSubscription = this.attempts.changes.listen((_) => _notify());
    // 取链指标与失败记录同属「本次运行」观测面：页面订阅同一个 changes，
    // 计数变化即重建，不需要单独的 provider。
    this.metrics.addListener(_notify);
    if (runner != null) attachRunner(runner);
    if (_autoInitialize) unawaited(initialize());
  }

  final FailureRingBuffer failures;

  /// 取链会话指标（与 CatalogService 共用同一实例，见 [ResolveMetrics.session]）。
  final ResolveMetrics metrics;

  final RotatingFileLogSink? logSink;

  /// 异常退出标记（由生命周期回调驱动；见 [DiagnosticSessionTracker]）。
  final DiagnosticSessionTracker session;

  /// 跨重启的最近问题历史（跟随失败缓冲变化去抖写入）。
  final DiagnosticsHistoryStore history;

  /// 播放恢复链的本次运行记录。
  final PlaybackAttemptLog attempts;

  final StreamController<void> _changes = StreamController<void>.broadcast();
  StreamSubscription<void>? _failureSubscription;
  StreamSubscription<void>? _attemptSubscription;
  StreamSubscription<void>? _healthSubscription;
  StreamSubscription<void>? _runnerSubscription;
  SourceHealthChecker? _health;
  DiagnosticsRunner? _runner;
  Future<void>? _initializeFuture;
  bool _disposed = false;
  final bool _autoInitialize;

  Stream<void> get changes => _changes.stream;

  SourceHealthChecker? get health => _health;

  DiagnosticsRunner? get runner => _runner;

  List<HealthRun> get healthRuns => _health?.runs ?? const [];

  HealthRun? get currentHealthRun => _health?.current;

  /// 渠道健康检查或统一检查正在运行。
  bool get isChecking =>
      (_runner?.running ?? false) || (_health?.running ?? false);

  int get healthTargetCount => _health?.targetCount ?? 0;

  DiagnosticLogStatus get logStatus =>
      logSink?.status ?? DiagnosticLogStatus.stopped;

  /// 最近失败聚合出的问题组（按最近发生排序）。
  List<DiagnosticIssueGroup> get issues =>
      groupDiagnosticFailures(failures.records);

  DiagnosticSessionInfo? get sessionInfo => session.info;

  List<PlaybackAttempt> get playbackAttempts => attempts.attempts;

  List<DiagnosticCheckRun> get checkRuns => _runner?.runs ?? const [];

  DiagnosticCheckRun? get currentCheckRun => _runner?.current;

  bool get canStartChecks => _runner?.canStart ?? false;

  /// 启动加载：恢复持久化的问题历史并记录本次会话开始。
  ///
  /// 幂等；存储不可用时只记日志，页面仍能使用其余诊断信息。
  Future<void> initialize() => _initializeFuture ??= _initialize();

  Future<void> _initialize() async {
    try {
      final stored = await history.load();
      if (_disposed) return;
      if (stored.isNotEmpty) failures.restore(stored);
    } catch (error) {
      _logger.warning('恢复问题历史失败: $error');
    }
    if (_disposed) return;
    try {
      await session.start();
    } catch (error) {
      _logger.warning('记录启动会话状态失败: $error');
    }
    _notify();
  }

  /// catalog 建好后挂上健康检查器（同一个 provider 实例继续使用）。
  void attachHealth(SourceHealthChecker checker) {
    if (identical(checker, _health)) return;
    unawaited(_healthSubscription?.cancel());
    _health = checker;
    _healthSubscription = checker.changes.listen((_) => _notify());
    // 只有接线方显式注入 session / history 时才自动读盘：默认实例构造在
    // 单元测试里可能没有偏好存储，过早触发只会产生无意义的失败日志。
    if (_autoInitialize) unawaited(initialize());
    _notify();
  }

  /// 统一检查器建好后挂上（可由接线方晚于服务构造）。
  void attachRunner(DiagnosticsRunner runner) {
    if (identical(runner, _runner)) return;
    unawaited(_runnerSubscription?.cancel());
    _runner = runner;
    _runnerSubscription = runner.changes.listen((_) => _notify());
    if (_autoInitialize) unawaited(initialize());
    _notify();
  }

  @override
  void recordFailure({
    required SourceFailure failure,
    required String channelKey,
    required String channelDisplayName,
  }) {
    failures.recordFailure(
      failure: failure,
      channelKey: channelKey,
      channelDisplayName: channelDisplayName,
    );
  }

  Future<bool> startHealthCheck() => _health?.start() ?? Future.value(false);

  void stopHealthCheck() => _health?.cancel();

  Future<bool> startChecks({bool includeNetwork = true}) =>
      _runner?.start(includeNetwork: includeNetwork) ?? Future.value(false);

  void stopChecks() => _runner?.cancel();

  /// 导出 / 退出前落盘待写状态（日志队列 + 去抖中的问题历史）。
  Future<void> flushPendingWrites() async {
    // 直接取一次缓冲快照：changes 是异步事件，导出不能等它到达。
    if (failures.records.isNotEmpty) history.persist(failures.records);
    try {
      await logSink?.flush();
    } catch (_) {
      // 日志不可用不阻塞导出。
    }
    await history.flush();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _runner?.dispose();
    await _runnerSubscription?.cancel();
    await _health?.dispose();
    await _healthSubscription?.cancel();
    await _failureSubscription?.cancel();
    await _attemptSubscription?.cancel();
    metrics.removeListener(_notify);
    await attempts.dispose();
    if (failures.records.isNotEmpty) {
      // 退出前兜底：即使 changes 事件还没派发，也保留最近失败。
      history.persist(failures.records);
    }
    try {
      await history.dispose().timeout(const Duration(seconds: 1));
    } catch (_) {
      // 退出路径有界：持久化卡住不能拖住 dispose。
    }
    await failures.dispose();
    await logSink?.close();
    await _changes.close();
  }
}
