/// 年度报告海报：数据拼装、离线渲染与统一分享弹层入口。
///
/// 海报尺寸固定 1440×1920（见 `AnnualPosterService`），本文件只负责把
/// 报告聚合转成渲染输入，不读 provider。
library;

import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../../domain/models/annual_report.dart';
import '../../l10n/app_localizations.dart';
import '../../services/annual_poster_service.dart';
import '../../services/poster/poster_render_style.dart';
import '../../widgets/labels/listened_duration.dart';
import '../../widgets/poster_share_sheet.dart';
import 'annual_report_models.dart';

/// 年度报告海报的分享入口。
abstract final class AnnualReportPoster {
  /// 打开统一分享弹层（预览 + 分享 + 保存图片）。
  static Future<void> show(
    BuildContext context, {
    required AppLocalizations l10n,
    required AnnualReport report,
  }) {
    return showPosterShareSheet(
      context,
      title: l10n.annualReportSharePoster,
      renderPoster: () => _render(context, l10n, report),
      shareText: l10n.annualReportTitle,
      fileName: 'molia_annual_${report.year}.png',
      saveDialogTitle: l10n.shareSaveImage,
      emptyMessage: l10n.annualReportEmpty,
    );
  }

  /// 海报展示数据（全部为渲染前的字符串 / 数值）。
  static AnnualPosterData buildData(
    BuildContext context,
    AppLocalizations l10n,
    AnnualReport report,
  ) {
    final topPlatform = report.platforms.isEmpty
        ? null
        : annualReportSourceName(
            context,
            l10n,
            report.platforms.first.sourceKey,
          );
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

  static Future<Uint8List?> _render(
    BuildContext context,
    AppLocalizations l10n,
    AnnualReport report,
  ) async {
    final posterData = buildData(context, l10n, report);
    final style = await resolvePosterRenderStyle(context);
    if (!context.mounted) return null;
    return AnnualPosterService().render(
      data: posterData,
      palette: style.palette,
      fontFamily: style.fontFamily,
      fontFamilyFallback: style.fontFamilyFallback,
      watermarkText: l10n.appName,
    );
  }
}
