/// 年度听歌报告：单页滚动、只读、无二级导航。
///
/// 数据全部来自既有听歌统计表（`AnnualReportProvider` → 仓库年度窗口），
/// 不新增表 / 列，也不改统计口径。唯一主操作是顶栏「分享」；保存图片在统一
/// 分享弹层里；底部可选把年度 Top 50 存成歌单，写入仍走既有资料库导入引擎。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/annual_report.dart';
import '../domain/models/source.dart' show SourceDescriptor;
import '../domain/models/track.dart';
import '../domain/ports/source_registry.dart';
import '../l10n/app_localizations.dart';
import '../providers/annual_report_provider.dart';
import '../providers/library_provider.dart';
import '../providers/playback_provider.dart';
import '../services/annual_poster_service.dart';
import '../services/notification_service.dart';
import '../theme/m3e_context.dart';
import '../theme/motion_policy.dart';
import '../utils/listened_duration.dart';
import '../utils/poster_render_style.dart';
import '../widgets/empty_state.dart';
import '../widgets/poster_share_sheet.dart';
import '../widgets/settings/settings_subpage.dart';
import '../widgets/track_row.dart';

class AnnualReportPage extends StatefulWidget {
  const AnnualReportPage({
    super.key,
    required this.years,
    required this.featuredYear,
  });

  final List<int> years;
  final int featuredYear;

  @override
  State<AnnualReportPage> createState() => _AnnualReportPageState();
}

class _AnnualReportPageState extends State<AnnualReportPage> {
  late final AnnualReportProvider _provider;
  bool _shareSheetOpen = false;
  bool _savingPlaylist = false;

