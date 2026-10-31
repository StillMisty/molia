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
import '../services/download/download_manager.dart';
import '../services/download/download_queue.dart';
import '../services/download/download_records.dart';
import '../services/haptics.dart';
import '../services/notification_service.dart';
import '../services/save_as.dart';
import '../services/track_local_data_controller.dart';
import '../services/track_local_data_service.dart';
import '../theme/m3e_context.dart';
import '../utils/download_failure_label.dart';
import '../utils/download_task_label.dart';
import '../utils/responsive.dart';
import '../utils/source_quality_label.dart';
import '../utils/track_local_data_label.dart';
import '../widgets/detail_page/detail_page_chrome.dart';
import '../widgets/download_data_saver_guard.dart';
import '../widgets/settings/settings_tiles.dart';

/// 打开「本地数据」页（歌曲信息页唯一入口）。
Future<void> showTrackLocalDataPage(
  BuildContext context, {
  required Track track,
}) {
  return ResponsiveNavigation.showSecondaryPage<void>(
    context: context,
    title: AppLocalizations.of(context)!.localDataTitle,
    body: TrackLocalDataPage(track: track, embedded: true),
    preferredMode: SecondaryPageMode.sideSheet,
  );
}

@visibleForTesting
class TrackLocalDataPage extends StatefulWidget {
  const TrackLocalDataPage({
    super.key,
    required this.track,
    this.embedded = false,
  });

  final Track track;

  /// 作为二级页正文挂进外层 chrome（侧边弹层 / 全屏路由的 AppBar）时为
  /// true：不再自带 Scaffold + AppBar，避免双层标题栏。
  final bool embedded;

  @override
  State<TrackLocalDataPage> createState() => _TrackLocalDataPageState();
}

class _TrackLocalDataPageState extends State<TrackLocalDataPage> {
  static const List<LocalCachePart> _cacheParts = LocalCachePart.values;

  TrackLocalDataService? _service;
  CacheService? _cacheService;
  DownloadRecords? _records;
  DownloadManager? _downloads;

  /// 本地数据的监听 / 防抖 / 单飞 / 切歌守卫在这里，与信息页共用同一套语义。
  TrackLocalDataController? _controller;

  /// 当前曲目的音频任务（排队 / 运行 / 失败）：进度只订阅它，不整页扫盘。
  DownloadTask? _task;
  bool _busy = false;

  /// 当前选中的下载音质（缺省 = 偏好音质 × 曲目可用音质，命中缓存优先）。
  String? _quality;

  bool _listening = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final service = context.read<TrackLocalDataService?>();
    final cacheService = context.read<CacheService?>() ?? CacheService.instance;
    final records = context.read<DownloadRecords?>();
    if (_controller == null ||
        !identical(_service, service) ||
        !identical(_cacheService, cacheService) ||
        !identical(_records, records)) {
      _controller?.dispose();
      _service = service;
      _cacheService = cacheService;
      _records = records;
      _controller = TrackLocalDataController(
        service: service,
        cacheService: cacheService,
        downloadRecords: records,
      );
    }
    // 页面始终绑定一首曲目：构造后立即加载（控制器内部单飞 / 去重）。
    _controller!.setTrack(widget.track);

