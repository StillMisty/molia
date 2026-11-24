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
import 'package:molia/providers/search_provider.dart';
import 'package:molia/providers/sources_provider.dart';
import 'package:molia/providers/sync_provider.dart';
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

/// 懒构造的启动期状态对象（等价于旧 `provider_tree.dart` 的 `create:`）。
///
/// 与 [LegacyListenableNotifier] 的区别：对象由 provider 自己创建并在销毁时
/// dispose，而不是从 [AppRuntime] 取已存在的实例。
class LazyListenableNotifier<T extends ChangeNotifier> extends Notifier<T> {
  LazyListenableNotifier(this._create)
    : _preferRuntime = true,
      _ownsValue = true;

  /// 测试专用：接管一个已构造的实例（容器不负责 dispose）。
  LazyListenableNotifier.withValue(T value)
    : _create = ((Ref _) => value),
      _preferRuntime = false,
      _ownsValue = false;

  final T Function(Ref ref) _create;

  /// 测试 / 宿主已把派生实例登记进 [AppRuntime] 时优先复用，
  /// 避免再构造第二份状态（页面与测试句柄必须操作同一实例）。
  final bool _preferRuntime;
  bool _ownsValue;
  late T _value;

  @override
  T build() {
    final existing = _preferRuntime
        ? ref.read(appRuntimeProvider).maybe<T>()
        : null;
    final value = existing ?? _create(ref);
    _ownsValue = _ownsValue && existing == null;
    _value = value;
    value.addListener(_onChanged);
    ref.onDispose(() {
      value.removeListener(_onChanged);
      if (_ownsValue) value.dispose();
    });
    return value;
  }

  void _onChanged() => state = _value;

  @override
  bool updateShouldNotify(T previous, T next) => true;
}

/// 可空变体：依赖未登记（测试 / 独立预览）时返回 null，不抛启动期异常。
class LazyNullableListenableNotifier<T extends ChangeNotifier>
    extends Notifier<T?> {
  LazyNullableListenableNotifier(this._create)
    : _preferRuntime = true,
      _ownsValue = true;

  /// 测试专用：接管一个已构造的实例（容器不负责 dispose）。
  LazyNullableListenableNotifier.withValue(T value)
    : _create = ((Ref _) => value),
      _preferRuntime = false,
      _ownsValue = false;

  final T? Function(Ref ref) _create;

  /// 同 [LazyListenableNotifier]：测试已登记的实例优先复用。
  final bool _preferRuntime;
  bool _ownsValue;
  T? _value;

  @override
  T? build() {
    final existing = _preferRuntime
        ? ref.read(appRuntimeProvider).maybe<T>()
        : null;
    final value = existing ?? _create(ref);
    _ownsValue = _ownsValue && existing == null;
    _value = value;
    if (value != null) {
      value.addListener(_onChanged);
      ref.onDispose(() {
        value.removeListener(_onChanged);
        if (_ownsValue) value.dispose();
      });
    }
    return value;
  }

  void _onChanged() => state = _value;

  @override
  bool updateShouldNotify(T? previous, T? next) => true;
}

T _require<T>(Ref ref) => ref.watch(appRuntimeProvider).require<T>();

// ---------------------------------------------------------------------------
// 启动期登记的实例。
// ---------------------------------------------------------------------------

final playbackProvider =
    NotifierProvider<
      LegacyListenableNotifier<PlaybackProvider>,
      PlaybackProvider
    >(() => LegacyListenableNotifier((ref) => _require<PlaybackProvider>(ref)));
final maybePlaybackProvider =
    NotifierProvider<
      LazyNullableListenableNotifier<PlaybackProvider>,
      PlaybackProvider?
    >(
      () => LazyNullableListenableNotifier(
        (ref) => ref.read(appRuntimeProvider).maybe<PlaybackProvider>(),
      ),
    );

final libraryProvider =
    NotifierProvider<
      LegacyListenableNotifier<LibraryProvider>,
      LibraryProvider
    >(() => LegacyListenableNotifier((ref) => _require<LibraryProvider>(ref)));
final searchProvider =
    NotifierProvider<LegacyListenableNotifier<SearchProvider>, SearchProvider>(
      () => LegacyListenableNotifier((ref) => _require<SearchProvider>(ref)),
    );
