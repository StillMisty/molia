/// 年度听歌报告：单页滚动、只读、无二级导航。
///
/// 数据全部来自既有听歌统计表（`AnnualReportProvider` → 仓库年度窗口），
/// 不新增表 / 列，也不改统计口径。唯一主操作是顶栏「分享」；保存图片在统一
/// 分享弹层里；底部可选把年度 Top 50 存成歌单，写入仍走既有资料库导入引擎。
/// 内容块 / 海报 / 页面内 DTO 按职责拆在同目录文件里；公开入口仍是
/// `lib/pages/annual_report_page.dart`。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../domain/models/annual_report.dart';
import '../../domain/models/source.dart' show SourceDescriptor;
import '../../domain/ports/source_registry.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/annual_report_provider.dart';
import '../../providers/app_providers.dart';
import '../../services/notification_service.dart';
import '../../theme/m3e_context.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/settings/settings_subpage.dart';
import 'annual_report_poster.dart';
import 'annual_report_sections.dart';

class AnnualReportPage extends ConsumerStatefulWidget {
  const AnnualReportPage({
    super.key,
    required this.years,
    required this.featuredYear,
  });

  final List<int> years;
  final int featuredYear;

  @override
  ConsumerState<AnnualReportPage> createState() => _AnnualReportPageState();
}

class _AnnualReportPageState extends ConsumerState<AnnualReportPage> {
  late final AnnualReportProvider _provider;
  bool _shareSheetOpen = false;
  bool _savingPlaylist = false;

  @override
  void initState() {
    super.initState();
    _provider = ref.read(annualReportPageProvider.notifier);
    final SourceRegistry? registry = ref.read(sourceRegistryProvider);
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
    return Consumer(
      builder: (context, ref, _) {
        ref.watch(annualReportPageProvider);
        final l10n = AppLocalizations.of(context)!;
        return SettingsSubPage.body(
          title: l10n.annualReportTitle,
          safeArea: true,
          actions: [
            _yearPicker(l10n, _provider),
            if (_provider.report?.hasData ?? false)
              M3EIconButton(
                variant: M3EIconButtonVariant.standard,
                icon: const Icon(Icons.ios_share_rounded),
                semanticLabel: l10n.shareAction,
                onPressed: _shareSheetOpen
                    ? null
                    : () => unawaited(_openShareSheet(_provider)),
              ),
          ],
          body: _body(context, l10n, _provider),
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
        final coverage = buildAnnualReportCoverage(context, l10n, report);
        final sections = <Widget>[
          AnnualReportHero(l10n: l10n, report: report),
          const SizedBox(height: 20),
          AnnualReportNumbers(l10n: l10n, report: report, wide: wide),
          const SizedBox(height: 24),
          AnnualReportMonthly(l10n: l10n, report: report),
          if (report.pageTopTracks.isNotEmpty) ...[
            const SizedBox(height: 24),
            AnnualReportTopTracks(
              l10n: l10n,
              report: report,
              onTap: (index) => unawaited(_playTopTracks(report, index)),
            ),
          ],
          if (report.pageTopArtists.isNotEmpty ||
              report.pageTopAlbums.isNotEmpty) ...[
            const SizedBox(height: 24),
            AnnualReportTwoUp(
              wide: wide,
              first: report.pageTopArtists.isEmpty
                  ? null
                  : AnnualReportTopArtists(l10n: l10n, report: report),
              second: report.pageTopAlbums.isEmpty
                  ? null
                  : AnnualReportTopAlbums(l10n: l10n, report: report),
            ),
          ],
          if (report.platforms.isNotEmpty) ...[
            const SizedBox(height: 24),
            AnnualReportPlatforms(l10n: l10n, report: report),
          ],
          if (report.firstPlay != null || report.lastPlay != null) ...[
            const SizedBox(height: 24),
            AnnualReportEdges(l10n: l10n, report: report, wide: wide),
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

  Future<void> _playTopTracks(AnnualReport report, int index) async {
    if (report.topTracks.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    final library = ref.read(libraryProvider);
    final playback = ref.read(playbackControllerProvider);
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
    final NotificationService? notifications = ref.read(
      notificationServiceProvider,
    );
    final name = l10n.annualReportPlaylistName(report.year);
    try {
      final library = ref.read(libraryProvider);
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
      await AnnualReportPoster.show(context, l10n: l10n, report: report);
    } finally {
      if (mounted) setState(() => _shareSheetOpen = false);
    }
  }
}
