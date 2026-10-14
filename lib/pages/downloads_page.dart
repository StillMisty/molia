/// 已下载页：本地下载列表（离线播放 / 收藏 / 加入列表 / 删除）。
///
/// 入口：收藏页标题行「已下载」按钮（存储不可用 / Web 平台不显示）。
/// 列表项还原为「本地曲目」快照（`sourceKey = local` + 带路径 raw）：
/// - 播放走 `local` 音源（读 `downloads/` 文件，离线可用）；
/// - 收藏 / 加入列表落自包含快照（`playlist_tracks` 无需改表）；
/// - 删除下载是独立动作（连同歌词 / 封面文件），不影响缓存。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/download.dart';
import '../l10n/app_localizations.dart';
import '../providers/library_provider.dart';
import '../services/download/download_service.dart';
import '../utils/duration_text.dart';
import '../utils/responsive.dart';
import '../widgets/add_to_library.dart';
import '../widgets/swipe_reveal_row.dart';
import '../widgets/track_row.dart';

/// 打开已下载页（收藏页入口；ResponsiveNavigation 全屏 / 侧边弹层自适应）。
Future<void> showDownloadsPage(BuildContext context) {
  return ResponsiveNavigation.showSecondaryPage<void>(
    context: context,
    // 页面自带 AppBar（含返回），不再叠一层关闭行。
    showCloseButton: false,
    child: const DownloadsPage(),
  );
}

@visibleForTesting
class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final service = context.watch<DownloadService?>();
    final downloads = service?.downloads ?? const <DownloadedTrack>[];

    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.downloadsTitle),
        automaticallyImplyLeading: true,
      ),
      body: service == null || !service.supported
          ? _buildEmptyState(
              context,
              l10n.downloadsUnsupported,
              Icons.download_rounded,
            )
          : downloads.isEmpty
              ? _buildEmptyState(
                  context,
                  l10n.downloadsEmpty,
                  Icons.download_rounded,
                )
              : _buildList(context, l10n, service, downloads),
    );
  }

  Widget _buildList(
    BuildContext context,
    AppLocalizations l10n,
    DownloadService service,
    List<DownloadedTrack> downloads,
  ) {
    final totalBytes = downloads.fold<int>(
      0,
      (sum, record) => sum + record.sizeBytes,
    );
    final horizontalPadding =
        context.layoutType(ResponsivePageType.browse).horizontalPadding;
    final gap = TrackRow.gapOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(horizontalPadding, 12, horizontalPadding, 4),
          child: Text(
            l10n.downloadsSummary(downloads.length, _formatSize(totalBytes)),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),
        Expanded(
          child: Scrollbar(
            thumbVisibility: true,
            interactive: true,
            child: ListView.builder(
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                4,
                horizontalPadding,
                8,
              ),
              itemExtent: TrackRow.extent + gap,
              itemCount: downloads.length,
              itemBuilder: (context, index) => _buildRow(
                context,
                l10n,
                service,
                downloads,
                index,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRow(
    BuildContext context,
    AppLocalizations l10n,
    DownloadService service,
    List<DownloadedTrack> downloads,
    int index,
  ) {
    final record = downloads[index];
    final library = context.watch<LibraryProvider>();
    final isFavorite =
        library.isFavorite(kLocalSourceKey, record.localSongId);
    final row = TrackRow(
      // 稳定 key：删除后列表原地刷新，不整段重建/丢滚动位置。
      key: ValueKey<String>('d:${record.key}'),
      title: record.title,
      artist: record.artist,
      coverUrl: record.artworkUri?.toString(),
      trailingText: durationText(record.durationMs),
      position: calculateCardPosition(index, downloads.length),
      onTap: () => _play(context, l10n, downloads, index),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: TrackRow.gapOf(context)),
      child: SwipeRevealRow(
        actions: _swipeActions(
          context,
          l10n,
          service,
          library,
          record,
          isFavorite,
        ),
        child: row,
      ),
    );
  }

  List<M3EListSwipeAction> _swipeActions(
    BuildContext context,
    AppLocalizations l10n,
    DownloadService service,
    LibraryProvider library,
    DownloadedTrack record,
    bool isFavorite,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final addedAt = DateTime.now().millisecondsSinceEpoch;
    final snapshot = record.toPlaylistTrack(addedAt: addedAt);
    return [
      M3EListSwipeAction(
        icon: Tooltip(
          message: l10n.addToPlaylist,
          child: const Icon(Icons.playlist_add_rounded),
        ),
        onPressed: () => unawaited(
          addTracksToLibraryTarget(
            context,
            provider: library,
            tracks: [snapshot],
            includeHistory: false,
          ),
        ),
      ),
      M3EListSwipeAction(
        icon: Tooltip(
          message: isFavorite ? l10n.favoriteRemove : l10n.favoriteAdd,
          child: Icon(
            isFavorite ? Icons.heart_broken_rounded : Icons.favorite_border_rounded,
          ),
        ),
        onPressed: () => unawaited(
          isFavorite
              ? library.removeTracksFromFavorites([
                  (sourceKey: kLocalSourceKey, songId: record.localSongId),
                ])
              : library.addTracksToFavorites([snapshot]),
        ),
      ),
      M3EListSwipeAction(
        icon: Tooltip(
          message: l10n.downloadDelete,
          child: const Icon(Icons.delete_rounded),
        ),
        isPrimary: true,
        backgroundColor: scheme.error,
        foregroundColor: scheme.onError,
        onPressed: () => unawaited(
          _confirmDelete(context, l10n, service, record),
        ),
      ),
    ];
  }

  /// 播放可见顺序即队列顺序（本地曲目，离线可播）。
  void _play(
    BuildContext context,
    AppLocalizations l10n,
    List<DownloadedTrack> downloads,
    int index,
  ) {
    HapticFeedback.lightImpact();
    final addedAt = DateTime.now().millisecondsSinceEpoch;
    unawaited(
      context.read<LibraryProvider>().playPlaylistTracks(
            [for (final record in downloads) record.toPlaylistTrack(addedAt: addedAt)],
            index,
            contextName: l10n.downloadsTitle,
          ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    AppLocalizations l10n,
    DownloadService service,
    DownloadedTrack record,
  ) async {
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.downloadDelete,
        content: Text(l10n.downloadDeleteConfirm),
        actions: [
          M3EButton.text(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          M3EButton.filled(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    HapticFeedback.lightImpact();
    await service.delete(record);
  }

  Widget _buildEmptyState(
    BuildContext context,
    String message,
    IconData icon,
  ) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }
}
