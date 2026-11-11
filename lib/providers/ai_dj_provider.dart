/// AI 推歌控制器：**当前推荐（active）** + **历史推荐** + **推歌会话（电台）**。
///
/// 定位（对齐「个性推荐」）：
/// - 历史批次持久化在 [AiRecommendationStore]（索引 + 每批一键），任何时刻
///   可浏览、可播放；显式「生成推荐 / 换一批」才切换 active；
/// - 手动补批与队列低水位自动补歌只追加队列 + 写历史（`manualFeed` /
///   `autoFeed`），**不切换 active**；自动补歌不产生任何可见进度；
/// - `enabled` 是功能启用（持久化；退出队列不关功能），`status` 是电台状态。
///
/// 深模块分工：
/// - 生成策略 / 请求组装在 [AiGenerationRequest] + [AiGenerationExecutor]；
/// - 电台状态机与曲目跟踪在 [AiRadioSession]；
/// - 反馈账本（本轮 + 长期记忆）在 [AiFeedbackBook]。
/// 本类只保留配置 / 同意 / 偏好、历史门面与命令编排，并对外委托现有 getter。
///
/// 组合根接线（main.dart）：播放快照 / 进度接进 [onPlaybackChanged] /
/// [onPositionChanged]；跳过判定、低水位静默补歌都在会话模块内判定。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../data/mapping/track_mapper.dart';
import '../domain/models/ai_dj.dart';
import '../domain/models/failure.dart';
import '../domain/models/playback.dart';
import '../domain/models/track.dart';
import '../services/ai/ai_generation_executor.dart';
import '../services/ai/ai_generation_request.dart';
import '../services/ai/ai_recommendation_service.dart';
import '../services/ai/ai_recommendation_store.dart';
import '../services/ai/ai_settings_store.dart';
import '../services/ai/ai_text.dart';
import 'ai_dj_history_controller.dart';
import 'ai_feedback_book.dart';
import 'ai_radio_session.dart';
import 'library_provider.dart';
import 'playback_provider.dart';

class AiDjProvider extends ChangeNotifier {
  AiDjProvider({
    required this._playbackProvider,
    required this._libraryProvider,
    required this._recommendationService,
    required this._settingsStore,
    AiRecommendationStore? recommendationStore,
  }) {
    _generation = AiGenerationExecutor();
    _generation.state.addListener(_onGenerationStateChanged);
    _feedback = AiFeedbackBook(
      persist: _settingsStore.saveFeedbackMemory,
      onRevision: _bumpPreferencesRevision,
    );
    _radio = AiRadioSession(
      playbackProvider: _playbackProvider,
      libraryProvider: _libraryProvider,
      onSkip: _feedback.recordSkip,
    );
    _history = AiDjHistoryController(
      store: recommendationStore ?? AiRecommendationStore(),
      decode: _restoreBatch,
      encode: _toStored,
    );
  }

  final PlaybackProvider _playbackProvider;
  final LibraryProvider _libraryProvider;
  final AiRecommendationGenerator _recommendationService;
  final AiSettingsStore _settingsStore;
  final Logger _logger = Logger('molia.ai_dj_provider');

  late final AiDjHistoryController _history;

  /// 生成执行器：token / epoch / 取消 / 可见进度 / 空批次失败只在这里维护。
  late final AiGenerationExecutor _generation;

  /// 反馈账本：本轮反馈 + 跨重启记忆 + 不感兴趣撤销栈。
  late final AiFeedbackBook _feedback;

  /// 电台会话：状态机、曲目跟踪、队列操作互斥位与补歌失败计数。
  late final AiRadioSession _radio;

  /// 上一次转发给聚合通知的生成离散状态（进度分片不转发）。
  bool _lastGenerationBusy = false;
  String? _lastReplacingUri;

  /// 上一次在播放快照变化后展示过的派生排队数（用于补一次通知）。
  int _lastQueuedCount = 0;

  // 常量保留在门面上，历史调用方无需改引用；实现口径归会话模块。
  static const int lowWatermark = AiRadioSession.lowWatermark;
  static const int maxConsecutiveFailures =
      AiRadioSession.maxConsecutiveFailures;
  static const int completionToleranceMs = AiRadioSession.completionToleranceMs;

  LlmConfig? _config;
  bool _consentGranted = false;
  bool _enabled = false;

  AiPreferences _preferences = AiPreferences.defaults;

  SourceFailure? _lastError;

  AiPrompt? _lastSentPrompt;
  String? _lastRawResponse;

  int _preferencesRevision = 0;

  LlmConfig? get config => _config;
  bool get hasConfig => _config != null;
  bool get consentGranted => _consentGranted;
  bool get enabled => _enabled;
  AiDjStatus get status => _radio.status;

