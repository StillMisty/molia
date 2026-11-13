import 'dart:async';

import 'package:intl/intl.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/failure.dart';
import '../l10n/app_localizations.dart';
import '../providers/diagnostics_provider.dart';
import '../services/diagnostics/failure_ring_buffer.dart';
import '../services/diagnostics/log_file_sink.dart';
import '../services/diagnostics/source_health_checker.dart';
import '../services/notification_service.dart';
import '../services/save_as.dart';
import '../utils/save_as_label.dart';
import '../widgets/card_list_surface.dart';
import '../widgets/empty_state.dart';
import '../widgets/settings/settings_subpage.dart';
import '../widgets/settings/settings_tiles.dart';

/// 问题排查页：概览 / 最近问题 / 渠道检查 / 导出一个主操作。
///
/// 只读内存快照与一次包信息读取；打开页面不触发渠道检查、数据库扫描或
/// 日志读取。没有图表、日志查看器、筛选器或新的导航入口。
class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  @override
  void initState() {
    super.initState();
    // 包信息是轻量平台元数据，不联网、不扫盘；只读一次。
    context.read<DiagnosticsProvider>().ensureAppInfo();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.watch<DiagnosticsProvider>();
    return SettingsSubPage(
      title: l10n.diagnosticsTitle,
      children: [
        _overview(context, l10n, provider),
        const SizedBox(height: kSettingsSectionSpacing),
        _recentIssues(context, l10n, provider),
        const SizedBox(height: kSettingsSectionSpacing),
        _channelCheck(context, l10n, provider),
        const SizedBox(height: kSettingsSectionSpacing),
        _exportSection(context, l10n, provider),
      ],
    );
  }

  Widget _overview(
    BuildContext context,
    AppLocalizations l10n,
    DiagnosticsProvider provider,
  ) {
    final info = provider.appInfo;
    return SettingsSectionCard(
      title: l10n.diagnosticsOverviewSection,
      children: [
        SettingsInfoTile(
          icon: Icons.info_rounded,
          title: l10n.diagnosticsAppVersion,
          subtitle: info == null
              ? l10n.diagnosticsLoading
              : l10n.diagnosticsVersionValue(info.version, info.buildNumber),
        ),
        SettingsInfoTile(
          icon: Icons.devices_rounded,
          title: l10n.diagnosticsPlatform,
          subtitle: info == null
              ? l10n.diagnosticsLoading
              : l10n.diagnosticsPlatformValue(info.platform, info.osVersion),
        ),
        SettingsInfoTile(
          icon: Icons.receipt_long_rounded,
          title: l10n.diagnosticsLogStatus,
          subtitle: _logStatusText(l10n, provider.logStatus),
        ),
      ],
    );
  }

  Widget _recentIssues(
    BuildContext context,
    AppLocalizations l10n,
    DiagnosticsProvider provider,
  ) {
    final failures = provider.failures;
    return SettingsSectionCard(
      title: l10n.diagnosticsRecentIssuesSection,
      children: failures.isEmpty
          ? [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: EmptyState(
                  icon: Icons.check_circle_outline_rounded,
                  message: l10n.diagnosticsRecentIssuesEmpty,
                  hint: l10n.diagnosticsRecentIssuesEmptyHint,
                ),
              ),
            ]
          : [
              for (final record in failures.reversed)
                _FailureRow(key: ValueKey(record), record: record),
            ],
    );
  }

  Widget _channelCheck(
    BuildContext context,
    AppLocalizations l10n,
    DiagnosticsProvider provider,
  ) {
    final current = provider.currentHealthRun;
    final run = current ?? provider.healthRuns.firstOrNull;
    final running = provider.isChecking;
    final canCheck = running || provider.canStartCheck;
    final hasChannels = provider.hasCheckableChannels;
    final actionLabel = running
        ? l10n.diagnosticsChannelCheckStop
        : l10n.diagnosticsChannelCheckStart;
    return SettingsSectionCard(
      title: l10n.diagnosticsChannelCheckSection,
      footer: SettingsSectionHint(text: l10n.diagnosticsChannelCheckHint),
      children: [
        if (!hasChannels && (run == null || run.results.isEmpty))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: EmptyState(
              icon: Icons.search_off_rounded,
              message: l10n.diagnosticsChannelCheckNone,
              hint: l10n.diagnosticsChannelCheckNoneHint,
            ),
          )
        else if (run == null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: EmptyState(
              icon: Icons.network_check_rounded,
              message: l10n.diagnosticsChannelCheckEmpty,
              hint: l10n.diagnosticsChannelCheckEmptyHint,
            ),
          )
        else ...[
          for (final result in run.results)
            _HealthRow(
              key: ValueKey('${run.startedAt}-${result.channelKey}'),
              result: result,
              l10n: l10n,
            ),
          if (run.cancelled)
            SettingsInfoTile(
              icon: Icons.stop_circle_rounded,
              title: l10n.diagnosticsChannelCheckSection,
              subtitle: l10n.diagnosticsChannelStatusCancelled,
            )
          else if (run.finishedAt != null)
            SettingsInfoTile(
              icon: Icons.schedule_rounded,
              title: l10n.diagnosticsChannelCheckSection,
              subtitle: l10n.diagnosticsCheckedAt(
                DateFormat('MM-dd HH:mm').format(run.startedAt),
              ),
            ),
        ],
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: SizedBox(
            width: double.infinity,
            child: M3EButton.tonal(
              key: const Key('diagnosticsCheckButton'),
              enabled: canCheck,
              onPressed: () {
                if (running) {
                  provider.stopHealthCheck();
                } else {
                  unawaited(provider.startHealthCheck());
                }
              },
              semanticLabel: actionLabel,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (running) ...[
                    M3EProgressIndicator.circular(size: 16, strokeWidth: 2),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    running ? l10n.diagnosticsChannelCheckRunning : actionLabel,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _exportSection(
    BuildContext context,
    AppLocalizations l10n,
    DiagnosticsProvider provider,
  ) {
    final exporting = provider.isExporting;
    return SettingsSectionCard(
      title: l10n.diagnosticsExportSection,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: SizedBox(
            width: double.infinity,
            child: M3EButton.filled(
              key: const Key('diagnosticsExportButton'),
              enabled: !exporting,
              onPressed: () => unawaited(_runExport(context, l10n)),
              semanticLabel: l10n.diagnosticsExportAction,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (exporting) ...[
                    M3EProgressIndicator.circular(size: 16, strokeWidth: 2),
                    const SizedBox(width: 8),
                  ],
                  Semantics(
                    liveRegion: exporting,
                    child: Text(
                      exporting
                          ? l10n.diagnosticsExporting
                          : l10n.diagnosticsExportAction,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        SettingsSectionHint(text: l10n.diagnosticsExportPrivacy),
        const SizedBox(height: 4),
        SettingsSectionHint(text: l10n.diagnosticsExportWarning),
      ],
    );
  }

  Future<void> _runExport(BuildContext context, AppLocalizations l10n) async {
    final provider = context.read<DiagnosticsProvider>();
    final notifications = context.read<NotificationService?>();
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final result = await provider.export(
      dialogTitle: l10n.diagnosticsExportAction,
      screenWidth: size.width,
      screenHeight: size.height,
      devicePixelRatio: dpr,
    );
    if (!mounted) return;
    switch (result) {
      case SaveAsSaved(:final displayPath, :final kind):
        notifications?.showSuccessSnackBar(
          savedLocationMessage(l10n, kind, displayPath),
        );
      case SaveAsCancelled():
        return;
      case SaveAsFailed():
        notifications?.showErrorSnackBar(l10n.saveFailed);
    }
  }
}

class _FailureRow extends StatelessWidget {
  const _FailureRow({super.key, required this.record});

  final DiagnosticFailureRecord record;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final m3e = M3ETheme.of(context);
    final time = DateFormat('MM-dd HH:mm').format(record.at);
    final reason = diagnosticFailureReason(l10n, record.kind);
    return CardListSurface(
      position: SettingsRowPosition.of(context),
      padding: kSettingsRowPadding,
      onPressed: null,
      semanticLabel: '$time, ${record.channelDisplayName}, $reason',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              Icons.error_outline_rounded,
              size: 18,
              color: m3e.colorScheme.error,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$time · ${record.channelDisplayName}',
                  style: m3e.typeScale.bodyMedium,
                ),
                Text(
                  reason,
                  style: m3e.typeScale.bodySmall.copyWith(
                    color: m3e.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HealthRow extends StatelessWidget {
  const _HealthRow({super.key, required this.result, required this.l10n});

  final HealthChannelResult result;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final m3e = M3ETheme.of(context);
    final status = result.overallStatus;
    final isOk = status == HealthStepStatus.ok;
    final isFailed = status == HealthStepStatus.failed;
    final failure = isFailed
        ? (result.search.failure ?? result.resolve?.failure)
        : null;
    final detail = <String>[
      _stepText(l10n, l10n.diagnosticsChannelSearch, result.search),
      if (result.resolve != null &&
          result.resolve!.status != HealthStepStatus.skipped)
        _stepText(l10n, l10n.diagnosticsChannelResolve, result.resolve!),
      l10n.diagnosticsLatencyMs(result.latencyMs),
    ].join(' · ');
    return CardListSurface(
      position: SettingsRowPosition.of(context),
      padding: kSettingsRowPadding,
      onPressed: null,
      semanticLabel:
          '${result.channelDisplayName}, ${_statusText(l10n, status, failure)}',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              isOk
                  ? Icons.check_circle_outline_rounded
                  : (isFailed
                        ? Icons.error_outline_rounded
                        : Icons.remove_circle_outline_rounded),
              size: 18,
              color: isFailed
                  ? m3e.colorScheme.error
                  : m3e.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${result.channelDisplayName} · '
                  '${_statusText(l10n, status, failure)}',
                  style: m3e.typeScale.bodyMedium,
                ),
                Text(
                  detail,
                  style: m3e.typeScale.bodySmall.copyWith(
                    color: m3e.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _stepText(
    AppLocalizations l10n,
    String label,
    HealthStepResult step,
  ) {
    if (step.status == HealthStepStatus.failed && step.failure != null) {
      return '$label: ${diagnosticFailureReason(l10n, step.failure!.kind)}';
    }
    return '$label: ${_statusText(l10n, step.status, step.failure)}';
  }
}

/// 失败类别 → 用户文案（不展示原始异常）。
String diagnosticFailureReason(AppLocalizations l10n, FailureKind kind) {
  return switch (kind) {
    FailureKind.network => l10n.diagnosticsFailureNetwork,
    FailureKind.timeout => l10n.diagnosticsFailureTimeout,
    FailureKind.unsupported => l10n.diagnosticsFailureUnsupported,
    FailureKind.notFound => l10n.diagnosticsFailureNotFound,
    FailureKind.unauthorized => l10n.diagnosticsFailureUnauthorized,
    FailureKind.rateLimited => l10n.diagnosticsFailureRateLimited,
    FailureKind.scriptError => l10n.diagnosticsFailureScript,
    FailureKind.engineRestarting => l10n.diagnosticsFailureEngineRestarting,
    FailureKind.cancelled => l10n.diagnosticsFailureCancelled,
    FailureKind.playback => l10n.diagnosticsFailurePlayback,
    FailureKind.unknown => l10n.diagnosticsFailureUnknown,
  };
}

String _statusText(
  AppLocalizations l10n,
  HealthStepStatus status,
  HealthFailure? failure,
) {
  if (status == HealthStepStatus.failed && failure != null) {
    return diagnosticFailureReason(l10n, failure.kind);
  }
  return switch (status) {
    HealthStepStatus.ok => l10n.diagnosticsChannelStatusOk,
    HealthStepStatus.empty => l10n.diagnosticsChannelStatusEmpty,
    HealthStepStatus.failed => l10n.diagnosticsFailureUnknown,
    HealthStepStatus.skipped => l10n.diagnosticsChannelStatusCancelled,
  };
}

String _logStatusText(AppLocalizations l10n, DiagnosticLogStatus status) {
  return switch (status) {
    DiagnosticLogStatus.recording => l10n.diagnosticsLogRecording,
    DiagnosticLogStatus.unavailable => l10n.diagnosticsLogUnavailable,
    DiagnosticLogStatus.stopped => l10n.diagnosticsLogStopped,
  };
}
