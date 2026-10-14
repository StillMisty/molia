/// 下载弹层：当前曲目的下载状态与动作（歌曲信息页「下载」行唯一入口）。
///
/// 结构：曲目头 → 音频段（音质 + 状态 + 下载/取消/删除/分享）。
/// 歌词 / 封面的单独下载与音质选择器随下载改造接入（记录已支持分项状态）。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../domain/models/download.dart';
import '../domain/models/failure.dart';
import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../services/notification_service.dart';
import '../providers/sources_provider.dart';
import '../services/data_saver_service.dart';
import '../services/download/download_service.dart';
import '../utils/download_failure_label.dart';
import '../utils/responsive.dart';
import '../utils/source_quality_label.dart';
import '../utils/track_cache_label.dart';
import 'settings/settings_tiles.dart';

/// 打开下载弹层（歌曲信息页「下载」行唯一入口）。
Future<void> showDownloadSheet(BuildContext context, {required Track track}) {
  return ResponsiveNavigation.showAdaptiveModalPage<void>(
    context: context,
    title: AppLocalizations.of(context)!.downloadSection,
    child: _DownloadSheet(track: track),
  );
}

class _DownloadSheet extends StatefulWidget {
  const _DownloadSheet({required this.track});

  final Track track;

  @override
  State<_DownloadSheet> createState() => _DownloadSheetState();
}