  /// 电台是否生效（生成中 / 推歌中）。
  bool get isFeeding => _radio.isFeeding;

  /// 显式操作进行中（生成 / 加入队列 / 重找未解析）。
  bool get isBusy => _generation.isBusy || _radio.queueBusy;

  /// 生成状态（独立 ValueListenable）：进度分片只通知它，不触发聚合通知。
  ValueListenable<AiGenerationState> get generationState => _generation.state;

  /// 显式生成的阶段进度；静默补歌永远不设置它。
  AiDjProgress? get progress => _generation.progress;

  /// 是否正在替换某一行（行内进度，其他行仍可操作）。
  bool isReplacing(String uri) => _generation.replacingUri == uri;

  /// 推荐偏好的单调版本（页面据此重载发送原文预览）。
  int get preferencesRevision => _preferencesRevision;

  AiPreferences get preferences => _preferences;
  AiFeedbackMemory get feedbackMemory => _feedback.memory;
  List<String> get seeds => _feedback.seeds;

  bool get autoFeedHalted => _radio.autoFeedHalted;
  int get autoFeedFailures => _radio.autoFeedFailures;
  SourceFailure? get autoFeedError => _radio.autoFeedError;

  /// 上次实际发送的提示词（内存；不落盘、不打日志）。
  AiPrompt? get lastSentPrompt => _lastSentPrompt;

  /// 上次 LLM 原始返回（内存；不落盘、不打日志）。
  String? get lastRawResponse => _lastRawResponse;

  /// 当前推荐（可能为空：未生成 / 已清空）。
  AiDjBatch? get recommendations => _history.active;
  bool get hasRecommendations =>
      _history.active != null && _history.active!.items.isNotEmpty;
  DateTime? get lastUpdatedAt => _history.active?.generatedAt;
  String? get activeBatchId => _history.active?.id;

  /// 历史索引（含 active；历史页首屏只读它）。
  List<AiDjHistoryEntry> get historyEntries => _history.entries;
  int get historyCount => _history.count;
  bool isActiveBatch(String id) => _history.isActive(id);

  SourceFailure? get lastError => _lastError;

  /// 会话内仍在队列「当前及之后」的 AI 曲目数（从 live 快照派生）。
  int get queuedCount => _radio.queuedCount;

  /// 会话内自动判定 + 手动「不感兴趣」的跳过项（本轮）。
  List<String> get skippedLabels => _feedback.skippedLabels;
  List<String> get likedLabels => _feedback.likedLabels;

  /// 跨重启记忆（UI 反馈区展示用）。
  List<String> get rememberedSkippedLabels => _feedback.rememberedSkippedLabels;
  List<String> get rememberedLikedLabels => _feedback.rememberedLikedLabels;

  /// 合并后的本轮反馈（自动跳过 + 长期记忆 + 本轮喜欢）。
  List<String> get mergedSkippedLabels => _feedback.mergedSkippedLabels;
  List<String> get mergedLikedLabels => _feedback.mergedLikedLabels;

  /// 手动「不感兴趣」项（可撤销）。
  List<ResolvedRecommendation> get notInterestedItems =>
      _feedback.notInterestedItems;

  /// 列表项是否已在播放队列（页面标记「队列中」）。
  bool isQueued(String uri) => _radio.isQueued(uri);

  Future<void> init() async {
    // 配置 / 确认 / 开关 / 偏好 / 反馈记忆互不依赖：并行读。其中配置走安全
    // 存储（Android Keystore / 桌面 keyring），串行会把多次冷读叠加到启动尾巴。
    // 历史索引 / active 批次也不依赖设置：同样并行起步，最后再统一接状态。
    final historyReady = _history.init();
    final (config, consentGranted, enabled, preferences, feedback) = await (
      _settingsStore.readConfig(),
      _settingsStore.hasConsent(),
      _settingsStore.readEnabled(),
      _settingsStore.readPreferences(),
      _settingsStore.readFeedbackMemory(),
    ).wait;
    _config = config;
    _consentGranted = consentGranted;
    _enabled = enabled;
    _preferences = preferences.copyWith(seeds: feedback.seeds);
    _feedback.replaceMemory(feedback);

    await historyReady;
    // 冷启动恢复的 AI 队列继续自动补歌，不需要用户再点一次播放。
    final snapshot = _playbackProvider.snapshot;
    final adopted = _radio.adoptIfNeeded(snapshot, canAdopt: _canRunRadio);
    notifyListeners();
    if (adopted) _maybeAutoFeed(snapshot);
  }

  /// 恢复态 / 切回 AI 队列时允许接管（显式 stop 后会话自身不接管）。
  bool get _canRunRadio => _enabled && hasConfig && _consentGranted;

