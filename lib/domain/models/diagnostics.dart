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
    this.stream,
  });

  final String channelKey;
  final String channelDisplayName;
  final HealthStepResult search;
  final HealthStepResult? resolve;

  /// 首字节探测结果；无取链能力 / 搜索为空时为 null 或 skipped。
  final HealthStepResult? stream;
  final int latencyMs;

  /// 用户可读的结论：搜索失败 → 取链失败 → 流探测失败 → 搜索空结果 → ok。
  HealthStepStatus get overallStatus {
    if (search.status == HealthStepStatus.failed) return search.status;
    final resolve = this.resolve;
    if (resolve != null && resolve.status == HealthStepStatus.failed) {
      return resolve.status;
    }
    final stream = this.stream;
    if (stream != null && stream.status == HealthStepStatus.failed) {
      return stream.status;
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

/// 统一检查分组（页面按组展示，不按实现模块）。
enum DiagnosticCheckGroup { app, sources, playback, storage, sync }

/// 单个检查的结论；[skipped] 表示本轮未执行（如未包含网络检查）。
enum DiagnosticCheckStatus { ok, warning, failed, skipped }

/// 统一检查项标识。
///
/// 枚举而不是字符串：检查结果、页面分类与诊断包都依赖同一份稳定 id，
/// 新增检查必须同时在这里登记，避免不同入口写出自由文本。
enum DiagnosticCheckId {
  appVersion,
  sessionExit,
  notificationPermission,
  audioBackend,
  sourceEngine,
  channelSearch,
  channelResolve,
  channelStream,
  logWrite,
  databaseSchema,
  databaseIntegrity,
  syncTransport,
  biliAccount,
}

/// 一条检查结果（不可变、可安全进入页面与诊断包）。
///
/// 只保留类型化失败（[HealthFailure]）：原始异常、URL、Cookie 与响应正文
/// 在进入本模型前已被丢弃。
class DiagnosticCheckResult {
  const DiagnosticCheckResult({
    required this.id,
    required this.group,
    required this.status,
    required this.at,
    this.failure,
    this.latencyMs = 0,
    this.channelKey,
    this.channelDisplayName,
    this.stableValue,
  });

  final DiagnosticCheckId id;
  final DiagnosticCheckGroup group;
  final DiagnosticCheckStatus status;
  final DateTime at;
  final HealthFailure? failure;
  final int latencyMs;

  /// 渠道级检查才有的公开标识；其它检查保持 null。
  final String? channelKey;
  final String? channelDisplayName;

  /// 稳定的短值（版本号、后端名、表版本等），由检查实现负责脱敏。
  final String? stableValue;

  @override
  String toString() =>
      'DiagnosticCheckResult(${group.name}/${id.name}, ${status.name})';
}

/// 一轮统一检查（完成或取消）。
class DiagnosticCheckRun {
  DiagnosticCheckRun({
    required this.startedAt,
    required List<DiagnosticCheckResult> results,
    this.finishedAt,
    this.cancelled = false,
  }) : results = List<DiagnosticCheckResult>.unmodifiable(results);

  final DateTime startedAt;
  final DateTime? finishedAt;
  final bool cancelled;
  final List<DiagnosticCheckResult> results;

  /// 任一 failed → failed；任一 warning → warning；否则 ok。
  DiagnosticCheckStatus get overallStatus {
    var warning = false;
    for (final result in results) {
      if (result.status == DiagnosticCheckStatus.failed) {
        return DiagnosticCheckStatus.failed;
      }
      if (result.status == DiagnosticCheckStatus.warning) warning = true;
    }
    return warning ? DiagnosticCheckStatus.warning : DiagnosticCheckStatus.ok;
  }

  DiagnosticCheckRun copyWith({
    DateTime? finishedAt,
    bool? cancelled,
    List<DiagnosticCheckResult>? results,
  }) => DiagnosticCheckRun(
    startedAt: startedAt,
    finishedAt: finishedAt ?? this.finishedAt,
    cancelled: cancelled ?? this.cancelled,
    results: results ?? this.results,
  );
}

/// 由最近失败记录聚合出的问题组（同渠道 + 同类别）。
///
/// 页面与诊断包展示「哪些渠道反复出同一种错」，而不是逐条流水。
class DiagnosticIssueGroup {
  const DiagnosticIssueGroup({
    required this.channelKey,
    required this.channelDisplayName,
    required this.kind,
    required this.count,
    required this.firstAt,
    required this.lastAt,
    this.l10nKey,
    this.retryable = false,
  });

  final String channelKey;
  final String channelDisplayName;
  final FailureKind kind;
  final int count;
  final DateTime firstAt;
  final DateTime lastAt;
  final String? l10nKey;
  final bool retryable;

  @override
  String toString() => 'DiagnosticIssueGroup($channelKey/${kind.name}, $count)';
}

/// 按 (channelKey, kind) 聚合失败记录；组内展示名 / l10n / retryable
/// 取最近一条记录，历史渠道改名不会把旧记录重写成新名字。
List<DiagnosticIssueGroup> groupDiagnosticFailures(
  Iterable<DiagnosticFailureRecord> records,
) {
  final groups = <String, DiagnosticIssueGroup>{};
  for (final record in records) {
    final key = '${record.channelKey}\u0000${record.kind.name}';
    final existing = groups[key];
    if (existing == null) {
      groups[key] = DiagnosticIssueGroup(
        channelKey: record.channelKey,
        channelDisplayName: record.channelDisplayName,
        kind: record.kind,
        count: 1,
        firstAt: record.at,
        lastAt: record.at,
        l10nKey: record.l10nKey,
        retryable: record.retryable,
      );
      continue;
    }
    final newest = !record.at.isBefore(existing.lastAt);
    groups[key] = DiagnosticIssueGroup(
      channelKey: existing.channelKey,
      channelDisplayName: newest
          ? record.channelDisplayName
          : existing.channelDisplayName,
      kind: existing.kind,
      count: existing.count + 1,
      firstAt: record.at.isBefore(existing.firstAt)
          ? record.at
          : existing.firstAt,
      lastAt: newest ? record.at : existing.lastAt,
      l10nKey: newest ? record.l10nKey : existing.l10nKey,
      retryable: newest ? record.retryable : existing.retryable,
    );
  }
  final result = groups.values.toList()
    ..sort((a, b) {
      final byLast = b.lastAt.compareTo(a.lastAt);
      if (byLast != 0) return byLast;
      final byCount = b.count.compareTo(a.count);
      if (byCount != 0) return byCount;
      return a.channelKey.compareTo(b.channelKey);
    });
  return List<DiagnosticIssueGroup>.unmodifiable(result);
}

/// 本次启动的会话事实（上次退出只用于解释异常）。
class DiagnosticSessionInfo {
  const DiagnosticSessionInfo({
    required this.startedAt,
    this.previousExitAt,
    this.previousVersion,
    this.previousAbnormalExit = false,
  });

  /// 本次启动时间。
  final DateTime startedAt;

  /// 上一次进程最后可见的时间；没有记录时为 null。
  final DateTime? previousExitAt;
  final String? previousVersion;

  /// 上一次最后可见状态为前台：本次启动可能是异常退出后的重启。
  final bool previousAbnormalExit;

  bool get hasPreviousSession => previousExitAt != null;

  @override
  String toString() =>
      'DiagnosticSessionInfo($startedAt, abnormal=$previousAbnormalExit)';
}

/// 会话最后可见状态：只记前台 / 后台 / 已正常关闭，不记录页面或播放内容。
enum DiagnosticSessionPhase { foreground, background, closed }

/// 日志文件里的一条记录；[detail] 收拢随后的错误 / 堆栈续行。
class DiagnosticLogEntry {
  const DiagnosticLogEntry({
    required this.time,
    required this.level,
    required this.logger,
    required this.message,
    this.detail,
  });

  final DateTime time;

  /// `package:logging` 的级别名（INFO / WARNING / SEVERE …）。
  final String level;
  final String logger;
  final String message;
  final String? detail;

  bool matchesKeyword(String keyword, {bool caseSensitive = false}) {
    if (keyword.isEmpty) return true;
    if (!caseSensitive) {
      final needle = keyword.toLowerCase();
      return message.toLowerCase().contains(needle) ||
          (detail?.toLowerCase().contains(needle) ?? false) ||
          logger.toLowerCase().contains(needle);
    }
    return message.contains(keyword) ||
        (detail?.contains(keyword) ?? false) ||
        logger.contains(keyword);
  }

  @override
  String toString() => 'DiagnosticLogEntry($level $logger: $message)';
}

/// 播放恢复链阶段（只记发生了什么，不记曲目标题 / payload / URL）。
enum PlaybackAttemptPhase { invalidateCache, reload, retry, autoSwap }

/// 一次播放恢复尝试的类型化记录。
class PlaybackAttempt {
  const PlaybackAttempt({
    required this.at,
    required this.phase,
    required this.sourceKey,
    required this.succeeded,
    this.failure,
  });

  final DateTime at;
  final PlaybackAttemptPhase phase;
  final String sourceKey;
  final bool succeeded;
  final HealthFailure? failure;

  @override
  String toString() =>
      'PlaybackAttempt(${phase.name}, $sourceKey, ok=$succeeded)';
}

/// 播放恢复链的记录端口（组合根注入；测试可直接断言调用）。
abstract interface class PlaybackAttemptRecorder {
  void recordPlaybackAttempt({
    required PlaybackAttemptPhase phase,
    required String sourceKey,
    required bool succeeded,
    HealthFailure? failure,
  });
}
