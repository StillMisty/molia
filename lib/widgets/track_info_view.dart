import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/download.dart';
import '../domain/models/track.dart';
import '../domain/ports/source_registry.dart';
import '../l10n/app_localizations.dart';
import '../pages/source_swap_page.dart';
import '../pages/track_local_data_page.dart';
import '../providers/comments_provider.dart';
import '../providers/lyrics_provider.dart';
import '../providers/playback_provider.dart';
import '../providers/sleep_timer.dart';
import '../providers/sources_provider.dart';
import '../services/cache_service.dart';
import '../services/covers/cover_resolution.dart';
import '../services/data_saver_service.dart';
import '../services/download/download_records.dart';
import '../services/track_local_data_controller.dart';
import '../services/track_local_data_service.dart';
import '../utils/lyrics_provider_label.dart';
import '../utils/source_label.dart';
import '../utils/source_quality_label.dart';
import '../utils/track_local_data_label.dart';
import 'empty_state.dart';
import 'settings/settings_tiles.dart';
import 'cover_picker_sheet.dart';
import 'cover_viewer.dart';
import 'track_artwork.dart';
import 'track_quality_sheet.dart';
import 'sleep_timer_sheet.dart';
import 'track_actions.dart';
import 'track_share_sheet.dart';

/// 播放页第三个 tab：当前曲目操作 + 信息 + 本地数据入口。
///
/// 段落顺序（按使用频度）：**操作**（评论 / 定时关闭 / 换源）→ **本地数据**
/// （单行入口 → 两档状态 / 占用 / 下载转存与清理）→ **信息**（音质 / 专辑 /
/// 来源 / 歌词来源）。
///
/// 口径说明：
/// - 音质行只显示**本次播放档位**（`PlaybackProvider.currentQualityType`，
///   展示名本地化）；点击后列出全部可用档位并支持切换。取链接口不返回
///   实际码率，因此不展示「实际音质」；
/// - 来源行合并「渠道 + 曲目 ID」，点击进分享 / 复制弹层；歌词来源只读；
/// - 「本地数据」页里缓存与下载是**两套东西**：清缓存永不触碰 `downloads/`，
///   已缓存可「转存」成持久下载（不触网）。
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
  TrackLocalDataService? _localDataService;
  CacheService? _cacheService;
  DownloadRecords? _downloads;

  /// 本地数据的监听 / 防抖 / 单飞 / 切歌守卫都在控制器里，两个消费面共用。
  TrackLocalDataController? _localDataController;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final service = context.read<TrackLocalDataService?>();
    final cacheService = context.read<CacheService?>() ?? CacheService.instance;
    final downloads = context.read<DownloadRecords?>();
    if (_localDataController == null ||
        !identical(_localDataService, service) ||
        !identical(_cacheService, cacheService) ||
        !identical(_downloads, downloads)) {
      _localDataController?.dispose();
      _localDataService = service;
      _cacheService = cacheService;
      _downloads = downloads;
      _localDataController = TrackLocalDataController(
        service: service,
        cacheService: cacheService,
        downloadRecords: downloads,
      );
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
    _localDataController?.dispose();
    super.dispose();
  }

  /// 切歌（含自动连播）与封面补取回写都会走到这里；控制器负责比对曲目 /
  /// 封面并决定是否立即重载。
  void _syncTrack() {
    _localDataController?.setTrack(_playback?.snapshot.current);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 订阅音质偏好（音源页）与省流开关（数据设置）：「本次播放音质」
    // 是二者的派生值，改完设置要立即刷新，不等下一次播放通知。
    final sources = context.watch<SourcesProvider?>();
    final dataSaver = context.watch<DataSaverService?>();
    final (track, qualityType) = context
        .select<PlaybackProvider, (Track?, String)>(
          (provider) =>
              (provider.snapshot.current, provider.currentQualityType),
        );
    // 恢复态（冷启动未起播）没有真实播放，音质行只读；手动切换覆盖省流
    // 上限时不再显示「省流模式」后缀。
    final restored = context.select<PlaybackProvider, bool>(
      (provider) => provider.hasRestoredSession,
    );
    final qualityOverridden = context.select<PlaybackProvider, bool>(
      (provider) => provider.isCurrentQualityOverridden,
    );
    final commentsSupported = context.select<CommentsProvider?, bool>(
      (provider) =>
          track == null ? false : (provider?.supports(track) ?? false),
    );
    // 专辑行：映射层派生了专辑 id 且渠道能力位为真时可点（否则保持只读信息行）。
    final sourceRegistry = context.watch<SourceRegistry?>();
    final albumSupported =
        track != null &&
        track.platformAlbumId != null &&
        (sourceRegistry?.byKey(track.id.sourceKey)?.capabilities.collection ??
            false);
    // 歌手行：能力位为真且曲目带平台歌手 id 时可点（脚本扩展源只读）。
    final artistNames = track?.artistLabel ?? '';
    final artistSupported =
        track != null &&
        platformArtistOf(track) != null &&
        (sourceRegistry?.byKey(track.id.sourceKey)?.capabilities.artist ??
            false);
    final lyricsProviderName = context.select<LyricsProvider, String?>(
      (provider) => track != null && provider.state.trackId == track.id.uri
          ? provider.state.providerName
          : null,
    );
    final hasQualities =
        track?.qualities.any((quality) => quality.type.isNotEmpty) ?? false;
    final qualityLabel = qualityType.isEmpty
        ? l10n.trackInfoQualityUnknown
        : sourceQualityLabel(l10n, qualityType);
    final dataSaverActive = dataSaver?.active ?? false;
    final showDataSaverHint = dataSaverActive && !qualityOverridden;

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
                      ? () =>
                            unawaited(openTrackComments(context, track: track))
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
            // 本地数据：单行入口（两档状态 / 音质选择 / 转存与清理在页内）。
            // 只订阅控制器状态，进度 / 记录变化不重建信息区其它行。
            ValueListenableBuilder<TrackLocalDataState>(
              valueListenable: _localDataController!,
              builder: (context, localData, _) => SettingsSectionCard(
                children: [
                  SettingsNavTile(
                    key: const Key('trackInfoLocalDataItem'),
                    icon: Icons.storage_rounded,
                    title: l10n.localDataTitle,
                    subtitle: localData.data == null
                        ? l10n.cacheUsageComputing
                        : trackLocalDataSummaryLabel(
                            l10n,
                            localData.data!,
                            localSource: track.id.sourceKey == kLocalSourceKey,
                          ),
                    onTap: _localDataService == null
                        ? null
                        : () => unawaited(
                            showTrackLocalDataPage(context, track: track),
                          ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: kSettingsSectionSpacing),
            // 信息：封面 / 音质（点开切换可用档位）/ 专辑 / 来源 / 歌词来源。
            SettingsSectionCard(
              children: [
                CoverChangeBuilder(
                  builder: (context, covers) {
                    final custom = covers.realOf(track).isCustom;
                    return SettingsNavTile(
                      key: const Key('trackInfoCoverItem'),
                      icon: Icons.image_rounded,
                      title: l10n.coverTitle,
                      subtitle: custom
                          ? l10n.coverCustomized
                          : l10n.coverFollowSong,
                      trailing: TrackArtwork(
                        track: track,
                        // 外层 CoverChangeBuilder 已经订阅，避免双监听。
                        listenForChanges: false,
                        size: 32,
                        borderRadius: M3EShapes.radiusSmall,
                        memCacheWidth:
                            (32 * MediaQuery.of(context).devicePixelRatio)
                                .round(),
                        fallbackIconSize: 16,
                      ),
                      onTap: () =>
                          unawaited(_openCover(context, track, covers, l10n)),
                    );
                  },
                ),
                // 音质：默认只显示本次档位，点开列出全部可用档位并切换。
                if (!hasQualities)
                  SettingsInfoTile(
                    icon: Icons.high_quality_rounded,
                    title: l10n.trackInfoQuality,
                    subtitle: l10n.trackInfoQualityUnknown,
                  )
                else if (restored)
                  SettingsInfoTile(
                    icon: Icons.high_quality_rounded,
                    title: l10n.trackInfoQuality,
                    subtitle: showDataSaverHint
                        ? '$qualityLabel · ${l10n.settingsDataSaverTitle}'
                        : qualityLabel,
                  )
                else
                  SettingsValueTile(
                    key: const Key('trackInfoQualityItem'),
                    icon: Icons.high_quality_rounded,
                    title: l10n.trackInfoQuality,
                    value: qualityLabel,
                    subtitle: showDataSaverHint
                        ? l10n.settingsDataSaverTitle
                        : null,
                    onTap: () => unawaited(
                      showTrackQualitySheet(
                        context,
                        track: track,
                        currentQuality: qualityType,
                      ),
                    ),
                  ),
                if (artistNames.isNotEmpty)
                  artistSupported
                      ? SettingsNavTile(
                          key: const Key('trackInfoArtistItem'),
                          icon: Icons.person_rounded,
                          title: l10n.trackInfoArtist,
                          subtitle:
                              '$artistNames · ${l10n.trackInfoArtistOpen}',
                          onTap: () =>
                              unawaited(openTrackArtist(context, track: track)),
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
          ],
        ],
      ),
    );
  }

  /// 封面行：有真实封面先看原图（查看器内可换封面）；没有真实封面时
  /// 保持原行为直接进封面选择弹层。
  Future<void> _openCover(
    BuildContext context,
    Track track,
    CoverResolver covers,
    AppLocalizations l10n,
  ) async {
    final url = covers.realOf(track).url;
    final fileNameBase = track.artistLabel.isEmpty
        ? track.title
        : '${track.title} - ${track.artistLabel}';
    if (url == null) {
      await showCoverPickerSheet(
        context,
        trackId: track.id,
        originalCoverUrl: track.artwork?.uri.toString(),
        fileNameBase: fileNameBase,
      );
      return;
    }
    final action = await showCoverViewer(
      context,
      coverUrl: url,
      title: l10n.coverLabel,
      subtitle: track.title,
      fileNameBase: fileNameBase,
      allowEdit: true,
    );
    if (!context.mounted || action != CoverViewerAction.editCover) return;
    await showCoverPickerSheet(
      context,
      trackId: track.id,
      originalCoverUrl: track.artwork?.uri.toString(),
      fileNameBase: fileNameBase,
    );
  }

  Widget _buildEmptyState(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 96),
      child: EmptyState(icon: Icons.info_rounded, message: l10n.trackInfoEmpty),
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
}