  Future<void> saveConfig(LlmConfig config) async {
    await _settingsStore.saveConfig(config);
    _config = config;
    _lastError = null; // 新配置：允许自动生成/重试
    notifyListeners();
  }

  /// 重新从存储读取配置（跨设备同步应用远端凭证后由注册表重载钩子调用）。
  Future<void> reloadConfig() async {
    final config = await _settingsStore.readConfig();
    if (_sameConfig(_config, config)) return;
    _config = config;
    _lastError = null;
    notifyListeners();
  }

  /// 重新读取偏好 / 反馈记忆（跨设备同步设置后由注册表重载钩子调用）。
  Future<void> reloadPreferences() async {
    final preferences = await _settingsStore.readPreferences();
    final feedback = await _settingsStore.readFeedbackMemory();
    _preferences = preferences.copyWith(seeds: feedback.seeds);
    _feedback.replaceMemory(feedback);
    _bumpPreferencesRevision();
    notifyListeners();
  }

  static bool _sameConfig(LlmConfig? a, LlmConfig? b) =>
      a?.baseUrl == b?.baseUrl &&
      a?.apiKey == b?.apiKey &&
      a?.model == b?.model;

  Future<void> clearConfig() async {
    await _settingsStore.clearConfig();
    _config = null;
    _lastError = null;
    notifyListeners();
  }

  Future<void> grantConsent() async {
    await _settingsStore.grantConsent();
    _consentGranted = true;
    _lastError = null;
    notifyListeners();
  }

  /// 连接测试（页面「测试连接」按钮）；失败抛 [SourceFailure]。
  Future<void> testConnection(LlmConfig config) =>
      _recommendationService.testConnection(config);

  /// 上行数据摘要（「本次发送的数据」；失败返回 null，UI 隐藏该区块）。
  Future<AiUpstreamSummary?> summarizeUpstream() async {
    try {
      return await _recommendationService.summarizeUpstream(
        preferences: _snapshotPreferences(),
      );
    } catch (e) {
      _logger.warning('AI 推歌：上行摘要失败 $e');
      return null;
    }
  }

  /// 预览实际会发送的提示词（只读：不标记喜欢、不写反馈记忆）。
  Future<AiPrompt?> previewPrompt() async {
    if (!hasConfig) return null;
    try {
      final request = _buildGenerationRequest(
        count: _preferences.batchSize,
        commitLikes: false,
      );
      return await _recommendationService.buildPromptPreview(
        count: request.count,
        preferences: request.preferences,
        skippedLabels: request.feedback.skipped,
        likedLabels: request.feedback.liked,
        excludeLabels: request.exclusions.labels,
      );
    } catch (e) {
      _logger.warning('AI 推歌：提示词预览失败 $e');
      return null;
    }
  }

  /// 功能开关：只控制「推荐可用」，不接管播放（播放全部/点某首才进电台）。
  Future<void> setEnabled(bool value) async {
    if (value == _enabled) return;
    _enabled = value;
    await _settingsStore.saveEnabled(value);
    if (!value) {
      _radio.markOff();
      _radio.clearTracked();
      _cancelAutoFeed();
    }
    notifyListeners();
    if (value) await ensureRecommendations();
  }

  /// 保存推荐偏好：改动即时生效，只影响下一次生成，不自动生成。
  Future<void> savePreferences(AiPreferences preferences) async {
    // 净化已由 AiPreferences.tryFromJson 在读取时完成；这里只固定「种子
    // 以反馈记忆为准」这一条会话语义，不再重复截断 / 校正。
    final next = preferences.copyWith(seeds: _feedback.seeds);
    final autoFeedDisabled = _preferences.autoFeed && !next.autoFeed;
    final autoFeedEnabled = !_preferences.autoFeed && next.autoFeed;
    if (autoFeedDisabled) _cancelAutoFeed();
    _preferences = next;
    if (autoFeedEnabled) _radio.resetAutoFeed();
    _bumpPreferencesRevision();
    // 偏好页是即时保存：先让 UI 用上新值，再落盘。
    notifyListeners();
    try {
      await _settingsStore.savePreferences(next);
    } catch (e) {
      _logger.warning('AI 推歌：保存推荐偏好失败 $e');
    }
  }

  Future<void> resetPreferences() =>
      savePreferences(AiPreferences.defaults.copyWith(seeds: _feedback.seeds));

  /// 自动补歌开关：走统一偏好保存路径（关闭取消在途静默任务，打开清除停止态）。
  Future<void> setAutoFeed(bool value) async {
    if (value == _preferences.autoFeed) return;
    await savePreferences(_preferences.copyWith(autoFeed: value));
  }

