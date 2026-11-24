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
/// 各内容块按职责拆在同目录文件里；公开入口仍是
/// `lib/pages/play_statistics_page.dart`。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../domain/models/play_statistics.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_providers.dart';
import '../../providers/play_statistics_provider.dart';
import '../../services/listening_stats_poster_service.dart';
import '../../services/notification_service.dart';
import '../../services/play_statistics_service.dart';
import '../../services/poster/poster_render_style.dart';
import '../../services/statistics/listening_statistics.dart';
import '../../theme/m3e_context.dart';
import '../../widgets/poster_share_sheet.dart';
import '../../widgets/responsive.dart';
import '../../widgets/settings/settings_subpage.dart';
import '../../widgets/settings/settings_tiles.dart';
import '../../widgets/statistics/annual_report_entry_card.dart';
import '../annual_report_page.dart';
import 'statistics_heatmap.dart';
import 'statistics_models.dart';
import 'statistics_rankings.dart';
import 'statistics_summary.dart';

/// 海报文件名：时间戳来自统计窗口（[now] 已接受窗口的 `now`）。
///
/// 窗口尚未就绪时不盖时间戳，避免退回墙钟；此时海报渲染也返回 null，
/// 文件名不会被写到磁盘。
String playStatisticsPosterFileName(DateTime? now, PlayStatisticsRange range) {
  final stamp = now?.toIso8601String().replaceAll(':', '-');
  final parts = <String>['molia_listening_stats', range.name, ?stamp];
  return '${parts.join('_')}.png';
}

class PlayStatisticsPage extends ConsumerStatefulWidget {
  const PlayStatisticsPage({super.key, this.sharePoster});

  /// 分享通道；null 时用 [SharePlus.instance]。仅测试注入。
  final PosterFileShare? sharePoster;

  @override
  ConsumerState<PlayStatisticsPage> createState() => _PlayStatisticsPageState();
}

class _PlayStatisticsPageState extends ConsumerState<PlayStatisticsPage> {
  late final PlayStatisticsProvider _provider;

  /// 日历热力图选中的一天（弹层打开期间保持放大 + 描边）。
  DateTime? _selectedDay;

  /// 分享弹层打开期间禁用入口，避免叠出第二层。
  bool _shareSheetOpen = false;

  @override
  void initState() {
    super.initState();
    _provider = ref.read(playStatisticsPageProvider.notifier);
    // provider 可能在本帧才被懒创建：加载会立即 notify，必须等首帧结束再写，
    // 否则会在 Provider 挂载期间触发重建断言（与年度报告页同一约定）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
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
    final l10n = AppLocalizations.of(context)!;
    return SettingsSubPage.body(
      title: l10n.statsTitle,
      safeArea: true,
      actions: [
        M3EIconButton(
          variant: M3EIconButtonVariant.standard,
          icon: const Icon(Icons.ios_share_rounded),
          semanticLabel: l10n.shareAction,
          onPressed: _shareSheetOpen ? null : _openShareSheet,
        ),
        M3EMenu.entries(
          position: M3EMenuAnchorPosition.bottomEnd,
          anchorBuilder: (context, open) => M3EIconButton(
            variant: M3EIconButtonVariant.standard,
            icon: const Icon(Icons.more_vert_rounded),
            semanticLabel: l10n.moreActions,
            onPressed: open,
          ),
          onSelected: (value) {
            switch (value) {
              case 'export':
                unawaited(exportPlayStatistics(ref, context, _provider));
              case 'clear':
                unawaited(_confirmClear());
            }
          },
          entries: [
            M3EMenuEntry(
              label: l10n.shareExportData,
              value: 'export',
              leading: const Icon(Icons.file_upload_rounded),
            ),
            M3EMenuEntry(
              label: l10n.statsClear,
              value: 'clear',
              leading: const Icon(Icons.delete_outline_rounded),
              isDestructive: true,
            ),
          ],
        ),
      ],
      body: Consumer(
        builder: (context, ref, _) {
          ref.watch(playStatisticsPageProvider);
          // 首帧 provider 还没开始加载（加载在 post-frame 里启动）：先显示
          // 加载态。否则会用空快照先建一遍日历（80 周 × 7 = 560 个格子），
          // 数据回来后再整页重建一次——开页实测白付一帧 20ms+ 和同帧 GC。
          if (!_provider.hasLoaded) {
            return _provider.hasError
                ? _errorState(l10n, _provider)
                : const Center(child: M3ELoadingIndicator());
          }
          return _content(l10n, _provider);
        },
      ),
    );
  }

