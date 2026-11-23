import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../domain/models/diagnostics.dart';
import '../../domain/models/failure.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/diagnostics_provider.dart';
import '../../widgets/card_list_surface.dart';
import '../empty_state.dart';
import '../settings/settings_tiles.dart';
import 'diagnostics_labels.dart';

/// 检查结果分区：按五域分组，渠道三步合并一行，失败置顶。
class DiagnosticsCheckSection extends StatelessWidget {
  const DiagnosticsCheckSection({
    super.key,
    required this.provider,
    required this.onOpenCheck,
  });

  final DiagnosticsProvider provider;
  final ValueChanged<DiagnosticCheckRow> onOpenCheck;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ValueListenableBuilder<DiagnosticsChecksState>(
      valueListenable: provider.checkResults,
      builder: (context, checks, _) {
        final groups = buildDiagnosticCheckGroups(checks.results);
        final empty = groups.isEmpty;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsSectionCard(
              title: l10n.diagnosticsCheckResultsSection,
              footer: SettingsSectionHint(
                text: l10n.diagnosticsCheckResultsHint,
              ),
              children: [
                if (empty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: EmptyState(
                      icon: checks.running
                          ? Icons.hourglass_top_rounded
                          : Icons.fact_check_rounded,
                      message: checks.running
                          ? l10n.diagnosticsSummaryRunning
                          : l10n.diagnosticsCheckResultsEmpty,
                      hint: checks.running
                          ? l10n.diagnosticsCheckingHint
                          : (!checks.hasCheckableChannels
                                ? l10n.diagnosticsCheckNoChannelsHint
                                : l10n.diagnosticsCheckResultsEmptyHint),
                    ),
                  )
                else
                  SettingsInfoTile(
                    icon: Icons.timer_rounded,
                    title: l10n.diagnosticsCheckedAt(
                      diagnosticShortTime(
                        checks.run?.finishedAt ??
                            checks.run?.startedAt ??
                            DateTime.now(),
                      ),
                    ),
                    subtitle: checks.run?.cancelled ?? false
                        ? l10n.diagnosticsChannelStatusCancelled
                        : '',
                  ),
              ],
            ),
            for (final group in groups) ...[
              const SizedBox(height: kSettingsSectionSpacing),
              SettingsSectionCard(
                title: diagnosticGroupLabel(l10n, group.group),
                children: [
                  for (final row in group.rows)
                    _CheckRow(
                      key: ValueKey('diagnosticsCheckRow-${row.rowKey}'),
                      row: row,
                      onTap: () => onOpenCheck(row),
                    ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({super.key, required this.row, required this.onTap});

  final DiagnosticCheckRow row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final m3e = M3ETheme.of(context);
    final status = diagnosticStatusText(l10n, row.status);
    final title = row.isChannel
        ? '${row.channelDisplayName ?? row.channelKey} · $status'
        : '${diagnosticCheckLabel(l10n, row.id!)} · $status';
    final detail = _rowDetail(l10n, row);
    return CardListSurface(
      position: SettingsRowPosition.of(context),
      padding: kSettingsRowPadding,
      onPressed: onTap,
      semanticLabel: '$title, $detail, ${l10n.diagnosticsOpenDetails}',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              diagnosticStatusIcon(row.status),
              size: 20,
              color: diagnosticStatusColor(context, row.status),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: m3e.typeScale.bodyLarge,
                ),
                if (detail.isNotEmpty)
                  Text(
                    detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: m3e.typeScale.bodySmall.copyWith(
                      color: m3e.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            size: kSettingsTileActionSize,
            color: m3e.colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

String _rowDetail(AppLocalizations l10n, DiagnosticCheckRow row) {
  final parts = <String>[];
  if (row.isChannel) {
    for (final id in const [
      DiagnosticCheckId.channelSearch,
      DiagnosticCheckId.channelResolve,
      DiagnosticCheckId.channelStream,
    ]) {
      final step = row.step(id);
      final label = diagnosticCheckLabel(l10n, id);
      if (step == null) {
        parts.add(
          l10n.diagnosticsCheckStep(label, l10n.diagnosticsStatusSkipped),
        );
        continue;
      }
      parts.add(
        l10n.diagnosticsCheckStepLatency(
          label,
          diagnosticStatusText(l10n, step.status),
          step.latencyMs,
        ),
      );
    }
    if (row.latencyMs > 0) {
      parts.add(l10n.diagnosticsCheckTotalLatency(row.latencyMs));
    }
  } else {
    final result = row.steps[row.id]!;
    parts.add(diagnosticStatusText(l10n, result.status));
    final failure = result.failure;
    if (failure != null &&
        (result.status == DiagnosticCheckStatus.failed ||
            result.status == DiagnosticCheckStatus.warning)) {
      parts.add(diagnosticFailureReason(l10n, failure.kind));
    }
    final stable = diagnosticStableValueText(l10n, result);
    if (stable != null && result.status != DiagnosticCheckStatus.skipped) {
      parts.add(stable);
    }
    if (row.latencyMs > 0) {
      parts.add(l10n.diagnosticsCheckTotalLatency(row.latencyMs));
    }
  }
  return parts.join(' · ');
}

DiagnosticCheckFailure? diagnosticRowFailure(DiagnosticCheckRow row) {
  for (final result in row.steps.values) {
    final failure = result.failure;
    if (failure != null) return (kind: failure.kind, failure: failure);
  }
  return null;
}

typedef DiagnosticCheckFailure = ({FailureKind kind, HealthFailure failure});