  /// 用户手动恢复自动补歌（连续失败停止后）。
  void resumeAutoFeed() {
    if (!_preferences.autoFeed) return;
    _radio.resetAutoFeed();
    notifyListeners();
  }

  /// 确保有可浏览的推荐列表。
  ///
  /// 仅在「启用 + 已配置 + 已确认 + 列表缺失 + 上次没有失败」时生成：
  /// 不跨天自动换批（不静默消耗 token），失败后也不自动重试。
  Future<void> ensureRecommendations() async {
    if (!_enabled || !hasConfig || !_consentGranted) return;
    if (recommendations != null) return;
    if (_lastError != null) return;
    await refreshRecommendations();
  }

  void _cancelAutoFeed() => _generation.cancelAutoFeed();

  /// 「生成推荐 / 换一批」：新批成为 active，旧 active 留在历史。
  Future<void> refreshRecommendations() async {
    if (!hasConfig || isBusy) return;
    await _runExplicitGeneration(
      origin: AiDjOrigin.refresh,
      count: _preferences.batchSize,
    );
  }

  /// 取消显式生成：不写错误、不动列表；晚到结果按 epoch 丢弃。
  void cancelGeneration() => _generation.cancelExplicit();

  /// 开始推歌（电台）：用当前推荐替换当前队列并从 [fromIndex] 起播。
  Future<void> startRadio({int fromIndex = 0}) async {
    if (isBusy) return;
    if (recommendations == null) {
      await ensureRecommendations();
    }
    final batch = recommendations;
    if (batch == null || batch.items.isEmpty) return;
    final clamped = fromIndex.clamp(0, batch.items.length - 1).toInt();
    final uri = batch.items[clamped].track.id.uri;
    _radio.clearStoppedByUser();
    if (_radio.isQueued(uri)) {
      await _playbackProvider.playLocalQueueItemById(uri);
      _radio.markTracked(uri);
      return;
    }

    _radio.beginQueueOperation();
    _lastError = null;
    _radio.markPreparing();
    notifyListeners();
    try {
      _feedback.resetRound();
      _radio.start();
      await _playbackProvider.playDomainTracks(
        [for (final item in batch.items) item.track],
        clamped,
        contextName: kAiDjContextName,
      );
      _radio.registerTracks(batch.items);
      _radio.markPlaying();
      _lastError = null;
    } catch (e) {
      _lastError = _failureOf(e);
      _radio.markError();
      _logger.severe('AI 推歌：起播失败', e);
    } finally {
      _radio.endQueueOperation();
      notifyListeners();
    }
  }

  /// 播放推荐中的某一首：已在队列则跳转，否则从该首接管队列。
  Future<void> playRecommendation(int index) => startRadio(fromIndex: index);

  /// 「全部加入队列」：把当前推荐里还没入队的曲目追加到队尾（不打断播放）。
  Future<void> enqueueRecommendations() async {
    final batch = recommendations;
    if (batch == null || batch.items.isEmpty || isBusy) return;
    final missing = _radio.missingFromQueue(batch.items);
    if (missing.isEmpty) return;
    _radio.beginQueueOperation();
    _lastError = null;
    notifyListeners();
    try {
      await _radio.enqueueTracks(missing);
    } catch (e) {
      _lastError = _failureOf(e);
      _logger.severe('AI 推歌：加入队列失败', e);
    } finally {
      _radio.endQueueOperation();
      notifyListeners();
    }
  }

  /// 手动「补一批到队尾」：显式操作（可显示进度），但**不切换 active**。
  Future<void> feedMore() async {
    if (isBusy) return;
    if (_radio.status != AiDjStatus.playing &&
        _radio.status != AiDjStatus.error) {
      return;
    }
    final batch = await _runExplicitGeneration(
      origin: AiDjOrigin.manualFeed,
      count: _preferences.batchSize,
    );
    if (batch != null) {
      if (_radio.status == AiDjStatus.error) _radio.markPlaying();
    }
  }

  /// 单曲「换一首」：重新生成一首替换当前推荐项；已在队列则原位跟随替换。
  Future<void> replaceRecommendation(int index) async {
    final batch = recommendations;
    if (batch == null ||
        index < 0 ||
        index >= batch.items.length ||
        isBusy ||
        _generation.replacingUri != null) {
      return;
    }
    final target = batch.items[index];
    final targetUri = target.track.id.uri;
    final request = _buildGenerationRequest(count: 1, commitLikes: true);
    _lastError = null;

    await _generation.run<void>(
      intent: AiGenerationIntent(
        origin: AiDjOrigin.refresh,
        request: request,
        lane: AiGenerationLane.replace,
        replacingUri: targetUri,
        emptyBatchMessage: '换一首没有生成可播放的曲目',
      ),
      invoke: _invokeGeneration,
      commit: (generated) async {
        final replacement = generated.items.first;
        final latest = recommendations;
        if (latest == null || latest.id != batch.id) return;
        final items = List<ResolvedRecommendation>.of(latest.items);
        if (index >= items.length) return;
        items[index] = replacement;
        await _history.updateActive(latest.copyWith(items: items));
        if (_radio.isQueued(targetUri)) {
          await _radio.replaceQueuedTrack(target, replacement);
        }
      },
      onFailure: _onGenerationFailure,
    );
  }