  Widget _content(AppLocalizations l10n, PlayStatisticsProvider provider) {
    final view = provider.view!;
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
    final PlayStatisticsService? statistics = ref.watch(
      playStatisticsServiceProvider,
    );
    final topTracks = view.snapshot.topTracks;
    final topArtists = view.snapshot.topArtists;
    final sections = <Widget>[
      // 采集开关跟随统计页：关闭 = 停止记录新事件，已有数据保留。
      if (statistics != null) ...[
        SettingsSectionCard(
          children: [
            ValueListenableBuilder<bool>(
              valueListenable: statistics.enabledNotifier,
              builder: (context, enabled, _) => SettingsSwitchTile(
                switchKey: const Key('settingsPlayStatisticsSwitch'),
                icon: Icons.query_stats_rounded,
                title: l10n.statsRecordSwitch,
                subtitle: l10n.statsRecordSwitchSubtitle,
                value: enabled,
                onChanged: (value) => unawaited(statistics.setEnabled(value)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
      ],
      ..._annualEntry(view),
      rangeRow,
      const SizedBox(height: 16),
      if (provider.isEmpty)
        _emptyState(l10n)
      else ...[
        // 围绕热力图设计：范围切换 → hero 热力图 → 汇总条 → 作息 → 指标 → 榜单。
        StatisticsCalendarHeatmapCard(
          l10n: l10n,
          view: view,
          valueMode: provider.valueMode,
          selectedDay: _selectedDay,
          onValueModeChanged: provider.setValueMode,
          onDayTap: (day) => unawaited(_showDayDetail(day)),
        ),
        const SizedBox(height: 16),
        StatisticsSummaryBlocks(
          l10n: l10n,
          snapshot: view.snapshot,
          now: view.window.now,
          wide: isWide,
        ),
        const SizedBox(height: 16),
        StatisticsWeekdayHourCard(
          l10n: l10n,
          view: view,
          valueMode: provider.valueMode,
        ),
        const SizedBox(height: 16),
        StatisticsMetricsSection(
          l10n: l10n,
          snapshot: view.snapshot,
          sourceName: (sourceKey) => statisticsSourceName(ref, sourceKey),
          wide: isWide,
        ),
        const SizedBox(height: 24),
        // ≥900dp：Top 曲目与 Top 歌手并排两栏。
        if (isDesktop)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: StatisticsTopTracksSection(
                  l10n: l10n,
                  tracks: topTracks,
                  onTap: (index) => unawaited(_playTopTracks(topTracks, index)),
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: StatisticsTopArtistsSection(
                  l10n: l10n,
                  artists: topArtists,
                ),
              ),
            ],
          )
        else ...[
          StatisticsTopTracksSection(
            l10n: l10n,
            tracks: topTracks,
            onTap: (index) => unawaited(_playTopTracks(topTracks, index)),
          ),
          const SizedBox(height: 24),
          StatisticsTopArtistsSection(l10n: l10n, artists: topArtists),
        ],
      ],
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: sections,
    );
  }

  /// 年度报告入口：数据来自本页已有的全量日历 rollup，不额外查询。
  ///
  /// 入口本身由统计视图投影（同一份日历 + 同一窗口 now）；页面不再拆分字段。
  List<Widget> _annualEntry(ListeningStatisticsView view) {
    final entry = view.annualEntry;
    if (!entry.isVisible) return const [];
    return [
      AnnualReportEntryCard(
        entry: entry,
        onTap: () => unawaited(
          openSettingsSubPage(
            context,
            AnnualReportPage(
              years: entry.years,
              featuredYear: entry.featuredYear,
            ),
          ),
        ),
      ),
      const SizedBox(height: 16),
    ];
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

  Future<void> _playTopTracks(
    List<PlayStatTrackEntry> entries,
    int index,
  ) async {
    if (entries.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    final library = ref.read(libraryProvider);
    final playback = ref.read(playbackControllerProvider);
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
    final library = ref.read(libraryProvider);
    final playback = ref.read(playbackControllerProvider);
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
        builder: (_) => StatisticsDayDetailSheet(
          day: day,
          detail: detail,
          onPlay: (index) => unawaited(_playDayEvents(events, index)),
        ),
      );
    } finally {
      if (mounted) setState(() => _selectedDay = null);
    }
  }

  /// 统一分享弹层：预览 + 分享；导出数据在页面 ⋮ 里。
  Future<void> _openShareSheet() async {
    if (_shareSheetOpen) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _shareSheetOpen = true);
    try {
      await showPosterShareSheet(
        context,
        title: l10n.statsShareTitle,
        renderPoster: () => _renderPoster(_provider),
        shareText: l10n.statsPosterTitle,
        // 文件名时间戳取已接受统计窗口的 now（不读墙钟）；还没有窗口时
        // 不盖时间戳——渲染本就返回 null，文件名不会落盘。
        fileName: playStatisticsPosterFileName(
          _provider.window?.now,
          _provider.range,
        ),
        saveDialogTitle: l10n.shareSaveImage,
        emptyMessage: l10n.statsPosterEmpty,
        shareFile: widget.sharePoster,
      );
    } finally {
      if (mounted) setState(() => _shareSheetOpen = false);
    }
  }

  Future<Uint8List?> _renderPoster(PlayStatisticsProvider provider) async {
    final view = provider.view;
    if (view == null || provider.isEmpty) return null;
    final l10n = AppLocalizations.of(context)!;
    final data = buildListeningStatsPosterData(
      l10n: l10n,
      view: view,
      narrowWeekdays: MaterialLocalizations.of(context).narrowWeekdays,
      sourceName: (sourceKey) => statisticsSourceName(ref, sourceKey),
    );
    final style = await resolvePosterRenderStyle(context);
    if (!mounted) return null;
    return const ListeningStatsPosterService().render(
      data: data,
      palette: style.palette,
      fontFamily: style.fontFamily,
      fontFamilyFallback: style.fontFamilyFallback,
      watermarkText: l10n.appName,
    );
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
          settingsDestructiveAction(
            context,
            onPressed: () => navigator.pop(true),
            label: l10n.statsClear,
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final NotificationService? notifications = ref.read(
      notificationServiceProvider,
    );
    await _provider.clearAll();
    if (!mounted) return;
    setState(() => _selectedDay = null);
    notifications?.showSuccessSnackBar(l10n.statsCleared);
  }
}
