/// 手动音源健康检查：顺序探测、类型化结果、取消与冷却。
///
/// 只依赖注入的 [SourceHealthProbe]，不认识 UI / 播放 / 具体平台客户端。
/// 检查本身不保存异常对象或响应正文：所有错误在边界归一化为
/// [SourceFailure]（kind / l10nKey / retryable），结果集合只保留类型化字段。
library;

import 'dart:async';

import '../../domain/models/failure.dart';
import '../../domain/models/track.dart';

/// 一个可探测渠道（只含展示所需的公开字段）。
class SourceHealthTarget {
  const SourceHealthTarget({
    required this.key,
    required this.displayName,
    this.canResolve = false,
  });

  final String key;
  final String displayName;

  /// 是否具备取播放链接能力；false 时只做搜索探测。
  final bool canResolve;
}

/// 渠道探测端口：生产适配器走正常搜索 / 取链路径，测试注入假实现。
abstract interface class SourceHealthProbe {
  /// 当前应检查的渠道（只含已启用且可搜索的渠道）。
  List<SourceHealthTarget> get targets;

  /// 一次低成本的搜索；失败抛任意异常，由检查器归一化。
  Future<Track?> search(SourceHealthTarget target);

  /// 对搜索结果中的一首曲目取一次播放链接；失败抛任意异常。
  Future<void> resolve(SourceHealthTarget target, Track track);
}

/// 单步（搜索或取链）结果。
enum HealthStepStatus { ok, empty, failed, skipped }

/// 健康检查失败的类型化投影：只保留 kind / l10nKey / retryable。
///
/// 刻意不持有 [SourceFailure.message] 或 cause：结果会进入设置页与诊断包，
/// 原始异常文本可能带响应正文 / URL。
class HealthFailure {
  const HealthFailure({
    required this.kind,
    this.l10nKey,
    this.retryable = false,
  });

  factory HealthFailure.from(SourceFailure failure) => HealthFailure(
    kind: failure.kind,
    l10nKey: failure.l10nKey,
    retryable: failure.retryable,
  );

  final FailureKind kind;
  final String? l10nKey;
  final bool retryable;

  @override
  String toString() => 'HealthFailure(${kind.name})';
}

class HealthStepResult {
  const HealthStepResult({
    required this.status,
    required this.latencyMs,
    this.failure,
  });

  final HealthStepStatus status;
  final int latencyMs;
  final HealthFailure? failure;

  bool get isOk => status == HealthStepStatus.ok;
}

/// 单渠道检查结果。
class HealthChannelResult {
  const HealthChannelResult({
    required this.channelKey,
    required this.channelDisplayName,
    required this.search,
    required this.latencyMs,
    this.resolve,
  });

  final String channelKey;
  final String channelDisplayName;
  final HealthStepResult search;
  final HealthStepResult? resolve;
  final int latencyMs;

  /// 用户可读的结论：取链失败优先于搜索空结果。
  HealthStepStatus get overallStatus {
    if (search.status == HealthStepStatus.failed) return search.status;
    final resolve = this.resolve;
    if (resolve != null && resolve.status == HealthStepStatus.failed) {
      return resolve.status;
    }
    if (search.status == HealthStepStatus.empty) return search.status;
    return HealthStepStatus.ok;
  }
}

/// 一次手动检查（完成或取消）。
class HealthRun {
  HealthRun({
    required this.startedAt,
    required List<HealthChannelResult> results,
    this.finishedAt,
    this.cancelled = false,
  }) : results = List<HealthChannelResult>.unmodifiable(results);

  final DateTime startedAt;
  final DateTime? finishedAt;
  final bool cancelled;
  final List<HealthChannelResult> results;

  HealthRun copyWith({
    DateTime? finishedAt,
    bool? cancelled,
    List<HealthChannelResult>? results,
  }) => HealthRun(
    startedAt: startedAt,
    finishedAt: finishedAt ?? this.finishedAt,
    cancelled: cancelled ?? this.cancelled,
    results: results ?? this.results,
  );
}

/// 检查器配置（常量集中，便于测试压短）。
class SourceHealthConfig {
  const SourceHealthConfig({
    this.searchTimeout = const Duration(seconds: 8),
    this.resolveTimeout = const Duration(seconds: 5),
    this.gap = const Duration(milliseconds: 300),
    this.cooldown = const Duration(seconds: 30),
    this.maxChannels = 20,
    this.maxRuns = 3,
  });

  final Duration searchTimeout;
  final Duration resolveTimeout;
  final Duration gap;
  final Duration cooldown;
  final int maxChannels;
  final int maxRuns;
}

/// 顺序、可取消、带冷却的手动渠道检查。
class SourceHealthChecker {
  SourceHealthChecker({
    required this._probe,
    this._config = const SourceHealthConfig(),
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
  }) : _now = now ?? DateTime.now,
       _delay = delay ?? Future<void>.delayed;

  final SourceHealthProbe _probe;
  final SourceHealthConfig _config;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _delay;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  final List<HealthRun> _runs = [];
  HealthRun? _current;
  bool _running = false;
  DateTime? _lastStartedAt;
  int _generation = 0;
  bool _disposed = false;