final channelSelectionProvider =
    NotifierProvider<
      LegacyListenableNotifier<ChannelSelection>,
      ChannelSelection
    >(() => LegacyListenableNotifier((ref) => _require<ChannelSelection>(ref)));
final diagnosticsProvider =
    NotifierProvider<
      LegacyListenableNotifier<DiagnosticsProvider>,
      DiagnosticsProvider
    >(
      () =>
          LegacyListenableNotifier((ref) => _require<DiagnosticsProvider>(ref)),
    );
final aiDjProvider =
    NotifierProvider<LegacyListenableNotifier<AiDjProvider>, AiDjProvider>(
      () => LegacyListenableNotifier((ref) => _require<AiDjProvider>(ref)),
    );
final scrobbleServiceProvider =
    NotifierProvider<
      LegacyListenableNotifier<ScrobbleService>,
      ScrobbleService
    >(() => LegacyListenableNotifier((ref) => _require<ScrobbleService>(ref)));

final lyricsDisplayProvider =
    NotifierProvider<
      LegacyListenableNotifier<LyricsDisplayProvider>,
      LyricsDisplayProvider
    >(
      () => LegacyListenableNotifier(
        (ref) => _require<LyricsDisplayProvider>(ref),
      ),
    );
final lyricsDisplaySettingsProvider =
    NotifierProvider<
      LegacyListenableNotifier<LyricsDisplaySettings>,
      LyricsDisplaySettings
    >(
      () => LegacyListenableNotifier(
        (ref) => _require<LyricsDisplaySettings>(ref),
      ),
    );

final syncProvider =
    NotifierProvider<LegacyListenableNotifier<SyncProvider>, SyncProvider>(
      () => LegacyListenableNotifier((ref) => _require<SyncProvider>(ref)),
    );
final updateProvider =
    NotifierProvider<LegacyListenableNotifier<UpdateProvider>, UpdateProvider>(
      () => LegacyListenableNotifier((ref) => _require<UpdateProvider>(ref)),
    );
final sourceSwapSettingsProvider =
    NotifierProvider<
      LegacyListenableNotifier<SourceSwapSettings>,
      SourceSwapSettings
    >(
      () =>
          LegacyListenableNotifier((ref) => _require<SourceSwapSettings>(ref)),
    );
final libraryAddSettingsProvider =
    NotifierProvider<
      LegacyListenableNotifier<LibraryAddSettings>,
      LibraryAddSettings
    >(
      () =>
          LegacyListenableNotifier((ref) => _require<LibraryAddSettings>(ref)),
    );

final shortcutSettingsProvider =
    NotifierProvider<
      LegacyListenableNotifier<ShortcutSettings>,
      ShortcutSettings
    >(() => LegacyListenableNotifier((ref) => _require<ShortcutSettings>(ref)));
final audioFocusSettingsProvider =
    NotifierProvider<
      LegacyListenableNotifier<AudioFocusSettings>,
      AudioFocusSettings
    >(
      () =>
          LegacyListenableNotifier((ref) => _require<AudioFocusSettings>(ref)),
    );
final downloadRecordsProvider =
    NotifierProvider<
      LegacyListenableNotifier<DownloadRecords>,
      DownloadRecords
    >(
      () => LegacyListenableNotifier(
        (ref) =>
            ref.read(appRuntimeProvider).maybe<DownloadRecords>() ??
            DownloadRecords(initialized: true, supported: false),
      ),
    );
final localCacheIndexProvider = Provider<LocalCacheIndexStore?>(
  (ref) => ref.read(appRuntimeProvider).maybe<LocalCacheIndexStore>(),
);
final downloadManagerProvider = Provider<DownloadManager?>(
  (ref) => ref.read(appRuntimeProvider).maybe<DownloadManager>(),
);

final downloadSettingsProvider = Provider<DownloadSettings?>(
  (ref) => ref.read(appRuntimeProvider).maybe<DownloadSettings>(),
);

final localLibraryServiceProvider =
    NotifierProvider<
      LegacyListenableNotifier<LocalLibraryService>,
      LocalLibraryService
    >(
      () =>
          LegacyListenableNotifier((ref) => _require<LocalLibraryService>(ref)),
    );
final dataSaverServiceProvider =
    NotifierProvider<
      LegacyListenableNotifier<DataSaverService>,
      DataSaverService
    >(() => LegacyListenableNotifier((ref) => _require<DataSaverService>(ref)));