  @override
  void initState() {
    super.initState();
    _provider = context.read<AnnualReportProvider>();
    final registry = context.read<SourceRegistry?>();
    final sourceNames = <String, String>{
      for (final descriptor
          in registry?.descriptors ?? const <SourceDescriptor>[])
        descriptor.key: descriptor.displayName,
    };
    // provider 可能在本帧才被懒创建：配置即通知，必须等首帧结束再写，
    // 否则会在 ChangeNotifierProvider 挂载期间触发重建断言。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _provider.configure(
        years: widget.years,
        featuredYear: widget.featuredYear,
        sourceNames: sourceNames,
      );
      _provider.startWatching();
      unawaited(_provider.ensureLoaded());
    });
  }

  @override
  void dispose() {
    _provider.stopWatching();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AnnualReportProvider>(
      builder: (context, provider, _) {
        final l10n = AppLocalizations.of(context)!;
        return SettingsSubPage.body(
          title: l10n.annualReportTitle,
          safeArea: true,
          actions: [
            _yearPicker(l10n, provider),
            if (provider.report?.hasData ?? false)
              M3EIconButton(
                variant: M3EIconButtonVariant.standard,
                icon: const Icon(Icons.ios_share_rounded),
                semanticLabel: l10n.shareAction,
                onPressed: _shareSheetOpen
                    ? null
                    : () => unawaited(_openShareSheet(provider)),
              ),
          ],
          body: _body(context, l10n, provider),
        );
      },
    );
  }

  Widget _yearPicker(AppLocalizations l10n, AnnualReportProvider provider) {
    if (provider.years.length < 2) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(
          '${provider.selectedYear}',
          style: context.typeScale.titleSmall,
        ),
      );
    }
    // 年份切换是报告页的第二主操作：显示当前年份 + 下拉箭头，比只放
    // 日历图标更容易发现；打开后仍是同一份年份菜单。
    return M3EMenu.entries(
      position: M3EMenuAnchorPosition.bottomEnd,
      anchorBuilder: (context, open) => M3EButton.text(
        key: const Key('annualYearPicker'),
        semanticLabel: l10n.annualReportPickYear,
        onPressed: open,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${provider.selectedYear}',
              style: context.typeScale.titleSmall,
            ),
            const SizedBox(width: 2),
            const Icon(Icons.arrow_drop_down_rounded, size: 20),
          ],
        ),
      ),
      onSelected: (value) {
        if (value is int) unawaited(provider.selectYear(value));
      },
      entries: [
        for (final year in provider.years)
          M3EMenuEntry(
            label: '$year',
            value: year,
            leading: year == provider.selectedYear
                ? const Icon(Icons.check_rounded)
                : null,
          ),
      ],
    );
  }

  Widget _body(
    BuildContext context,
    AppLocalizations l10n,
    AnnualReportProvider provider,
  ) {
    if (provider.isLoading && !provider.hasLoaded) {
      return const Center(child: M3ELoadingIndicator());
    }
    if (provider.hasError && !provider.hasLoaded) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, size: 40),
            const SizedBox(height: 12),
            Text(l10n.annualReportLoadFailed),
            const SizedBox(height: 12),
            M3EButton.filled(
              onPressed: () => unawaited(provider.refresh()),
              child: Text(l10n.retry),
            ),
          ],
        ),
      );
    }
    final report = provider.report;
    if (report == null) {
      return const Center(child: M3ELoadingIndicator());
    }
    if (!report.hasData) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: EmptyState(
            icon: Icons.insights_rounded,
            message: l10n.annualReportEmpty,
            hint: l10n.annualReportEmptyHint,
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // 报告页活在设置弹层里，内容区比窗口窄：两栏必须按实际内容宽判断，
        // 否则 880 弹层里的 600 宽窗口会误判成宽屏。
        const horizontalPadding = 16.0;
        final wide = constraints.maxWidth - horizontalPadding * 2 >= 760;
        final coverage = _coverage(context, l10n, report);
        final sections = <Widget>[
          _hero(context, l10n, report),
          const SizedBox(height: 20),
          _numbers(context, l10n, report, wide: wide),
          const SizedBox(height: 24),
          _monthly(context, l10n, report),
          if (report.pageTopTracks.isNotEmpty) ...[
            const SizedBox(height: 24),
            _topTracks(context, l10n, report),
          ],
          if (report.pageTopArtists.isNotEmpty ||
              report.pageTopAlbums.isNotEmpty) ...[
            const SizedBox(height: 24),
            _twoUp(
              wide: wide,
              first: report.pageTopArtists.isEmpty
                  ? null
                  : _topArtists(context, l10n, report),
              second: report.pageTopAlbums.isEmpty
                  ? null
                  : _topAlbums(context, l10n, report),
            ),
          ],
          if (report.platforms.isNotEmpty) ...[
            const SizedBox(height: 24),
            _platforms(context, l10n, report),
          ],
          if (report.firstPlay != null || report.lastPlay != null) ...[
            const SizedBox(height: 24),
            _edges(context, l10n, report, wide: wide),
          ],
          if (coverage != null) ...[const SizedBox(height: 24), coverage],
          const SizedBox(height: 24),
          _playlistAction(context, l10n, report, wide: wide),
          const SizedBox(height: 24),
        ];
        return ListView(
          padding: const EdgeInsets.fromLTRB(
            horizontalPadding,
            8,
            horizontalPadding,
            32,
          ),
          children: sections,
        );
      },
    );
  }

  /// 宽屏两栏、窄屏顺排。两栏只用于成组的榜单 / 时刻，避免在宽屏里
  /// 每块都拉满一行造成的松散感。
  Widget _twoUp({
    required bool wide,
    required Widget? first,
    required Widget? second,
  }) {
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

  Widget _hero(
    BuildContext context,
    AppLocalizations l10n,
    AnnualReport report,
  ) {
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

  Widget _numbers(
    BuildContext context,
    AppLocalizations l10n,
    AnnualReport report, {
    required bool wide,
  }) {
    final tiles = [
      _NumberTile(
        icon: Icons.headphones_rounded,
        label: l10n.statsPlays,
        value: report.qualifiedPlayCount,
      ),
      _NumberTile(
        icon: Icons.library_music_rounded,
        label: l10n.annualReportStatTracks,
        value: report.uniqueTrackCount,
      ),
      _NumberTile(
        icon: Icons.person_rounded,
        label: l10n.annualReportStatArtists,
        value: report.uniqueArtistCount,
      ),
      _NumberTile(
        icon: Icons.local_fire_department_rounded,
        label: l10n.annualReportStreakCaption,
        value: report.streak.days,
      ),
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

  Widget _topTracks(
    BuildContext context,
    AppLocalizations l10n,
    AnnualReport report,
  ) {
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
            onTap: () => unawaited(_playTopTracks(report, index)),
          ),
        ],
      ],
    );
  }

  Widget _topArtists(
    BuildContext context,
    AppLocalizations l10n,
    AnnualReport report,
  ) {
    return _section(
      context,
      title: l10n.annualReportTopArtists,
      child: Column(
        children: [
          for (var index = 0; index < report.pageTopArtists.length; index++)
            _rankRow(
              context,
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

  Widget _topAlbums(
    BuildContext context,
    AppLocalizations l10n,
    AnnualReport report,
  ) {
    return _section(
      context,
      title: l10n.annualReportTopAlbums,
      child: Column(
        children: [
          for (var index = 0; index < report.pageTopAlbums.length; index++)
            _rankRow(
              context,
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

  /// 歌手 / 专辑榜单共用一行的排名槽与省略规则，避免同一页出现两套对齐。
  Widget _rankRow(
    BuildContext context, {
    required int index,
    required String label,
    required String trailing,
  }) {
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

  Widget _platforms(
    BuildContext context,
    AppLocalizations l10n,
    AnnualReport report,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return _section(
      context,
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
                    _sourceName(
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

  Widget _monthly(
    BuildContext context,
    AppLocalizations l10n,
    AnnualReport report,
  ) {
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
    return _section(
      context,
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

  Widget _edges(
    BuildContext context,
    AppLocalizations l10n,
    AnnualReport report, {
    required bool wide,
  }) {
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
    return _twoUp(wide: wide, first: first, second: last);
  }

  Widget? _coverage(
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

  Widget _playlistAction(
    BuildContext context,
    AppLocalizations l10n,
    AnnualReport report, {
    required bool wide,
  }) {
    final button = M3EButton.icon(
      style: M3EButtonStyle.outlined,
      onPressed: _savingPlaylist
          ? null
          : () => unawaited(_savePlaylist(context, report)),
      icon: const Icon(Icons.playlist_add_rounded, size: 18),
      label: Text(l10n.annualReportSavePlaylist),
    );
    // 窄屏整行宽度让次要操作也好点；宽屏保持行内按钮，避免 832 宽的一条
    // 空心按钮压过顶栏分享的主操作。
    if (wide) {
      return Align(alignment: Alignment.centerLeft, child: button);
    }
    return SizedBox(width: double.infinity, child: button);
  }

  Widget _section(
    BuildContext context, {
    required String title,
    required Widget child,
  }) {
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

  String _sourceName(
    BuildContext context,
    AppLocalizations l10n,
    String sourceKey,
  ) {
    if (sourceKey == 'other') return l10n.statsSourceOther;
    final registry = context.read<SourceRegistry?>();
    for (final descriptor in registry?.descriptors ?? const []) {
      if (descriptor.key == sourceKey) return descriptor.displayName;
    }
    return sourceKey;
  }

  Future<void> _playTopTracks(AnnualReport report, int index) async {
    if (report.topTracks.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    final library = context.read<LibraryProvider>();
    final playback = context.read<PlaybackProvider>();
    final tracks = [
      for (final entry in report.topTracks)
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
      contextName: l10n.annualReportTopTracks,
    );
  }

  Future<void> _savePlaylist(BuildContext context, AnnualReport report) async {
    if (report.topTracks.isEmpty || _savingPlaylist) return;
    setState(() => _savingPlaylist = true);
    final l10n = AppLocalizations.of(context)!;
    final notifications = context.read<NotificationService?>();
    final name = l10n.annualReportPlaylistName(report.year);
    try {
      final library = context.read<LibraryProvider>();
      final result = await library.importTracksAsPlaylist(
        name: name,
        tracks: buildAnnualPlaylistTracks(
          report,
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      if (!mounted) return;
      notifications?.showSuccessSnackBar(
        l10n.annualReportPlaylistAddedTracks(name, result.added),
      );
    } catch (_) {
      if (mounted) {
        notifications?.showErrorSnackBar(l10n.annualReportPlaylistFailed);
      }
    } finally {
      if (mounted) setState(() => _savingPlaylist = false);
    }
  }

  /// 统一分享弹层：预览 + 分享；保存图片是弹层内的次要输出。
  Future<void> _openShareSheet(AnnualReportProvider provider) async {
    final report = provider.report;
    if (report == null || !report.hasData || _shareSheetOpen) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _shareSheetOpen = true);
    try {
      await showPosterShareSheet(
        context,
        title: l10n.annualReportSharePoster,
        renderPoster: () => _renderPosterBytes(l10n, report),
        shareText: l10n.annualReportTitle,
        fileName: 'molia_annual_${report.year}.png',
        saveDialogTitle: l10n.shareSaveImage,
        emptyMessage: l10n.annualReportEmpty,
      );
    } finally {
      if (mounted) setState(() => _shareSheetOpen = false);
    }
  }

  Future<Uint8List?> _renderPosterBytes(
    AppLocalizations l10n,
    AnnualReport report,
  ) async {
    final posterData = _posterData(l10n, report);
    final style = await resolvePosterRenderStyle(context);
    if (!mounted) return null;
    return AnnualPosterService().render(
      data: posterData,
      palette: style.palette,
      fontFamily: style.fontFamily,
      fontFamilyFallback: style.fontFamilyFallback,
      watermarkText: l10n.appName,
    );
  }

  AnnualPosterData _posterData(AppLocalizations l10n, AnnualReport report) {
    final topPlatform = report.platforms.isEmpty
        ? null
        : _sourceName(context, l10n, report.platforms.first.sourceKey);
    return AnnualPosterData(
      yearLabel: '${report.year}',
      subtitle: l10n.annualReportSubtitle,
      listenedLabel: formatListenedDuration(l10n, report.totalListenedMs),
      listenedCaption: l10n.annualReportListenedCaption,
      playsLabel: '${report.qualifiedPlayCount}',
      playsCaption: l10n.statsPlays,
      artistsLabel: '${report.uniqueArtistCount}',
      artistsCaption: l10n.annualReportStatArtists,
      streakLabel: '${report.streak.days}',
      streakCaption: l10n.annualReportStreakCaption,
      monthlyTitle: l10n.annualReportMonthly,
      topTracksTitle: l10n.annualReportTopTracks,
      topArtistsTitle: l10n.annualReportTopArtists,
      months: report.monthlyListenedMs,
      topArtists: [
        for (final artist in report.topArtists.take(3)) artist.artist,
      ],
      topTracks: [
        for (final track in report.topTracks.take(3))
          AnnualPosterTrack(title: track.title, artist: track.artist),
      ],
      topPlatform: topPlatform == null
          ? null
          : l10n.annualReportTopPlatform(topPlatform),
    );
  }
}

class _NumberTile extends StatelessWidget {
  const _NumberTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final int value;

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
                    tween: Tween<double>(begin: 0, end: value.toDouble()),
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
                    label,
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
            Icon(icon, size: 22, color: scheme.primary),
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
