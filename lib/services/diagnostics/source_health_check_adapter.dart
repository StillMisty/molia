/// 音源健康检查 → 统一检查结果的适配入口。
///
/// [SourceHealthChecker] 保留自己的顺序、冷却与取消语义；渠道检查接入统一
/// 执行器时，只需在它完成后把 [HealthRun] 投影成 [DiagnosticCheckResult]，
/// 不复制检查器的守卫逻辑，也不重新探测。
library;

import '../../domain/models/diagnostics.dart';

/// 把一轮健康检查投影为统一结果（每渠道的搜索 / 取链 / 流探测各一条）。
///
/// 空结果按 warning 处理：渠道通了但没有搜到东西，通常值得排查而不是直接
/// 判失败；[HealthStepStatus.skipped] 保持 skipped。
List<DiagnosticCheckResult> healthRunCheckResults(
  HealthRun run, {
  DateTime? at,
}) {
  final when = at ?? run.finishedAt ?? run.startedAt;
  return [
    for (final channel in run.results)
      ...healthChannelCheckResults(channel, at: when),
  ];
}

/// 把单个渠道结果投影为统一结果（顺序：搜索 → 取链 → 首字节）。
///
/// 统一检查执行器按渠道逐条写入结果时直接复用本函数，保持与整轮投影同一
/// 口径；[HealthStepResult] 为空（无能力 / 未执行）时不出对应 id。
List<DiagnosticCheckResult> healthChannelCheckResults(
  HealthChannelResult channel, {
  required DateTime at,
}) {
  return [
    DiagnosticCheckResult(
      id: DiagnosticCheckId.channelSearch,
      group: DiagnosticCheckGroup.sources,
      status: _statusOf(channel.search),
      at: at,
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
        at: at,
        failure: channel.resolve!.failure,
        latencyMs: channel.resolve!.latencyMs,
        channelKey: channel.channelKey,
        channelDisplayName: channel.channelDisplayName,
      ),
    if (channel.stream != null)
      DiagnosticCheckResult(
        id: DiagnosticCheckId.channelStream,
        group: DiagnosticCheckGroup.sources,
        status: _statusOf(channel.stream!),
        at: at,
        failure: channel.stream!.failure,
        latencyMs: channel.stream!.latencyMs,
        channelKey: channel.channelKey,
        channelDisplayName: channel.channelDisplayName,
      ),
  ];
}

DiagnosticCheckStatus _statusOf(HealthStepResult step) => switch (step.status) {
  HealthStepStatus.ok => DiagnosticCheckStatus.ok,
  HealthStepStatus.empty => DiagnosticCheckStatus.warning,
  HealthStepStatus.failed => DiagnosticCheckStatus.failed,
  HealthStepStatus.skipped => DiagnosticCheckStatus.skipped,
};
