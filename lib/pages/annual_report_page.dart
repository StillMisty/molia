/// 年度听歌报告：单页滚动、只读、无二级导航。
///
/// 数据全部来自既有听歌统计表（`AnnualReportProvider` → 仓库年度窗口），
/// 不新增表 / 列，也不改统计口径。唯一主操作是「分享海报」；保存图片收在
/// 旁边的溢出菜单里；底部可选把年度 Top 50 存成歌单，写入仍走既有资料库
/// 导入引擎。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

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
import '../services/save_as.dart';
import '../theme/m3e_context.dart';
import '../utils/listened_duration.dart';
import '../utils/poster_render_style.dart';
import '../utils/responsive.dart';
import '../utils/save_as_label.dart';
import '../widgets/empty_state.dart';
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
  bool _sharing = false;
  bool _savingImage = false;
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
          actions: [_yearPicker(l10n, provider)],
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
    return M3EMenu.entries(
      position: M3EMenuAnchorPosition.bottomEnd,
      anchorBuilder: (context, open) => M3EIconButton(
        variant: M3EIconButtonVariant.standard,
        icon: const Icon(Icons.calendar_month_rounded),
        semanticLabel: l10n.annualReportPickYear,
        onPressed: open,
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
    final wide = context.isLargeScreen;
    final sections = <Widget>[
      _hero(context, l10n, report),
      const SizedBox(height: 20),
      _numbers(context, l10n, report, wide: wide),
      if (report.pageTopArtists.isNotEmpty) ...[
        const SizedBox(height: 24),
        _topArtists(context, l10n, report),
      ],
      if (report.pageTopTracks.isNotEmpty) ...[
        const SizedBox(height: 24),
        _topTracks(context, l10n, report),
      ],
      if (report.pageTopAlbums.isNotEmpty) ...[
        const SizedBox(height: 24),
        _topAlbums(context, l10n, report),
      ],
      if (report.platforms.isNotEmpty) ...[
        const SizedBox(height: 24),
        _platforms(context, l10n, report),
      ],
      const SizedBox(height: 24),
      _monthly(context, l10n, report),
      if (report.firstPlay != null || report.lastPlay != null) ...[
        const SizedBox(height: 24),
        _edges(context, l10n, report),
      ],
      const SizedBox(height: 24),
      _coverage(context, l10n, report),
      const SizedBox(height: 24),
      _playlistAction(context, l10n, report),
      const SizedBox(height: 24),
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: sections,
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
                  style: context.typeScale.displaySmall.copyWith(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (report.asOfToday)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    l10n.annualReportAsOfToday,
                    style: context.typeScale.labelMedium.copyWith(
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            formatListenedDuration(l10n, report.totalListenedMs),
            style: context.typeScale.headlineMedium.copyWith(
              color: scheme.onPrimaryContainer,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            l10n.annualReportListenedCaption,
            style: context.typeScale.bodyMedium.copyWith(
              color: scheme.onPrimaryContainer.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              M3EButton.filled(
                onPressed: _sharing
                    ? null
                    : () => unawaited(_share(context, report)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.ios_share_rounded, size: 18),
                    const SizedBox(width: 8),
                    Text(l10n.annualReportSharePoster),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // 次要输出（保存图片）收进溢出菜单：主操作仍只有「分享海报」。
              M3EMenu.entries(
                position: M3EMenuAnchorPosition.bottomEnd,
                anchorBuilder: (context, open) => M3EIconButton(
                  variant: M3EIconButtonVariant.standard,
                  icon: const Icon(Icons.more_vert_rounded),
                  semanticLabel: l10n.annualReportMoreActions,
                  onPressed: _savingImage ? null : open,
                ),
                onSelected: (value) {
                  if (value == 'save') unawaited(_saveImage(context, report));
                },
                entries: [
                  M3EMenuEntry(
                    label: l10n.annualReportSaveImage,
                    value: 'save',
                    leading: const Icon(Icons.download_rounded),
                  ),
                ],
              ),
            ],
          ),
          if (_sharing || _savingImage) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              label: l10n.annualReportPosterGenerating,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.annualReportPosterGenerating,
                    style: context.typeScale.bodySmall.copyWith(
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const M3EProgressIndicator.linear(),
                ],
              ),
            ),
          ],
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
        value: '${report.qualifiedPlayCount}',
      ),
      _NumberTile(
        icon: Icons.library_music_rounded,
        label: l10n.annualReportStatTracks,
        value: '${report.uniqueTrackCount}',
      ),
      _NumberTile(
        icon: Icons.person_rounded,
        label: l10n.annualReportStatArtists,
        value: '${report.uniqueArtistCount}',
      ),
      _NumberTile(
        icon: Icons.local_fire_department_rounded,
        label: l10n.annualReportStreakCaption,
        value: '${report.streak.days}',
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
    final scheme = Theme.of(context).colorScheme;
    return _section(
      context,
      title: l10n.annualReportTopArtists,
      child: Column(
        children: [
          for (var index = 0; index < report.pageTopArtists.length; index++)
            Padding(
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
                      report.pageTopArtists[index].artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.typeScale.bodyLarge,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    l10n.statsPlaysCount(
                      report.pageTopArtists[index].playCount,
                    ),
                    style: context.typeScale.labelSmall.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
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
    final scheme = Theme.of(context).colorScheme;
    return _section(
      context,
      title: l10n.annualReportTopAlbums,
      child: Column(
        children: [
          for (var index = 0; index < report.pageTopAlbums.length; index++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      report.pageTopAlbums[index].album,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.typeScale.bodyLarge,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    l10n.statsPlaysCount(report.pageTopAlbums[index].playCount),
                    style: context.typeScale.labelSmall.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
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
                    borderRadius: BorderRadius.circular(4),
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
                Text(
                  formatListenedDuration(
                    l10n,
                    report.platforms[index].listenedMs,
                  ),
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
    return _section(
      context,
      title: l10n.annualReportMonthly,
      child: SizedBox(
        height: 120,
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
                            color: scheme.primary,
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(4),
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
    );
  }

  Widget _edges(
    BuildContext context,
    AppLocalizations l10n,
    AnnualReport report,
  ) {
    final moments = <Widget>[
      if (report.firstPlay != null)
        _MomentTile(
          label: l10n.annualReportFirstPlay,
          moment: report.firstPlay!,
        ),
      if (report.lastPlay != null)
        _MomentTile(label: l10n.annualReportLastPlay, moment: report.lastPlay!),
    ];
    if (moments.length == 2 && context.isLargeScreen) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: moments[0]),
          const SizedBox(width: 12),
          Expanded(child: moments[1]),
        ],
      );
    }
    return Column(
      children: [
        for (final moment in moments) ...[
          if (moment != moments.first) const SizedBox(height: 12),
          moment,
        ],
      ],
    );
  }

  Widget _coverage(
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
    if (lines.isEmpty) return const SizedBox.shrink();
    return Text(
      lines.join('\n'),
      style: context.typeScale.bodySmall.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    );
  }

  Widget _playlistAction(
    BuildContext context,
    AppLocalizations l10n,
    AnnualReport report,
  ) {
    return Align(
      alignment: Alignment.centerLeft,
      child: M3EButton.icon(
        style: M3EButtonStyle.outlined,
        onPressed: _savingPlaylist
            ? null
            : () => unawaited(_savePlaylist(context, report)),
        icon: const Icon(Icons.playlist_add_rounded, size: 18),
        label: Text(l10n.annualReportSavePlaylist),
      ),
    );
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

  Future<void> _share(BuildContext context, AnnualReport report) async {
    if (_sharing) return;
    setState(() => _sharing = true);
    final l10n = AppLocalizations.of(context)!;
    final notifications = context.read<NotificationService?>();
    try {
      final bytes = await _renderPosterBytes(l10n, report);
      if (!mounted || bytes == null) return;
      final directory = await getTemporaryDirectory();
      if (!mounted) return;
      final file = File('${directory.path}/annual_report_${report.year}.png');
      await file.writeAsBytes(Uint8List.fromList(bytes), flush: true);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: l10n.annualReportTitle),
      );
    } catch (_) {
      if (mounted) {
        notifications?.showErrorSnackBar(l10n.annualReportShareFailed);
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  /// 保存海报到另存目录（与分享共用同一份渲染数据）。
  Future<void> _saveImage(BuildContext context, AnnualReport report) async {
    if (_savingImage) return;
    final l10n = AppLocalizations.of(context)!;
    final notifications = context.read<NotificationService?>();
    final saveAs = context.read<SaveAs?>();
    setState(() => _savingImage = true);
    try {
      if (saveAs == null) throw StateError('SaveAs 未装配');
      final bytes = await _renderPosterBytes(l10n, report);
      if (!mounted || bytes == null) return;
      final result = await saveAs.saveBytes(
        fileName: 'molia_annual_${report.year}.png',
        bytes: bytes,
        mimeType: 'image/png',
        relativeDir: saveAsPostersDirName,
        dialogTitle: l10n.annualReportSaveImage,
      );
      if (!mounted) return;
      switch (result) {
        case SaveAsSaved(:final displayPath, :final kind):
          notifications?.showSuccessSnackBar(
            savedLocationMessage(l10n, kind, displayPath),
          );
        case SaveAsCancelled():
          return;
        case SaveAsFailed():
          notifications?.showErrorSnackBar(l10n.annualReportSaveFailed);
      }
    } catch (_) {
      if (mounted) {
        notifications?.showErrorSnackBar(l10n.annualReportSaveFailed);
      }
    } finally {
      if (mounted) setState(() => _savingImage = false);
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
      months: report.monthlyListenedMs,
      topArtists: [
        for (final artist in report.topArtists.take(3)) artist.artist,
      ],
      topTracks: [for (final track in report.topTracks.take(3)) track.title],
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
  final String value;

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
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.typeScale.titleLarge.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w700,
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
