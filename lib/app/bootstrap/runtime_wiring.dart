/// 把各启动阶段的产物登记进 [AppRuntime]，供 Riverpod provider 读取。
///
/// 只做“同一实例登记”，不在这里构造新的业务对象；派生 provider 在
/// `lib/providers/app_providers.dart` 里懒构造。分阶段登记是为了让功能栈 /
/// 尾部栈在构造期间也能通过容器读到已经就绪的依赖（例如主题、导航）。
library;

import '../../data/catalog/catalog_service.dart';
import '../../data/catalog/comments_service.dart';
import '../../domain/ports/album_repository.dart';
import '../../domain/ports/artist_repository.dart';
import '../../domain/ports/source_registry.dart';
import '../../providers/ai_dj_provider.dart';
import '../../providers/channel_selection.dart';
import '../../providers/library_provider.dart';
import '../../providers/search_provider.dart';
import '../../providers/sync_provider.dart';
import '../../providers/update_provider.dart';
import '../../services/ai/ai_recommendation_service.dart';
import '../../services/ai/ai_settings_store.dart';
import '../../services/artwork_palette_service.dart';
import '../../services/audio_focus_settings.dart';
import '../../services/bili_account_service.dart';
import '../../services/cache_service.dart';
import '../../services/covers/custom_cover_store.dart';
import '../../services/data_saver_service.dart';
import '../../services/diagnostics/diagnostics_export.dart';
import '../../services/diagnostics/diagnostics_service.dart';
import '../../services/download/download_maintenance.dart';
import '../../services/download/download_manager.dart';
import '../../services/download/download_records.dart';
import '../../services/download/download_service.dart';
import '../../services/download/download_settings.dart';
import '../../services/local/local_library_service.dart';
import '../../services/local/local_metadata_service.dart';
import '../../services/local_cache_index_store.dart';
import '../../services/lyrics/lyrics_source_registry.dart';
import '../../services/lyrics_display/lyrics_display_settings.dart';
import '../../services/notification_service.dart';
import '../../services/save_as.dart';
import '../../services/shortcut_settings.dart';
import '../../services/source_swap/swap_query_planner.dart';
import '../../services/update/update_check_coordinator.dart';
import '../../services/window/tray_settings.dart';
import '../../sources/source_manager.dart';
import 'app_dependencies.dart';
import 'app_runtime.dart';

/// 核心栈完成后可登记的实例（本地数据 / 资料库 / 播放 / 渠道搜索）。
void wireCoreRuntime(AppRuntime runtime, CoreStacks core) {
  final catalog = core.catalog;
  final local = core.local;
  final library = core.library;
  final playback = core.playback;

  runtime.put<SourceManager>(catalog.sourceManager);
  runtime.put<SourceRegistry>(catalog.sourceRegistry);
  runtime.put<CatalogService>(catalog.catalogService);
  runtime.put<CommentsService>(catalog.commentsService);
  runtime.put<AlbumRepository>(catalog.albumService);
  runtime.put<ArtistRepository>(catalog.artistService);
  runtime.put<SwapQueryPlanner>(catalog.swapQueryPlanner);
  runtime.put<BiliAccountService>(catalog.biliAccount);

  runtime.put<AudioFocusSettings>(playback.audioFocusSettings);
  runtime.put(playback.playbackProvider);

  runtime.put<DataSaverService>(local.dataSaver);
  runtime.put<DownloadSettings>(local.downloadSettings);
  runtime.put<DownloadService>(local.downloadService);
  runtime.put<DownloadManager>(local.downloadService);
  runtime.put<DownloadMaintenance>(local.downloadService);
  runtime.put<DownloadRecords>(local.downloadService.records);
  runtime.put<LocalLibraryService>(local.localLibrary);
  runtime.put<LocalMetadataService>(local.localMetadata);
  runtime.put<LocalCacheIndexStore>(local.localCacheIndex);
  runtime.put(local.lyricsService);
  runtime.put<CustomCoverStore>(local.customCovers);
  runtime.put(CacheService.instance);

  runtime.put(library.libraryRepository);
  runtime.put(library.playStatisticsRepository);
  runtime.put(library.playStatisticsService);
  runtime.put(library.sourceSwapSettings);
  runtime.put(library.libraryAddSettings);
  runtime.put<LibraryProvider>(core.libraryProvider);
  runtime.put(core.scrobble.service);
  runtime.put<ChannelSelection>(core.channelSelection);
  runtime.put<SearchProvider>(core.searchProvider);

  runtime.put(createSaveAs(customRoot: () => local.downloadSettings.saveDir));
}

/// 功能栈完成后登记（桌面 / AI / 歌词 / 歌词显示与主题）。
void wireFeatureRuntime(AppRuntime runtime, FeatureStacks features) {
  runtime.put<TraySettings>(features.desktop.traySettings);
  runtime.put<AiDjProvider>(features.ai.djProvider);
  runtime.put<AiSettingsStore>(features.ai.settingsStore);
  runtime.put<AiRecommendationService>(features.ai.recommendationService);
  runtime.put(features.lyrics.lyricsProvider);
  runtime.put<LyricsSourceRegistry>(features.lyrics.lyricsSourceRegistry);
  runtime.put<LyricsDisplaySettings>(features.display.lyricsDisplaySettings);
  runtime.put(features.display.lyricsDisplay);
  runtime.put(features.display.navProvider);
  runtime.put<ArtworkPaletteService>(features.display.artworkPaletteService);
}

/// 尾部栈完成后登记（同步 / 更新 / 诊断导出 / 通知）。
void wireAuxRuntime(
  AppRuntime runtime, {
  required PlatformBootstrap platform,
  required AuxStacks aux,
}) {
  runtime.put<SyncProvider>(aux.sync.provider);
  runtime.put<UpdateProvider>(aux.update.provider);
  runtime.put<UpdateCheckCoordinator>(aux.update.coordinator);
  runtime.put<DiagnosticsExporter>(aux.diagnosticsExporter);
  runtime.put<DiagnosticsService>(platform.diagnostics.service);
  runtime.put<NotificationService>(platform.notifications);
  runtime.put<ShortcutSettings>(ShortcutSettings.instance);
}