  /// 未解析项「重新找一次」：只重新搜索，不重新调 LLM。
  Future<void> retryUnresolved() async {
    final batch = recommendations;
    if (batch == null || batch.unresolved.isEmpty || isBusy) return;
    final request = _buildGenerationRequest(
      count: batch.unresolved.length,
      commitLikes: false,
    );
    await _generation.run<void>(
      intent: AiGenerationIntent(
        origin: AiDjOrigin.refresh,
        request: request,
        lane: AiGenerationLane.explicit,
        initialProgress: AiDjProgress(
          phase: AiDjPhase.resolving,
          startedAt: DateTime.now(),
          total: batch.unresolved.length,
          targetCount: batch.unresolved.length,
        ),
        requirePlayableResult: false,
      ),
      invoke: (token, request, onProgress) =>
          _recommendationService.resolveUnresolved(
            batch: batch,
            preferences: request.preferences,
            cancelToken: token,
            onProgress: onProgress,
          ),
      commit: (updated) => _history.updateActive(updated),
      onFailure: _onGenerationFailure,
    );
  }

  /// 「不感兴趣」：从当前推荐移除 + 长期记忆（下一批不再推荐），可撤销。
  Future<void> markNotInterested(String uri) async {
    final batch = recommendations;
    if (batch == null) return;
    final index = batch.items.indexWhere((item) => item.track.id.uri == uri);
    if (index < 0) return;
    final item = batch.items[index];
    _feedback.rememberNotInterested(index, item);
    final items = List<ResolvedRecommendation>.of(batch.items)..removeAt(index);
    await _history.updateActive(batch.copyWith(items: items));
    await _feedback.persist();
    notifyListeners();
  }

  /// 撤销「不感兴趣」：原位插回列表并解除排除（长期记忆同步移除）。
  Future<void> undoNotInterested(String uri) async {
    final entry = _feedback.undo(uri);
    if (entry == null) return;
    final batch = recommendations;
    if (batch != null) {
      final items = List<ResolvedRecommendation>.of(batch.items);
      items.insert(entry.index.clamp(0, items.length), entry.item);
      await _history.updateActive(batch.copyWith(items: items));
    }
    await _feedback.persist();
    notifyListeners();
  }

  /// 「多来点这种」：加入种子，下一批成功生成后消费；失败/重启前保留。
  Future<void> addSeed(String label) async {
    final value = label.trim();
    if (value.isEmpty) return; // 空输入不算一次偏好变更，也不发通知。
    await _feedback.addSeed(value);
    notifyListeners();
  }

  Future<void> removeSeed(String label) async {
    await _feedback.removeSeed(label);
    notifyListeners();
  }

  /// 清空长期记忆（确认由页面负责）。
  Future<void> clearFeedbackMemory() async {
    await _feedback.clearMemory();
    notifyListeners();
  }

  /// 历史「播放这批」：加载 → 设为 active → 强制替换队列并起播。
  ///
  /// 功能关闭时按普通队列播放（不启动自动补歌）。
  Future<void> playHistoryBatch(String id) async {
    final batch = await loadHistoryBatch(id);
    if (batch == null || batch.items.isEmpty || isBusy) return;
    _radio.clearStoppedByUser();
    _feedback.clearUndo();
    await _history.setActive(id);
    _radio.beginQueueOperation();
    notifyListeners();
    try {
      _feedback.resetRound();
      _radio.reset();
      await _playbackProvider.playDomainTracks(
        [for (final item in batch.items) item.track],
        0,
        contextName: _enabled ? kAiDjContextName : null,
      );
      _radio.registerTracks(batch.items);
      if (_enabled) {
        _radio.markPlaying();
      } else {
        _radio.markOff();
      }
    } catch (e) {
      _lastError = _failureOf(e);
      _logger.severe('AI 推歌：播放历史批次失败', e);
    } finally {
      _radio.endQueueOperation();
      notifyListeners();
    }
  }

