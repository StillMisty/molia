import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../providers/playback_provider.dart';
import '../providers/sources_provider.dart';
import '../services/cache_service.dart';
import '../services/data_saver_service.dart';
import '../services/notification_service.dart';
import '../services/track_cache_service.dart';
import '../utils/source_label.dart';
import '../utils/source_quality_label.dart';
import 'settings/settings_tiles.dart';

/// 播放页第三个 tab：当前曲目信息 + 单曲缓存管理。
///
/// - 信息区：本次播放音质、可用音质、渠道、专辑、时长、曲目 ID（复制）；
/// - 缓存区：音频 / 歌词 / 封面 / 取链四项占用与清理。
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

  /// 当前已加载占用的曲目；用于切歌重载与过期结果丢弃。
  TrackId? _usageForTrack;
  TrackCacheUsage? _usage;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _cacheService = context.read<TrackCacheService?>();
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
          ],
        ],
      ),
    );
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
  String _channelLabel(
    AppLocalizations l10n,
    SourcesProvider? sources,
    Track track,
  ) {
    final key = track.id.sourceKey;
    if (key.isEmpty) return l10n.trackInfoChannelUnknown;
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
