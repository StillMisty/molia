import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../domain/models/diagnostics.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/diagnostics_provider.dart';
import '../../widgets/card_list_surface.dart';
import '../empty_state.dart';
import '../settings/settings_tiles.dart';
import 'diagnostics_labels.dart';

/// 最近问题：按渠道 + 原因归并后的问题组，点开看单条记录与下一步。
class DiagnosticsIssueSection extends StatelessWidget {
  const DiagnosticsIssueSection({
    super.key,
    required this.provider,
    required this.onOpenIssue,
  });

  final DiagnosticsProvider provider;
  final ValueChanged<DiagnosticIssueGroup> onOpenIssue;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ValueListenableBuilder<List<DiagnosticIssueGroup>>(
      valueListenable: provider.issueGroups,
      builder: (context, groups, _) {
        return SettingsSectionCard(
          title: l10n.diagnosticsRecentIssuesSection,
          children: groups.isEmpty
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
                  for (final group in groups)
                    _IssueRow(
                      key: ValueKey(
                        'diagnosticsIssueRow-${group.channelKey}-${group.kind.name}',
                      ),
                      group: group,
                      onTap: () => onOpenIssue(group),
                    ),
                ],
        );
      },
    );
  }
}

class _IssueRow extends StatelessWidget {
  const _IssueRow({super.key, required this.group, required this.onTap});

  final DiagnosticIssueGroup group;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final m3e = M3ETheme.of(context);
    final reason = diagnosticFailureReason(l10n, group.kind);
    final title = '${group.channelDisplayName} · $reason';
    final detail =
        '${l10n.diagnosticsIssueOccurrences(group.count)} · '
        '${l10n.diagnosticsIssueLastAt(diagnosticShortTime(group.lastAt))}';
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
              Icons.error_outline_rounded,
              size: 20,
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
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: m3e.typeScale.bodyLarge,
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
