/// 听歌统计页：范围切换 + 汇总数字块 + 日历/作息热力图 + 指标 + 榜单。
///
/// 结构：
/// ① 范围切换（设置页共享分段行）+ 汇总数字块 ×4
/// ② hero 日历热力图（**全量历史**；范围切换只做高亮 + 数字联动；
///    值可切换 时长/次数）
/// ③ 作息热力图（7×24，随范围过滤）
/// ④ 指标行（完整播放率 / 跳过率 / 来源分布）
/// ⑤ Top 曲目（可点播）⑥ Top 歌手（拆分后的艺人）
///
/// 订阅用 Consumer（整页低频重建）：页面状态是多字段聚合，`select` 禁止
/// 返回 List 引用（AGENTS 约定），按页订阅最直接；`position` 不参与本页。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/play_statistics.dart';
import '../domain/models/track.dart';
import '../domain/ports/source_registry.dart';
import '../l10n/app_localizations.dart';
import '../providers/library_provider.dart';
import '../providers/play_statistics_provider.dart';
import '../providers/playback_provider.dart';
import '../services/notification_service.dart';
import '../theme/m3e_context.dart';
import '../utils/responsive.dart';
import '../widgets/settings/settings_tiles.dart';
import '../widgets/statistics/listening_heatmap.dart';
import '../widgets/track_row.dart';

class PlayStatisticsPage extends StatefulWidget {
  const PlayStatisticsPage({super.key});

  @override
  State<PlayStatisticsPage> createState() => _PlayStatisticsPageState();
}

class _PlayStatisticsPageState extends State<PlayStatisticsPage> {
  late final PlayStatisticsProvider _provider;

  /// 日历热力图选中的一天（弹层打开期间保持放大 + 描边）。
  DateTime? _selectedDay;

  @override
  void initState() {
    super.initState();
    _provider = context.read<PlayStatisticsProvider>();
    _provider.startWatching();
    unawaited(_provider.ensureLoaded());
  }

