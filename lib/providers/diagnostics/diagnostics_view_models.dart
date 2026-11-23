/// 问题排查页的纯投影视图模型：摘要、检查行分组、报告 / 日志分区状态。
///
/// 这些类型不依赖 provider 的内部状态，也不做 I/O；provider 只负责把 service
/// 快照投影成这些不可变值，页面按分区订阅。
library;

import '../../domain/models/diagnostics.dart';
import '../../services/save_as.dart';

/// 报告预览的读取上限：预览只需要一眼能读完的结论与日志末尾。
const int diagnosticsReportPreviewMaxBytes = 64 * 1024;

/// 摘要结论（一句话状态）。
enum DiagnosticsSummaryTone {
  notChecked,
  running,
  ok,
  warning,
  failed,
  stopped,
}

/// 状态摘要卡读取的窄快照。
class DiagnosticsSummary {
  const DiagnosticsSummary({
    required this.tone,
    this.failedCount = 0,
    this.warningCount = 0,
    this.lastCheckedAt,
    this.previousAbnormalExit = false,
    this.previousExitAt,
    this.allSkipped = false,
  });

  final DiagnosticsSummaryTone tone;
  final int failedCount;
  final int warningCount;
  final DateTime? lastCheckedAt;
  final bool previousAbnormalExit;
  final DateTime? previousExitAt;

  /// 本轮没有 failed / warning，但所有检查行都被跳过。
  final bool allSkipped;

  bool get running => tone == DiagnosticsSummaryTone.running;
}

/// 检查结果分区：当前运行（或最近一轮）+ 可执行状态。
class DiagnosticsChecksState {
  const DiagnosticsChecksState({
    required this.run,
    required this.running,
    required this.canStart,
    required this.hasCheckableChannels,
  });

  final DiagnosticCheckRun? run;
  final bool running;
  final bool canStart;
  final bool hasCheckableChannels;

  List<DiagnosticCheckResult> get results => run?.results ?? const [];
}

/// 报告动作阶段（顶栏图标据此禁用并显示进度）。
enum DiagnosticsReportStage { idle, preparing, saving, sharing }

class DiagnosticsReportState {
  const DiagnosticsReportState({this.stage = DiagnosticsReportStage.idle});

  final DiagnosticsReportStage stage;

  bool get busy => stage != DiagnosticsReportStage.idle;
}

/// 日志子页的加载状态。
enum DiagnosticsLogsStatus { idle, loading, ready, unavailable, failed }

class DiagnosticsLogsState {
  const DiagnosticsLogsState({
    required this.status,
    required this.logStatus,
    this.entries = const [],
    this.loadedAt,
  });

  final DiagnosticsLogsStatus status;

  /// 文件日志 sink 自身的状态（正在记录 / 已停止 / 不可用）。
  final DiagnosticLogStatus logStatus;

  final List<DiagnosticLogEntry> entries;
  final DateTime? loadedAt;
}

/// 分享结果：成功、平台不支持时退化为保存、或失败。
enum DiagnosticsShareOutcome { shared, savedFallback, failed }

class DiagnosticsShareResult {
  const DiagnosticsShareResult(this.outcome, {this.saved});

  final DiagnosticsShareOutcome outcome;

  /// 退化保存时的结果；用户取消 / 失败时保留原始类型。
  final SaveAsResult? saved;
}

/// 页面按渠道合并后的检查行：渠道检查三步收一行，非渠道检查一行一项。
class DiagnosticCheckRow {
  DiagnosticCheckRow({
    required this.group,
    required this.status,
    required Map<DiagnosticCheckId, DiagnosticCheckResult> steps,
    required this.latencyMs,
    this.id,
    this.channelKey,
    this.channelDisplayName,
  }) : steps = Map<DiagnosticCheckId, DiagnosticCheckResult>.unmodifiable(
         steps,
       );

  final DiagnosticCheckGroup group;
  final DiagnosticCheckStatus status;
  final Map<DiagnosticCheckId, DiagnosticCheckResult> steps;
  final int latencyMs;

  /// 非渠道检查的稳定 id；渠道行由 [channelKey] 标识。
  final DiagnosticCheckId? id;
  final String? channelKey;
  final String? channelDisplayName;

  bool get isChannel => channelKey != null;

  String get rowKey => channelKey ?? id!.name;