  /// 历史「加入队列」：只追加未入队曲目，不切换 active。
  Future<void> enqueueHistoryBatch(String id) async {
    final batch = await loadHistoryBatch(id);
    if (batch == null || isBusy) return;
    final missing = _radio.missingFromQueue(batch.items);
    if (missing.isEmpty) return;
    _radio.beginQueueOperation();
    notifyListeners();
    try {
      await _radio.enqueueTracks(missing);
    } catch (e) {
      _lastError = _failureOf(e);
      _logger.severe('AI 推歌：历史批次加入队列失败', e);
    } finally {
      _radio.endQueueOperation();
      notifyListeners();
    }
  }

  /// 历史「设为当前」：只切换浏览列表，不动队列。
  Future<void> setActiveBatch(String id) async {
    if (await _history.load(id) == null) return;
    _feedback.clearUndo();
    if (await _history.setActive(id)) notifyListeners();
  }

  /// 历史「删除」：只删历史记录，不动正在播放的队列。
  Future<void> deleteHistoryBatch(String id) async {
    final wasActive = recommendations?.id == id;
    if (!await _history.delete(id)) {
      _logger.warning('AI 推歌：删除历史批次失败，保留内存状态');
      return;
    }
    if (wasActive) _feedback.clearUndo();
    notifyListeners();
  }

  /// 清空历史：默认保留 active（只删记录之外的历史与批次键）。
  Future<void> clearHistory() async {
    if (!await _history.clear()) {
      _logger.warning('AI 推歌：清空历史失败，保留内存状态');
      return;
    }
    notifyListeners();
  }

  /// 按需加载历史详情（不切换 active）。
  Future<AiDjBatch?> loadHistoryBatch(String id) => _history.load(id);

  /// 退出推歌（电台）。默认保留当前队列继续播放（清空由调用方显式传 false）。
  ///
  /// 功能启用状态与推荐列表不受影响（退出队列 ≠ 关闭功能）。
  Future<void> stop({bool keepQueue = true}) async {
    _radio.markStoppedByUser();
    if (_radio.status == AiDjStatus.off) return;
    _cancelAutoFeed();
    _radio.stop();
    _lastError = null;
    notifyListeners();
    if (!keepQueue) {
      await _playbackProvider.stopLocalPlayback();
    }
  }

  /// 播放快照变化：跳过判定 + 低水位静默补歌。
  ///
  /// 播放被停止或队列换成本地内容时只结束「电台」，功能保持启用。
  void onPlaybackChanged() {
    _handlePlaybackChanged();
    // 队列推进会让派生的 queuedCount 变小：这里按「上次展示值」补一次
    // 通知，页面上的「队列中还有 N 首推荐」才不会停在上一次生成时的数字。
    final current = queuedCount;
    if (current != _lastQueuedCount) {
      _lastQueuedCount = current;
      notifyListeners();
    }
  }

  void _handlePlaybackChanged() {
    final snapshot = _playbackProvider.snapshot;
    if (_radio.adoptIfNeeded(snapshot, canAdopt: _canRunRadio)) {
      notifyListeners();
    }
    if (_radio.onSnapshot(snapshot)) notifyListeners();
    _maybeAutoFeed(snapshot);
  }

  /// 进度 tick：记录当前 AI 曲目到达的最大位置（跳过判定用）。
  void onPositionChanged() {
    _radio.onPosition(_playbackProvider.currentPosition);
  }

  Future<AiDjBatch?> _runExplicitGeneration({
    required AiDjOrigin origin,
    required int count,
  }) async {
    final makeActive = origin == AiDjOrigin.refresh;
    final appendToQueue = origin == AiDjOrigin.manualFeed;
    if (!hasConfig || isBusy) return null;
    if (origin == AiDjOrigin.manualFeed &&
        _radio.status != AiDjStatus.playing &&
        _radio.status != AiDjStatus.error) {
      return null;
    }
    final request = _buildGenerationRequest(count: count, commitLikes: true);
    _lastError = null;
    return _generation.run<AiDjBatch>(
      intent: AiGenerationIntent(
        origin: origin,
        request: request,
        lane: AiGenerationLane.explicit,
      ),
      invoke: _invokeGeneration,
      commit: (batch) async {
        final stamped = _stampBatch(batch, origin, request.preferences);
        if (appendToQueue) await _radio.appendGenerated(stamped.items);
        await _history.archive(stamped, makeActive: makeActive);
        if (makeActive) _feedback.clearUndo();
        _lastSentPrompt = stamped.prompt;
        _lastRawResponse = stamped.rawResponse;
        await _feedback.consumeSeeds();
        if (origin != AiDjOrigin.autoFeed) _radio.resetAutoFeed();
        return stamped;
      },
      onFailure: _onGenerationFailure,
    );
  }

