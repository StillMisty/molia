/// 年度报告页的内容块：汇总 / 榜单 / 平台 / 月度 / 连续天数 / 首末播放 /
/// 覆盖范围。所有块只读 [AnnualReport] 与本地化文案，点播回调由页面注入。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../domain/models/annual_report.dart';
import '../../domain/models/track.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/m3e_context.dart';
import '../../theme/motion_policy.dart';
import '../../widgets/labels/listened_duration.dart';
import '../../widgets/track_row.dart';
import 'annual_report_models.dart';

/// 宽屏两栏、窄屏顺排。两栏只用于成组的榜单 / 时刻，避免在宽屏里
/// 每块都拉满一行造成的松散感。
class AnnualReportTwoUp extends StatelessWidget {
  const AnnualReportTwoUp({
    super.key,
    required this.wide,
    required this.first,
    required this.second,
  });

  final bool wide;
  final Widget? first;
  final Widget? second;

  @override
  Widget build(BuildContext context) {
    final children = [?first, ?second];
    if (children.isEmpty) return const SizedBox.shrink();
    if (!wide || children.length == 1) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < children.length; index++) ...[
            if (index > 0) const SizedBox(height: 24),
            children[index],
          ],
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: children[0]),
        const SizedBox(width: 24),
        Expanded(child: children[1]),
      ],
    );
  }
}

/// Hero：年份 + 总收听时长 + 「截至今天」徽标。
class AnnualReportHero extends StatelessWidget {
  const AnnualReportHero({super.key, required this.l10n, required this.report});

  final AppLocalizations l10n;
  final AnnualReport report;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return M3ECard(
      variant: M3ECardVariant.filled,
      color: scheme.primaryContainer,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  '${report.year}',
                  style: context.emphasizedTypeScale.displaySmall.copyWith(
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ),
              if (report.asOfToday)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.onPrimaryContainer.withValues(alpha: 0.08),
                      borderRadius: const BorderRadius.all(
                        Radius.circular(M3EShapes.full),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      child: Text(
                        l10n.annualReportAsOfToday,
                        style: context.typeScale.labelMedium.copyWith(
                          color: scheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            formatListenedDuration(l10n, report.totalListenedMs),
            style: context.emphasizedTypeScale.headlineMedium.copyWith(
              color: scheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            l10n.annualReportListenedCaption,
            style: context.typeScale.bodyMedium.copyWith(
              color: scheme.onPrimaryContainer.withValues(alpha: 0.8),
            ),
          ),
        ],
      ),
    );
  }
}

/// 汇总数字块 ×4：播放 / 曲目 / 歌手 / 连续天数。
class AnnualReportNumbers extends StatelessWidget {
  const AnnualReportNumbers({
    super.key,
    required this.l10n,
    required this.report,
    required this.wide,
  });

  final AppLocalizations l10n;
  final AnnualReport report;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final tiles = [
      for (final metric in buildAnnualReportMetrics(l10n, report))
        _NumberTile(metric: metric),
    ];
    if (wide) {
      return Row(
        children: [
          for (final tile in tiles) ...[
            if (tile != tiles.first) const SizedBox(width: 12),
            Expanded(child: tile),
          ],
        ],
      );
    }
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: tiles[0]),
            const SizedBox(width: 12),
            Expanded(child: tiles[1]),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: tiles[2]),
            const SizedBox(width: 12),
            Expanded(child: tiles[3]),
          ],
        ),
      ],
    );
  }
}

/// 月度趋势：12 根柱子，唯一峰值用完整主色。
class AnnualReportMonthly extends StatelessWidget {
  const AnnualReportMonthly({
    super.key,
    required this.l10n,
    required this.report,
  });