  /// 渠道行按固定顺序取步骤；缺失表示本轮没有执行。
  DiagnosticCheckResult? step(DiagnosticCheckId stepId) => steps[stepId];
}

/// 一个分组下的检查行（失败置顶，其余按扫描顺序稳定展示）。
class DiagnosticsCheckGroupView {
  DiagnosticsCheckGroupView({required this.group, required this.rows});

  final DiagnosticCheckGroup group;
  final List<DiagnosticCheckRow> rows;
}

const List<DiagnosticCheckGroup> diagnosticCheckGroupOrder = [
  DiagnosticCheckGroup.app,
  DiagnosticCheckGroup.sources,
  DiagnosticCheckGroup.playback,
  DiagnosticCheckGroup.storage,
  DiagnosticCheckGroup.sync,
];

const Set<DiagnosticCheckId> _channelCheckIds = {
  DiagnosticCheckId.channelSearch,
  DiagnosticCheckId.channelResolve,
  DiagnosticCheckId.channelStream,
};

/// 把扁平结果投影成「渠道合并 + 失败置顶」的分组视图。
///
/// 纯函数：不改写结果，只按只读记录分组；同一渠道的搜索 / 取链 / 播放流
/// 合并成一行，其它检查一行一项。
List<DiagnosticsCheckGroupView> buildDiagnosticCheckGroups(
  Iterable<DiagnosticCheckResult> results,
) {
  final rows = <DiagnosticCheckRow>[];
  final channelRows = <String, _ChannelRowBuilder>{};
  for (final result in results) {
    final channelKey = result.channelKey;
    if (_channelCheckIds.contains(result.id) && channelKey != null) {
      final builder = channelRows.putIfAbsent(
        channelKey,
        () => _ChannelRowBuilder(
          channelKey: channelKey,
          channelDisplayName: result.channelDisplayName ?? channelKey,
        ),
      );
      builder
        ..steps[result.id] = result
        ..latencyMs += result.latencyMs;
      continue;
    }
    rows.add(
      DiagnosticCheckRow(
        id: result.id,
        group: result.group,
        status: result.status,
        steps: {result.id: result},
        latencyMs: result.latencyMs,
      ),
    );
  }
  rows.addAll(channelRows.values.map((builder) => builder.build()));

  final Map<DiagnosticCheckGroup, List<DiagnosticCheckRow>> grouped = {};
  for (final row in rows) {
    grouped.putIfAbsent(row.group, () => []).add(row);
  }
  return [
    for (final group in diagnosticCheckGroupOrder)
      if (grouped[group]?.isNotEmpty ?? false)
        DiagnosticsCheckGroupView(
          group: group,
          rows: grouped[group]!..sort(_compareCheckRows),
        ),
  ];
}

int _statusRank(DiagnosticCheckStatus status) => switch (status) {
  DiagnosticCheckStatus.failed => 0,
  DiagnosticCheckStatus.warning => 1,
  DiagnosticCheckStatus.skipped => 2,
  DiagnosticCheckStatus.ok => 3,
};

int _compareCheckRows(DiagnosticCheckRow a, DiagnosticCheckRow b) {
  final byStatus = _statusRank(a.status).compareTo(_statusRank(b.status));
  if (byStatus != 0) return byStatus;
  return a.rowKey.compareTo(b.rowKey);
}

class _ChannelRowBuilder {
  _ChannelRowBuilder({
    required this.channelKey,
    required this.channelDisplayName,
  });

  final String channelKey;
  final String channelDisplayName;
  final Map<DiagnosticCheckId, DiagnosticCheckResult> steps = {};
  int latencyMs = 0;

  DiagnosticCheckRow build() {
    var status = DiagnosticCheckStatus.ok;
    var allSkipped = true;
    for (final step in steps.values) {
      if (step.status != DiagnosticCheckStatus.skipped) allSkipped = false;
      if (step.status == DiagnosticCheckStatus.failed) {
        status = DiagnosticCheckStatus.failed;
        break;
      }
      if (step.status == DiagnosticCheckStatus.warning) {
        status = DiagnosticCheckStatus.warning;
      }
    }
    if (allSkipped) status = DiagnosticCheckStatus.skipped;
    return DiagnosticCheckRow(
      group: DiagnosticCheckGroup.sources,
      status: status,
      steps: steps,
      latencyMs: latencyMs,
      channelKey: channelKey,
      channelDisplayName: channelDisplayName,
    );
  }
}
