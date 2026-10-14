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
import '../providers/playback_provider.dart';
import '../providers/sources_provider.dart';
import '../services/cache_service.dart';
import '../services/data_saver_service.dart';
import '../services/download/download_service.dart';
import '../services/notification_service.dart';
import '../services/track_cache_service.dart';
import '../utils/source_label.dart';
import '../utils/source_quality_label.dart';
import 'settings/settings_tiles.dart';

/// 播放页第三个 tab：当前曲目信息 + 单曲缓存管理 + 本地下载。
///
/// - 信息区：本次播放音质、可用音质、渠道、专辑、时长、曲目 ID（复制）；
/// - 缓存区：音频 / 歌词 / 封面 / 取链四项占用与清理；
/// - 下载区：未下载 / 下载中（百分比 + 取消）/ 已下载（大小 + 删除 +
///   分享导出）。下载与缓存是**两套东西**：清缓存永不触碰 `downloads/`。
///
/// 口径说明：音质显示的是**本次请求音质**（偏好音质 × 曲目可用列表 ×
/// 省流上限 = `PlaybackProvider.currentQualityType`，展示名本地化）；
/// 取链接口不返回实际码率，因此不展示「实际音质」。缓存占用与清理统一走
/// [TrackCacheService]，页面不拼缓存 key（四种后端的 key 形态各不相同）。
class TrackInfoView extends StatefulWidget {
  const TrackInfoView({
    super.key,
    required this.controller,
    this.topPadding = 0,
  });

  /// 滚动控制器（父页面「滑到顶下拉收起播放器」与滚动条共用）。
  final ScrollController controller;

  /// 内容顶部额外留白（播放页圆点过渡带）。
  final double topPadding;

  @override
  State<TrackInfoView> createState() => _TrackInfoViewState();
}

class _TrackInfoViewState extends State<TrackInfoView> {
  PlaybackProvider? _playback;
  TrackCacheService? _cacheService;
  DownloadService? _downloadService;

  /// 当前已加载占用的曲目；用于切歌重载与过期结果丢弃。
  TrackId? _usageForTrack;
  TrackCacheUsage? _usage;
  bool _busy = false;

