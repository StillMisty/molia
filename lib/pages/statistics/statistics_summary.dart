/// 听歌统计页的汇总区：四个数字块、完整播放率 / 跳过率与来源分布。
library;

import 'dart:math' as math;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../domain/models/play_statistics.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/m3e_context.dart';
import '../../theme/motion_policy.dart';
import '../../widgets/labels/listened_duration.dart';
import 'statistics_models.dart';

/// 汇总数字块 ×4：播放次数 / 时长 / 曲目数 / 起始日期。
class StatisticsSummaryBlocks extends StatelessWidget {
  const StatisticsSummaryBlocks({
    super.key,
    required this.l10n,
    required this.snapshot,
    required this.wide,
  });

  final AppLocalizations l10n;
  final ListeningStatisticsSnapshot? snapshot;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final data = snapshot;
    if (data == null) return const SizedBox.shrink();
    final summary = data.summary;
    final firstPlayedAt = summary.firstPlayedAt;
    final scheme = Theme.of(context).colorScheme;
    // 常规卡片 + 语义图标：不规则形状只留在热力图格子/空态/徽标等
    // 真正需要表现力的地方，汇总统计保持克制。
    final blocks = <Widget>[
      StatisticsStatBlock(
        icon: Icons.headphones_rounded,
        iconColor: scheme.primary,
        value: '${summary.qualifiedPlayCount}',
        label: l10n.statsPlays,
      ),
      StatisticsStatBlock(
        icon: Icons.schedule_rounded,
        iconColor: scheme.secondary,
        value: formatListenedDuration(l10n, summary.totalListenedMs),
        label: l10n.statsListened,
      ),
      StatisticsStatBlock(
        icon: Icons.library_music_rounded,
        iconColor: scheme.tertiary,
        value: '${summary.uniqueTrackCount}',
        label: l10n.statsTracks,
      ),
      StatisticsStatBlock(
        icon: Icons.calendar_month_rounded,
        iconColor: scheme.onSurfaceVariant,
        value: firstPlayedAt == null
            ? '—'
            : formatCompactStatisticsDate(firstPlayedAt),
        label: l10n.statsSince,
      ),
    ];

    if (wide) {
      return Row(
        children: [
          for (final block in blocks) ...[
            if (block != blocks.first) const SizedBox(width: 12),
            Expanded(child: block),
          ],
        ],
      );
    }
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: blocks[0]),
            const SizedBox(width: 12),
            Expanded(child: blocks[1]),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: blocks[2]),
            const SizedBox(width: 12),
            Expanded(child: blocks[3]),
          ],
        ),
      ],
    );
  }
}

/// 指标行：完整播放率 / 跳过率 / 来源分布。
class StatisticsMetricsSection extends StatelessWidget {
  const StatisticsMetricsSection({
    super.key,
    required this.l10n,
    required this.snapshot,
    required this.sourceName,
    required this.wide,
  });

  final AppLocalizations l10n;
  final ListeningStatisticsSnapshot? snapshot;
  final String Function(String sourceKey) sourceName;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final data = snapshot;
    if (data == null) return const SizedBox.shrink();
    final summary = data.summary;
    final cards = [
      StatisticsRateCard(
        title: l10n.statsCompleteRate,
        value: summary.completionRate,
      ),
      StatisticsRateCard(title: l10n.statsSkipRate, value: summary.skipRate),
      _SourcesCard(l10n: l10n, sources: data.sources, sourceName: sourceName),
    ];
    if (wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final card in cards) ...[
            if (card != cards.first) const SizedBox(width: 12),
            Expanded(child: card),
          ],
        ],
      );
    }
    return Column(
      children: [
        for (final card in cards) ...[
          if (card != cards.first) const SizedBox(height: 12),
          card,
        ],
      ],
    );
  }
}

/// 汇总数字卡：常规 M3E 卡片 + 语义图标点缀。
class StatisticsStatBlock extends StatelessWidget {
  const StatisticsStatBlock({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.value,
    required this.label,
  });

  final IconData icon;
  final Color iconColor;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final type = context.typeScale;
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 84,
      child: M3ECard(
        variant: M3ECardVariant.filled,
        color: scheme.surfaceContainerHigh,
        padding: const EdgeInsets.fromLTRB(16, 12, 14, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.emphasizedTypeScale.titleLarge.copyWith(
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.labelSmall.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(icon, size: 22, color: iconColor),
          ],
        ),
      ),
    );
  }
}

/// 指标卡：百分比 + 细进度条。
class StatisticsRateCard extends StatelessWidget {
  const StatisticsRateCard({
    super.key,
    required this.title,
    required this.value,
  });

  final String title;
  final double value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return M3ECard(
      variant: M3ECardVariant.filled,
      color: scheme.surfaceContainerHigh,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: context.typeScale.titleSmall),
          const SizedBox(height: 8),
          Text(
            '${(value * 100).round()}%',
            style: context.typeScale.headlineSmall,
          ),
          const SizedBox(height: 10),
          StatisticsShareBar(
            share: value.clamp(0, 1),
            background: scheme.surfaceContainerHighest,
            color: scheme.primary,
          ),
        ],
      ),
    );
  }
}

/// 细圆角占比条（指标卡 / 来源分布共用）。
class StatisticsShareBar extends StatelessWidget {
  const StatisticsShareBar({
    super.key,
    required this.share,
    required this.background,
    required this.color,
  });

  static const double _height = 8;

  final double share;
  final Color background;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final double target = share.clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(_height / 2),
      child: Container(
        height: _height,
        color: background,
        child: Align(
          alignment: Alignment.centerLeft,
          // 一次性入场 / 数值变化动画（不是常驻 ticker）：落定后停在目标
          // 占比；减弱动效零时长硬切到目标。
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: target),
            duration: effectDurationOf(context, M3EMotion.short4),
            curve: M3EMotion.emphasizedDecelerate,
            builder: (context, value, _) => FractionallySizedBox(
              widthFactor: value,
              heightFactor: 1,
              child: ColoredBox(color: color),
            ),
          ),
        ),
      ),
    );
  }
}

class _SourcesCard extends StatelessWidget {
  const _SourcesCard({
    required this.l10n,
    required this.sources,
    required this.sourceName,
  });

  final AppLocalizations l10n;
  final List<SourceListened> sources;
  final String Function(String sourceKey) sourceName;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxListened = sources.fold<int>(
      0,
      (max, entry) => math.max(max, entry.listenedMs),
    );
    return M3ECard(
      variant: M3ECardVariant.filled,
      color: scheme.surfaceContainerHigh,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.statsSources, style: context.typeScale.titleSmall),
          const SizedBox(height: 12),
          for (var i = 0; i < sources.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            Row(
              children: [
                SizedBox(
                  width: 64,
                  child: Text(
                    sourceName(sources[i].sourceKey),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.typeScale.labelMedium,
                  ),
                ),
                Expanded(
                  child: StatisticsShareBar(
                    share: maxListened <= 0
                        ? 0
                        : sources[i].listenedMs / maxListened,
                    background: scheme.surfaceContainerHighest,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  formatListenedDuration(l10n, sources[i].listenedMs),
                  style: context.typeScale.labelSmall.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
