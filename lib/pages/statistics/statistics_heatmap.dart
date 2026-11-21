/// 听歌统计页的热力图块：日历热力图（全量历史 + 范围高亮）、作息
/// 热力图（7×24，随范围过滤）与单日明细弹层。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../domain/models/play_statistics.dart';
import '../../domain/models/track.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/play_statistics_provider.dart';
import '../../services/statistics/listening_statistics.dart';
import '../../theme/m3e_context.dart';
import '../../widgets/labels/listened_duration.dart';
import '../../widgets/statistics/listening_heatmap.dart';
import '../../widgets/track_row.dart';

/// 日历热力图卡片：全量历史格子 + 范围高亮 + 时长/次数切换。
///
/// 值、起始日、今天与高亮起点都来自 [ListeningStatisticsView]。
class StatisticsCalendarHeatmapCard extends StatelessWidget {
  const StatisticsCalendarHeatmapCard({
    super.key,
    required this.l10n,
    required this.view,
    required this.valueMode,
    required this.selectedDay,
    required this.onValueModeChanged,
    required this.onDayTap,
  });

  final AppLocalizations l10n;
  final ListeningStatisticsView view;
  final PlayStatisticsValueMode valueMode;
  final DateTime? selectedDay;
  final ValueChanged<PlayStatisticsValueMode> onValueModeChanged;
  final ValueChanged<DateTime> onDayTap;

  @override
  Widget build(BuildContext context) {
    final duration = valueMode == PlayStatisticsValueMode.duration;
    final values = view.calendarValues(duration: duration);
    final localizations = MaterialLocalizations.of(context);

    return M3ECard(
      variant: M3ECardVariant.filled,
      // 底色降一档：空日格（surfaceContainerHighest）才有对比可见。
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              const HeatmapLegend(),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  M3EChip(
                    label: l10n.statsValueDuration,
                    type: M3EChipType.filter,
                    selected: valueMode == PlayStatisticsValueMode.duration,
                    onPressed: () =>
                        onValueModeChanged(PlayStatisticsValueMode.duration),
                  ),
                  const SizedBox(width: 8),
                  M3EChip(
                    label: l10n.statsValueCount,
                    type: M3EChipType.filter,
                    selected: valueMode == PlayStatisticsValueMode.count,
                    onPressed: () =>
                        onValueModeChanged(PlayStatisticsValueMode.count),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          CalendarHeatmap(
            values: values,
            firstDay: view.firstDay,
            lastDay: view.today,
            cellSize: 14,
            selectedDay: selectedDay,
            highlightFrom: view.window.start,
            tooltipFor: (day, value) => l10n.statsTooltip(
              localizations.formatMediumDate(day),
              duration
                  ? formatListenedDuration(l10n, value)
                  : l10n.statsPlaysCount(value),
            ),
            onDayTap: (day) {
              if (values.containsKey(day)) onDayTap(day);
            },
          ),
        ],
      ),
    );
  }
}

/// 作息热力图卡片：7×24 矩阵，随范围过滤。
class StatisticsWeekdayHourCard extends StatelessWidget {
  const StatisticsWeekdayHourCard({
    super.key,
    required this.l10n,
    required this.view,
    required this.valueMode,
  });

  final AppLocalizations l10n;
  final ListeningStatisticsView view;
  final PlayStatisticsValueMode valueMode;

  @override
  Widget build(BuildContext context) {
    final duration = valueMode == PlayStatisticsValueMode.duration;
    final values = view.weekdayHourValues(duration: duration);
    final narrow = MaterialLocalizations.of(context).narrowWeekdays;

    return M3ECard(
      variant: M3ECardVariant.filled,
      // 与日历热力图同底色：空时段格可见。
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.all(16),
      child: WeekdayHourHeatmap(
        values: values,
        tooltipFor: (weekday, hour, value) => l10n.statsTooltip(
          '${narrow[(weekday + 1) % 7]} $hour:00',
          duration
              ? formatListenedDuration(l10n, value)
              : l10n.statsPlaysCount(value),
        ),
      ),
    );
  }
}

/// 某一天的播放明细弹层（日期 + 当天汇总 + 曲目列表，可点播）。
class StatisticsDayDetailSheet extends StatelessWidget {
  const StatisticsDayDetailSheet({
    super.key,
    required this.day,
    required this.detail,
    required this.onPlay,
  });

  final DateTime day;
  final DayPlayEvents detail;
  final void Function(int index) onPlay;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final localizations = MaterialLocalizations.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Text(
              localizations.formatFullDate(day),
              style: context.typeScale.titleMedium,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
            child: Text(
              l10n.statsDaySummary(
                detail.playCount,
                formatListenedDuration(l10n, detail.listenedMs),
              ),
              style: context.typeScale.bodySmall.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              itemCount: detail.events.length,
              separatorBuilder: (context, _) =>
                  SizedBox(height: TrackRow.gapOf(context)),
              itemBuilder: (context, index) {
                final event = detail.events[index];
                final time = localizations.formatTimeOfDay(
                  TimeOfDay.fromDateTime(
                    DateTime.fromMillisecondsSinceEpoch(event.startedAt),
                  ),
                  alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(
                    context,
                  ),
                );
                return TrackRow(
                  model: TrackRowModel(
                    title: event.title,
                    artist: event.artist,
                    coverUrl: event.coverUrl,
                    durationMs: event.durationMs,
                    trackId: TrackId(event.sourceKey, event.songId),
                    trailingText:
                        '$time · ${formatListenedDuration(l10n, event.listenedMs)}',
                  ),
                  position: calculateCardPosition(index, detail.events.length),
                  onTap: () => onPlay(index),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
