/// Riverpod 与启动期实例之间的桥。
///
/// 迁移期组合根仍按顺序构造服务；这里把同一实例登记为 provider，UI 只通过
/// `ref` 读取。纯依赖用 `Provider`；仍以 `ChangeNotifier` 通知的服务用
/// [LegacyListenableNotifier] 保留「每次 notify 都重建 watcher」的语义。
///
/// 组合根自己的派生状态（评论 / 发现 / 换源 / 下载请求 / 单曲信息等）直接
/// 在 provider 里懒构造，跟旧 `provider_tree.dart` 的 `create:` 语义一致。
///
/// 新代码不要再往里加：新增状态应直接写 `Notifier` / `AsyncNotifier`
/// （ADR-0041）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:molia/app/bootstrap/runtime_providers.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/data/catalog/comments_service.dart';
import 'package:molia/data/library_repository.dart';
import 'package:molia/data/play_statistics_repository.dart';
import 'package:molia/domain/ports/album_repository.dart';
import 'package:molia/domain/ports/artist_repository.dart';
import 'package:molia/domain/ports/source_registry.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';
import 'package:molia/sources/builtin/discover_source.dart';
import 'package:molia/providers/ai_dj_provider.dart';
import 'package:molia/providers/channel_selection.dart';
import 'package:molia/providers/diagnostics_provider.dart';
import 'package:molia/providers/library_collection_request.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/lyrics_display_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/providers/snapshot_source.dart';
import 'package:molia/providers/search_provider.dart';
import 'package:molia/providers/sources_backend.dart';
import 'package:molia/providers/sources_provider.dart';
import 'package:molia/providers/sync_provider.dart';
import 'package:molia/providers/sync_ui_state.dart';
import 'package:molia/providers/update_provider.dart';
import 'package:molia/services/ai/ai_recommendation_service.dart';
import 'package:molia/services/ai/ai_settings_store.dart';
import 'package:molia/services/artwork/artwork_cache.dart';
import 'package:molia/services/artwork_palette_service.dart';
import 'package:molia/services/audio_focus_settings.dart';
import 'package:molia/services/bili_account_service.dart';
import 'package:molia/services/cache_service.dart';
import 'package:molia/services/covers/custom_cover_store.dart';
import 'package:molia/services/data_saver_service.dart';
import 'package:molia/services/diagnostics/diagnostics_export.dart';
import 'package:molia/services/diagnostics/diagnostics_service.dart';
import 'package:molia/services/diagnostics/log_tail_reader.dart';
import 'package:molia/services/download/download_maintenance.dart';
import 'package:molia/services/download/download_manager.dart';
import 'package:molia/services/download/download_records.dart';
import 'package:molia/services/download/download_requests.dart';
import 'package:molia/services/download/download_service.dart';
import 'package:molia/services/download/download_settings.dart';
import 'package:molia/services/library/library_add_settings.dart';
import 'package:molia/services/local/local_library_service.dart';
import 'package:molia/services/local/local_metadata_service.dart';
import 'package:molia/services/local_cache_index_store.dart';
import 'package:molia/services/lyrics_service.dart';
import 'package:molia/services/lyrics/lyrics_source_registry.dart';
import 'package:molia/services/lyrics_display/lyrics_display_settings.dart';
import 'package:molia/services/notification_service.dart';
import 'package:molia/services/play_statistics_service.dart';
import 'package:molia/services/save_as.dart';
import 'package:molia/services/scrobble/scrobble_service.dart';
import 'package:molia/services/shortcut_settings.dart';
import 'package:molia/services/source_swap/source_swap_settings.dart';
import 'package:molia/services/source_swap/swap_query_planner.dart';
import 'package:molia/services/track_local_data_service.dart';
import 'package:molia/services/update/update_check_coordinator.dart';
import 'package:molia/sources/source_manager.dart';

/// 把一个启动期 `ChangeNotifier` 实例暴露成 Riverpod provider。
///
/// `state = _value` 是同一实例；`updateShouldNotify` 恒为 true，因此每次
/// `notifyListeners()` 都会通知 watcher（与 `MultiProvider` 的行为一致）。
class LegacyListenableNotifier<T extends Listenable> extends Notifier<T> {
  LegacyListenableNotifier(this._resolve);

  final T Function(Ref ref) _resolve;
  late T _value;

  @override
  T build() {
    final value = _resolve(ref);
    _value = value;
    value.addListener(_onChanged);
    ref.onDispose(() => value.removeListener(_onChanged));
    return value;
  }