  @override
  void dispose() {
    _provider.stopWatching();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.statsTitle),
        automaticallyImplyLeading: true,
        actions: [
          M3EIconButton(
            variant: M3EIconButtonVariant.standard,
            icon: const Icon(Icons.ios_share_rounded),
            semanticLabel: l10n.statsExport,
            onPressed: _export,
          ),
          M3EMenu.entries(
            position: M3EMenuAnchorPosition.bottomEnd,
            anchorBuilder: (context, open) => M3EIconButton(
              variant: M3EIconButtonVariant.standard,
              icon: const Icon(Icons.more_vert_rounded),
              semanticLabel: l10n.statsClear,
              onPressed: open,
            ),
            onSelected: (value) {
              if (value == 'clear') unawaited(_confirmClear());
            },
            entries: [
              M3EMenuEntry(
                label: l10n.statsClear,
                value: 'clear',
                leading: const Icon(Icons.delete_outline_rounded),
                isDestructive: true,
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Consumer<PlayStatisticsProvider>(
          builder: (context, provider, _) {
            if (!provider.hasLoaded && provider.isLoading) {
              return const Center(child: M3ELoadingIndicator());
            }
            if (!provider.hasLoaded && provider.hasError) {
              return _errorState(l10n, provider);
            }
            return _content(l10n, provider);
          },
        ),
      ),
    );
  }

  Widget _content(AppLocalizations l10n, PlayStatisticsProvider provider) {
    final isWide = context.isLargeScreen;
    final isDesktop = context.isDesktop;
    // 范围切换走设置页共享的分段行（SettingsChoiceRow 显式给紧约束宽度，
    // M3ESegmentedButton 才能等宽铺满；放 Row 尾位会零宽溢出）。
    final rangeRow = SettingsChoiceRow<PlayStatisticsRange>(
      icon: Icons.date_range_rounded,
      title: l10n.statsRangeTitle,
      value: provider.range,
      options: [
        (PlayStatisticsRange.week, l10n.statsRangeWeek),
        (PlayStatisticsRange.month, l10n.statsRangeMonth),
        (PlayStatisticsRange.all, l10n.statsRangeAll),
      ],
      onChanged: (range) => unawaited(provider.setRange(range)),
    );
    final sections = <Widget>[
      rangeRow,
      const SizedBox(height: 16),
      if (provider.isEmpty)
        _emptyState(l10n)
      else ...[
        // 围绕热力图设计：范围切换 → hero 热力图 → 汇总条 → 作息 → 指标 → 榜单。
        _heatmapCard(l10n, provider),
        const SizedBox(height: 16),
        _summaryBlocks(l10n, provider, wide: isWide),
        const SizedBox(height: 16),
        _weekdayHourCard(l10n, provider),
        const SizedBox(height: 16),
        _metricsSection(l10n, provider, wide: isWide),
        const SizedBox(height: 24),
        // ≥900dp：Top 曲目与 Top 歌手并排两栏。
        if (isDesktop)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _topTracksSection(l10n, provider)),
              const SizedBox(width: 24),
              Expanded(child: _topArtistsSection(l10n, provider)),
            ],
          )
        else ...[
          _topTracksSection(l10n, provider),
          const SizedBox(height: 24),
          _topArtistsSection(l10n, provider),
        ],
      ],
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: sections,
    );
  }

  Widget _errorState(AppLocalizations l10n, PlayStatisticsProvider provider) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded, size: 40),
          const SizedBox(height: 12),
          Text(l10n.statsEmpty),
          const SizedBox(height: 12),
          M3EButton.filled(
            onPressed: () => unawaited(provider.refresh()),
            child: Text(l10n.retry),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 48),
      child: Column(
        children: [
          M3EShapeContainer(
            kind: M3EShapeKind.bun,
            width: 96,
            height: 96,
            color: scheme.tertiaryContainer,
            child: Icon(
              Icons.music_note_rounded,
              size: 40,
              color: scheme.onTertiaryContainer,
            ),
          ),
          const SizedBox(height: 20),
          Text(l10n.statsEmpty, style: context.typeScale.titleMedium),
          const SizedBox(height: 6),
          Text(
            l10n.statsEmptyHint,
            style: context.typeScale.bodySmall.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryBlocks(
    AppLocalizations l10n,
    PlayStatisticsProvider provider, {
    required bool wide,
  }) {
    final snapshot = provider.snapshot;
    if (snapshot == null) return const SizedBox.shrink();
    final summary = snapshot.summary;
    final firstPlayedAt = summary.firstPlayedAt;
    final scheme = Theme.of(context).colorScheme;
    // 常规卡片 + 语义图标：不规则形状只留在热力图格子/空态/徽标等
    // 真正需要表现力的地方，汇总统计保持克制。
    final blocks = <Widget>[
      _StatBlock(
        icon: Icons.headphones_rounded,
        iconColor: scheme.primary,
        value: '${summary.qualifiedPlayCount}',
        label: l10n.statsPlays,
      ),
      _StatBlock(
        icon: Icons.schedule_rounded,
        iconColor: scheme.secondary,
        value: _formatListened(l10n, summary.totalListenedMs),
        label: l10n.statsListened,
      ),
      _StatBlock(
        icon: Icons.library_music_rounded,
        iconColor: scheme.tertiary,
        value: '${summary.uniqueTrackCount}',
        label: l10n.statsTracks,
      ),
      _StatBlock(
        icon: Icons.calendar_month_rounded,
        iconColor: scheme.onSurfaceVariant,
        value: firstPlayedAt == null ? '—' : _compactDate(firstPlayedAt),
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

  /// 紧凑日期：同年 `M/d`、跨年 `yyyy/M`（完整日期会在窄块里被裁切）。
  String _compactDate(int epochMs) {
    final date = DateTime.fromMillisecondsSinceEpoch(epochMs);
    final now = DateTime.now();
    return date.year == now.year
        ? '${date.month}/${date.day}'
        : '${date.year}/${date.month}';
  }

  Map<DateTime, int> _calendarValues(PlayStatisticsProvider provider) {
    final snapshot = provider.snapshot;
    if (snapshot == null) return const {};
    final duration = provider.valueMode == PlayStatisticsValueMode.duration;
    return {
      for (final entry in snapshot.daily)
        entry.day: duration ? entry.listenedMs : entry.playCount,
    };
  }

  Widget _heatmapCard(AppLocalizations l10n, PlayStatisticsProvider provider) {
    final values = _calendarValues(provider);
    final today = DateUtils.dateOnly(DateTime.now());
    final firstPlayedAt = provider.snapshot?.summary.firstPlayedAt;
    final firstDay = firstPlayedAt == null
        ? today
        : DateUtils.dateOnly(
            DateTime.fromMillisecondsSinceEpoch(firstPlayedAt));
    final localizations = MaterialLocalizations.of(context);
    final duration = provider.valueMode == PlayStatisticsValueMode.duration;

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
                    selected:
                        provider.valueMode == PlayStatisticsValueMode.duration,
                    onPressed: () =>
                        provider.setValueMode(PlayStatisticsValueMode.duration),
                  ),
                  const SizedBox(width: 8),
                  M3EChip(
                    label: l10n.statsValueCount,
                    type: M3EChipType.filter,
                    selected:
                        provider.valueMode == PlayStatisticsValueMode.count,
                    onPressed: () =>
                        provider.setValueMode(PlayStatisticsValueMode.count),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          CalendarHeatmap(
            values: values,
            firstDay: firstDay,
            lastDay: today,
            cellSize: 14,
            selectedDay: _selectedDay,
            highlightFrom: provider.rangeStart,
            tooltipFor: (day, value) => l10n.statsTooltip(
              localizations.formatMediumDate(day),
              duration
                  ? _formatListened(l10n, value)
                  : l10n.statsPlaysCount(value),
            ),
            onDayTap: (day) {
              if (values.containsKey(day)) unawaited(_showDayDetail(day));
            },
          ),
        ],
      ),
    );
  }

  Widget _weekdayHourCard(
    AppLocalizations l10n,
    PlayStatisticsProvider provider,
  ) {
    // 7×24 矩阵（0=周一）；值按当前维度取。
    final values = [
      for (final row in List.generate(7, (_) => List.filled(24, 0)))
        List<int>.of(row),
    ];
    final snapshot = provider.snapshot;
    if (snapshot == null) return const SizedBox.shrink();
    for (final entry in snapshot.byWeekdayHour) {
      if (entry.weekday < 0 || entry.weekday > 6) continue;
      values[entry.weekday][entry.hour] =
          provider.valueMode == PlayStatisticsValueMode.duration
              ? entry.listenedMs
              : entry.playCount;
    }
    final duration = provider.valueMode == PlayStatisticsValueMode.duration;
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
          duration ? _formatListened(l10n, value) : l10n.statsPlaysCount(value),
        ),
      ),
    );
  }

  Widget _metricsSection(
    AppLocalizations l10n,
    PlayStatisticsProvider provider, {
    required bool wide,
  }) {
    final snapshot = provider.snapshot;
    if (snapshot == null) return const SizedBox.shrink();
    final summary = snapshot.summary;
    final cards = [
      _RateCard(title: l10n.statsCompleteRate, value: summary.completionRate),
      _RateCard(title: l10n.statsSkipRate, value: summary.skipRate),
      _sourcesCard(l10n, provider),
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

  Widget _sourcesCard(AppLocalizations l10n, PlayStatisticsProvider provider) {
    final scheme = Theme.of(context).colorScheme;
    final sources = provider.snapshot?.sources ?? const <SourceListened>[];
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
          Text(
            l10n.statsSources,
            style: context.typeScale.titleSmall,
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < sources.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            Row(
              children: [
                SizedBox(
                  width: 64,
                  child: Text(
                    _sourceName(sources[i].sourceKey),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.typeScale.labelMedium,
                  ),
                ),
                Expanded(
                  child: _ShareBar(
                    share: maxListened <= 0
                        ? 0
                        : sources[i].listenedMs / maxListened,
                    background: scheme.surfaceContainerHighest,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _formatListened(l10n, sources[i].listenedMs),
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

  String _sourceName(String sourceKey) {
    final registry = context.read<SourceRegistry?>();
    for (final descriptor in registry?.descriptors ?? const []) {
      if (descriptor.key == sourceKey) return descriptor.displayName;
    }
    return sourceKey;
  }

  Widget _topTracksSection(
    AppLocalizations l10n,
    PlayStatisticsProvider provider,
  ) {
    final tracks = provider.snapshot?.topTracks ?? const <PlayStatTrackEntry>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.statsTopTracks, style: context.typeScale.titleMedium),
        const SizedBox(height: 12),
        for (var i = 0; i < tracks.length; i++) ...[
          if (i > 0) SizedBox(height: TrackRow.gapOf(context)),
          TrackRow(
            model: TrackRowModel(
              title: tracks[i].title,
              artist: tracks[i].artist,
              coverUrl: tracks[i].coverUrl,
              durationMs: tracks[i].durationMs,
              trackId: TrackId(tracks[i].sourceKey, tracks[i].songId),
              trailingText: '${l10n.statsPlaysCount(tracks[i].playCount)} · '
                  '${_formatListened(l10n, tracks[i].listenedMs)}',
            ),
            position: calculateCardPosition(i, tracks.length),
            onTap: () => unawaited(_playTopTracks(tracks, i)),
          ),
        ],
      ],
    );
  }

  Widget _topArtistsSection(
    AppLocalizations l10n,
    PlayStatisticsProvider provider,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final artists =
        provider.snapshot?.topArtists ?? const <PlayStatArtistEntry>[];
    if (artists.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.statsTopArtists, style: context.typeScale.titleMedium),
        const SizedBox(height: 12),
        M3ECard(
          variant: M3ECardVariant.filled,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            children: [
              for (var i = 0; i < artists.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      _rankBadge(i),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          artists[i].artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.typeScale.bodyLarge,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        l10n.statsPlaysCount(artists[i].playCount),
                        style: context.typeScale.labelSmall.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _rankBadge(int index) {
    final scheme = Theme.of(context).colorScheme;
    if (index >= 3) {
      return SizedBox(
        width: 28,
        child: Text(
          '${index + 1}',
          textAlign: TextAlign.center,
          style: context.typeScale.labelMedium.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }
    const shapes = [
      M3EShapeKind.cookie4Sided,
      M3EShapeKind.softBurst,
      M3EShapeKind.clover4Leaf,
    ];
    return M3EShapeContainer(
      kind: shapes[index],
      width: 28,
      height: 28,
      color: scheme.tertiaryContainer,
      child: Center(
        child: Text(
          '${index + 1}',
          style: context.typeScale.labelSmall.copyWith(
            color: scheme.onTertiaryContainer,
          ),
        ),
      ),
    );
  }

  Future<void> _playTopTracks(
      List<PlayStatTrackEntry> entries, int index) async {
    if (entries.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    final library = context.read<LibraryProvider>();
    final playback = context.read<PlaybackProvider>();
    final tracks = [
      for (final entry in entries)
        library.sourceTrackFromRaw(
          sourceKey: entry.sourceKey,
          title: entry.title,
          artist: entry.artist,
          album: entry.album,
          coverUrl: entry.coverUrl,
          durationMs: entry.durationMs,
          raw: entry.raw,
        ),
    ];
    await playback.playSourceTracks(
      tracks,
      index.clamp(0, tracks.length - 1),
      contextName: l10n.statsTopTracks,
    );
  }

  Future<void> _playDayEvents(List<PlayEvent> events, int index) async {
    if (events.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    final library = context.read<LibraryProvider>();
    final playback = context.read<PlaybackProvider>();
    final tracks = [
      for (final event in events)
        library.sourceTrackFromRaw(
          sourceKey: event.sourceKey,
          title: event.title,
          artist: event.artist,
          album: event.album,
          coverUrl: event.coverUrl,
          durationMs: event.durationMs,
          raw: event.raw,
        ),
    ];
    await playback.playSourceTracks(
      tracks,
      index.clamp(0, tracks.length - 1),
      contextName: l10n.statsTitle,
    );
  }

  Future<void> _showDayDetail(DateTime day) async {
    setState(() => _selectedDay = day);
    try {
      final detail = await _provider.loadDay(day);
      if (!mounted) return;
      final events = detail.events;
      await M3EBottomSheet.show<void>(
        context,
        initialValue: M3EBottomSheetValue.expanded,
        builder: (_) => _DayDetailSheet(
          day: day,
          detail: detail,
          onPlay: (index) => unawaited(_playDayEvents(events, index)),
        ),
      );
    } finally {
      if (mounted) setState(() => _selectedDay = null);
    }
  }

  Future<void> _export() async {
    final l10n = AppLocalizations.of(context)!;
    final notifications = context.read<NotificationService?>();
    final success = await _provider.export();
    if (!mounted) return;
    // 成功时系统分享面板本身即反馈（与备份导出同约定），失败才提示。
    if (!success) notifications?.showErrorSnackBar(l10n.statsExportFailed);
  }

  Future<void> _confirmClear() async {
    final l10n = AppLocalizations.of(context)!;
    // 弹层 dialog 挂 root navigator（M3EDialog.show 语义）；本页位于设置弹层的
    // 嵌套 Navigator 内，页面 context 上的 pop 会误退本页，关闭要显式定向。
    final navigator = Navigator.of(context, rootNavigator: true);
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.statsClear,
        content: Text(l10n.statsClearConfirm),
        actions: [
          M3EButton.text(
            onPressed: () => navigator.pop(false),
            child: Text(l10n.cancel),
          ),
          M3EButton.filled(
            onPressed: () => navigator.pop(true),
            child: Text(l10n.statsClear),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final notifications = context.read<NotificationService?>();
    await _provider.clearAll();
    if (!mounted) return;
    setState(() => _selectedDay = null);
    notifications?.showSuccessSnackBar(l10n.statsCleared);
  }
}

/// 汇总数字卡：常规 M3E 卡片 + 语义图标点缀。
class _StatBlock extends StatelessWidget {
  const _StatBlock({
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
                    style: type.titleLarge.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w700,
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
class _RateCard extends StatelessWidget {
  const _RateCard({required this.title, required this.value});

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
          _ShareBar(
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
class _ShareBar extends StatelessWidget {
  const _ShareBar({
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
    return ClipRRect(
      borderRadius: BorderRadius.circular(_height / 2),
      child: Container(
        height: _height,
        color: background,
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: share,
            heightFactor: 1,
            child: ColoredBox(color: color),
          ),
        ),
      ),
    );
  }
}

/// 某一天的播放明细弹层（日期 + 当天汇总 + 曲目列表，可点播）。
class _DayDetailSheet extends StatelessWidget {
  const _DayDetailSheet({
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
                _formatListened(l10n, detail.listenedMs),
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
                  alwaysUse24HourFormat:
                      MediaQuery.alwaysUse24HourFormatOf(context),
                );
                return TrackRow(
                  model: TrackRowModel(
                    title: event.title,
                    artist: event.artist,
                    coverUrl: event.coverUrl,
                    durationMs: event.durationMs,
                    trackId: TrackId(event.sourceKey, event.songId),
                    trailingText:
                        '$time · ${_formatListened(l10n, event.listenedMs)}',
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

/// 收听时长文案（秒 / 分钟 / 小时·分）。
String _formatListened(AppLocalizations l10n, int listenedMs) {
  final totalSeconds = listenedMs ~/ 1000;
  if (totalSeconds < 60) return l10n.statsDurationSeconds(totalSeconds);
  final minutes = totalSeconds ~/ 60;
  if (minutes < 60) return l10n.statsDurationMinutes(minutes);
  return l10n.statsDurationHours(minutes ~/ 60, minutes % 60);
}