  /// 状态变化通知（开始 / 单个渠道完成 / 取消 / 完成）。
  Stream<void> get changes => _changes.stream;

  bool get running => _running;

  /// 最近一次开始时间（冷却判据）。
  DateTime? get lastStartedAt => _lastStartedAt;

  /// 最近完成的运行（新 → 旧，最多 [SourceHealthConfig.maxRuns]）。
  List<HealthRun> get runs => List<HealthRun>.unmodifiable(_runs);

  /// 当前可检查渠道数（页面空态用；不触发探测）。
  int get targetCount => _probe.targets.length;

  /// 正在跑的运行（含已完成的渠道）；没有时为 null。
  HealthRun? get current => _current;

  bool get canStart {
    if (_running || _disposed) return false;
    final last = _lastStartedAt;
    return last == null || _now().difference(last) >= _config.cooldown;
  }

  /// 开始一轮检查；冷却中 / 已有运行 / 已释放时返回 false。
  Future<bool> start() async {
    if (!canStart) return false;
    _running = true;
    _lastStartedAt = _now();
    final generation = ++_generation;
    final targets = List<SourceHealthTarget>.of(
      _probe.targets.take(_config.maxChannels),
    );
    _current = HealthRun(startedAt: _now(), results: const []);
    _notify();
    if (targets.isEmpty) {
      _finish(generation);
      return true;
    }
    // 不阻塞调用方：页面先进入“检查中”，结果通过状态通知逐条到达。
    unawaited(_run(generation, targets));
    return true;
  }

  Future<void> _run(int generation, List<SourceHealthTarget> targets) async {
    for (var i = 0; i < targets.length; i++) {
      if (generation != _generation) return;
      if (i > 0) await _delay(_config.gap);
      if (generation != _generation) return;
      final result = await _probeChannel(generation, targets[i]);
      if (result == null || generation != _generation) return;
      final current = _current;
      if (current == null) return;
      _current = current.copyWith(results: [...current.results, result]);
      _notify();
    }
    _finish(generation);
  }

  Future<HealthChannelResult?> _probeChannel(
    int generation,
    SourceHealthTarget target,
  ) async {
    final total = Stopwatch()..start();
    final searchWatch = Stopwatch()..start();
    HealthStepResult search;
    Track? track;
    try {
      track = await _probe.search(target).timeout(_config.searchTimeout);
      search = HealthStepResult(
        status: track == null ? HealthStepStatus.empty : HealthStepStatus.ok,
        latencyMs: searchWatch.elapsedMilliseconds,
      );
    } catch (error) {
      if (generation != _generation) return null;
      search = HealthStepResult(
        status: HealthStepStatus.failed,
        latencyMs: searchWatch.elapsedMilliseconds,
        failure: HealthFailure.from(SourceFailure.from(error)),
      );
    }
    if (generation != _generation) return null;
    if (track == null || !target.canResolve) {
      return HealthChannelResult(
        channelKey: target.key,
        channelDisplayName: target.displayName,
        search: search,
        latencyMs: total.elapsedMilliseconds,
        resolve: target.canResolve
            ? const HealthStepResult(
                status: HealthStepStatus.skipped,
                latencyMs: 0,
              )
            : null,
      );
    }

    final resolveWatch = Stopwatch()..start();
    HealthStepResult resolve;
    try {
      await _probe.resolve(target, track).timeout(_config.resolveTimeout);
      resolve = HealthStepResult(
        status: HealthStepStatus.ok,
        latencyMs: resolveWatch.elapsedMilliseconds,
      );
    } catch (error) {
      if (generation != _generation) return null;
      resolve = HealthStepResult(
        status: HealthStepStatus.failed,
        latencyMs: resolveWatch.elapsedMilliseconds,
        failure: HealthFailure.from(SourceFailure.from(error)),
      );
    }
    if (generation != _generation) return null;
    return HealthChannelResult(
      channelKey: target.key,
      channelDisplayName: target.displayName,
      search: search,
      resolve: resolve,
      latencyMs: total.elapsedMilliseconds,
    );
  }

  void _finish(int generation) {
    if (generation != _generation) return;
    final current = _current;
    _running = false;
    _current = null;
    if (current != null) {
      _runs.insert(0, current.copyWith(finishedAt: _now(), cancelled: false));
      while (_runs.length > _config.maxRuns) {
        _runs.removeLast();
      }
    }
    _notify();
  }

  /// 取消当前运行：不再启动下一个渠道，丢弃在途步骤的迟到结果，保留已完成
  /// 的部分并标记为已停止。不触碰 LX 引擎、播放队列或缓存。
  void cancel() {
    if (!_running) return;
    _generation++;
    _running = false;
    final current = _current;
    _current = null;
    if (current != null) {
      _runs.insert(0, current.copyWith(finishedAt: _now(), cancelled: true));
      while (_runs.length > _config.maxRuns) {
        _runs.removeLast();
      }
    }
    _notify();
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