  void _onChanged() => state = _value;

  @override
  bool updateShouldNotify(T previous, T next) => true;
}

T _require<T>(Ref ref) => ref.watch(appRuntimeProvider).require<T>();

// ---------------------------------------------------------------------------
// 启动期登记的实例。
// ---------------------------------------------------------------------------

final playbackProvider =
    NotifierProvider<
      SnapshotNotifier<PlaybackProvider, PlaybackState>,
      PlaybackState
    >(() => SnapshotNotifier((ref) => _require<PlaybackProvider>(ref)));
final maybePlaybackProvider =
    NotifierProvider<
      NullableSnapshotNotifier<PlaybackProvider, PlaybackState>,
      PlaybackState?
    >(
      () => NullableSnapshotNotifier(
        (ref) => ref.read(appRuntimeProvider).maybe<PlaybackProvider>(),
      ),
    );
final playbackControllerProvider = snapshotController<PlaybackProvider>();
final maybePlaybackControllerProvider =
    maybeSnapshotController<PlaybackProvider>();

final libraryProvider =
    NotifierProvider<
      SnapshotNotifier<LibraryProvider, LibraryState>,
      LibraryState
    >(() => SnapshotNotifier((ref) => _require<LibraryProvider>(ref)));
final maybeLibraryProvider =
    NotifierProvider<
      NullableSnapshotNotifier<LibraryProvider, LibraryState>,
      LibraryState?
    >(
      () => NullableSnapshotNotifier(
        (ref) => ref.read(appRuntimeProvider).maybe<LibraryProvider>(),
      ),
    );
final libraryControllerProvider = snapshotController<LibraryProvider>();
final maybeLibraryControllerProvider =
    maybeSnapshotController<LibraryProvider>();
final searchProvider =
    NotifierProvider<
      SnapshotNotifier<SearchProvider, SearchState>,
      SearchState
    >(() => SnapshotNotifier((ref) => _require<SearchProvider>(ref)));
final searchControllerProvider = snapshotController<SearchProvider>();
final channelSelectionProvider =
    NotifierProvider<
      SnapshotNotifier<ChannelSelection, ChannelSelectionState>,
      ChannelSelectionState
    >(() => SnapshotNotifier((ref) => _require<ChannelSelection>(ref)));
final channelSelectionControllerProvider =
    snapshotController<ChannelSelection>();
final diagnosticsProvider =
    NotifierProvider<
      SnapshotNotifier<DiagnosticsProvider, DiagnosticsState>,
      DiagnosticsState
    >(() => SnapshotNotifier((ref) => _require<DiagnosticsProvider>(ref)));
final diagnosticsControllerProvider = snapshotController<DiagnosticsProvider>();
final aiDjProvider =
    NotifierProvider<SnapshotNotifier<AiDjProvider, AiDjState>, AiDjState>(
      () => SnapshotNotifier((ref) => _require<AiDjProvider>(ref)),
    );
final aiDjControllerProvider = snapshotController<AiDjProvider>();
final scrobbleProvider =
    NotifierProvider<
      SnapshotNotifier<ScrobbleService, ScrobbleState>,
      ScrobbleState
    >(() => SnapshotNotifier((ref) => _require<ScrobbleService>(ref)));
final maybeScrobbleProvider =
    NotifierProvider<
      NullableSnapshotNotifier<ScrobbleService, ScrobbleState>,
      ScrobbleState?
    >(
      () => NullableSnapshotNotifier(
        (ref) => ref.read(appRuntimeProvider).maybe<ScrobbleService>(),
      ),
    );
final scrobbleControllerProvider = snapshotController<ScrobbleService>();
final maybeScrobbleControllerProvider =
    maybeSnapshotController<ScrobbleService>();

final lyricsDisplayProvider =
    NotifierProvider<
      SnapshotNotifier<LyricsDisplayProvider, LyricsDisplayState>,
      LyricsDisplayState
    >(() => SnapshotNotifier((ref) => _require<LyricsDisplayProvider>(ref)));
final lyricsDisplayControllerProvider =
    maybeSnapshotController<LyricsDisplayProvider>();
final lyricsDisplaySettingsProvider =
    NotifierProvider<
      SnapshotNotifier<LyricsDisplaySettings, LyricsDisplaySettingsState>,
      LyricsDisplaySettingsState
    >(() => SnapshotNotifier((ref) => _require<LyricsDisplaySettings>(ref)));
