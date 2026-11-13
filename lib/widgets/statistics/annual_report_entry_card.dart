/// 统计页内的年度报告入口：无年份时完全隐藏；12–1 月高强调，其余月份低调。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../domain/models/annual_report_entry.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/m3e_context.dart';

class AnnualReportEntryCard extends StatelessWidget {
  const AnnualReportEntryCard({
    super.key,
    required this.entry,
    required this.onTap,
  });

  /// 稳定 Key（统计页测试 / 集成测试定位用）。
  static const Key cardKey = Key('annualReportEntry');

  final AnnualReportEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (!entry.isVisible) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final prominent = entry.prominent;
    final foreground = prominent ? scheme.onPrimaryContainer : scheme.onSurface;
    final background = prominent
        ? scheme.primaryContainer
        : scheme.surfaceContainerHigh;
    return M3ECard(
      key: cardKey,
      variant: M3ECardVariant.filled,
      color: background,
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      onPressed: onTap,
      child: Row(
        children: [
          Icon(
            Icons.insights_rounded,
            size: 24,
            color: prominent ? scheme.primary : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.annualReportTitle,
                  style: context.typeScale.titleSmall.copyWith(
                    color: foreground,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.annualReportEntrySubtitle(entry.featuredYear),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.typeScale.bodySmall.copyWith(
                    color: prominent
                        ? scheme.onPrimaryContainer.withValues(alpha: 0.82)
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (prominent)
            M3EButton.filled(
              onPressed: onTap,
              child: Text(l10n.annualReportEntryAction),
            )
          else
            Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
        ],
      ),
    );
  }
}
