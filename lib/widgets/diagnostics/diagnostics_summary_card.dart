import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/diagnostics_provider.dart';
import '../../theme/app_semantic_colors.dart';
import '../card_list_surface.dart';
import '../settings/settings_tiles.dart';
import 'diagnostics_labels.dart';

/// 状态摘要：一句结论 + 最近检查 / 上次异常退出 + 唯一主按钮。
class DiagnosticsSummaryCard extends StatelessWidget {
  const DiagnosticsSummaryCard({
    super.key,
    required this.provider,
    required this.onStart,
    required this.onStop,
    required this.onOpenLogs,
  });

  final DiagnosticsProvider provider;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onOpenLogs;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ValueListenableBuilder<DiagnosticsChecksState>(
      valueListenable: provider.checkResults,
      builder: (context, checks, _) {
        return ValueListenableBuilder<DiagnosticsSummary>(
          valueListenable: provider.summary,
          builder: (context, summary, _) {
            return SettingsSectionCard(
              title: l10n.diagnosticsSummarySection,
              children: [
                CardListSurface(
                  position: SettingsRowPosition.of(context),
                  padding: const EdgeInsets.all(kSettingsElementSpacing),
                  onPressed: null,
                  child: _content(context, l10n, summary, checks),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _content(
    BuildContext context,
    AppLocalizations l10n,
    DiagnosticsSummary summary,
    DiagnosticsChecksState checks,
  ) {
    final m3e = M3ETheme.of(context);
    final scheme = m3e.colorScheme;
    final status = _statusStyle(context, summary.tone);
    final title = switch (summary.tone) {
      DiagnosticsSummaryTone.notChecked => l10n.diagnosticsSummaryNotChecked,
      DiagnosticsSummaryTone.running => l10n.diagnosticsSummaryRunning,
      DiagnosticsSummaryTone.ok => l10n.diagnosticsSummaryOk,
      DiagnosticsSummaryTone.failed => l10n.diagnosticsSummaryFailed(
        summary.failedCount,
      ),
      DiagnosticsSummaryTone.warning => l10n.diagnosticsSummaryWarning(
        summary.warningCount,
      ),
      DiagnosticsSummaryTone.stopped => l10n.diagnosticsSummaryStopped,
    };
    final hint = summary.allSkipped
        ? l10n.diagnosticsSummaryAllSkippedHint
        : switch (summary.tone) {
            DiagnosticsSummaryTone.notChecked =>
              l10n.diagnosticsSummaryNotCheckedHint,
            DiagnosticsSummaryTone.running => l10n.diagnosticsCheckingHint,
            DiagnosticsSummaryTone.ok => l10n.diagnosticsSummaryOkHint,
            DiagnosticsSummaryTone.failed => l10n.diagnosticsSummaryFailedHint,
            DiagnosticsSummaryTone.warning =>
              l10n.diagnosticsSummaryWarningHint,
            DiagnosticsSummaryTone.stopped =>
              l10n.diagnosticsSummaryStoppedHint,
          };
    final running = summary.tone == DiagnosticsSummaryTone.running;
    final canAct = running || checks.canStart;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(status.icon, size: 28, color: status.color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                    liveRegion: running,
                    child: Text(title, style: m3e.typeScale.titleMedium),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    hint,
                    style: m3e.typeScale.bodySmall.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (summary.lastCheckedAt != null) ...[
          const SizedBox(height: 10),
          Text(
            l10n.diagnosticsCheckedAt(
              diagnosticShortTime(summary.lastCheckedAt!),
            ),
            style: m3e.typeScale.bodySmall.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
        if (summary.previousAbnormalExit && summary.previousExitAt != null) ...[
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 18,
                color: AppSemanticColors.of(context).warning,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      l10n.diagnosticsAbnormalExitTime(
                        diagnosticShortTime(summary.previousExitAt!),
                      ),
                      style: m3e.typeScale.bodySmall.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    M3EChip(
                      key: const Key('diagnosticsSummaryOpenLogs'),
                      type: M3EChipType.assist,
                      label: l10n.diagnosticsLogView,
                      onPressed: onOpenLogs,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: M3EButton.filled(
            key: const Key('diagnosticsPrimaryAction'),
            enabled: canAct,
            semanticLabel: running
                ? l10n.diagnosticsPrimaryStop
                : l10n.diagnosticsPrimaryStart,
            onPressed: running ? onStop : (checks.canStart ? onStart : null),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (running) ...[
                  M3EProgressIndicator.circular(size: 16, strokeWidth: 2),
                  const SizedBox(width: 8),
                ],
                Semantics(
                  liveRegion: running,
                  child: Text(
                    running
                        ? l10n.diagnosticsPrimaryRunning
                        : l10n.diagnosticsPrimaryStart,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  _ToneStyle _statusStyle(BuildContext context, DiagnosticsSummaryTone tone) {
    final scheme = M3ETheme.of(context).colorScheme;
    final semantic = AppSemanticColors.of(context);
    return switch (tone) {
      DiagnosticsSummaryTone.notChecked => _ToneStyle(
        Icons.info_outline_rounded,
        scheme.onSurfaceVariant,
      ),
      DiagnosticsSummaryTone.running => _ToneStyle(
        Icons.sync_rounded,
        scheme.primary,
      ),
      DiagnosticsSummaryTone.ok => _ToneStyle(
        Icons.check_circle_outline_rounded,
        semantic.success,
      ),
      DiagnosticsSummaryTone.warning => _ToneStyle(
        Icons.warning_amber_rounded,
        semantic.warning,
      ),
      DiagnosticsSummaryTone.failed => _ToneStyle(
        Icons.error_outline_rounded,
        scheme.error,
      ),
      DiagnosticsSummaryTone.stopped => _ToneStyle(
        Icons.stop_circle_rounded,
        scheme.onSurfaceVariant,
      ),
    };
  }
}

class _ToneStyle {
  const _ToneStyle(this.icon, this.color);

  final IconData icon;
  final Color color;
}