final lyricsDisplaySettingsControllerProvider =
    maybeSnapshotController<LyricsDisplaySettings>();

final syncProvider =
    NotifierProvider<SnapshotNotifier<SyncProvider, SyncUiState>, SyncUiState>(
      () => SnapshotNotifier((ref) => _require<SyncProvider>(ref)),
    );
final maybeSyncProvider =
    NotifierProvider<
      NullableSnapshotNotifier<SyncProvider, SyncUiState>,
      SyncUiState?
    >(
      () => NullableSnapshotNotifier(
        (ref) => ref.read(appRuntimeProvider).maybe<SyncProvider>(),
      ),
    );
final syncControllerProvider = snapshotController<SyncProvider>();
final maybeSyncControllerProvider = maybeSnapshotController<SyncProvider>();
final updateProvider =
    NotifierProvider<
      SnapshotNotifier<UpdateProvider, UpdateState>,
      UpdateState
    >(() => SnapshotNotifier((ref) => _require<UpdateProvider>(ref)));
final maybeUpdateProvider =
    NotifierProvider<
      NullableSnapshotNotifier<UpdateProvider, UpdateState>,
      UpdateState?
    >(
      () => NullableSnapshotNotifier(
        (ref) => ref.read(appRuntimeProvider).maybe<UpdateProvider>(),
      ),
    );
final updateControllerProvider = snapshotController<UpdateProvider>();
final maybeUpdateControllerProvider = maybeSnapshotController<UpdateProvider>();
final sourceSwapSettingsProvider =
    NotifierProvider<
      SnapshotNotifier<SourceSwapSettings, SourceSwapSettingsState>,
      SourceSwapSettingsState
    >(() => SnapshotNotifier((ref) => _require<SourceSwapSettings>(ref)));
final maybeSourceSwapSettingsProvider =
    NotifierProvider<
      NullableSnapshotNotifier<SourceSwapSettings, SourceSwapSettingsState>,
      SourceSwapSettingsState?
    >(
      () => NullableSnapshotNotifier(
        (ref) => ref.read(appRuntimeProvider).maybe<SourceSwapSettings>(),
      ),
    );
final sourceSwapSettingsControllerProvider =
    maybeSnapshotController<SourceSwapSettings>();
final libraryAddSettingsProvider =
    NotifierProvider<
      SnapshotNotifier<LibraryAddSettings, LibraryAddSettingsState>,
      LibraryAddSettingsState
    >(() => SnapshotNotifier((ref) => _require<LibraryAddSettings>(ref)));
final maybeLibraryAddSettingsProvider =
    NotifierProvider<
      NullableSnapshotNotifier<LibraryAddSettings, LibraryAddSettingsState>,
      LibraryAddSettingsState?
    >(
      () => NullableSnapshotNotifier(
        (ref) => ref.read(appRuntimeProvider).maybe<LibraryAddSettings>(),
      ),
    );
final libraryAddSettingsControllerProvider =
    maybeSnapshotController<LibraryAddSettings>();

final shortcutSettingsProvider =
    NotifierProvider<
      SnapshotNotifier<ShortcutSettings, ShortcutSettingsState>,
      ShortcutSettingsState
    >(() => SnapshotNotifier((ref) => _require<ShortcutSettings>(ref)));
final shortcutSettingsControllerProvider =
    snapshotController<ShortcutSettings>();
final audioFocusSettingsProvider =
    NotifierProvider<SnapshotNotifier<AudioFocusSettings, bool>, bool>(
      () => SnapshotNotifier((ref) => _require<AudioFocusSettings>(ref)),
    );
final maybeAudioFocusSettingsProvider =
    NotifierProvider<NullableSnapshotNotifier<AudioFocusSettings, bool>, bool?>(
      () => NullableSnapshotNotifier(
        (ref) => ref.read(appRuntimeProvider).maybe<AudioFocusSettings>(),
      ),
    );
final audioFocusSettingsControllerProvider =
    maybeSnapshotController<AudioFocusSettings>();