  final AppLocalizations l10n;
  final AnnualReport report;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxValue = report.monthlyListenedMs.fold<int>(
      0,
      (max, value) => value > max ? value : max,
    );
    // 多个月并列最高时不强行挑一个「峰值」，否则连续持平的数据会误导。
    final peakCount = maxValue <= 0
        ? 0
        : report.monthlyListenedMs.where((value) => value == maxValue).length;
    final peakMonth = peakCount == 1
        ? report.monthlyListenedMs.indexOf(maxValue)
        : -1;
    return _Section(
      title: l10n.annualReportMonthly,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 140,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var month = 0; month < 12; month++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: Semantics(
                        label: l10n.annualReportMonthLabel(
                          month + 1,
                          formatListenedDuration(
                            l10n,
                            report.monthlyListenedMs[month],
                          ),
                        ),
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: FractionallySizedBox(
                            heightFactor:
                                maxValue <= 0 ||
                                    report.monthlyListenedMs[month] <= 0
                                ? 0
                                : (report.monthlyListenedMs[month] / maxValue)
                                      .clamp(0.02, 1),
                            widthFactor: 1,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                // 最高月份用完整主色，其余降透明度：不增加
                                // 图例，也能一眼看出全年峰值。
                                color: month == peakMonth
                                    ? scheme.primary
                                    : scheme.primary.withValues(alpha: 0.45),
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(M3EShapes.extraSmall),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Container(
            height: 1,
            color: scheme.outlineVariant.withValues(alpha: 0.6),
          ),
          const SizedBox(height: 6),
          // 柱子自己的 Semantics 已经带月份与时长；这排数字只是视觉刻度，
          // 不重复读给读屏。
          ExcludeSemantics(
            child: Row(
              children: [
                for (var month = 0; month < 12; month++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: Text(
                        '${month + 1}',
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        style: context.typeScale.labelSmall.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
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

/// Top 曲目（可点播）。
class AnnualReportTopTracks extends StatelessWidget {
  const AnnualReportTopTracks({
    super.key,
    required this.l10n,
    required this.report,
    required this.onTap,
  });

  final AppLocalizations l10n;
  final AnnualReport report;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final tracks = report.pageTopTracks;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.annualReportTopTracks, style: context.typeScale.titleMedium),
        const SizedBox(height: 12),
        for (var index = 0; index < tracks.length; index++) ...[
          if (index > 0) SizedBox(height: TrackRow.gapOf(context)),
          TrackRow(
            model: TrackRowModel(
              title: tracks[index].title,
              artist: tracks[index].artist,
              coverUrl: tracks[index].coverUrl,
              durationMs: tracks[index].durationMs,
              trackId: TrackId(tracks[index].sourceKey, tracks[index].songId),
              trailingText:
                  '${l10n.statsPlaysCount(tracks[index].playCount)} · '
                  '${formatListenedDuration(l10n, tracks[index].listenedMs)}',
            ),
            position: calculateCardPosition(index, tracks.length),
            onTap: () => onTap(index),
          ),
        ],
      ],
    );
  }
}

/// Top 歌手榜单。
class AnnualReportTopArtists extends StatelessWidget {
  const AnnualReportTopArtists({
    super.key,
    required this.l10n,
    required this.report,
  });

  final AppLocalizations l10n;
  final AnnualReport report;

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: l10n.annualReportTopArtists,
      child: Column(
        children: [
          for (var index = 0; index < report.pageTopArtists.length; index++)
            _RankRow(
              index: index,
              label: report.pageTopArtists[index].artist,
              trailing: l10n.statsPlaysCount(
                report.pageTopArtists[index].playCount,
              ),
            ),
        ],
      ),
    );
  }
}

/// Top 专辑榜单。
class AnnualReportTopAlbums extends StatelessWidget {
  const AnnualReportTopAlbums({
    super.key,
    required this.l10n,
    required this.report,
  });

  final AppLocalizations l10n;
  final AnnualReport report;

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: l10n.annualReportTopAlbums,
      child: Column(
        children: [
          for (var index = 0; index < report.pageTopAlbums.length; index++)
            _RankRow(
              index: index,
              label: report.pageTopAlbums[index].album,
              trailing: l10n.statsPlaysCount(
                report.pageTopAlbums[index].playCount,
              ),
            ),
        ],
      ),
    );
  }
}

/// 平台分布：平台名 + 占比条 + 时长 · 百分比。
class AnnualReportPlatforms extends StatelessWidget {
  const AnnualReportPlatforms({
    super.key,
    required this.l10n,
    required this.report,
  });

