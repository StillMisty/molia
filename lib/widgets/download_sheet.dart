/// 下载弹层：音频（音质选择 / 状态 / 下载动作）+ 附加内容（歌词 / 封面
/// 单独下载）+ 全部下载（歌曲信息页「下载」行唯一入口）。
///
/// 缓存优先的语义在这里可见：命中完整音频缓存的音质标「本地缓存」，
/// 选中后下载直接拷贝不触网；歌词 / 封面命中缓存同样直接落盘。
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
import '../services/data_saver_service.dart';
import '../services/download/download_service.dart';
import '../services/notification_service.dart';
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
  /// 音频动作进行中（下载 / 删除 / 分享互斥，避免重复触发）。
  bool _audioBusy = false;

  /// 附加内容动作进行中（歌词 / 封面单独下载）。
  bool _partBusy = false;

  /// 当前选中的下载音质（缺省 = 服务端偏好音质 × 曲目可用音质）。
  String? _quality;

  /// 音质 → 是否命中完整音频缓存（弹层打开时探测一次）。
  final Map<String, bool> _cacheHits = {};

  @override
  void initState() {
    super.initState();
    scheduleMicrotask(_probeCacheHits);
  }

  Future<void> _probeCacheHits() async {
    final downloads = context.read<DownloadService?>();
    if (downloads == null) return;
    final qualities = _qualityOptions(widget.track);
    final hits = <String, bool>{};
    for (final quality in qualities) {
      hits[quality] = await downloads.audioCacheHit(widget.track, quality);
    }
    if (!mounted) return;
    setState(() {
      _cacheHits
        ..clear()
        ..addAll(hits);
    });
  }

  /// 可选音质（LX 标识，去重保序；空曲目列表回退偏好音质）。
  static List<String> _qualityOptions(Track track) {
    final types = <String>[];
    for (final quality in track.qualities) {
      final type = quality.type;
      if (type.isNotEmpty && !types.contains(type)) types.add(type);
    }
    return types;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final downloads = context.read<DownloadService?>();
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
    final qualities = _qualityOptions(widget.track);
    final selectedQuality = _quality ??
        downloads?.defaultQualityFor(widget.track) ??
        (qualities.isEmpty ? '' : qualities.first);

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTrackHeader(context),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SettingsSectionCard(
                  title: l10n.downloadAudioSection,
                  children: [
                    if (qualities.isNotEmpty)
                      for (final quality in qualities)
                        M3EListItem(
                          key: Key('downloadQuality_$quality'),
                          leading: Icon(
                            quality == selectedQuality
                                ? Icons.radio_button_checked_rounded
                                : Icons.radio_button_unchecked_rounded,
                          ),
                          headline: sourceQualityLabel(l10n, quality),
                          trailingText: _cacheHits[quality] == true
                              ? l10n.downloadQualityCached
                              : null,
                          selected: quality == selectedQuality,
                          enabled: record == null || !record.hasAudio,
                          onTap: record == null || !record.hasAudio
                              ? () => setState(() => _quality = quality)
                              : null,
                        ),
                    SettingsInfoTile(
                      key: const Key('downloadSheetStatus'),
                      icon: record?.hasAudio ?? false
                          ? Icons.download_done_rounded
                          : progress != null
                              ? Icons.downloading_rounded
                              : Icons.download_rounded,
                      title: record?.hasAudio ?? false
                          ? l10n.downloadStatusDownloaded
                          : progress != null
                              ? l10n.downloadStatusDownloading
                              : l10n.downloadStatusNotDownloaded,
                      subtitle: _statusSubtitle(l10n, record, progress),
                    ),
                    ..._buildAudioActions(
                      context,
                      l10n,
                      downloads,
                      record,
                      progress,
                      selectedQuality,
                    ),
                  ],
                ),
                const SizedBox(height: kSettingsSectionSpacing),
                SettingsSectionCard(
                  title: l10n.downloadExtrasSection,
                  children: [
                    _buildPartTile(
                      key: const Key('downloadLyricsPart'),
                      icon: Icons.lyrics_rounded,
                      title: l10n.lyricsTitle,
                      downloaded: record?.hasLyrics ?? false,
                      onDownload: downloads == null
                          ? null
                          : () => unawaited(
                                _downloadPart(downloads, lyrics: true),
                              ),
                    ),
                    _buildPartTile(
                      key: const Key('downloadCoverPart'),
                      icon: Icons.image_rounded,
                      title: l10n.downloadCoverPart,
                      downloaded: record?.hasCover ?? false,
                      onDownload: downloads == null
                          ? null
                          : () => unawaited(
                                _downloadPart(downloads, lyrics: false),
                              ),
                    ),
                  ],
                ),
                const SizedBox(height: kSettingsSectionSpacing),
                M3EButton.filled(
                  key: const Key('downloadAll'),
                  onPressed: downloads == null ||
                          !downloads.supported ||
                          _audioBusy ||
                          (record?.hasAudio ?? false)
                      ? null
                      : () => unawaited(
                            _startDownload(
                              downloads,
                              quality: selectedQuality,
                              includeLyrics: true,
                              includeCover: true,
                            ),
                          ),
                  child: Text(l10n.downloadAll),
                ),
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
          Icon(
            Icons.music_note_rounded,
            color: theme.colorScheme.onSurfaceVariant,
          ),
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
    if (record != null && record.hasAudio) {
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
  List<Widget> _buildAudioActions(
    BuildContext context,
    AppLocalizations l10n,
    DownloadService? downloads,
    DownloadedTrack? record,
    DownloadProgress? progress,
    String selectedQuality,
  ) {
    final supported = downloads != null && downloads.supported;
    if (record != null && record.hasAudio) {
      return [
        SettingsNavTile(
          key: const Key('downloadSheetShare'),
          icon: Icons.ios_share_rounded,
          title: l10n.downloadShare,
          subtitle: '',
          onTap: _audioBusy ? null : () => unawaited(_share(record)),
        ),
        SettingsNavTile(
          key: const Key('downloadSheetDelete'),
          icon: Icons.delete_rounded,
          // 本地导入是就地引用：文案区分「删除下载」与「从列表移除」。
          title: record.imported ? l10n.localSongsRemove : l10n.downloadDelete,
          subtitle: '',
          isDestructive: true,
          onTap: _audioBusy
              ? null
              : () => unawaited(_confirmDelete(downloads, record)),
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
        onTap: !supported || _audioBusy
            ? null
            : () => unawaited(
                  _startDownload(
                    downloads,
                    quality: selectedQuality,
                    includeLyrics: true,
                    includeCover: true,
                  ),
                ),
      ),
    ];
  }

  /// 附加内容行：状态 + 「单独下载」（缓存优先，与音频同一套机制）。
  Widget _buildPartTile({
    required Key key,
    required IconData icon,
    required String title,
    required bool downloaded,
    required VoidCallback? onDownload,
  }) {
    final l10n = AppLocalizations.of(context)!;
    return SettingsNavTile(
      key: key,
      icon: icon,
      title: title,
      subtitle: downloaded
          ? l10n.downloadStatusDownloaded
          : l10n.downloadStatusNotDownloaded,
      onTap: _partBusy || downloaded ? null : onDownload,
    );
  }

  /// 单独下载歌词 / 封面。
  Future<void> _downloadPart(
    DownloadService downloads, {
    required bool lyrics,
  }) async {
    if (_partBusy) return;
    final l10n = AppLocalizations.of(context)!;
    HapticFeedback.lightImpact();
    setState(() => _partBusy = true);
    try {
      if (lyrics) {
        await downloads.downloadLyrics(widget.track);
        if (mounted) _showMessage(l10n.downloadLyricsDone);
      } else {
        await downloads.downloadCover(widget.track);
        if (mounted) _showMessage(l10n.downloadCoverDone);
      }
    } on SourceFailure catch (failure) {
      if (!mounted || failure.kind == FailureKind.cancelled) return;
      _showMessage(downloadFailureLabel(l10n, failure));
    } catch (e) {
      if (mounted) _showMessage(l10n.downloadFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _partBusy = false);
    }
  }

  /// 下载音频；省流生效（移动数据 + 已开启）时先确认再下载。
  Future<void> _startDownload(
    DownloadService? downloads, {
    required String quality,
    required bool includeLyrics,
    required bool includeCover,
  }) async {
    if (downloads == null || _audioBusy) return;
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
    setState(() => _audioBusy = true);
    try {
      await downloads.download(
        widget.track,
        quality: quality.isEmpty ? null : quality,
        includeLyrics: includeLyrics,
        includeCover: includeCover,
      );
      if (!mounted) return;
      _showMessage(l10n.downloadCompleted);
    } on SourceFailure catch (failure) {
      if (!mounted || failure.kind == FailureKind.cancelled) return;
      _showMessage(downloadFailureLabel(l10n, failure));
    } catch (e) {
      if (!mounted) return;
      _showMessage(l10n.downloadFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _audioBusy = false);
    }
  }

  /// 删除下载（确认后删除音频 + 歌词 + 封面；不影响缓存）。
  ///
  /// 本地导入（`record.imported`）只移除记录：文案与确认都用「从列表移除」。
  Future<void> _confirmDelete(
    DownloadService? downloads,
    DownloadedTrack record,
  ) async {
    if (downloads == null || _audioBusy) return;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: record.imported ? l10n.localSongsRemove : l10n.downloadDelete,
        content: Text(
          record.imported
              ? l10n.localSongsRemoveConfirm
              : l10n.downloadDeleteConfirm,
        ),
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
    setState(() => _audioBusy = true);
    try {
      await downloads.delete(record);
    } finally {
      if (mounted) setState(() => _audioBusy = false);
    }
  }

  /// 分享导出音频文件（系统分享面板；桌面端为分享/另存入口）。
  Future<void> _share(DownloadedTrack record) async {
    if (_audioBusy) return;
    final path = record.filePath;
    if (path == null || path.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(path)]),
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
