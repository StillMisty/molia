/// 听歌统计页的榜单区：Top 曲目（可点播）、Top 歌手与导出 JSON 入口。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../domain/models/play_statistics.dart';
import '../../domain/models/track.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/play_statistics_provider.dart';
import '../../services/notification_service.dart';
import '../../services/save_as.dart';
import '../../theme/m3e_context.dart';
import '../../widgets/card_list_surface.dart';
import '../../widgets/labels/listened_duration.dart';
import '../../widgets/labels/save_as_label.dart';
import '../../widgets/track_row.dart';

/// Top 曲目：行内展示次数 + 时长，点按从该首起播。
class StatisticsTopTracksSection extends StatelessWidget {
  const StatisticsTopTracksSection({
    super.key,
    required this.l10n,
    required this.tracks,
    required this.onTap,
  });

  final AppLocalizations l10n;
  final List<PlayStatTrackEntry> tracks;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
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
              trailingText:
                  '${l10n.statsPlaysCount(tracks[i].playCount)} · '
                  '${formatListenedDuration(l10n, tracks[i].listenedMs)}',
            ),
            position: calculateCardPosition(i, tracks.length),
            onTap: () => onTap(i),
          ),
        ],
      ],
    );
  }
}

/// Top 歌手（拆分后的艺人）：名次徽标 + 播放次数。
class StatisticsTopArtistsSection extends StatelessWidget {
  const StatisticsTopArtistsSection({
    super.key,
    required this.l10n,
    required this.artists,
  });

  final AppLocalizations l10n;
  final List<PlayStatArtistEntry> artists;

  @override
  Widget build(BuildContext context) {
    if (artists.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.statsTopArtists, style: context.typeScale.titleMedium),
        const SizedBox(height: 12),
        // 与 Top 曲目同一视觉层级：都用页面裸行（CardListSurface 分段形状），
        // 不再一边裸行一边套 filled 卡。
        for (var i = 0; i < artists.length; i++) ...[
          if (i > 0) SizedBox(height: TrackRow.gapOf(context)),
          CardListSurface(
            position: calculateCardPosition(i, artists.length),
            onPressed: null,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                StatisticsRankBadge(index: i),
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
      ],
    );
  }
}

/// 名次徽标：前三名用不规则形状，其后用等宽数字。
class StatisticsRankBadge extends StatelessWidget {
  const StatisticsRankBadge({super.key, required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
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
}

/// 导出 JSON（页面 ⋮ 里的入口）：面向 AI 消费，写入 exports 目录。
Future<void> exportPlayStatistics(
  BuildContext context,
  PlayStatisticsProvider provider,
) async {
  final l10n = AppLocalizations.of(context)!;
  final notifications = context.read<NotificationService?>();
  final saveAs = context.read<SaveAs?>();
  try {
    if (saveAs == null) throw StateError('SaveAs 未装配');
    final json = await provider.buildExportJson();
    final result = await saveAs.saveBytes(
      fileName:
          'molia_listening_${DateTime.now().toIso8601String().replaceAll(':', '-')}.json',
      bytes: Uint8List.fromList(utf8.encode(json)),
      mimeType: 'application/json',
      relativeDir: saveAsExportsDirName,
      dialogTitle: l10n.statsExport,
    );
    if (!context.mounted) return;
    switch (result) {
      case SaveAsSaved(:final displayPath, :final kind):
        notifications?.showSuccessSnackBar(
          savedLocationMessage(l10n, kind, displayPath),
        );
      case SaveAsCancelled():
        return;
      case SaveAsFailed():
        notifications?.showErrorSnackBar(l10n.statsExportFailed);
    }
  } catch (_) {
    if (context.mounted) {
      notifications?.showErrorSnackBar(l10n.statsExportFailed);
    }
  }
}