  /// 下载动作进行中（下载/删除/分享互斥，避免重复触发）。
  bool _downloadBusy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _cacheService = context.read<TrackCacheService?>();
    _downloadService = context.read<DownloadService?>();
    final playback = context.read<PlaybackProvider?>();
    if (playback != null && !identical(_playback, playback)) {
      _playback?.removeListener(_syncTrack);
      _playback = playback..addListener(_syncTrack);
    }
    _syncTrack();
  }

  @override
  void dispose() {
    _playback?.removeListener(_syncTrack);
    super.dispose();
  }

  /// 切歌（含自动连播）时重载占用；同一曲目重复通知不重复请求。
  void _syncTrack() {
    final track = _playback?.snapshot.current;
    if (track?.id == _usageForTrack) return;
    _usageForTrack = track?.id;
    _usage = null;
    if (track != null) unawaited(_loadUsage(track));
  }

  Future<void> _loadUsage(Track track) async {
    final service = _cacheService;
    if (service == null) return;
    try {
      final usage = await service.usage(track);
      if (!mounted || _usageForTrack != track.id) return;
      setState(() => _usage = usage);
    } catch (_) {
      // 占用查询失败按「无缓存」呈现；清理本身仍可尝试。
      if (!mounted || _usageForTrack != track.id) return;
      setState(() => _usage = const TrackCacheUsage());
    }
  }

  Future<void> _clear(Track track, TrackCachePart part) async {
    final service = _cacheService;
    if (service == null || _busy) return;
    HapticFeedback.lightImpact();
    setState(() => _busy = true);
    try {
      final result = await service.clear(track, part);
      if (!mounted) return;
      _showClearResult(result);
      await _loadUsage(track);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyTrackId(Track track) async {
    HapticFeedback.lightImpact();
    await Clipboard.setData(ClipboardData(text: track.id.uri));
    if (!mounted) return;
    _showMessage(AppLocalizations.of(context)!.trackInfoIdCopied);
  }

  /// 清理结果提示：清到东西 / 活动文件跳过 / 本来就没缓存，三种分开说。
  void _showClearResult(TrackCacheClearResult result) {
    final l10n = AppLocalizations.of(context)!;
    if (result.cleared) {
      final size = result.part == TrackCachePart.resolveUrl
          ? l10n.trackInfoCacheEntries(result.freed.count)
          : _formatSize(result.freed.bytes);
      _showMessage(l10n.trackInfoCacheCleared(size));
    } else if (result.skipped > 0) {
      _showMessage(l10n.trackInfoCachePlaying);
    } else {
      _showMessage(l10n.trackInfoCacheNone);
    }
  }

  // 下载动作（与缓存清理是两套东西：删除下载只删 downloads/ 下的副本）

  /// 下载当前曲目；省流生效（移动数据 + 已开启）时先确认再下载。
  Future<void> _startDownload(Track track) async {
    final service = _downloadService;
    if (service == null || _downloadBusy) return;
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
    setState(() => _downloadBusy = true);
    try {
      await service.download(track);
      if (!mounted) return;
      _showMessage(l10n.downloadCompleted);
    } on SourceFailure catch (failure) {
      if (!mounted || failure.kind == FailureKind.cancelled) return;
      _showMessage(_downloadFailureMessage(l10n, failure));
    } catch (e) {
      if (!mounted) return;
      _showMessage(l10n.downloadFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _downloadBusy = false);
    }
  }

  /// 删除下载（确认后删除音频 + 歌词 + 封面；不影响缓存）。
  Future<void> _confirmDeleteDownload(DownloadedTrack record) async {
    final service = _downloadService;
    if (service == null || _downloadBusy) return;
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
    setState(() => _downloadBusy = true);
    try {
      await service.delete(record);
    } finally {
      if (mounted) setState(() => _downloadBusy = false);
    }
  }

  /// 分享导出音频文件（系统分享面板；桌面端为分享/另存入口）。
  Future<void> _shareDownload(DownloadedTrack record) async {
    if (_downloadBusy) return;
    final l10n = AppLocalizations.of(context)!;
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(record.filePath)]),
      );
    } catch (_) {
      if (mounted) _showMessage(l10n.exportFailed);
    }
  }

  /// 下载失败文案：已知 l10nKey 精确映射，未知回退通用失败（带原始信息）。
  String _downloadFailureMessage(
    AppLocalizations l10n,
    SourceFailure failure,
  ) {
    switch (failure.l10nKey) {
      case 'downloadUnsupported':
        return l10n.downloadUnsupported;
      case 'downloadAlreadyExists':
        return l10n.downloadAlreadyExists;
      case 'downloadCancelled':
        return l10n.downloadCancelled;
      case 'downloadFileMissing':
        return l10n.downloadFileMissing;
      default:
        return l10n.downloadFailed(failure.message);
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 订阅音质偏好（音源页）与省流开关（数据设置）：「本次播放音质」
    // 是二者的派生值，改完设置要立即刷新，不等下一次播放通知。
    final sources = context.watch<SourcesProvider?>();
    final dataSaver = context.watch<DataSaverService?>();
    final (track, qualityType) =
        context.select<PlaybackProvider, (Track?, String)>(
      (provider) => (provider.snapshot.current, provider.currentQualityType),
    );
    final qualityLabel = sourceQualityLabel(l10n, qualityType);
    // 下载状态订阅：仅当前曲目的「记录 / 进度」变化时重建。
    final (downloadRecord, downloadProgress) =
        context.select<DownloadService?, (DownloadedTrack?, DownloadProgress?)>(
      (service) {
        final current = track;
        if (service == null || current == null) return (null, null);
        return (
          service.recordForTrack(current),
          service.progressForTrack(current),
        );
      },
    );
    final downloadService = _downloadService;
    final showDownload = downloadService != null && downloadService.supported;

    return Scrollbar(
      controller: widget.controller,
      thumbVisibility: true,
      interactive: true,
      child: ListView(
        controller: widget.controller,
        padding: EdgeInsets.fromLTRB(
          kSettingsPadding,
          widget.topPadding,
          kSettingsPadding,
          kSettingsPadding * 2,
        ),
        children: [
          if (track == null)
            _buildEmptyState(l10n)
          else ...[
            SettingsSectionCard(
              children: [
                SettingsInfoTile(
                  icon: Icons.graphic_eq_rounded,
                  title: l10n.trackInfoQuality,
                  subtitle: (dataSaver?.active ?? false)
                      ? '$qualityLabel · ${l10n.settingsDataSaverTitle}'
                      : qualityLabel,
                ),
                SettingsInfoTile(
                  icon: Icons.high_quality_rounded,
                  title: l10n.trackInfoQualityAvailable,
                  subtitle: _availableQualitiesLabel(l10n, track),
                ),
                SettingsInfoTile(
                  icon: Icons.hub_rounded,
                  title: l10n.trackInfoChannel,
                  subtitle: _channelLabel(l10n, sources, track),
                ),
                if ((track.album ?? '').isNotEmpty)
                  SettingsInfoTile(
                    icon: Icons.album_rounded,
                    title: l10n.trackInfoAlbum,
                    subtitle: track.album!,
                  ),
                SettingsInfoTile(
                  icon: Icons.schedule_rounded,
                  title: l10n.trackInfoDuration,
                  subtitle: _formatDuration(track.duration),
                ),
                SettingsNavTile(
                  key: const Key('trackInfoCopyIdItem'),
                  icon: Icons.tag_rounded,
                  title: l10n.trackInfoTrackId,
                  subtitle: track.id.uri,
                  onTap: () => unawaited(_copyTrackId(track)),
                ),
              ],
            ),
            const SizedBox(height: kSettingsSectionSpacing),
            SettingsSectionCard(
              title: l10n.trackInfoCacheSection,
              children: [
                _cacheTile(l10n, track, TrackCachePart.audio,
                    icon: Icons.audiotrack_rounded,
                    title: l10n.cachePartitionAudio),
                _cacheTile(l10n, track, TrackCachePart.lyrics,
                    icon: Icons.lyrics_rounded,
                    title: l10n.cachePartitionLyrics),
                _cacheTile(l10n, track, TrackCachePart.artwork,
                    icon: Icons.image_rounded,
                    title: l10n.cachePartitionArtwork),
                _cacheTile(l10n, track, TrackCachePart.resolveUrl,
                    icon: Icons.link_rounded,
                    title: l10n.trackInfoCacheResolve),
              ],
            ),
            if (showDownload) ...[
              const SizedBox(height: kSettingsSectionSpacing),
              SettingsSectionCard(
                title: l10n.downloadSection,
                children: _downloadTiles(
                  l10n,
                  track,
                  downloadRecord,
                  downloadProgress,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  /// 下载区行：未下载（下载）/ 下载中（百分比 + 取消）/ 已下载
  /// （大小 + 分享导出 + 删除）。本地曲目（`local`）同样是「已下载」。
  List<Widget> _downloadTiles(
    AppLocalizations l10n,
    Track track,
    DownloadedTrack? record,
    DownloadProgress? progress,
  ) {
    if (record != null) {
      return [
        SettingsInfoTile(
          key: const Key('trackInfoDownloadStatus'),
          icon: Icons.download_done_rounded,
          title: l10n.downloadStatusDownloaded,
          subtitle: _downloadedSubtitle(l10n, record),
        ),
        SettingsNavTile(
          key: const Key('trackInfoDownloadShare'),
          icon: Icons.ios_share_rounded,
          title: l10n.downloadShare,
          subtitle: '',
          onTap: _downloadBusy ? null : () => unawaited(_shareDownload(record)),
        ),
        SettingsNavTile(
          key: const Key('trackInfoDownloadDelete'),
          icon: Icons.delete_rounded,
          title: l10n.downloadDelete,
          subtitle: '',
          isDestructive: true,
          onTap: _downloadBusy
              ? null
              : () => unawaited(_confirmDeleteDownload(record)),
        ),
      ];
    }
    if (progress != null) {
      final percent = progress.percent;
      return [
        SettingsInfoTile(
          key: const Key('trackInfoDownloadStatus'),
          icon: Icons.downloading_rounded,
          title: l10n.downloadStatusDownloading,
          subtitle: percent == null
              ? _formatSize(progress.receivedBytes)
              : l10n.downloadProgressPercent(percent),
        ),
        SettingsNavTile(
          key: const Key('trackInfoDownloadCancel'),
          icon: Icons.close_rounded,
          title: l10n.downloadCancel,
          subtitle: '',
          isDestructive: true,
          onTap: () {
            HapticFeedback.lightImpact();
            _downloadService?.cancelTrack(track);
          },
        ),
      ];
    }
    return [
      SettingsNavTile(
        key: const Key('trackInfoDownloadStart'),
        icon: Icons.download_rounded,
        title: l10n.downloadAction,
        subtitle: l10n.downloadStatusNotDownloaded,
        onTap: _downloadBusy ? null : () => unawaited(_startDownload(track)),
      ),
    ];
  }

  /// 已下载副标题：`大小 · 音质`（音质未知时只显示大小）。
  String _downloadedSubtitle(AppLocalizations l10n, DownloadedTrack record) {
    final quality = record.quality.isEmpty
        ? ''
        : sourceQualityLabel(l10n, record.quality);
    if (quality.isEmpty) return record.sizeLabel;
    return '${record.sizeLabel} · $quality';
  }

  Widget _buildEmptyState(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 96),
      child: Column(
        children: [
          Icon(Icons.info_rounded, size: 40, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            l10n.trackInfoEmpty,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  /// 缓存行：副标题为该项占用，点击清理（进行中整行禁用）。
  Widget _cacheTile(
    AppLocalizations l10n,
    Track track,
    TrackCachePart part, {
    required IconData icon,
    required String title,
  }) {
    return SettingsNavTile(
      key: Key('trackInfoCache_${part.name}'),
      icon: icon,
      title: title,
      subtitle: _usageLabel(l10n, part),
      isDestructive: true,
      onTap: _cacheService == null || _busy
          ? null
          : () => unawaited(_clear(track, part)),
    );
  }

  /// 单项占用文案：未就绪「统计中」、命中「大小 · 条数」、未命中「无缓存」。
  String _usageLabel(AppLocalizations l10n, TrackCachePart part) {
    final usage = _usage;
    if (usage == null) return l10n.cacheUsageComputing;
    final (CacheUsage value, bool isCountOnly) = switch (part) {
      TrackCachePart.audio => (usage.audio, false),
      TrackCachePart.lyrics => (usage.lyrics, false),
      TrackCachePart.artwork => (usage.artwork, false),
      TrackCachePart.resolveUrl => (
          CacheUsage(bytes: 0, count: usage.resolveEntries),
          true,
        ),
    };
    if (value.count <= 0) return l10n.trackInfoCacheNone;
    if (isCountOnly) return l10n.trackInfoCacheEntries(value.count);
    return l10n.cacheUsage(_formatSize(value.bytes), value.count);
  }

  /// 可用音质：本地化音质名（未知值回退原值），有体积时附在括号里。
  String _availableQualitiesLabel(AppLocalizations l10n, Track track) {
    final labels = [
      for (final quality in track.qualities)
        if (quality.type.isNotEmpty)
          (quality.size ?? '').isEmpty
              ? sourceQualityLabel(l10n, quality.type)
              : '${sourceQualityLabel(l10n, quality.type)}'
                  ' (${quality.size})',
    ];
    return labels.isEmpty
        ? l10n.trackInfoQualityUnknown
        : labels.join(' · ');
  }

  /// 渠道展示名：音源列表（含停用项）查 key；查不到回退原始 key。
  /// 本地下载曲目固定显示「本地下载」。
  String _channelLabel(
    AppLocalizations l10n,
    SourcesProvider? sources,
    Track track,
  ) {
    final key = track.id.sourceKey;
    if (key.isEmpty) return l10n.trackInfoChannelUnknown;
    if (key == kLocalSourceKey) return l10n.downloadSourceLocal;
    return sourceChannelLabel(sources?.channels ?? const [], key);
  }

  static String _formatDuration(Duration? duration) {
    if (duration == null || duration <= Duration.zero) return '--:--';
    final minutes = duration.inMinutes;
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  static String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }
}
