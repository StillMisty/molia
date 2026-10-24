import 'dart:async';

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
import '../services/data_saver_service.dart';
import '../services/download/download_service.dart';
import '../services/track_local_data_service.dart';
import '../theme/m3e_context.dart';
import '../utils/lyrics_provider_label.dart';
import '../utils/source_label.dart';
import '../utils/source_quality_label.dart';
import '../utils/track_local_data_label.dart';
import 'settings/settings_tiles.dart';
import 'sleep_timer_sheet.dart';
import 'track_actions.dart';
import 'track_share_sheet.dart';

/// 播放页第三个 tab：当前曲目操作 + 信息 + 本地数据入口。
///
/// 段落顺序（按使用频度）：**操作**（评论 / 定时关闭 / 换源）→ **本地数据**
/// （单行入口 → 两档状态 / 占用 / 下载转存与清理）→ **信息**（音质 / 可用音质 /
/// 专辑 / 来源 / 歌词来源）。
///
/// 口径说明：
/// - 音质显示的是**本次请求音质**（偏好音质 × 曲目可用列表 × 省流上限 =
///   `PlaybackProvider.currentQualityType`，展示名本地化）；取链接口不返回
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
  CacheService? _cacheServiceRevision;
  DownloadService? _downloads;

  /// 当前已加载本地数据的曲目；用于切歌重载与过期结果丢弃。
  TrackId? _dataForTrack;

  /// 本地数据对应的封面地址（封面补取回写曲目后需重算封面占用）。
  String? _dataArtwork;

  TrackLocalData? _localData;
  bool _listening = false;

  /// 下载进度触发的本地数据重算防抖。
  ///
  /// 进度通知每秒可达数十次，而一次重算要递归列音频缓存目录并统计每个
  /// 文件；300ms 窗口把同一批进度合并成一次扫描。
  static const Duration _reloadDebounce = Duration(milliseconds: 300);
  Timer? _reloadTimer;

  /// 本地数据加载单飞：加载中再收到请求只补跑一次（用最新当前曲目）。
  bool _loadInFlight = false;
  bool _loadQueued = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _localDataService = context.read<TrackLocalDataService?>();
    _cacheServiceRevision =
        context.read<CacheService?>() ?? CacheService.instance;
    final downloads = context.read<DownloadService?>();
    if (!identical(_downloads, downloads)) {
      _downloads?.removeListener(_onDownloadProgress);
      _downloads = downloads;
      downloads?.addListener(_onDownloadProgress);
    }
    if (!_listening) {
      _listening = true;
      _cacheServiceRevision?.revision.addListener(_onLocalDataChanged);
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
    _downloads?.removeListener(_onDownloadProgress);
    if (_listening) {
      _cacheServiceRevision?.revision.removeListener(_onLocalDataChanged);
    }
    _cancelReloadTimer();
    _loadQueued = false;
    super.dispose();
  }

  /// 下载进度 / 完成 / 删除：防抖后重算，避免逐分片扫缓存目录。
  void _onDownloadProgress() {
    if (!mounted) return;
    _reloadTimer?.cancel();
    _reloadTimer = Timer(_reloadDebounce, () {
      _reloadTimer = null;
      unawaited(_requestLocalDataReload());
    });
  }

  /// 缓存修订等即时变化：丢弃待执行的防抖，立即重算。
  void _onLocalDataChanged() {
    if (!mounted) return;
    _cancelReloadTimer();
    unawaited(_requestLocalDataReload());
  }

  void _cancelReloadTimer() {
    _reloadTimer?.cancel();
    _reloadTimer = null;
  }

  /// 本地数据加载单飞 + 尾随一次：并发触发不叠加磁盘扫描。
  ///
  /// 加载期间收到的请求只记一个标记；当前加载结束后按最新当前曲目补跑
  /// 一次。切歌时在途结果由 [_loadLocalData] 的过期守卫丢弃。
  Future<void> _requestLocalDataReload() async {
    if (_loadInFlight) {
      _loadQueued = true;
      return;
    }
    _loadInFlight = true;
    try {
      do {
        _loadQueued = false;
        if (!mounted) return;
        final track = _playback?.snapshot.current;
        if (track != null) await _loadLocalData(track);
      } while (_loadQueued && mounted);
    } finally {
      _loadInFlight = false;
    }
  }

  /// 切歌（含自动连播）时重载本地数据；封面补取回写（同 id、换封面）也重算。
  void _syncTrack() {
    final track = _playback?.snapshot.current;
    final artwork = track?.artwork?.uri.toString();
    if (track?.id == _dataForTrack && artwork == _dataArtwork) return;
    // 切歌 / 封面变化要立即看到新曲目的本地数据：丢弃进度触发的防抖。
    _cancelReloadTimer();
    _dataForTrack = track?.id;
    _dataArtwork = artwork;
    // 下载档同步种子：避免首帧把「已下载」闪成「未下载」。
    _localData = track == null ? null : _localDataService?.downloadState(track);
    if (track != null) unawaited(_requestLocalDataReload());
  }

  Future<void> _loadLocalData(Track? track) async {
    final service = _localDataService;
    if (service == null || track == null) return;
    try {
      final data = await service.load(track);
      if (!mounted || _dataForTrack != track.id) return;
      setState(() => _localData = data);
    } catch (_) {
      // 占用查询失败按「无缓存」呈现；清理本身仍可尝试。
      if (!mounted || _dataForTrack != track.id) return;
      setState(() => _localData = _localDataService?.downloadState(track));
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
    // 歌手行：能力位为真且能定位歌手时可点——优先 raw 歌手 id，历史数据
    // （无 id）按歌手名回退解析（见 track_actions.openTrackArtist）。
    final artistNames = track?.artistLabel ?? '';
    final artistSupported = track != null &&
        trackHasArtistEntry(track) &&
        (sourceRegistry
                ?.byKey(track.id.sourceKey)
                ?.capabilities
                .artist ??
            false);
    final lyricsProviderName = context.select<LyricsProvider, String?>(
      (provider) =>
          track != null && provider.state.trackId == track.id.uri
              ? provider.state.providerName
              : null,
    );

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
            // 本地数据：单行入口（两档状态 / 音质选择 / 转存与清理在页内）。
            SettingsSectionCard(
              children: [
                SettingsNavTile(
                  key: const Key('trackInfoLocalDataItem'),
                  icon: Icons.storage_rounded,
                  title: l10n.localDataTitle,
                  subtitle: _localData == null
                      ? l10n.cacheUsageComputing
                      : trackLocalDataSummaryLabel(
                          l10n,
                          _localData!,
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
            style: context.typeScale.bodyMedium.copyWith(
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
