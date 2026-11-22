/// 音源健康检查 → 统一检查结果的适配入口。
///
/// [SourceHealthChecker] 保留自己的顺序、冷却与取消语义；渠道检查接入统一
/// 执行器时，只需在它完成后把 [HealthRun] 投影成 [DiagnosticCheckResult]，
/// 不复制检查器的守卫逻辑，也不重新探测。
library;

import '../../domain/models/diagnostics.dart';

/// 把一轮健康检查投影为统一结果（搜索 + 可选取链各一条）。
///
/// 空结果按 warning 处理：渠道通了但没有搜到东西，通常值得排查而不是直接
/// 判失败；[HealthStepStatus.skipped] 保持 skipped。
List<DiagnosticCheckResult> healthRunCheckResults(
  HealthRun run, {
  DateTime? at,
}) {
  final when = at ?? run.finishedAt ?? run.startedAt;
  return [
    for (final channel in run.results) ...[
      DiagnosticCheckResult(
        id: DiagnosticCheckId.channelSearch,
        group: DiagnosticCheckGroup.sources,
        status: _statusOf(channel.search),
        at: when,
        failure: channel.search.failure,
        latencyMs: channel.search.latencyMs,
        channelKey: channel.channelKey,
        channelDisplayName: channel.channelDisplayName,
      ),
      if (channel.resolve != null)
        DiagnosticCheckResult(
          id: DiagnosticCheckId.channelResolve,
          group: DiagnosticCheckGroup.sources,
          status: _statusOf(channel.resolve!),
          at: when,
          failure: channel.resolve!.failure,
          latencyMs: channel.resolve!.latencyMs,
          channelKey: channel.channelKey,
          channelDisplayName: channel.channelDisplayName,
        ),
    ],
  ];
}

DiagnosticCheckStatus _statusOf(HealthStepResult step) => switch (step.status) {
  HealthStepStatus.ok => DiagnosticCheckStatus.ok,
  HealthStepStatus.empty => DiagnosticCheckStatus.warning,
  HealthStepStatus.failed => DiagnosticCheckStatus.failed,
  HealthStepStatus.skipped => DiagnosticCheckStatus.skipped,
};