/// 下载记录实例：未登记（设置页 / 单页预览）时给一个「不支持」的空实例，
/// 入口按隐藏处理；回退实例由容器持有并在销毁时释放。
final _downloadRecordsSourceProvider = Provider<DownloadRecords>((ref) {
  final registered = ref.read(appRuntimeProvider).maybe<DownloadRecords>();
  if (registered != null) return registered;
  final fallback = DownloadRecords(initialized: true, supported: false);
  ref.onDispose(fallback.dispose);
  return fallback;
});
final downloadRecordsProvider =
    NotifierProvider<
      SnapshotNotifier<DownloadRecords, DownloadRecordsState>,
      DownloadRecordsState
    >(
      () =>
          SnapshotNotifier((ref) => ref.watch(_downloadRecordsSourceProvider)),
    );
final downloadRecordsControllerProvider = Provider<DownloadRecords>(
  (ref) => ref.watch(_downloadRecordsSourceProvider),
);

final localCacheIndexProvider =
    NotifierProvider<
      NullableSnapshotNotifier<LocalCacheIndexStore, LocalCacheIndexState>,
      LocalCacheIndexState?
    >(
      () => NullableSnapshotNotifier(
        (ref) => ref.read(appRuntimeProvider).maybe<LocalCacheIndexStore>(),
      ),
    );
final localCacheIndexControllerProvider =
    maybeSnapshotController<LocalCacheIndexStore>();

final downloadManagerProvider =
    NotifierProvider<
      NullableSnapshotNotifier<DownloadManager, DownloadManagerState>,
      DownloadManagerState?
    >(
      () => NullableSnapshotNotifier(
        (ref) => ref.read(appRuntimeProvider).maybe<DownloadManager>(),
      ),
    );
final downloadManagerControllerProvider =
    maybeSnapshotController<DownloadManager>();

final downloadSettingsProvider =
    NotifierProvider<
      SnapshotNotifier<DownloadSettings, DownloadSettingsState>,
      DownloadSettingsState
    >(() => SnapshotNotifier((ref) => _require<DownloadSettings>(ref)));
final maybeDownloadSettingsProvider =
    NotifierProvider<
      NullableSnapshotNotifier<DownloadSettings, DownloadSettingsState>,
      DownloadSettingsState?
    >(
      () => NullableSnapshotNotifier(
        (ref) => ref.read(appRuntimeProvider).maybe<DownloadSettings>(),
      ),
    );
final downloadSettingsControllerProvider =
    maybeSnapshotController<DownloadSettings>();

final localLibraryServiceProvider =
    NotifierProvider<
      SnapshotNotifier<LocalLibraryService, LocalLibraryServiceState>,
      LocalLibraryServiceState
    >(() => SnapshotNotifier((ref) => _require<LocalLibraryService>(ref)));
final localLibraryServiceControllerProvider =
    snapshotController<LocalLibraryService>();
final dataSaverServiceProvider =
    NotifierProvider<
      SnapshotNotifier<DataSaverService, DataSaverState>,
      DataSaverState
    >(() => SnapshotNotifier((ref) => _require<DataSaverService>(ref)));
final maybeDataSaverServiceProvider =
    NotifierProvider<
      NullableSnapshotNotifier<DataSaverService, DataSaverState>,
      DataSaverState?
    >(
      () => NullableSnapshotNotifier(
        (ref) => ref.read(appRuntimeProvider).maybe<DataSaverService>(),
      ),
    );
final dataSaverServiceControllerProvider =
    maybeSnapshotController<DataSaverService>();
final biliAccountProvider =
    NotifierProvider<
      NullableSnapshotNotifier<BiliAccountService, BiliAccountState>,
      BiliAccountState?
    >(
      () => NullableSnapshotNotifier(
        (ref) => ref.read(appRuntimeProvider).maybe<BiliAccountService>(),
      ),
    );
final biliAccountControllerProvider =
    maybeSnapshotController<BiliAccountService>();
final sourceManagerProvider =
    NotifierProvider<LegacyListenableNotifier<SourceManager>, SourceManager>(
      () => LegacyListenableNotifier((ref) => _require<SourceManager>(ref)),
    );

// ---------------------------------------------------------------------------
// 可空别名：设置页等“可选入口”消费方使用，未接线时返回 null。
// ---------------------------------------------------------------------------

/// 可空快照：发现页轮播在没有 AI 栈（测试 / 独立预览）时整块不渲染。
final maybeAiDjProvider =
    NotifierProvider<
      NullableSnapshotNotifier<AiDjProvider, AiDjState>,
      AiDjState?
    >(
      () => NullableSnapshotNotifier(
        (ref) => ref.read(appRuntimeProvider).maybe<AiDjProvider>(),
      ),
    );
