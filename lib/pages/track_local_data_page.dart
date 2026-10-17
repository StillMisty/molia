/// 「本地数据」页：单曲在本机的两档数据（已下载 / 已缓存）唯一入口。
///
/// 为什么是一个页面（而不是「下载」弹层 + 「缓存」子页两个面）：
/// 两档数据读的是同一批后端（音频目录 / 歌词 prefs / 封面 cache manager /
/// 内存取链 / drift 下载记录），拆成两个入口必然出现两套口径（缓存面说命中、
/// 下载面说没有）。合并后一个页面同时回答「本机有什么」（状态）与「占了多少、
/// 能清什么」（占用与动作）。
///
/// 分档口径（唯一出处 `TrackLocalDataService` / [LocalPartState]）：
/// - **已下载**：持久副本，可分享、清缓存不影响；
/// - **已缓存**：易失副本，可离线播放，动作是「转存」（拷贝成持久副本，
///   不触网）或清理；
/// - **未下载**：两档都没有，动作是下载。
library;

import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../domain/models/download.dart';
import '../domain/models/failure.dart';
import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../services/audio_cache_platform.dart';
import '../services/cache_service.dart';
import '../services/data_saver_service.dart';
import '../services/download/download_service.dart';
import '../services/haptics.dart';
import '../services/notification_service.dart';
import '../services/track_local_data_service.dart';
import '../utils/download_failure_label.dart';
import '../utils/responsive.dart';
import '../utils/source_quality_label.dart';
import '../utils/track_local_data_label.dart';
import '../widgets/settings/settings_tiles.dart';

/// 打开「本地数据」页（歌曲信息页唯一入口）。
Future<void> showTrackLocalDataPage(
  BuildContext context, {
  required Track track,
}) {
  return ResponsiveNavigation.showSecondaryPage<void>(
    context: context,
    child: TrackLocalDataPage(track: track),
    preferredMode: SecondaryPageMode.sideSheet,
    maxWidth: 520,
    showCloseButton: false,
  );
}

@visibleForTesting
class TrackLocalDataPage extends StatefulWidget {
  const TrackLocalDataPage({super.key, required this.track});

  final Track track;

  @override
  State<TrackLocalDataPage> createState() => _TrackLocalDataPageState();
}

class _TrackLocalDataPageState extends State<TrackLocalDataPage> {
  static const List<LocalCachePart> _cacheParts = LocalCachePart.values;

  TrackLocalDataService? _service;
  CacheService? _cacheService;
  DownloadService? _downloads;
  TrackLocalData? _data;
  bool _busy = false;

  /// 音频缓存开关（关闭时音频行给出状态说明）。
  bool _audioEnabled = true;

  /// 当前选中的下载音质（缺省 = 偏好音质 × 曲目可用音质，命中缓存优先）。
  String? _quality;