    final downloads = context.read<DownloadManager?>();
    if (!identical(_downloads, downloads)) {
      if (_listening) _downloads?.taskChanges.removeListener(_onTasksChanged);
      _downloads = downloads;
      _task = null;
      if (_listening) downloads?.taskChanges.addListener(_onTasksChanged);
    }
    if (!_listening) {
      _listening = true;
      _downloads?.taskChanges.addListener(_onTasksChanged);
    }
    _syncTask();
  }

  @override
  void didUpdateWidget(covariant TrackLocalDataPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track == widget.track) return;
    // 同一页面实例换曲目（测试 / 复用）：旧音质选择不再适用。
    _quality = null;
    _controller?.setTrack(widget.track);
    _syncTask();
  }

  @override
  void dispose() {
    if (_listening) {
      _downloads?.taskChanges.removeListener(_onTasksChanged);
    }
    _controller?.dispose();
    super.dispose();
  }

  /// 任务结构变化（入队 / 完成 / 失败 / 取消）：切换音频区订阅的任务。
  void _onTasksChanged() {
    if (!mounted) return;
    setState(_syncTask);
  }

  void _syncTask() {
    _task = _downloads?.taskForTrack(widget.track);
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

  /// 当前选中音质：顺序的唯一实现在 [selectLocalDataQuality]。
  String _selectedQualityFor(TrackLocalData? data) => selectLocalDataQuality(
    explicitChoice: _quality,
    downloadedQuality: data?.download?.quality ?? '',
    cachedQualities: data?.cachedQualities ?? const <String>[],
    preferredQuality: _downloads?.defaultQualityFor(widget.track) ?? '',
    availableQualities: _qualities,
  );

  /// 下载 / 转存音频（缓存命中时由下载服务直接拷贝，不触网）。
  ///
  /// 只入队，不占用整页 `_busy`：任务进度经 [DownloadTask] 单独更新，页面
  /// 在排队 / 下载期间仍可操作。省流生效时先确认。
  Future<void> _downloadAudio() async {
    final downloads = _downloads;
    if (downloads == null) return;
    final l10n = AppLocalizations.of(context)!;
    if (!await confirmDownloadOnDataSaver(context) || !mounted) return;
    final quality = _selectedQualityFor(_controller?.value.data);
    await _runDownload(
      () => downloads.download(
        widget.track,
        quality: quality.isEmpty ? null : quality,
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
    if (!await confirmDownloadOnDataSaver(context) || !mounted) return;
    await _runDownload(
      () => lyrics
          ? downloads.downloadLyrics(widget.track)
          : downloads.downloadCover(widget.track),
      done: lyrics ? l10n.downloadLyricsDone : l10n.downloadCoverDone,
    );
  }

  /// 等待任务结果并提示；页面不锁，进度 / 状态由任务监听驱动。
  Future<void> _runDownload(
    Future<void> Function() action, {
    required String done,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    HapticsService.lightImpact();
    try {
      await action();
      if (!mounted) return;
      _showMessage(done);
      await _controller?.refreshNow();
    } on SourceFailure catch (failure) {
      if (!mounted || failure.kind == FailureKind.cancelled) return;
      _showMessage(downloadFailureLabel(l10n, failure));
    } catch (e) {
      if (mounted) _showMessage(l10n.downloadFailed(e.toString()));
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
    final navigator = Navigator.of(context, rootNavigator: true);
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
            onPressed: () => navigator.pop(false),
            child: Text(l10n.cancel),
          ),
          M3EButton.filled(
            onPressed: () => navigator.pop(true),
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
      if (mounted) await _controller?.refreshNow();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 分享导出音频文件（桌面端为分享 / 另存入口）。
  Future<void> _share(DownloadedTrack record) async {
    final path = record.filePath;
    if (path == null || path.isEmpty || _busy) return;
    final l10n = AppLocalizations.of(context)!;
    final saveAs = context.read<SaveAs?>();
    try {
      await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
    } catch (_) {
      // Linux 的 share_plus 不支持文件分享：文件本来就在另存目录，直接
      // 打开所在文件夹并说明位置。
      await saveAs?.reveal(path);
      if (!mounted) return;
      _showMessage(l10n.fileInDownloads(path));
    }
  }

  Future<void> _clearCache(LocalCachePart part) async {
    final service = _service;
    if (service == null || _busy) return;
    final l10n = AppLocalizations.of(context)!;
    final navigator = Navigator.of(context, rootNavigator: true);
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.trackCacheClearConfirm(localDataPartLabel(l10n, part)),
        content: Text(l10n.trackCacheClearHint),
        actions: [
          M3EButton.text(
            onPressed: () => navigator.pop(false),
            child: Text(l10n.cancel),
          ),
          M3EButton.filled(
            onPressed: () => navigator.pop(true),
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
      await _controller?.refreshNow();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearAllCache() async {
    final service = _service;
    if (service == null || _busy) return;
    final l10n = AppLocalizations.of(context)!;
    final navigator = Navigator.of(context, rootNavigator: true);
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.trackCacheClearAll,
        content: Text(l10n.trackCacheClearAllConfirm),
        actions: [
          M3EButton.text(
            onPressed: () => navigator.pop(false),
            child: Text(l10n.cancel),
          ),
          M3EButton.filled(
            onPressed: () => navigator.pop(true),
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
      await _controller?.refreshNow();
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
    return ValueListenableBuilder<TrackLocalDataState>(
      valueListenable: _controller!,
      builder: (context, localData, _) {
        final data = localData.data;
        final horizontal = detailPageHorizontalPadding(context);
        final body = ListView(
          padding: EdgeInsets.fromLTRB(horizontal, 0, horizontal, 24),
          children: [
            // 曲目身份条取代原来的单行信息卡：与评论 / 换源页共用同一形态。
            DetailPageTrackHeader(
              track: widget.track,
              padding: const EdgeInsets.only(top: 12, bottom: 8),
            ),
            const SizedBox(height: kSettingsSectionSpacing),
            _buildAudioSectionWidget(l10n, data, localData.audioEnabled),
            const SizedBox(height: kSettingsSectionSpacing),
            _buildExtrasSection(l10n, data),
            const SizedBox(height: kSettingsSectionSpacing),
            _buildCacheSection(l10n, data, localData.audioEnabled),
          ],
        );
        if (widget.embedded) return body;
        return Scaffold(
          appBar: M3EAppBar.top(
            title: Text(l10n.localDataTitle),
            automaticallyImplyLeading: true,
          ),
          body: body,
        );
      },
    );
  }

  /// 音频区只订阅当前任务：进度 / 状态变化不重建整页（缓存占用等）。
  Widget _buildAudioSectionWidget(
    AppLocalizations l10n,
    TrackLocalData? data,
    bool audioEnabled,
  ) {
    final task = _task;
    if (task == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _buildAudioSection(l10n, data, null, audioEnabled),
      );
    }
    return ListenableBuilder(
      listenable: task,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _buildAudioSection(l10n, data, _task, audioEnabled),
      ),
    );
  }

  List<Widget> _buildAudioSection(
    AppLocalizations l10n,
    TrackLocalData? data,
    DownloadTask? task,
    bool audioEnabled,
  ) {
    final downloads = _downloads;
    final qualities = _qualities;
    final selected = _selectedQualityFor(data);
    final state = data?.audioState ?? LocalPartState.none;
    final downloaded = state == LocalPartState.downloaded;
    final supported = downloads != null && downloads.supported;
    final active = task?.isActive ?? false;
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
              onTap: downloaded
                  ? null
                  : () => setState(() => _quality = quality),
            ),
          SettingsInfoTile(
            key: const Key('localDataAudioStatus'),
            icon: switch (state) {
              LocalPartState.downloaded => Icons.download_done_rounded,
              LocalPartState.cached => Icons.offline_pin_rounded,
              LocalPartState.none =>
                active ? Icons.downloading_rounded : Icons.download_rounded,
            },
            title: localPartStateLabel(l10n, state),
            subtitle: _audioSubtitle(l10n, data, task, audioEnabled),
          ),
          ..._buildAudioActions(l10n, data, task, supported),
        ],
      ),
    ];
  }

  /// 音频状态副标题：下载（体积 · 音质）/ 等待中 / 下载中（百分比）/
  /// 失败原因 / 缓存（体积 · 音质 · 可离线使用）/ 未下载（平台 / 开关说明）。
  String _audioSubtitle(
    AppLocalizations l10n,
    TrackLocalData? data,
    DownloadTask? task,
    bool audioEnabled,
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
    // 排队 / 下载 / 失败：任务状态优先于缓存说明，进度不能藏起来。
    if (task != null) return downloadTaskStatusLabel(l10n, task);
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
    if (!audioEnabled) return l10n.cacheAudioDisabled;
    return l10n.downloadStatusNotDownloaded;
  }

  /// 音频动作行：按两档状态给出下载 / 转存 / 取消 / 分享 / 删除。
  ///
  /// 排队中与下载中都可取消；失败后回落到「下载」动作（重新入队），
  /// 失败原因在状态副标题里说明。
  List<Widget> _buildAudioActions(
    AppLocalizations l10n,
    TrackLocalData? data,
    DownloadTask? task,
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
    if (task?.isActive ?? false) {
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
              LocalPartState.none =>
                downloads == null
                    ? l10n.downloadStatusNotDownloaded
                    : l10n.downloadAction,
            },
            onTap:
                part.state == LocalPartState.downloaded ||
                    downloads == null ||
                    _busy
                ? null
                : () => unawaited(_downloadPart(lyrics: part.lyrics)),
          ),
      ],
    );
  }

  Widget _buildCacheSection(
    AppLocalizations l10n,
    TrackLocalData? data,
    bool audioEnabled,
  ) {
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
                : _cachePartSubtitle(l10n, part, data, audioEnabled),
            trailing: M3EIconButton(
              variant: M3EIconButtonVariant.standard,
              icon: const Icon(Icons.delete_outline_rounded),
              semanticLabel: l10n.downloadPartRemove,
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
              style: context.typeScale.bodySmall.copyWith(
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
    bool audioEnabled,
  ) {
    final label = trackCacheUsageLabel(l10n, part, data);
    if (part != LocalCachePart.audio) return label;
    if (!audioEnabled) return l10n.cacheAudioDisabled;
    return label;
  }

  static IconData _cachePartIcon(LocalCachePart part) => switch (part) {
    LocalCachePart.audio => Icons.audiotrack_rounded,
    LocalCachePart.lyrics => Icons.lyrics_rounded,
    LocalCachePart.artwork => Icons.image_rounded,
    LocalCachePart.resolveUrl => Icons.link_rounded,
  };
}
