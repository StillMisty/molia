/// 年度报告页的页面内 DTO 与共享格式化。
///
/// 只放「页面自己定义、但不止一个拆分文件要用」的展示值：汇总数字块与
/// 平台显示名。年度窗口 / 月度 / 连续天数等口径仍在
/// `lib/domain/models/annual_report.dart`，本文件不复制聚合逻辑。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../domain/models/annual_report.dart';
import '../../domain/ports/source_registry.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_providers.dart';

/// 汇总数字块：图标 / 文案 / 计数。
class AnnualReportMetric {
  const AnnualReportMetric({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final int value;
}

/// 报告页顶部的四个数字块（播放 / 曲目 / 歌手 / 连续天数）。
List<AnnualReportMetric> buildAnnualReportMetrics(
  AppLocalizations l10n,
  AnnualReport report,
) => [
  AnnualReportMetric(
    icon: Icons.headphones_rounded,
    label: l10n.statsPlays,
    value: report.qualifiedPlayCount,
  ),
  AnnualReportMetric(
    icon: Icons.library_music_rounded,
    label: l10n.annualReportStatTracks,
    value: report.uniqueTrackCount,
  ),
  AnnualReportMetric(
    icon: Icons.person_rounded,
    label: l10n.annualReportStatArtists,
    value: report.uniqueArtistCount,
  ),
  AnnualReportMetric(
    icon: Icons.local_fire_department_rounded,
    label: l10n.annualReportStreakCaption,
    value: report.streak.days,
  ),
];

/// 平台显示名：`other` 与注册表命中优先，否则回退原始 key。
String annualReportSourceName(
  BuildContext context,
  AppLocalizations l10n,
  String sourceKey,
) {
  if (sourceKey == 'other') return l10n.statsSourceOther;
  final SourceRegistry? registry = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(sourceRegistryProvider);
  for (final descriptor in registry?.descriptors ?? const []) {
    if (descriptor.key == sourceKey) return descriptor.displayName;
  }
  return sourceKey;
}
