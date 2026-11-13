/// 诊断页 / 诊断包消费的类型化只读模型（纯 Dart，无 Flutter / I/O）。
///
/// 这些模型只含时间、渠道、失败类别、延迟等可展示字段，不保存原始异常、
/// 响应正文或请求头。服务层负责产生快照，UI 只依赖本文件与 provider。
library;

import 'failure.dart';

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

/// 健康检查失败的类型化投影：只保留 kind / l10nKey / retryable。
///
/// 刻意不持有 `SourceFailure.message` 或 cause：结果会进入设置页与诊断包，
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

/// 单步（搜索或取链）结果。
enum HealthStepStatus { ok, empty, failed, skipped }

class HealthStepResult {
  const HealthStepResult({
    required this.status,
    required this.latencyMs,
    this.failure,
  });

  final HealthStepStatus status;
  final int latencyMs;
  final HealthFailure? failure;
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

/// 本地文件日志状态（设置页只需区分“正在记录 / 不可用”）。
enum DiagnosticLogStatus { recording, unavailable, stopped }