class _DownloadSheetState extends State<_DownloadSheet> {
  /// 下载动作进行中（下载 / 删除 / 分享互斥，避免重复触发）。
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final downloads = context.read<DownloadService?>();
    final preferredQuality =
        context.watch<SourcesProvider?>()?.preferredQuality ?? '320k';
    final (record, progress) =
        context.select<DownloadService?, (DownloadedTrack?, DownloadProgress?)>(
      (service) {
        if (service == null) return (null, null);
        return (
          service.recordForTrack(widget.track),
          service.progressForTrack(widget.track),
        );
      },
    );

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTrackHeader(context),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: SettingsSectionCard(
              children: [
                SettingsInfoTile(
                  key: const Key('downloadSheetQuality'),
                  icon: Icons.high_quality_rounded,
                  title: l10n.downloadQualityLabel,
                  subtitle: sourceQualityLabel(l10n, preferredQuality),
                ),
                SettingsInfoTile(
                  key: const Key('downloadSheetStatus'),
                  icon: record != null
                      ? Icons.download_done_rounded
                      : progress != null
                          ? Icons.downloading_rounded
                          : Icons.download_rounded,
                  title: record != null
                      ? l10n.downloadStatusDownloaded
                      : progress != null
                          ? l10n.downloadStatusDownloading
                          : l10n.downloadStatusNotDownloaded,
                  subtitle: _statusSubtitle(l10n, record, progress),
                ),
                ..._buildActions(context, l10n, downloads, record, progress),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 曲目头：歌名 · 歌手（与评论页同构，明确下载对象）。
  Widget _buildTrackHeader(BuildContext context) {
    final theme = Theme.of(context);
    final artist = widget.track.artists
        .map((artist) => artist.name)
        .where((name) => name.isNotEmpty)
        .join(', ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
      child: Row(
        children: [
          Icon(Icons.music_note_rounded, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              artist.isEmpty
                  ? widget.track.title
                  : '${widget.track.title} · $artist',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _statusSubtitle(
    AppLocalizations l10n,
    DownloadedTrack? record,
    DownloadProgress? progress,
  ) {
    if (record != null) {
      final quality = record.quality.isEmpty
          ? ''
          : sourceQualityLabel(l10n, record.quality);
      return quality.isEmpty
          ? record.sizeLabel
          : '${record.sizeLabel} · $quality';
    }
    if (progress != null) {
      final percent = progress.percent;
      return percent == null
          ? formatCacheBytes(progress.receivedBytes)
          : l10n.downloadProgressPercent(percent);
    }
    if (widget.track.id.sourceKey == kLocalSourceKey) {
      return l10n.downloadFileMissing;
    }
    return l10n.downloadStatusNotDownloaded;
  }

  /// 音频动作行：按状态给出下载 / 取消 / 删除 / 分享。
  List<Widget> _buildActions(
    BuildContext context,
    AppLocalizations l10n,
    DownloadService? downloads,
    DownloadedTrack? record,
    DownloadProgress? progress,
  ) {
    final supported = downloads != null && downloads.supported;
    if (record != null) {
      return [
        SettingsNavTile(
          key: const Key('downloadSheetShare'),
          icon: Icons.ios_share_rounded,
          title: l10n.downloadShare,
          subtitle: '',
          onTap: _busy ? null : () => unawaited(_share(record)),
        ),
        SettingsNavTile(
          key: const Key('downloadSheetDelete'),
          icon: Icons.delete_rounded,
          title: l10n.downloadDelete,
          subtitle: '',
          isDestructive: true,
          onTap:
              _busy ? null : () => unawaited(_confirmDelete(downloads, record)),
        ),
      ];
    }
    if (progress != null) {
      return [
        SettingsNavTile(
          key: const Key('downloadSheetCancel'),
          icon: Icons.close_rounded,
          title: l10n.downloadCancel,
          subtitle: '',
          isDestructive: true,
          onTap: () {
            HapticFeedback.lightImpact();
            downloads?.cancelTrack(widget.track);
          },
        ),
      ];
    }
    if (widget.track.id.sourceKey == kLocalSourceKey) return const [];
    return [
      SettingsNavTile(
        key: const Key('downloadSheetStart'),
        icon: Icons.download_rounded,
        title: l10n.downloadAction,
        subtitle: '',
        onTap: !supported || _busy
            ? null
            : () => unawaited(_startDownload(downloads)),
      ),
    ];
  }

  /// 下载当前曲目；省流生效（移动数据 + 已开启）时先确认再下载。
  Future<void> _startDownload(DownloadService? downloads) async {
    if (downloads == null || _busy) return;
    final l10n = AppLocalizations.of(context)!;
    final dataSaver = context.read<DataSaverService?>();
    if (dataSaver?.active ?? false) {
      final confirmed = await M3EDialog.show<bool>(
        context,
        dialog: M3EDialog(
          title: l10n.downloadDataSaverTitle,
          content: Text(l10n.downloadDataSaverConfirm),
          actions: [
            M3EButton.text(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.cancel),
            ),
            M3EButton.filled(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.downloadContinue),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    HapticFeedback.lightImpact();
    setState(() => _busy = true);
    try {
      await downloads.download(widget.track);
      if (!mounted) return;
      _showMessage(l10n.downloadCompleted);
    } on SourceFailure catch (failure) {
      if (!mounted || failure.kind == FailureKind.cancelled) return;
      _showMessage(downloadFailureLabel(l10n, failure));
    } catch (e) {
      if (!mounted) return;
      _showMessage(l10n.downloadFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 删除下载（确认后删除音频 + 歌词 + 封面；不影响缓存）。
  Future<void> _confirmDelete(
    DownloadService? downloads,
    DownloadedTrack record,
  ) async {
    if (downloads == null || _busy) return;
    final l10n = AppLocalizations.of(context)!;
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
    if (confirmed != true || !mounted) return;
    HapticFeedback.lightImpact();
    setState(() => _busy = true);
    try {
      await downloads.delete(record);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 分享导出音频文件（系统分享面板；桌面端为分享/另存入口）。
  Future<void> _share(DownloadedTrack record) async {
    if (_busy) return;
    final l10n = AppLocalizations.of(context)!;
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(record.filePath)]),
      );
    } catch (_) {
      if (mounted) _showMessage(l10n.exportFailed);
    }
  }

  void _showMessage(String message) {
    final notifications = context.read<NotificationService?>();
    if (notifications != null) {
      notifications.showSnackBar(message);
    } else {
      M3ESnackbar.show(context, message: message);
    }
  }
}