final maybeAiDjControllerProvider = maybeSnapshotController<AiDjProvider>();

Provider<T?> _maybeService<T extends Object>() =>
    Provider<T?>((ref) => ref.read(appRuntimeProvider).maybe<T>());

final maybeLyricsDisplayProvider =
    NotifierProvider<
      NullableSnapshotNotifier<LyricsDisplayProvider, LyricsDisplayState>,
      LyricsDisplayState?
    >(
      () => NullableSnapshotNotifier(
        (ref) => ref.read(appRuntimeProvider).maybe<LyricsDisplayProvider>(),
      ),
    );
final maybeSourcesProvider =
    NotifierProvider<
      NullableSnapshotNotifier<SourcesProvider, SourcesState>,
      SourcesState?
    >(
      () => NullableSnapshotNotifier(
        (ref) => ref.read(appRuntimeProvider).maybe<SourcesProvider>(),
      ),
    );
final maybeSourcesControllerProvider =
    maybeSnapshotController<SourcesProvider>();
final maybeSourceManagerProvider = _maybeService<SourceManager>();

// ---------------------------------------------------------------------------
// 纯依赖（不随通知重建，只做注入）。
// ---------------------------------------------------------------------------

final saveAsProvider = Provider<SaveAs>((ref) => _require<SaveAs>(ref));
final maybeSaveAsProvider = Provider<SaveAs?>(
  (ref) => ref.read(appRuntimeProvider).maybe<SaveAs>(),
);
final sourceRegistryProvider = Provider<SourceRegistry?>(
  (ref) => ref.read(appRuntimeProvider).maybe<SourceRegistry>(),
);
final catalogServiceProvider = Provider<CatalogService>(
  (ref) => _require<CatalogService>(ref),
);
final commentsServiceProvider = Provider<CommentsService>(
  (ref) => _require<CommentsService>(ref),
);
final albumRepositoryProvider = Provider<AlbumRepository>(
  (ref) => _require<AlbumRepository>(ref),
);
final artistRepositoryProvider = Provider<ArtistRepository>(
  (ref) => _require<ArtistRepository>(ref),
);
final swapQueryPlannerProvider = Provider<SwapQueryPlanner>(
  (ref) => _require<SwapQueryPlanner>(ref),
);
final libraryRepositoryProvider = Provider<LibraryRepository>(
  (ref) => _require<LibraryRepository>(ref),
);
final artworkPaletteServiceProvider = Provider<ArtworkPaletteService>(
  (ref) => _require<ArtworkPaletteService>(ref),
);
final customCoverStoreProvider = Provider<CustomCoverStore>(
  (ref) => _require<CustomCoverStore>(ref),
);
final lyricsServiceProvider = Provider<LyricsService>(
  (ref) => _require<LyricsService>(ref),
);
final aiSettingsStoreProvider = Provider<AiSettingsStore>(
  (ref) => _require<AiSettingsStore>(ref),
);
final aiRecommendationServiceProvider = Provider<AiRecommendationService>(
  (ref) => _require<AiRecommendationService>(ref),
);
final playStatisticsRepositoryProvider = Provider<PlayStatisticsRepository>(
  (ref) => _require<PlayStatisticsRepository>(ref),
);
final playStatisticsServiceProvider = Provider<PlayStatisticsService?>(
  (ref) => ref.read(appRuntimeProvider).maybe<PlayStatisticsService>(),
);
final lyricsSourceRegistryProvider = Provider<LyricsSourceRegistry>(
  (ref) => _require<LyricsSourceRegistry>(ref),
);
final cacheServiceProvider = Provider<CacheService>(
  // 旧组合根始终注册进程级单例；测试 / 独立预览未登记时沿用同一单例。
  (ref) =>
      ref.read(appRuntimeProvider).maybe<CacheService>() ??
      CacheService.instance,
);
final localMetadataServiceProvider = Provider<LocalMetadataService>(
  (ref) => _require<LocalMetadataService>(ref),
);
final notificationServiceProvider = Provider<NotificationService>(
  (ref) => _require<NotificationService>(ref),
);
final maybeNotificationServiceProvider = Provider<NotificationService?>(
  (ref) => ref.read(appRuntimeProvider).maybe<NotificationService>(),
);
final downloadServiceProvider = Provider<DownloadService>(
  (ref) => _require<DownloadService>(ref),
);
final downloadMaintenanceProvider = Provider<DownloadMaintenance?>(
  (ref) => ref.read(appRuntimeProvider).maybe<DownloadMaintenance>(),
);
final updateCheckCoordinatorProvider = Provider<UpdateCheckCoordinator>(
  (ref) => _require<UpdateCheckCoordinator>(ref),
);
final diagnosticsServiceProvider = Provider<DiagnosticsService>(
  (ref) => _require<DiagnosticsService>(ref),
);
final diagnosticsExporterProvider = Provider<DiagnosticsExporter>(
  (ref) => _require<DiagnosticsExporter>(ref),
);

