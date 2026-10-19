/// AI 推歌栈：配置（安全存储）+ OpenAI-compatible 客户端 + 画像/生成服务 +
/// 模式控制器（AiDjProvider）。
///
/// 组合根把播放快照 / 进度接进控制器（跳过判定与低水位续推都在控制器里）；
/// 凭证属于同步类别，远端应用后按登记键触发配置回读。
library;

import 'dart:async';

import '../../data/settings/settings_keys.dart';
import '../../providers/ai_dj_provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/playback_provider.dart';
import '../../services/ai/ai_recommendation_service.dart';
import '../../services/ai/ai_settings_store.dart';
import '../../services/ai/llm_client.dart';
import '../../services/ai/taste_profile_builder.dart';
import 'catalog_stack.dart';
import 'library_stack.dart';

/// AI 推歌栈产物（构造顺序见 [buildAiStack]）。
typedef AiStack = ({
  AiSettingsStore settingsStore,
  AiRecommendationService recommendationService,
  AiDjProvider djProvider,
});

/// 装配 AI 推歌链路并挂到播放 / 资料库上（功能默认关闭，UI 引导开启）。
AiStack buildAiStack({
  required CatalogStack catalog,
  required LibraryStack library,
  required PlaybackProvider playback,
  required LibraryProvider libraryProvider,
}) {
  final aiSettings = catalog.settings.scope([
    kAiDjBaseUrl,
    kAiDjApiKey,
    kAiDjModel,
    kAiDjConsent,
    kAiDjEnabled,
    kAiDjCacheTtlDays,
  ]);
  final aiSettingsStore = AiSettingsStore(settings: aiSettings);
  final aiRecommendationService = AiRecommendationService(
    llm: LlmClient(),
    catalog: catalog.catalogService,
    registry: catalog.sourceRegistry,
    profileBuilder:
        TasteProfileBuilder(repository: library.playStatisticsRepository),
  );
  final aiDjProvider = AiDjProvider(
    playbackProvider: playback,
    libraryProvider: libraryProvider,
    recommendationService: aiRecommendationService,
    settingsStore: aiSettingsStore,
  );
  // AI 凭证属同步类别：远端应用后要立即回读，否则测试连接/生成仍用旧配置。
  catalog.settings.bindReload(kAiDjBaseUrl, aiDjProvider.reloadConfig);
  catalog.settings.bindReload(kAiDjApiKey, aiDjProvider.reloadConfig);
  catalog.settings.bindReload(kAiDjModel, aiDjProvider.reloadConfig);
  unawaited(aiDjProvider.init());
  playback.addListener(aiDjProvider.onPlaybackChanged);
  playback.position.addListener(aiDjProvider.onPositionChanged);

  return (
    settingsStore: aiSettingsStore,
    recommendationService: aiRecommendationService,
    djProvider: aiDjProvider,
  );
}