  bool _listening = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _service = context.read<TrackLocalDataService?>();
    _downloads = context.read<DownloadService?>();
    _cacheService = context.read<CacheService?>() ?? CacheService.instance;
    _data ??= _service?.downloadState(widget.track);
    if (!_listening) {
      _listening = true;
      // 缓存内容（清缓存 / LRU / 边播边缓存落成）与下载记录（转存 / 删除 /
      // 进度落库）任一变化都重算本页状态。
      _cacheService?.revision.addListener(_onChanged);
      _downloads?.addListener(_onChanged);
      unawaited(_reload());
    }
  }

  @override
  void dispose() {
    if (_listening) {
      _cacheService?.revision.removeListener(_onChanged);
      _downloads?.removeListener(_onChanged);
    }
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final service = _service;
    if (service == null) return;
    try {
      final results = await Future.wait([
        service.load(widget.track),
        _cacheService?.audioEnabled() ?? Future.value(true),
      ]);
      if (!mounted) return;
      setState(() {
        _data = results[0] as TrackLocalData;
        _audioEnabled = results[1] as bool;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _data = _service?.downloadState(widget.track));
    }
  }

  /// 可选音质（LX 标识，去重保序）。
  List<String> get _qualities {
    final types = <String>[];
    for (final quality in widget.track.qualities) {
      final type = quality.type;
      if (type.isNotEmpty && !types.contains(type)) types.add(type);
    }
    return types;
  }

  /// 当前选中音质：显式选择 → 已下载记录的音质 → 命中缓存的音质 →
  /// 偏好音质 → 首个可用音质。
  String get _selectedQuality {
    final explicit = _quality;
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final data = _data;
    final downloadedQuality = data?.download?.quality ?? '';
    if (downloadedQuality.isNotEmpty) return downloadedQuality;
    if (data != null && data.cachedQualities.isNotEmpty) {
      return data.cachedQualities.first;
    }
    final preferred = _downloads?.defaultQualityFor(widget.track) ?? '';
    if (preferred.isNotEmpty) return preferred;
    final qualities = _qualities;
    return qualities.isEmpty ? '' : qualities.first;
  }

  /// 下载 / 转存音频（缓存命中时由 `DownloadService` 直接拷贝，不触网）。
  Future<void> _downloadAudio() async {
    final downloads = _downloads;
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
    await _runDownload(
      () => downloads.download(
        widget.track,
        quality: _selectedQuality.isEmpty ? null : _selectedQuality,
        includeLyrics: true,
        includeCover: true,
      ),
      done: l10n.downloadCompleted,
    );
  }

  /// 单独下载 / 转存歌词或封面（缓存优先，同样不触网）。
  Future<void> _downloadPart({required bool lyrics}) async {
    final downloads = _downloads;
    if (downloads == null || _busy) return;
    final l10n = AppLocalizations.of(context)!;
    await _runDownload(
      () => lyrics
          ? downloads.downloadLyrics(widget.track)
          : downloads.downloadCover(widget.track),
      done: lyrics ? l10n.downloadLyricsDone : l10n.downloadCoverDone,
    );
  }

  Future<void> _runDownload(
    Future<void> Function() action, {
    required String done,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    HapticsService.lightImpact();
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
      _showMessage(done);
      await _reload();
    } on SourceFailure catch (failure) {
      if (!mounted || failure.kind == FailureKind.cancelled) return;
      _showMessage(downloadFailureLabel(l10n, failure));
    } catch (e) {
      if (mounted) _showMessage(l10n.downloadFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 取消进行中的下载。
  void _cancelDownload() {
    HapticsService.lightImpact();
    _downloads?.cancelTrack(widget.track);
  }

  /// 删除下载（确认后连歌词 / 封面一起删；不影响缓存）。
  Future<void> _deleteDownload(DownloadedTrack record) async {
    final downloads = _downloads;
    if (downloads == null || _busy) return;
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
    HapticsService.lightImpact();
    setState(() => _busy = true);
    try {
      await downloads.delete(record);
      if (mounted) await _reload();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 分享导出音频文件（桌面端为分享 / 另存入口）。
  Future<void> _share(DownloadedTrack record) async {
    final path = record.filePath;
    if (path == null || path.isEmpty || _busy) return;
    final l10n = AppLocalizations.of(context)!;
    try {
      await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
    } catch (_) {
      if (mounted) _showMessage(l10n.exportFailed);
    }
  }

  Future<void> _clearCache(LocalCachePart part) async {
    final service = _service;
    if (service == null || _busy) return;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.trackCacheClearConfirm(localDataPartLabel(l10n, part)),
        content: Text(l10n.trackCacheClearHint),
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
    HapticsService.lightImpact();
    setState(() => _busy = true);
    try {
      final result = await service.clear(widget.track, part);
      if (!mounted) return;
      _showMessage(trackCacheClearResultLabel(l10n, result));
      await _reload();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearAllCache() async {
    final service = _service;
    if (service == null || _busy) return;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.trackCacheClearAll,
        content: Text(l10n.trackCacheClearAllConfirm),
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
    HapticsService.lightImpact();
    setState(() => _busy = true);
    try {
      for (final part in _cacheParts) {
        await service.clear(widget.track, part);
      }
      if (!mounted) return;
      _showMessage(l10n.trackCacheClearAll);
      await _reload();
    } finally {
      if (mounted) setState(() => _busy = false);
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
    final data = _data;
    final progress = context.select<DownloadService?, DownloadProgress?>(
      (service) => service?.progressForTrack(widget.track),
    );
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.localDataTitle),
        automaticallyImplyLeading: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(kSettingsPadding),
        children: [
          SettingsSectionCard(
            children: [
              SettingsInfoTile(
                icon: Icons.music_note_rounded,
                title: widget.track.title,
                subtitle: widget.track.artistLabel,
              ),
            ],
          ),
          const SizedBox(height: kSettingsSectionSpacing),
          ..._buildAudioSection(l10n, data, progress),
          const SizedBox(height: kSettingsSectionSpacing),
          _buildExtrasSection(l10n, data),
          const SizedBox(height: kSettingsSectionSpacing),
          _buildCacheSection(l10n, data),
        ],
      ),
    );
  }

  List<Widget> _buildAudioSection(
    AppLocalizations l10n,
    TrackLocalData? data,
    DownloadProgress? progress,
  ) {
    final downloads = _downloads;
    final qualities = _qualities;
    final selected = _selectedQuality;
    final state = data?.audioState ?? LocalPartState.none;
    final downloaded = state == LocalPartState.downloaded;
    final supported = downloads != null && downloads.supported;
    return [
      SettingsSectionCard(
        title: l10n.downloadAudioSection,
        children: [
          for (final quality in qualities)
            M3EListItem(
              key: Key('localDataQuality_$quality'),
              leading: Icon(
                quality == selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
              ),
              headline: sourceQualityLabel(l10n, quality),
              trailingText: (data?.cachedQualities.contains(quality) ?? false)
                  ? l10n.downloadQualityCached
                  : null,
              selected: quality == selected,
              enabled: !downloaded,
              onTap:
                  downloaded ? null : () => setState(() => _quality = quality),
            ),
          SettingsInfoTile(
            key: const Key('localDataAudioStatus'),
            icon: switch (state) {
              LocalPartState.downloaded => Icons.download_done_rounded,
              LocalPartState.cached => Icons.offline_pin_rounded,
              LocalPartState.none => progress != null
                  ? Icons.downloading_rounded
                  : Icons.download_rounded,
            },
            title: localPartStateLabel(l10n, state),
            subtitle: _audioSubtitle(l10n, data, progress),
          ),
          ..._buildAudioActions(l10n, data, progress, supported),
        ],
      ),
    ];
  }

  /// 音频状态副标题：下载（体积 · 音质）/ 下载中（百分比）/ 缓存（体积 ·
  /// 音质 · 可离线使用）/ 未下载（平台 / 开关说明）。
  String _audioSubtitle(
    AppLocalizations l10n,
    TrackLocalData? data,
    DownloadProgress? progress,
  ) {
    if (data == null) return l10n.cacheUsageComputing;
    final record = data.download;
    if (data.audioState == LocalPartState.downloaded) {
      final quality = (record?.quality ?? '').isEmpty
          ? ''
          : sourceQualityLabel(l10n, record!.quality);
      return [
        record?.sizeLabel ?? '',
        if (quality.isNotEmpty) quality,
      ].where((part) => part.isNotEmpty).join(' · ');
    }
    // 下载 / 转存进行中（已有缓存时同样是「转存中」，进度不能藏起来）。
    if (progress != null) {
      final percent = progress.percent;
      return percent == null
          ? '${l10n.downloadStatusDownloading} · '
              '${formatCacheBytes(progress.receivedBytes)}'
          : '${l10n.downloadStatusDownloading} · '
              '${l10n.downloadProgressPercent(percent)}';
    }
    if (data.audioState == LocalPartState.cached) {
      final quality =
          data.cachedQualities.isEmpty || data.cachedQualities.first == 'auto'
              ? ''
              : sourceQualityLabel(l10n, data.cachedQualities.first);
      return [
        formatCacheBytes(data.audioCache.bytes),
        if (quality.isNotEmpty) quality,
        l10n.localDataOfflineAvailable,
      ].join(' · ');
    }
    if (data.audioWriting.count > 0) {
      return l10n.trackCacheAudioWriting(
        formatCacheBytes(data.audioWriting.bytes),
      );
    }
    if (widget.track.id.sourceKey == kLocalSourceKey) {
      return l10n.downloadFileMissing;
    }
    if (!platformSupportsAudioCaching()) {
      // 桌面：播放侧不写缓存（另有后台字节下载，见设置页说明）。
      return l10n.localDataAudioPlatformHint;
    }
    if (!_audioEnabled) return l10n.cacheAudioDisabled;
    return l10n.downloadStatusNotDownloaded;
  }

  /// 音频动作行：按两档状态给出下载 / 转存 / 取消 / 分享 / 删除。
  List<Widget> _buildAudioActions(
    AppLocalizations l10n,
    TrackLocalData? data,
    DownloadProgress? progress,
    bool supported,
  ) {
    final record = data?.download;
    if (record != null && record.hasAudio) {
      return [
        SettingsNavTile(
          key: const Key('localDataShare'),
          icon: Icons.ios_share_rounded,
          title: l10n.downloadShare,
          subtitle: '',
          onTap: _busy ? null : () => unawaited(_share(record)),
        ),
        SettingsNavTile(
          key: const Key('localDataDeleteDownload'),
          icon: Icons.delete_rounded,
          // 本地导入是就地引用：文案区分「删除下载」与「从列表移除」。
          title: record.imported ? l10n.localSongsRemove : l10n.downloadDelete,
          subtitle: '',
          isDestructive: true,
          onTap: _busy ? null : () => unawaited(_deleteDownload(record)),
        ),
      ];
    }
    if (progress != null) {
      return [
        SettingsNavTile(
          key: const Key('localDataCancel'),
          icon: Icons.close_rounded,
          title: l10n.downloadCancel,
          subtitle: '',
          isDestructive: true,
          onTap: _cancelDownload,
        ),
      ];
    }
    if (widget.track.id.sourceKey == kLocalSourceKey) return const [];
    final cached = data?.audioState == LocalPartState.cached;
    return [
      SettingsNavTile(
        key: const Key('localDataDownloadAudio'),
        icon: Icons.download_rounded,
        title: cached ? l10n.localDataTransferToFolder : l10n.downloadAction,
        subtitle: '',
        onTap: !supported || _busy ? null : () => unawaited(_downloadAudio()),
      ),
    ];
  }

  Widget _buildExtrasSection(AppLocalizations l10n, TrackLocalData? data) {
    final downloads = _downloads;
    final parts = [
      (
        state: data?.lyricsState ?? LocalPartState.none,
        title: l10n.lyricsTitle,
        icon: Icons.lyrics_rounded,
        key: const Key('localDataLyricsPart'),
        lyrics: true,
      ),
      (
        state: data?.artworkState ?? LocalPartState.none,
        title: l10n.downloadCoverPart,
        icon: Icons.image_rounded,
        key: const Key('localDataCoverPart'),
        lyrics: false,
      ),
    ];
    return SettingsSectionCard(
      title: l10n.downloadExtrasSection,
      children: [
        for (final part in parts)
          SettingsNavTile(
            key: part.key,
            icon: part.icon,
            title: part.title,
            subtitle: switch (part.state) {
              LocalPartState.downloaded => l10n.downloadStatusDownloaded,
              LocalPartState.cached => l10n.localDataTransferHint,
              LocalPartState.none => downloads == null
                  ? l10n.downloadStatusNotDownloaded
                  : l10n.downloadAction,
            },
            onTap: part.state == LocalPartState.downloaded ||
                    downloads == null ||
                    _busy
                ? null
                : () => unawaited(_downloadPart(lyrics: part.lyrics)),
          ),
      ],
    );
  }

  Widget _buildCacheSection(AppLocalizations l10n, TrackLocalData? data) {
    return SettingsSectionCard(
      title: l10n.localDataCacheSection,
      children: [
        for (final part in _cacheParts)
          M3EListItem(
            key: Key('localDataCache_${part.name}'),
            leading: Icon(_cachePartIcon(part)),
            headline: localDataPartLabel(l10n, part),
            supportingText: data == null
                ? l10n.cacheUsageComputing
                : _cachePartSubtitle(l10n, part, data),
            trailing: M3EIconButton(
              variant: M3EIconButtonVariant.standard,
              icon: const Icon(Icons.delete_outline_rounded),
              tooltip: l10n.downloadPartRemove,
              onPressed:
                  data == null || _busy || !_cachePartHasCache(part, data)
                      ? null
                      : () => unawaited(_clearCache(part)),
            ),
          ),
        if (data != null && !data.hasAnyCache)
          Padding(
            padding: const EdgeInsets.only(top: kSettingsSectionSpacing / 2),
            child: Text(
              l10n.trackCacheEmpty,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: kSettingsSectionSpacing / 2),
          child: M3EButton.icon(
            style: M3EButtonStyle.tonal,
            onPressed: data == null || _busy || !data.hasAnyCache
                ? null
                : _clearAllCache,
            icon: const Icon(Icons.delete_sweep_rounded),
            label: Text(l10n.trackCacheClearAll),
          ),
        ),
      ],
    );
  }

  bool _cachePartHasCache(LocalCachePart part, TrackLocalData data) =>
      switch (part) {
        LocalCachePart.audio => data.audioCache.count > 0,
        LocalCachePart.lyrics => data.lyricsCache.count > 0,
        LocalCachePart.artwork => data.artworkCache.count > 0,
        LocalCachePart.resolveUrl => data.resolveEntries > 0,
      };

  /// 单项副标题：命中「大小 · 条数」；音频分项按平台 / 开关如实说明。
  String _cachePartSubtitle(
    AppLocalizations l10n,
    LocalCachePart part,
    TrackLocalData data,
  ) {
    final label = trackCacheUsageLabel(l10n, part, data);
    if (part != LocalCachePart.audio) return label;
    if (!_audioEnabled) return l10n.cacheAudioDisabled;
    return label;
  }

  static IconData _cachePartIcon(LocalCachePart part) => switch (part) {
        LocalCachePart.audio => Icons.audiotrack_rounded,
        LocalCachePart.lyrics => Icons.lyrics_rounded,
        LocalCachePart.artwork => Icons.image_rounded,
        LocalCachePart.resolveUrl => Icons.link_rounded,
      };
}
