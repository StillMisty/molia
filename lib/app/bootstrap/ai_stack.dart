/// AI 推歌栈：配置（安全存储）+ OpenAI-compatible 客户端 + 画像/生成服务 +
/// 模式控制器（AiDjProvider）。
///
/// 组合根把播放快照 / 进度接进控制器（跳过判定与低水位续推都在控制器里）；
/// 凭证属于同步类别，远端应用后按登记键触发配置回读。
library;

import '../../data/settings/settings_keys.dart';
import '../../data/settings/settings_module.dart';
import '../../providers/ai_dj_provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/playback_provider.dart';
import '../../services/ai/ai_prompt_text.dart';
import '../../services/ai/ai_recommendation_service.dart';
import '../../services/ai/ai_settings_store.dart';
import '../../services/ai/llm_client.dart';
import '../../services/ai/taste_profile_builder.dart';
import '../../services/language_service.dart';
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
  // 一个挂载点覆盖 AI 的 7 个键，按键分三组重载：连接凭证回读 / 推荐偏好
  // 与反馈记忆重读 / 开关与隐私确认回读。凭证属同步类别，远端应用后必须
  // 立即回读，否则测试连接 / 生成仍用旧配置。
  late final AiDjProvider aiDjProvider;
  final aiSettings = catalog.settings.mount(
    SettingsModule.withReloads(
      keys: [
        kAiDjBaseUrl,
        kAiDjApiKey,
        kAiDjModel,
        kAiDjConsent,
        kAiDjEnabled,
        kAiDjPreferences,
        kAiDjFeedbackMemory,
      ],
      reloads: [
        (
          keys: [kAiDjBaseUrl, kAiDjApiKey, kAiDjModel],
          reload: () => aiDjProvider.reloadConfig(),
        ),
        (
          keys: [kAiDjPreferences, kAiDjFeedbackMemory],
          reload: () => aiDjProvider.reloadPreferences(),
        ),
        (
          keys: [kAiDjEnabled, kAiDjConsent],
          reload: () => aiDjProvider.reloadAccess(),
        ),
      ],
    ),
  );
  final aiSettingsStore = AiSettingsStore(settings: aiSettings);
  final tasteProfileBuilder = TasteProfileBuilder(
    repository: library.playStatisticsRepository,
    libraryStore: library.libraryRepository,
  );
  final aiRecommendationService = AiRecommendationService(
    llm: LlmClient(),
    catalog: catalog.catalogService,
    registry: catalog.sourceRegistry,
    profileBuilder: tasteProfileBuilder,
    promptLanguage: () =>
        aiPromptLanguageFor(LanguageService.effectiveLocale.languageCode),
  );
  aiDjProvider = AiDjProvider(
    playbackProvider: playback,
    libraryProvider: libraryProvider,
    recommendationService: aiRecommendationService,
    settingsStore: aiSettingsStore,
  );
  // init 读安全存储 / 历史批次，由 AI 页面打开时触发（幂等）：
  // 启动路径不碰钥匙串；AI 页与推荐流不在首帧内容里。
  playback.addListener(aiDjProvider.onPlaybackChanged);
  playback.position.addListener(aiDjProvider.onPositionChanged);

  return (
    settingsStore: aiSettingsStore,
    recommendationService: aiRecommendationService,
    djProvider: aiDjProvider,
  );
}
