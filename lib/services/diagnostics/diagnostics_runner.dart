/// 统一检查执行器：按注入的 [DiagnosticCheck] 顺序跑一轮，产出类型化结果。
///
/// 只负责调度、超时、取消与异常归一；每项检查自己决定查什么（版本、音源、
/// 数据库…）。网络检查必须串行执行（避免同时打多个平台接口），本地检查也
/// 走同一条队列以保持结果顺序稳定。原始异常不会离开本文件：超时 / 抛错都
/// 归一为 [DiagnosticCheckStatus.failed] + [HealthFailure]。
library;

import 'dart:async';

import '../../domain/models/diagnostics.dart';
import '../../domain/models/failure.dart';

/// 调度参数（常量集中，测试可压短超时）。
class DiagnosticRunnerConfig {
  const DiagnosticRunnerConfig({
    this.checkTimeout = const Duration(seconds: 10),
    this.cooldown = Duration.zero,
    this.maxRuns = 3,
  });

  /// 单项检查的超时；超时按 failed(timeout) 记录并继续下一项。
  final Duration checkTimeout;

  /// 两次检查之间的最小间隔；默认不设冷却（手动检查可连续触发）。
  final Duration cooldown;
  final int maxRuns;
}

/// 检查实现拿到的执行上下文。
///
/// 结果只能在运行仍有效时写入：[DiagnosticsRunner] 取消或某项超时后，
/// 迟到的 [addResult] 会被静默丢弃，不会污染已结束的运行。
class DiagnosticCheckContext {
  DiagnosticCheckContext._(
    this._now,
    this._isCancelled,
    this._addResult,
    this._addFailure,
  );

  final DateTime Function() _now;
  final bool Function() _isCancelled;
  final void Function(DiagnosticCheckResult) _addResult;
  final void Function(
    HealthFailure failure, {
    String? channelKey,
    String? channelDisplayName,
  })?
  _addFailure;

  bool get isCancelled => _isCancelled();

  DateTime now() => _now();

  /// 写入一条结果；运行已取消 / 当前检查已超时时无效。
  void addResult(DiagnosticCheckResult result) => _addResult(result);

  /// 把一次失败写入「最近问题」缓冲（可选；未接线时静默忽略）。
  void addFailure(
    HealthFailure failure, {
    String? channelKey,
    String? channelDisplayName,
  }) {
    _addFailure?.call(
      failure,
      channelKey: channelKey,
      channelDisplayName: channelDisplayName,
    );
  }
}

/// 一项检查的静态描述与执行入口。
abstract interface class DiagnosticCheck {
  DiagnosticCheckId get key;
  DiagnosticCheckGroup get group;

  /// true 时 `includeNetwork: false` 的一轮会把它标为 skipped。
  bool get requiresNetwork;

  /// 通过 [DiagnosticCheckContext.addResult] 写结果；抛错由执行器归一化。
  Future<void> run(DiagnosticCheckContext context);
}

/// 顺序、可取消、带单项超时的检查执行器。
class DiagnosticsRunner {
  DiagnosticsRunner({
    required List<DiagnosticCheck> checks,
    this.config = const DiagnosticRunnerConfig(),
    DateTime Function()? now,
    this.onFailure,
  }) : _checks = List<DiagnosticCheck>.of(checks),
       _now = now ?? DateTime.now;

  DiagnosticRunnerConfig config;
  final DateTime Function() _now;

  /// 检查实现报告的失败（转给上层写「最近问题」）；刻意不做去重。
  final void Function(
    HealthFailure failure, {
    String? channelKey,
    String? channelDisplayName,
  })?
  onFailure;

  final List<DiagnosticCheck> _checks;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  final List<DiagnosticCheckRun> _runs = [];

  DiagnosticCheckRun? _current;
  bool _running = false;
  bool _disposed = false;
  int _generation = 0;
  DateTime? _lastStartedAt;
  Completer<void>? _idleCompleter;
  Future<void> _idle = Future<void>.value();

  /// 开始 / 逐项完成 / 取消 / 结束时的状态通知。
  Stream<void> get changes => _changes.stream;

  bool get running => _running;

  bool get isDisposed => _disposed;

  DateTime? get lastStartedAt => _lastStartedAt;

  /// 最近完成的运行（新 → 旧，最多 [DiagnosticRunnerConfig.maxRuns]）。
  List<DiagnosticCheckRun> get runs =>
      List<DiagnosticCheckRun>.unmodifiable(_runs);

  /// 正在跑的运行（含已完成的结果）；没有时为 null。
  DiagnosticCheckRun? get current => _current;

  /// 当前运行结束（或取消）时完成；未在跑时立即完成。
  Future<void> get idle => _idle;

  bool get canStart {
    if (_running || _disposed) return false;
    final last = _lastStartedAt;
    return last == null || _now().difference(last) >= config.cooldown;
  }

  /// 替换检查列表；运行中调用会被忽略（返回 false）。
  bool updateChecks(List<DiagnosticCheck> checks) {
    if (_running) return false;
    _checks
      ..clear()
      ..addAll(checks);
    return true;
  }