final biliAccountProvider = Provider<BiliAccountService?>(
  (ref) => ref.read(appRuntimeProvider).maybe<BiliAccountService>(),
);
final sourceManagerProvider =
    NotifierProvider<LegacyListenableNotifier<SourceManager>, SourceManager>(
      () => LegacyListenableNotifier((ref) => _require<SourceManager>(ref)),
    );

// ---------------------------------------------------------------------------
// 可空别名：设置页等“可选入口”消费方使用，未接线时返回 null。
// ---------------------------------------------------------------------------

NotifierProvider<LazyNullableListenableNotifier<T>, T?>
_maybeListenable<T extends ChangeNotifier>() =>
    NotifierProvider<LazyNullableListenableNotifier<T>, T?>(
      () => LazyNullableListenableNotifier(
        (ref) => ref.read(appRuntimeProvider).maybe<T>(),
      ),
    );

Provider<T?> _maybeService<T extends Object>() =>
    Provider<T?>((ref) => ref.read(appRuntimeProvider).maybe<T>());

final maybeDataSaverServiceProvider = _maybeListenable<DataSaverService>();
final maybeAudioFocusSettingsProvider = _maybeListenable<AudioFocusSettings>();
final maybeSourceSwapSettingsProvider = _maybeListenable<SourceSwapSettings>();
final maybeLyricsDisplayProvider = _maybeListenable<LyricsDisplayProvider>();
final maybeUpdateProvider = _maybeListenable<UpdateProvider>();
final maybeScrobbleServiceProvider = _maybeListenable<ScrobbleService>();
final maybeLibraryAddSettingsProvider = _maybeListenable<LibraryAddSettings>();
final maybeSyncProvider = _maybeListenable<SyncProvider>();
final maybeSourcesProvider = _maybeListenable<SourcesProvider>();
final maybeAiDjProvider = _maybeListenable<AiDjProvider>();
final maybeLibraryProvider = _maybeListenable<LibraryProvider>();
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

final libraryCollectionRequestProvider =
    NotifierProvider<
      LazyNullableListenableNotifier<LibraryCollectionRequest>,
      LibraryCollectionRequest?
    >(
      () => LazyNullableListenableNotifier((ref) => LibraryCollectionRequest()),
    );

final downloadRequestsProvider =
    NotifierProvider<
      LazyNullableListenableNotifier<DownloadRequests>,
      DownloadRequests?
    >(
      () => LazyNullableListenableNotifier((ref) {
        final downloads = ref.read(appRuntimeProvider).maybe<DownloadService>();
        if (downloads == null) return null;
        return DownloadRequests(
          downloads: downloads,
          records: ref.read(downloadRecordsProvider),
        );
      }),
    );

final discoverSourcesProvider = Provider<Map<String, DiscoverSource>>(
  (ref) => BuiltinDiscover.sources,
);
final discoverBuiltinTransportProvider = Provider<BuiltinTransport>(
  (ref) => BuiltinTransport(),
);

final sourcesProvider =
    NotifierProvider<LazyListenableNotifier<SourcesProvider>, SourcesProvider>(
      () => LazyListenableNotifier(
        (ref) => SourcesProvider(ref.read(sourceManagerProvider)),
      ),
    );

final diagnosticsPageProvider =
    NotifierProvider<
      LazyListenableNotifier<DiagnosticsProvider>,
      DiagnosticsProvider
    >(
      () => LazyListenableNotifier((ref) {
        final service = ref.read(diagnosticsServiceProvider);
        final exporter = ref.read(diagnosticsExporterProvider);
        return DiagnosticsProvider(
          service: service,
          builder: exporter,
          saveAs: ref.read(saveAsProvider),
          appInfo: exporter.appInfo.load,
          restartEngine: () => ref.read(sourceManagerProvider).retryEngine(),
          logReader: LogTailReader(
            directory: service.logSink?.directory ?? () async => null,
          ),
        );
      }),
    );

final trackLocalDataServiceProvider = Provider<TrackLocalDataService?>((ref) {
  final catalog = ref.read(appRuntimeProvider).maybe<CatalogService>();
  if (catalog == null) return null;
  return TrackLocalDataService(
    cacheService: ref.read(cacheServiceProvider),
    artworkCache: ArtworkCache.instance,
    catalogService: catalog,
    downloadRecords: ref.read(downloadRecordsProvider),
  );
});