  /// 静默补歌：不设置进度 / busy / 状态，不切换 active。
  Future<void> _autoFeed() async {
    if (!hasConfig || !_enabled || !_preferences.autoFeed) return;
    if (_radio.autoFeedHalted) return;
    if (isBusy || _generation.autoFeedInFlight) return;
    final before = _playbackProvider.snapshot;
    final request = _buildGenerationRequest(
      count: _preferences.batchSize,
      commitLikes: true,
    );
    await _generation.run<AiDjBatch>(
      intent: AiGenerationIntent(
        origin: AiDjOrigin.autoFeed,
        request: request,
        lane: AiGenerationLane.silent,
      ),
      invoke: _invokeGeneration,
      commit: (batch) async {
        final stamped = _stampBatch(
          batch,
          AiDjOrigin.autoFeed,
          request.preferences,
        );
        // 静默补歌去重：只追加队列里还没有的曲目，避免生成结果与现有
        // 队列重叠时把同一首重复塞进队尾。
        final missing = await _radio.appendGenerated(stamped.items);
        // 入队已经发生：即使此时显式操作取消了静默任务，也要补齐历史 /
        // 计数 / 种子，否则队列里会出现未登记的曲目。
        await _history.archive(stamped, makeActive: false);
        _radio.clearAutoFeedFailure();
        await _feedback.consumeSeeds();
        // 队列已经播完：从新追加的第一首静默续播（不提示、不改 active）。
        final after = _playbackProvider.snapshot;
        final oldLastIndex = before.queue.length - 1;
        if (missing.isNotEmpty &&
            after.current != null &&
            !after.isPlaying &&
            after.currentIndex >= oldLastIndex) {
          await _playbackProvider.playLocalQueueItemById(
            missing.first.track.id.uri,
          );
        }
        notifyListeners();
        return stamped;
      },
      onFailure: _onGenerationFailure,
    );
  }

  void _maybeAutoFeed(PlaybackSnapshot snapshot) {
    final canAutoFeed =
        _enabled && _preferences.autoFeed && !_radio.autoFeedHalted;
    final busy = isBusy || _generation.autoFeedInFlight;
    if (_radio.ensureFeed(snapshot, canAutoFeed: canAutoFeed, busy: busy)) {
      unawaited(_autoFeed());
    }
  }

  /// 生成失败统一出口：按意图的失败策略分流，取消已在执行器内过滤。
  void _onGenerationFailure(AiGenerationIntent intent, SourceFailure failure) {
    if (intent.failurePolicy == AiGenerationFailurePolicy.autoFeed) {
      final failures = _radio.recordAutoFeedFailure(failure);
      _logger.warning('AI 推歌：静默补歌失败（第 $failures 次）${failure.message}');
      notifyListeners();
      return;
    }
    _lastError = failure;
    final String label;
    if (intent.lane == AiGenerationLane.replace) {
      label = '换一首';
    } else if (intent.initialProgress?.phase == AiDjPhase.resolving) {
      label = '重新找未解析';
    } else {
      label = '${intent.origin.storageValue} 生成';
    }
    _logger.warning('AI 推歌：$label失败 ${failure.message}');
  }

  /// 四条生成路径共用的请求组装点（唯一拼 preferences / 反馈 / 排除项的地方）。
  AiGenerationRequest _buildGenerationRequest({
    required int count,
    required bool commitLikes,
  }) {
    final pendingLikes = _radio.pendingLikeLabels();
    final feedback = _feedback.mergedForPrompt(
      commit: commitLikes,
      pendingLikes: pendingLikes,
    );
    // 实际发送才提交喜欢回流；预览只模拟合并顺序。
    if (commitLikes && pendingLikes.isNotEmpty) {
      _radio.markLikesReported(pendingLikes);
    }
    final excludes = _recentRecommendationExcludes();
    return AiGenerationRequest(
      preferences: _snapshotPreferences(),
      feedback: feedback,
      exclusions: AiGenerationExclusions(
        labels: excludes.labels,
        keys: excludes.keys,
      ),
      count: count,
    );
  }

  /// 生成器调用的唯一适配点：统一请求 → 服务接口。
  Future<AiDjBatch> _invokeGeneration(
    AiGenerationCancelToken token,
    AiGenerationRequest request,
    void Function(AiDjProgress progress)? onProgress,
  ) => _recommendationService.generate(
    config: _config!,
    count: request.count,
    preferences: request.preferences,
    skippedLabels: request.feedback.skipped,
    likedLabels: request.feedback.liked,
    excludeLabels: request.exclusions.labels,
    excludeKeys: request.exclusions.keys,
    cancelToken: token,
    onProgress: onProgress,
    onRawResponse: (raw) => _lastRawResponse = raw,
  );