  final AppLocalizations l10n;
  final AnnualReport report;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _Section(
      title: l10n.annualReportPlatforms,
      child: Column(
        children: [
          for (var index = 0; index < report.platforms.length; index++) ...[
            if (index > 0) const SizedBox(height: 10),
            Row(
              children: [
                SizedBox(
                  width: 88,
                  child: Text(
                    annualReportSourceName(
                      context,
                      l10n,
                      report.platforms[index].sourceKey,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.typeScale.labelMedium,
                  ),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: M3EShapes.radiusExtraSmall,
                    child: SizedBox(
                      height: 8,
                      child: ColoredBox(
                        color: scheme.surfaceContainerHighest,
                        child: FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: report.platforms[index].share.clamp(
                            0,
                            1,
                          ),
                          child: ColoredBox(color: scheme.primary),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: Text(
                    '${formatListenedDuration(l10n, report.platforms[index].listenedMs)}'
                    ' · ${(report.platforms[index].share * 100).round()}%',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: context.typeScale.labelSmall.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
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

/// 首次 / 最后一次播放。
class AnnualReportEdges extends StatelessWidget {
  const AnnualReportEdges({
    super.key,
    required this.l10n,
    required this.report,
    required this.wide,
  });

  final AppLocalizations l10n;
  final AnnualReport report;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final first = report.firstPlay == null
        ? null
        : _MomentTile(
            label: l10n.annualReportFirstPlay,
            moment: report.firstPlay!,
          );
    final last = report.lastPlay == null
        ? null
        : _MomentTile(
            label: l10n.annualReportLastPlay,
            moment: report.lastPlay!,
          );
    return AnnualReportTwoUp(wide: wide, first: first, second: last);
  }
}

/// 覆盖范围说明；没有需要说明的内容时返回 null（页面据此省略整块）。
Widget? buildAnnualReportCoverage(
  BuildContext context,
  AppLocalizations l10n,
  AnnualReport report,
) {
  final scheme = Theme.of(context).colorScheme;
  final localizations = MaterialLocalizations.of(context);
  final lines = <String>[
    if (report.notice == AnnualReportNotice.recordingOff)
      l10n.annualReportRecordingOff,
    if (report.notice == AnnualReportNotice.partialCoverage)
      l10n.annualReportPartialCoverage,
    // 完整结束的往年不重复展示「整年」范围；进行中的当年与不完整年份
    // 才需要说明实际覆盖。
    if (report.coverageStart != null &&
        report.coverageEnd != null &&
        (report.asOfToday || report.notice != AnnualReportNotice.none))
      l10n.annualReportCoverage(
        localizations.formatMediumDate(report.coverageStart!),
        localizations.formatMediumDate(report.coverageEnd!),
      ),
  ];
  if (lines.isEmpty) return null;
  final text = lines.join('\n');
  // 「统计关闭 / 只覆盖部分时段」会影响用户对数字的信任，不能继续当
  // 脚注小字；普通「截至今天」仍保持轻量说明。
  if (report.notice == AnnualReportNotice.none) {
    return Text(
      text,
      style: context.typeScale.bodySmall.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    );
  }
  return M3ECard(
    variant: M3ECardVariant.filled,
    color: scheme.tertiaryContainer,
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.info_outline_rounded,
          size: 20,
          color: scheme.onTertiaryContainer,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: context.typeScale.bodySmall.copyWith(
              color: scheme.onTertiaryContainer,
            ),
          ),
        ),
      ],
    ),
  );
}

/// 标题 + 填色卡片的外壳。
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: context.typeScale.titleMedium),
        const SizedBox(height: 12),
        M3ECard(
          variant: M3ECardVariant.filled,
          color: scheme.surfaceContainerLow,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: child,
        ),
      ],
    );
  }
}

/// 歌手 / 专辑榜单共用一行的排名槽与省略规则，避免同一页出现两套对齐。
class _RankRow extends StatelessWidget {
  const _RankRow({
    required this.index,
    required this.label,
    required this.trailing,
  });

  final int index;
  final String label;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text(
              '${index + 1}',
              textAlign: TextAlign.center,
              style: context.typeScale.labelMedium.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.typeScale.bodyLarge,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            trailing,
            style: context.typeScale.labelSmall.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _NumberTile extends StatelessWidget {
  const _NumberTile({required this.metric});

  final AnnualReportMetric metric;

  @override
  Widget build(BuildContext context) {
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
                  // 一次性入场：从 0 滚到目标值，落定后停在目标数字（不是常驻
                  // ticker）；减弱动效零时长，直接硬切到目标值。
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(
                      begin: 0,
                      end: metric.value.toDouble(),
                    ),
                    duration: effectDurationOf(context, M3EMotion.short4),
                    curve: M3EMotion.emphasizedDecelerate,
                    builder: (context, current, _) => Text(
                      '${current.round()}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.emphasizedTypeScale.titleLarge.copyWith(
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    metric.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.typeScale.labelSmall.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(metric.icon, size: 22, color: scheme.primary),
          ],
        ),
      ),
    );
  }
}

class _MomentTile extends StatelessWidget {
  const _MomentTile({required this.label, required this.moment});

  final String label;
  final AnnualPlayMoment moment;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final date = MaterialLocalizations.of(context)
        .formatMediumDate(moment.localDay);
    return M3ECard(
      variant: M3ECardVariant.filled,
      color: scheme.surfaceContainerHigh,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: context.typeScale.labelMedium.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            moment.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.typeScale.bodyLarge,
          ),
          const SizedBox(height: 2),
          Text(
            '${moment.artist} · $date',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.typeScale.bodySmall.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