// ---------------------------------------------------------------------------
// 组合根派生状态：懒构造，等价于旧 `provider_tree.dart` 的 `create:`。
// ---------------------------------------------------------------------------

/// 跨页收藏请求的控制器：已登记（测试 / 宿主）优先复用。
final libraryCollectionRequestControllerProvider =
    Provider<LibraryCollectionRequest>((ref) {
      final existing = ref
          .read(appRuntimeProvider)
          .maybe<LibraryCollectionRequest>();
      if (existing != null) return existing;
      return LibraryCollectionRequest();
    });

final libraryCollectionRequestProvider =
    NotifierProvider<
      SnapshotNotifier<LibraryCollectionRequest, LibraryCollectionRequestState>,
      LibraryCollectionRequestState
    >(
      () => SnapshotNotifier(
        (ref) => ref.watch(libraryCollectionRequestControllerProvider),
      ),
    );

final downloadRequestsProvider =
    NotifierProvider<
      NullableSnapshotNotifier<DownloadRequests, DownloadRequestsState>,
      DownloadRequestsState?
    >(
      () => NullableSnapshotNotifier(
        (ref) => ref.read(appRuntimeProvider).maybe<DownloadRequests>(),
      ),
    );
final downloadRequestsControllerProvider =
    maybeSnapshotController<DownloadRequests>();

final discoverSourcesProvider = Provider<Map<String, DiscoverSource>>(
  (ref) => BuiltinDiscover.sources,
);
final discoverBuiltinTransportProvider = Provider<BuiltinTransport>(
  (ref) => BuiltinTransport(),
);

/// 音源管理控制器的懒构造：已登记（测试 / 宿主）优先复用，否则创建并释放。
final sourcesControllerProvider = Provider<SourcesProvider>((ref) {
  final existing = ref.read(appRuntimeProvider).maybe<SourcesProvider>();
  if (existing != null) return existing;
  final provider = SourcesProvider(
    SourceManagerBackend(ref.read(sourceManagerProvider)),
  );
  ref.onDispose(provider.dispose);
  return provider;
});

final sourcesProvider =
    NotifierProvider<
      SnapshotNotifier<SourcesProvider, SourcesState>,
      SourcesState
    >(() => SnapshotNotifier((ref) => ref.watch(sourcesControllerProvider)));

/// 诊断页控制器的懒构造：已登记（测试 / 宿主）优先复用，否则创建并释放。
final diagnosticsPageControllerProvider = Provider<DiagnosticsProvider>((ref) {
  final existing = ref.read(appRuntimeProvider).maybe<DiagnosticsProvider>();
  if (existing != null) return existing;
  final service = ref.read(diagnosticsServiceProvider);
  final exporter = ref.read(diagnosticsExporterProvider);
  final provider = DiagnosticsProvider(
    service: service,
    builder: exporter,
    saveAs: ref.read(saveAsProvider),
    appInfo: exporter.appInfo.load,
    restartEngine: () => ref.read(sourceManagerProvider).retryEngine(),
    logReader: LogTailReader(
      directory: service.logSink?.directory ?? () async => null,
    ),
  );
  ref.onDispose(provider.dispose);
  return provider;
});

final diagnosticsPageProvider =
    NotifierProvider<
      SnapshotNotifier<DiagnosticsProvider, DiagnosticsState>,
      DiagnosticsState
    >(
      () => SnapshotNotifier(
        (ref) => ref.watch(diagnosticsPageControllerProvider),
      ),
    );

final trackLocalDataServiceProvider = Provider<TrackLocalDataService?>((ref) {
  final catalog = ref.read(appRuntimeProvider).maybe<CatalogService>();
  if (catalog == null) return null;
  return TrackLocalDataService(
    cacheService: ref.read(cacheServiceProvider),
    artworkCache: ArtworkCache.instance,
    catalogService: catalog,
    downloadRecords: ref.read(downloadRecordsControllerProvider),
  );
});