  AiPreferences _snapshotPreferences() =>
      _preferences.copyWith(seeds: _feedback.seeds);

  /// 上一批 + 未解析 + 会话队列的排除快照。
  ///
  /// 预览与实际请求共用同一顺序；标签进提示词让模型主动避开，规范化键同时
  /// 进本地去重兜底，模型忽略排除清单时也不会把同一首再塞进下一批。
  ({List<String> labels, List<String> keys}) _recentRecommendationExcludes() {
    const limit = 50;
    final labels = <String>[];
    final keys = <String>[];
    final seenLabels = <String>{};
    final seenKeys = <String>{};

    void add(String label, String key) {
      final cleanLabel = label.trim();
      if (cleanLabel.isNotEmpty && seenLabels.add(cleanLabel)) {
        labels.add(cleanLabel);
      }
      final cleanKey = key.trim();
      if (cleanKey.isNotEmpty && cleanKey != '|' && seenKeys.add(cleanKey)) {
        keys.add(cleanKey);
      }
    }

    final active = recommendations;
    if (active != null) {
      for (final item in active.items) {
        add(
          item.source.label,
          aiTrackKey(item.source.title, item.source.artist),
        );
      }
      for (final item in active.unresolved) {
        add(item.label, aiTrackKey(item.title, item.artist));
      }
    }
    for (final entry in _radio.sessionTracks) {
      add(entry.label, entry.promptKey);
    }
    return (
      labels: labels.take(limit).toList(),
      keys: keys.take(limit).toList(),
    );
  }

  AiDjBatch _stampBatch(
    AiDjBatch batch,
    AiDjOrigin origin,
    AiPreferences preferences,
  ) {
    final id = batch.id.trim().isEmpty
        ? DateTime.now().microsecondsSinceEpoch.toString()
        : batch.id;
    return batch.copyWith(id: id, origin: origin, preferences: preferences);
  }

  StoredAiBatch _toStored(AiDjBatch batch) => StoredAiBatch(
    id: batch.id,
    items: [
      for (final item in batch.items)
        StoredAiBatchItem(
          sourceKey: item.track.id.sourceKey,
          songId: item.track.id.id,
          title: item.track.title,
          artist: item.track.artistLabel,
          album: item.track.album ?? '',
          reason: item.source.reason,
          sourceName: item.resolvedSourceName,
          coverUrl: item.track.artwork?.uri.toString(),
          durationMs: item.track.duration?.inMilliseconds,
          raw: item.track.payload,
        ),
    ],
    unresolved: batch.unresolved,
    generatedAt: batch.generatedAt,
    origin: batch.origin,
    preferences: batch.preferences,
  );

  AiDjBatch _restoreBatch(StoredAiBatch stored) => AiDjBatch(
    id: stored.id,
    items: [
      for (final item in stored.items)
        ResolvedRecommendation(
          source: AiRecommendation(
            title: item.title,
            artist: item.artist,
            reason: item.reason,
          ),
          track: _trackFromStored(item),
          sourceName: item.sourceName,
        ),
    ],
    unresolved: stored.unresolved,
    generatedAt: stored.generatedAt,
    origin: stored.origin,
    preferences: stored.preferences,
  );

  /// 库内形状 → 可播放领域 Track（raw 原样 + 规范 id 补齐）。
  Track _trackFromStored(StoredAiBatchItem item) {
    final source = _libraryProvider.sourceTrackFromRaw(
      sourceKey: item.sourceKey,
      title: item.title,
      artist: item.artist,
      album: item.album,
      coverUrl: item.coverUrl,
      durationMs: item.durationMs,
      raw: item.raw,
    );
    return trackFromSourceTrack(source);
  }

  void _bumpPreferencesRevision() => _preferencesRevision++;

  SourceFailure _failureOf(Object error) =>
      error is SourceFailure ? error : SourceFailure.from(error);

  bool _disposed = false;

  /// 只把生成状态的离散变化（忙碌位 / 行内替换）转成聚合通知。
  ///
  /// 进度分片由 `generationState` 自己通知窄订阅者；如果这里每个分片都
  /// `notifyListeners`，页面与轮播会整块重建。
  void _onGenerationStateChanged() {
    final state = _generation.stateValue;
    if (state.busy == _lastGenerationBusy &&
        state.replacingUri == _lastReplacingUri) {
      return;
    }
    _lastGenerationBusy = state.busy;
    _lastReplacingUri = state.replacingUri;
    notifyListeners();
  }

  /// dispose 后不再发通知（未 await 的预取/补歌可能晚于 dispose）。
  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation.state.removeListener(_onGenerationStateChanged);
    _generation.dispose();
    super.dispose();
  }
}
