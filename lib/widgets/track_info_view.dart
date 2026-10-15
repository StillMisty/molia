import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/download.dart';
import '../domain/models/track.dart';
import '../domain/ports/source_registry.dart';
import '../l10n/app_localizations.dart';
import '../pages/source_swap_page.dart';
import '../pages/track_cache_page.dart';
import '../providers/comments_provider.dart';
import '../providers/lyrics_provider.dart';
import '../providers/playback_provider.dart';
import '../providers/sleep_timer.dart';
import '../providers/sources_provider.dart';
import '../services/cache_service.dart';
import '../services/data_saver_service.dart';
import '../services/download/download_service.dart';
import '../services/track_cache_service.dart';
import '../utils/lyrics_provider_label.dart';
import '../utils/source_label.dart';
import '../utils/source_quality_label.dart';
import '../utils/track_cache_label.dart';
import 'download_sheet.dart';
import 'settings/settings_tiles.dart';
import 'sleep_timer_sheet.dart';
import 'track_actions.dart';
import 'track_share_sheet.dart';

/// 播放页第三个 tab：当前曲目操作 + 信息 + 缓存 / 下载入口。
///
/// 段落顺序（按使用频度）：**操作**（评论 / 定时关闭 / 换源）→ **下载**
/// （单行入口 → 下载弹层）→ **信息**（音质 / 可用音质 / 专辑 / 来源 /
/// 歌词来源）→ **缓存**（单行入口 → 单曲缓存子页）。
///
/// 口径说明：
/// - 音质显示的是**本次请求音质**（偏好音质 × 曲目可用列表 × 省流上限 =
///   `PlaybackProvider.currentQualityType`，展示名本地化）；取链接口不返回
///   实际码率，因此不展示「实际音质」；
/// - 来源行合并「渠道 + 曲目 ID」，点击进分享 / 复制弹层；歌词来源只读；
/// - 缓存与下载是**两套东西**：清缓存永不触碰 `downloads/`。
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
  CacheService? _cacheServiceRevision;

  /// 当前已加载占用的曲目；用于切歌重载与过期结果丢弃。
  TrackId? _usageForTrack;

  /// 占用对应的封面地址（封面补取回写曲目后需重算封面占用）。
  String? _usageArtwork;

  TrackCacheUsage? _usage;
  bool _listeningRevision = false;

  /// 当前曲目的完整音频缓存命中（缓存 = 已下载识别）；无缓存为 null。
  AudioCacheHit? _audioCacheHit;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _cacheService = context.read<TrackCacheService?>();
    _cacheServiceRevision =
        context.read<CacheService?>() ?? CacheService.instance;
    if (!_listeningRevision) {
      _listeningRevision = true;
      _cacheServiceRevision?.revision.addListener(_onCacheChanged);
    }
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
    if (_listeningRevision) {
      _cacheServiceRevision?.revision.removeListener(_onCacheChanged);
    }
    super.dispose();
  }

  void _onCacheChanged() {
    if (!mounted) return;
    final track = _playback?.snapshot.current;
    unawaited(_loadUsage(track));
    unawaited(_loadAudioCache(track));
  }

  /// 切歌（含自动连播）时重载占用；封面补取回写（同 id、换封面）也重算。
  void _syncTrack() {
    final track = _playback?.snapshot.current;
    final artwork = track?.artwork?.uri.toString();
    if (track?.id == _usageForTrack && artwork == _usageArtwork) return;
    _usageForTrack = track?.id;
    _usageArtwork = artwork;
    _usage = null;
    _audioCacheHit = null;
    if (track != null) {
      unawaited(_loadUsage(track));
      unawaited(_loadAudioCache(track));
    }
  }

  /// 完整音频缓存探测（缓存 = 已下载）：随曲目 / 缓存变更刷新状态行。
  Future<void> _loadAudioCache(Track? track) async {
    final downloads = context.read<DownloadService?>();
    if (downloads == null || track == null) {
      if (_audioCacheHit != null && mounted) {
        setState(() => _audioCacheHit = null);
      }
      return;
    }
    try {
      final hit = await downloads.audioCacheFor(track);
      if (!mounted || _usageForTrack != track.id) return;
      if (hit == _audioCacheHit) return;
      setState(() => _audioCacheHit = hit);
    } catch (_) {
      // 探测失败按「未缓存」呈现。
    }
  }

  Future<void> _loadUsage(Track? track) async {
    final service = _cacheService;
    if (service == null || track == null) return;
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
    final commentsSupported = context.select<CommentsProvider?, bool>(
      (provider) => track == null ? false : (provider?.supports(track) ?? false),
    );
    // 专辑行：payload 有专辑 id 且渠道能力位为真时可点（否则保持只读信息行）。
    final sourceRegistry = context.watch<SourceRegistry?>();
    final albumSupported = track != null &&
        platformAlbumId(track) != null &&
        (sourceRegistry
                ?.byKey(track.id.sourceKey)
                ?.capabilities
                .collection ??
            false);
    // 歌手行：曲目带歌手 id（raw `_artists`）且渠道能力位为真时可点。
    final artistRef = track == null ? null : platformArtistOf(track);
    final artistNames = track == null
        ? ''
        : track.artists
            .map((artist) => artist.name)
            .where((name) => name.isNotEmpty)
            .join('、');
    final artistSupported = artistRef != null &&
        (sourceRegistry
                ?.byKey(track!.id.sourceKey)
                ?.capabilities
                .artist ??
            false);
    final lyricsProviderName = context.select<LyricsProvider, String?>(
      (provider) =>
          track != null && provider.state.trackId == track.id.uri
              ? provider.state.providerName
              : null,
    );
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
    final downloadService = context.read<DownloadService?>();

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
          // 操作：曲目动作 + 与曲目无关的播放控制（空态也保留定时关闭）。
          SettingsSectionCard(
            children: [
              if (track != null)
                SettingsNavTile(
                  key: const Key('trackInfoCommentsItem'),
                  icon: Icons.comment_rounded,
                  title: l10n.commentsTitle,
                  subtitle: commentsSupported
                      ? l10n.trackActionCommentsSubtitle
                      : l10n.commentsUnsupported,
                  onTap: commentsSupported
                      ? () => unawaited(openTrackComments(context, track: track))
                      : null,
                ),
              // 定时关闭：与曲目无关的播放控制（队列播完后仍可取消）。
              ValueListenableBuilder<SleepTimerState>(
                valueListenable: context.read<PlaybackProvider>().sleepTimer,
                builder: (context, timerState, _) => SettingsNavTile(
                  key: const Key('trackInfoSleepTimerItem'),
                  icon: Icons.bedtime_rounded,
                  title: l10n.sleepTimerTitle,
                  subtitle: sleepTimerStatusLabel(l10n, timerState),
                  onTap: () => showSleepTimerSheet(context),
                ),
              ),
              // 本地下载曲目：文件是持久副本，不提供「换源」入口
              // （自动换源也已跳过）。
              if (track != null && track.id.sourceKey != kLocalSourceKey)
                SettingsNavTile(
                  key: const Key('trackInfoSourceSwapItem'),
                  icon: Icons.swap_horiz_rounded,
                  title: l10n.sourceSwap,
                  subtitle: l10n.trackActionSwapSubtitle,
                  onTap: () => unawaited(
                    openTrackSourceSwap(
                      context,
                      track: track,
                      initialTab: SourceSwapTab.audio,
                    ),
                  ),
                ),
            ],
          ),
          if (track == null) ...[
            const SizedBox(height: kSettingsSectionSpacing),
            _buildEmptyState(l10n),
          ] else ...[
            const SizedBox(height: kSettingsSectionSpacing),
            // 下载：单行入口（音质选择 / 歌词 / 封面在弹层内）。
            SettingsSectionCard(
              children: [
                SettingsNavTile(
                  key: const Key('trackInfoDownloadItem'),
                  icon: Icons.download_rounded,
                  title: l10n.downloadSection,
                  subtitle: _downloadSubtitle(
                    l10n,
                    track,
                    downloadRecord,
                    downloadProgress,
                  ),
                  onTap: downloadService == null
                      ? null
                      : () => unawaited(
                            showDownloadSheet(context, track: track),
                          ),
                ),
              ],
            ),
            const SizedBox(height: kSettingsSectionSpacing),
            // 信息：音质 / 可用音质 / 专辑 / 来源 / 歌词来源。
            SettingsSectionCard(
              children: [
                SettingsInfoTile(
                  icon: Icons.graphic_eq_rounded,
                  title: l10n.trackInfoQuality,
                  subtitle: (dataSaver?.active ?? false)
                      ? '${sourceQualityLabel(l10n, qualityType)} · '
                          '${l10n.settingsDataSaverTitle}'
                      : sourceQualityLabel(l10n, qualityType),
                ),
                SettingsInfoTile(
                  icon: Icons.high_quality_rounded,
                  title: l10n.trackInfoQualityAvailable,
                  subtitle: _availableQualitiesLabel(l10n, track),
                ),
                if (artistNames.isNotEmpty)
                  artistSupported
                      ? SettingsNavTile(
                          key: const Key('trackInfoArtistItem'),
                          icon: Icons.person_rounded,
                          title: l10n.trackInfoArtist,
                          subtitle:
                              '$artistNames · ${l10n.trackInfoArtistOpen}',
                          onTap: () => unawaited(
                              openTrackArtist(context, track: track)),
                        )
                      : SettingsInfoTile(
                          icon: Icons.person_rounded,
                          title: l10n.trackInfoArtist,
                          subtitle: artistNames,
                        ),
                if ((track.album ?? '').isNotEmpty)
                  albumSupported
                      ? SettingsNavTile(
                          key: const Key('trackInfoAlbumItem'),
                          icon: Icons.album_rounded,
                          title: l10n.trackInfoAlbum,
                          subtitle:
                              '${track.album!} · ${l10n.trackInfoAlbumOpen}',
                          onTap: () =>
                              unawaited(openTrackAlbum(context, track: track)),
                        )
                      : SettingsInfoTile(
                          icon: Icons.album_rounded,
                          title: l10n.trackInfoAlbum,
                          subtitle: track.album!,
                        ),
                SettingsNavTile(
                  key: const Key('trackInfoSourceItem'),
                  icon: Icons.hub_rounded,
                  title: l10n.trackInfoSource,
                  subtitle: _sourceSubtitle(l10n, sources, track),
                  onTap: () =>
                      unawaited(showTrackShareSheet(context, track: track)),
                ),
                SettingsInfoTile(
                  icon: Icons.lyrics_rounded,
                  title: l10n.trackInfoLyricsSource,
                  subtitle: lyricsProviderName == null
                      ? l10n.trackInfoLyricsSourceNone
                      : lyricsProviderLabel(
                          l10n,
                          sources?.channels ?? const [],
                          lyricsProviderName,
                        ),
                ),
              ],
            ),
            const SizedBox(height: kSettingsSectionSpacing),
            // 缓存：单行入口（四项占用与逐项清理在子页）。
            SettingsSectionCard(
              children: [
                SettingsNavTile(
                  key: const Key('trackInfoCacheItem'),
                  icon: Icons.storage_rounded,
                  title: l10n.trackInfoCacheSection,
                  subtitle: _usage == null
                      ? l10n.cacheUsageComputing
                      : trackCacheSummaryLabel(l10n, _usage!),
                  onTap: () =>
                      unawaited(showTrackCachePage(context, track: track)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 下载行副标题：已下载（大小 · 音质）/ 缓存命中（大小 · 音质 · 缓存副本）/
  /// 下载中百分比 / 未下载。
  String _downloadSubtitle(
    AppLocalizations l10n,
    Track track,
    DownloadedTrack? record,
    DownloadProgress? progress,
  ) {
    if (record != null) {
      if (!record.hasAudio) {
        // 只有歌词 / 封面：音频未下载，副标题列出已下载的附加项。
        final parts = <String>[
          if (record.hasLyrics) l10n.lyricsTitle,
          if (record.hasCover) l10n.downloadCoverPart,
        ];
        return parts.isEmpty ? l10n.downloadStatusNotDownloaded : parts.join(' · ');
      }
      final quality = record.quality.isEmpty
          ? ''
          : sourceQualityLabel(l10n, record.quality);
      return quality.isEmpty
          ? record.sizeLabel
          : '${record.sizeLabel} · $quality';
    }
    final cached = _audioCacheHit;
    if (cached != null) {
      final quality = cached.quality.isEmpty || cached.quality == 'auto'
          ? ''
          : sourceQualityLabel(l10n, cached.quality);
      final size = formatCacheBytes(cached.sizeBytes);
      return quality.isEmpty
          ? '$size · ${l10n.downloadStatusCachedCopy}'
          : '$size · $quality · ${l10n.downloadStatusCachedCopy}';
    }
    if (progress != null) {
      final percent = progress.percent;
      return percent == null
          ? '${l10n.downloadStatusDownloading} · '
              '${formatCacheBytes(progress.receivedBytes)}'
          : '${l10n.downloadStatusDownloading} · '
              '${l10n.downloadProgressPercent(percent)}';
    }
    if (track.id.sourceKey == kLocalSourceKey) {
      return l10n.downloadFileMissing;
    }
    return l10n.downloadStatusNotDownloaded;
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

  /// 来源行副标题：`渠道名 · {sourceKey}:{id}`（渠道查不到时回退 key）。
  String _sourceSubtitle(
    AppLocalizations l10n,
    SourcesProvider? sources,
    Track track,
  ) {
    final key = track.id.sourceKey;
    final channel = key.isEmpty
        ? l10n.trackInfoChannelUnknown
        : key == kLocalSourceKey
            ? l10n.downloadSourceLocal
            : sourceChannelName(sources?.channels ?? const [], key);
    final id = track.id.uri;
    return id.isEmpty ? channel : '$channel · $id';
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
}