  /// 开始一轮检查；冷却中 / 已有运行 / 已释放时返回 false。
  ///
  /// 不阻塞调用方：`current` 立即出现，结果通过 [changes] 逐条到达，
  /// 需要等待结束时 `await idle`。
  Future<bool> start({bool includeNetwork = true}) async {
    if (!canStart) return false;
    _running = true;
    _lastStartedAt = _now();
    final generation = ++_generation;
    final idle = Completer<void>();
    _idleCompleter = idle;
    _idle = idle.future;
    _current = DiagnosticCheckRun(startedAt: _now(), results: const []);
    _notify();
    final checks = List<DiagnosticCheck>.of(_checks);
    unawaited(_run(generation, checks, includeNetwork, idle));
    return true;
  }

  Future<void> _run(
    int generation,
    List<DiagnosticCheck> checks,
    bool includeNetwork,
    Completer<void> idle,
  ) async {
    try {
      for (final check in checks) {
        if (!_isCurrent(generation)) return;
        if (!includeNetwork && check.requiresNetwork) {
          _append(
            generation,
            DiagnosticCheckResult(
              id: check.key,
              group: check.group,
              status: DiagnosticCheckStatus.skipped,
              at: _now(),
            ),
          );
          continue;
        }
        await _runCheck(generation, check);
      }
      _finish(generation, cancelled: false);
    } finally {
      _completeIdle(idle);
    }
  }

  Future<void> _runCheck(int generation, DiagnosticCheck check) async {
    final watch = Stopwatch()..start();
    final scope = _CheckScope();
    final context = DiagnosticCheckContext._(
      _now,
      () => !scope.open || !_isCurrent(generation),
      (result) {
        if (!scope.open || !_isCurrent(generation)) return;
        scope.ids.add(result.id);
        _append(generation, result);
      },
      (failure, {channelKey, channelDisplayName}) {
        if (!scope.open || !_isCurrent(generation)) return;
        onFailure?.call(
          failure,
          channelKey: channelKey,
          channelDisplayName: channelDisplayName,
        );
      },
    );

    try {
      await check.run(context).timeout(config.checkTimeout);
      if (scope.ids.isEmpty && _isCurrent(generation)) {
        // 检查没写任何结果也视为通过：页面至少能看到「这项跑过了」。
        _append(
          generation,
          DiagnosticCheckResult(
            id: check.key,
            group: check.group,
            status: DiagnosticCheckStatus.ok,
            at: _now(),
            latencyMs: watch.elapsedMilliseconds,
          ),
        );
      }
    } on TimeoutException {
      scope.open = false;
      if (_isCurrent(generation) && !scope.ids.contains(check.key)) {
        _append(
          generation,
          DiagnosticCheckResult(
            id: check.key,
            group: check.group,
            status: DiagnosticCheckStatus.failed,
            at: _now(),
            latencyMs: watch.elapsedMilliseconds,
            failure: const HealthFailure(
              kind: FailureKind.timeout,
              retryable: true,
            ),
          ),
        );
      }
    } catch (error) {
      scope.open = false;
      if (_isCurrent(generation) && !scope.ids.contains(check.key)) {
        _append(
          generation,
          DiagnosticCheckResult(
            id: check.key,
            group: check.group,
            status: DiagnosticCheckStatus.failed,
            at: _now(),
            latencyMs: watch.elapsedMilliseconds,
            failure: HealthFailure.from(SourceFailure.from(error)),
          ),
        );
      }
    }
  }

  void _append(int generation, DiagnosticCheckResult result) {
    if (!_isCurrent(generation)) return;
    final current = _current;
    if (current == null) return;
    _current = current.copyWith(results: [...current.results, result]);
    _notify();
  }

  bool _isCurrent(int generation) =>
      !_disposed && _running && generation == _generation;

  void _finish(int generation, {required bool cancelled}) {
    if (generation != _generation) return;
    final current = _current;
    _running = false;
    _current = null;
    if (current != null) {
      _runs.insert(
        0,
        current.copyWith(finishedAt: _now(), cancelled: cancelled),
      );
      while (_runs.length > config.maxRuns) {
        _runs.removeLast();
      }
    }
    _notify();
  }

  /// 停止当前运行：丢弃在途检查的迟到结果，保留已完成的部分并标记为已停止。
  void cancel() {
    if (!_running) return;
    _generation++;
    final current = _current;
    _running = false;
    _current = null;
    if (current != null) {
      _runs.insert(0, current.copyWith(finishedAt: _now(), cancelled: true));
      while (_runs.length > config.maxRuns) {
        _runs.removeLast();
      }
    }
    final idle = _idleCompleter;
    if (idle != null) _completeIdle(idle);
    _notify();
  }

  void _completeIdle(Completer<void> idle) {
    if (!idle.isCompleted) idle.complete();
    if (identical(_idleCompleter, idle)) _idleCompleter = null;
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    cancel();
    _disposed = true;
    await _changes.close();
  }
}

/// 单个检查的存活标记：超时 / 抛错后关闭，迟到的结果不再入队。
class _CheckScope {
  bool open = true;
  final Set<DiagnosticCheckId> ids = {};
}
