/// AI 推歌控制器：**当前推荐（active）** + **历史推荐** + **推歌会话（电台）**。
///
/// 定位（对齐「个性推荐」）：
/// - 历史批次持久化在 [AiRecommendationStore]（索引 + 每批一键），任何时刻
///   可浏览、可播放；显式「生成推荐 / 换一批」才切换 active；
/// - 手动补批与队列低水位自动补歌只追加队列 + 写历史（`manualFeed` /
///   `autoFeed`），**不切换 active**；自动补歌不产生任何可见进度；
/// - `enabled` 是功能启用（持久化；退出队列不关功能），`status` 是电台状态。
///
/// 组合根接线（main.dart）：播放快照 / 进度接进 [onPlaybackChanged] /
/// [onPositionChanged]；跳过判定、低水位静默补歌都在本类完成。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../data/mapping/track_mapper.dart';
import '../domain/models/ai_dj.dart';
import '../domain/models/failure.dart';
import '../domain/models/play_statistics.dart';
import '../domain/models/playback.dart';
import '../domain/models/source.dart';
import '../domain/models/track.dart';
import '../domain/ports/source_registry.dart';
import '../services/ai/ai_recommendation_service.dart';
import '../services/ai/ai_recommendation_store.dart';
import '../services/ai/ai_settings_store.dart';
import 'library_provider.dart';
import 'playback_provider.dart';

/// 会话内一首 AI 曲目的跟踪状态（跳过/听完判定）。
class _SessionTrack {
  _SessionTrack({
    required this.label,
    required this.sourceKey,
    required this.songId,
    required this.durationMs,
  });

  final String label;
  final String sourceKey;
  final String songId;
  int durationMs;
  int maxPositionMs = 0;

  /// 已计入「喜欢」反馈，避免重复回流。
  bool likedReported = false;
}

/// 「不感兴趣」项：记录原下标以支持撤销原位插回。
class _NotInterestedItem {
  const _NotInterestedItem({required this.index, required this.item});

  final int index;
  final ResolvedRecommendation item;
}

class AiDjProvider extends ChangeNotifier {
  AiDjProvider({
    required PlaybackProvider playbackProvider,
    required LibraryProvider libraryProvider,
    required AiRecommendationGenerator recommendationService,
    required AiSettingsStore settingsStore,
    AiRecommendationStore? recommendationStore,
    SourceRegistry? sourceRegistry,
  })  : _playbackProvider = playbackProvider,
        _libraryProvider = libraryProvider,
        _recommendationService = recommendationService,
        _settingsStore = settingsStore,
        _store = recommendationStore ?? AiRecommendationStore(),
        _registry = sourceRegistry;

  final PlaybackProvider _playbackProvider;
  final LibraryProvider _libraryProvider;
  final AiRecommendationGenerator _recommendationService;
  final AiSettingsStore _settingsStore;
  final AiRecommendationStore _store;
  final SourceRegistry? _registry;
  final Logger _logger = Logger('molia.ai_dj_provider');

  /// 队列剩余曲目 ≤ 此值时静默补歌。
  static const int lowWatermark = 5;

  /// 连续失败达到此值时停止自动补歌（保留当前队列继续播放）。
  static const int maxConsecutiveFailures = 3;

  /// 完整播放容差（与统计口径一致）。
  static const int completionToleranceMs = 1000;

  /// 历史详情缓存上限（按需加载；不持久化）。
  static const int _historyCacheLimit = 20;

  LlmConfig? _config;
  bool _consentGranted = false;
  bool _enabled = false;

  AiPreferences _preferences = AiPreferences.defaults;
  AiFeedbackMemory _feedback = AiFeedbackMemory.empty;

  /// 当前推荐（发现页轮播 / AI 页列表）。
  AiDjBatch? _active;

  /// 历史索引（含 active；按生成时间倒序）。
  List<AiDjHistoryEntry> _historyEntries = const [];
  final Map<String, AiDjBatch> _historyCache = {};

  AiDjStatus _status = AiDjStatus.off;

  /// 用户显式 stop 后，恢复的 AI 队列不再自动接管（start/播放历史清除）。
  bool _radioStoppedByUser = false;

  SourceFailure? _lastError;
  bool _explicitBusy = false;
  AiDjProgress? _progress;
  AiGenerationCancelToken? _cancelToken;
  int _generationEpoch = 0;

  bool _autoFeedInFlight = false;
  AiGenerationCancelToken? _autoCancelToken;
  int _autoFeedFailures = 0;
  bool _autoFeedHalted = false;
  SourceFailure? _autoFeedError;

  String? _replacingUri;
  int _queuedCount = 0;

  AiPrompt? _lastSentPrompt;
  String? _lastRawResponse;

  final List<String> _skippedLabels = [];
  final List<String> _likedLabels = [];
  final List<_NotInterestedItem> _notInterested = [];
  final Map<String, _SessionTrack> _sessionTracks = {};
  String? _trackedUri;

  LlmConfig? get config => _config;
  bool get hasConfig => _config != null;
  bool get consentGranted => _consentGranted;
  bool get enabled => _enabled;
  AiDjStatus get status => _status;

  void _setStatus(AiDjStatus value) {
    _status = value;
  }

  /// 电台是否生效（生成中 / 推歌中）。
  bool get isFeeding =>
      _status == AiDjStatus.preparing || _status == AiDjStatus.playing;

  /// 显式操作进行中（生成 / 加入队列 / 重找未解析）。
  bool get isBusy => _explicitBusy;

  /// 显式生成的阶段进度；静默补歌永远不设置它。
  AiDjProgress? get progress => _progress;

  /// 是否正在替换某一行（行内进度，其他行仍可操作）。
  bool isReplacing(String uri) => _replacingUri == uri;

  /// 推荐偏好的单调版本（页面据此重载发送原文预览）。
  int get preferencesRevision => _preferencesRevision;
  int _preferencesRevision = 0;

  AiPreferences get preferences => _preferences;
  AiFeedbackMemory get feedbackMemory => _feedback;
  List<String> get seeds => List.unmodifiable(_feedback.seeds);
  bool get preferencesOutdated =>
      _active?.preferences != null &&
      !_preferences.copyWith(seeds: _feedback.seeds).sameGenerationInputs(
            _active!.preferences,
          );

  bool get autoFeedHalted => _autoFeedHalted;
  int get autoFeedFailures => _autoFeedFailures;
  SourceFailure? get autoFeedError => _autoFeedError;

  /// 所选渠道当前全部不可用（已回退自动渠道）；偏好页提示用。
  bool get selectedChannelsUnavailable {
    if (_preferences.sourceKeys.isEmpty) return false;
    final available = {for (final source in availableSources) source.key};
    return available.intersection(_preferences.sourceKeys.toSet()).isEmpty;
  }

  /// 可搜索渠道（按音源页顺序；偏好页多选用）。
  List<SourceDescriptor> get availableSources {
    final registry = _registry;
    if (registry == null) return const [];
    return aiDjSearchableSourcesInPageOrder(registry.descriptors);
  }

  /// 上次实际发送的提示词（内存；不落盘、不打日志）。
  AiPrompt? get lastSentPrompt => _lastSentPrompt;

  /// 上次 LLM 原始返回（内存；不落盘、不打日志）。
  String? get lastRawResponse => _lastRawResponse;

  /// 当前推荐（可能为空：未生成 / 已清空）。
  AiDjBatch? get recommendations => _active;
  bool get hasRecommendations => _active != null && _active!.items.isNotEmpty;
  DateTime? get lastUpdatedAt => _active?.generatedAt;
  String? get activeBatchId => _active?.id;

  /// 历史索引（含 active；历史页首屏只读它）。
  List<AiDjHistoryEntry> get historyEntries =>
      List.unmodifiable(_historyEntries);
  int get historyCount => _historyEntries.length;
  bool isActiveBatch(String id) => _active?.id == id;

  SourceFailure? get lastError => _lastError;

  /// 会话内已入队的 AI 曲目总数。
  int get queuedCount => _queuedCount;

  /// 会话内自动判定 + 手动「不感兴趣」的跳过项（本轮）。
  List<String> get skippedLabels => List.unmodifiable(_skippedLabels);
  List<String> get likedLabels => List.unmodifiable(_likedLabels);

  /// 跨重启记忆（UI 反馈区展示用）。
  List<String> get rememberedSkippedLabels =>
      List.unmodifiable(_feedback.skipped);
  List<String> get rememberedLikedLabels => List.unmodifiable(_feedback.liked);

  /// 合并后的本轮反馈（自动跳过 + 长期记忆 + 本轮喜欢）。
  List<String> get mergedSkippedLabels =>
      _unique([..._skippedLabels, ..._feedback.skipped]);
  List<String> get mergedLikedLabels =>
      _unique([..._likedLabels, ..._feedback.liked]);

  /// 手动「不感兴趣」项（可撤销）。
  List<ResolvedRecommendation> get notInterestedItems =>
      List.unmodifiable([for (final entry in _notInterested) entry.item]);

  /// 列表项是否已在播放队列（页面标记「队列中」）。
  bool isQueued(String uri) =>
      _playbackProvider.snapshot.queue.any((track) => track.id.uri == uri);

  Future<void> init() async {
    _config = await _settingsStore.readConfig();
    _consentGranted = await _settingsStore.hasConsent();
    _enabled = await _settingsStore.readEnabled();
    _preferences = await _settingsStore.readPreferences();
    _feedback = await _settingsStore.readFeedbackMemory();
    // 兼容旧偏好里带种子的数据：种子以反馈记忆为准。
    if (_feedback.seeds.isEmpty && _preferences.seeds.isNotEmpty) {
      _feedback = _feedback.withSeeds(_preferences.seeds);
      await _settingsStore.saveFeedbackMemory(_feedback);
    }
    _preferences = _preferences.copyWith(seeds: _feedback.seeds);

    final index = await _store.loadIndex();
    _historyEntries = index.entries;
    final activeId = index.activeBatchId;
    if (activeId != null) {
      final stored = await _store.loadBatch(activeId);
      if (stored != null) {
        final batch = _restoreBatch(stored);
        _active = batch;
        _historyCache[batch.id] = batch;
      }
    }
    // 冷启动恢复的 AI 队列继续自动补歌，不需要用户再点一次播放。
    _adoptRestoredRadioIfNeeded();
    notifyListeners();
  }

  /// 恢复态 / 切回 AI 队列时重新接管电台（显式 stop 后不接管）。
  bool _adoptRestoredRadioIfNeeded() {
    if (_status != AiDjStatus.off || _radioStoppedByUser) return false;
    if (!_enabled || !hasConfig || !_consentGranted) return false;
    final snapshot = _playbackProvider.snapshot;
    final current = snapshot.current;
    if (current == null || snapshot.context?.name != kAiDjContextName) {
      return false;
    }
    _setStatus(AiDjStatus.playing);
    _trackedUri = current.id.uri;
    return true;
  }

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
    _feedback = feedback;
    _preferencesRevision++;
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
      final liked = _unique([
        ...mergedLikedLabels,
        ..._collectNewLikes(mark: false),
      ]);
      return await _recommendationService.buildPromptPreview(
        count: _preferences.batchSize,
        preferences: _snapshotPreferences(),
        skippedLabels: mergedSkippedLabels,
        likedLabels: liked,
        excludeLabels: const [],
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
      _status = AiDjStatus.off;
      _trackedUri = null;
      _cancelAutoFeed();
    }
    notifyListeners();
    if (value) await ensureRecommendations();
  }

  /// 保存推荐偏好：只影响下一次生成，不自动生成。
  Future<void> savePreferences(AiPreferences preferences) async {
    final sanitized = preferences.copyWith(
      batchSize: AiPreferences.sanitizeBatchSize(preferences.batchSize),
      extraPrompt: preferences.extraPrompt.length >
              AiPreferences.extraPromptLimit
          ? preferences.extraPrompt.substring(0, AiPreferences.extraPromptLimit)
          : preferences.extraPrompt,
      seeds: _feedback.seeds,
    );
    final autoFeedDisabled = _preferences.autoFeed && !sanitized.autoFeed;
    final autoFeedEnabled = !_preferences.autoFeed && sanitized.autoFeed;
    if (autoFeedDisabled) _cancelAutoFeed();
    _preferences = sanitized;
    await _settingsStore.savePreferences(sanitized);
    if (autoFeedEnabled) {
      _autoFeedHalted = false;
      _autoFeedFailures = 0;
      _autoFeedError = null;
    }
    _preferencesRevision++;
    notifyListeners();
  }

  Future<void> resetPreferences() =>
      savePreferences(AiPreferences.defaults.copyWith(seeds: _feedback.seeds));

  /// 每批数量（下一次生成生效，不消耗额度）。
  Future<void> setBatchSize(int size) async {
    if (!kAiBatchSizeOptions.contains(size) || size == _preferences.batchSize) {
      return;
    }
    await savePreferences(_preferences.copyWith(batchSize: size));
  }

  /// 自动补歌开关：走统一偏好保存路径（关闭取消在途静默任务，打开清除停止态）。
  Future<void> setAutoFeed(bool value) async {
    if (value == _preferences.autoFeed) return;
    await savePreferences(_preferences.copyWith(autoFeed: value));
  }

  /// 用户手动恢复自动补歌（连续失败停止后）。
  void resumeAutoFeed() {
    if (!_preferences.autoFeed) return;
    _autoFeedHalted = false;
    _autoFeedFailures = 0;
    _autoFeedError = null;
    notifyListeners();
  }

  /// 确保有可浏览的推荐列表。
  ///
  /// 仅在「启用 + 已配置 + 已确认 + 列表缺失 + 上次没有失败」时生成：
  /// 不跨天自动换批（不静默消耗 token），失败后也不自动重试。
  Future<void> ensureRecommendations() async {
    if (!_enabled || !hasConfig || !_consentGranted) return;
    if (_active != null) return;
    if (_lastError != null) return;
    await refreshRecommendations();
  }

  void _cancelAutoFeed() {
    _cancelAutoFeedToken();
    _autoCancelToken = null;
    _autoFeedInFlight = false;
  }

  void _cancelAutoFeedToken() => _autoCancelToken?.cancel();

  /// 「生成推荐 / 换一批」：新批成为 active，旧 active 留在历史。
  Future<void> refreshRecommendations() async {
    if (!hasConfig || _explicitBusy) return;
    final batch = await _runExplicitGeneration(
      origin: AiDjOrigin.refresh,
      count: _preferences.batchSize,
    );
    if (batch != null) {
      _notInterested.clear();
    }
  }

  /// 取消显式生成：不写错误、不动列表；晚到结果按 epoch 丢弃。
  void cancelGeneration() {
    if (!_explicitBusy && _progress == null) return;
    _generationEpoch++;
    _cancelToken?.cancel();
    _cancelToken = null;
    _explicitBusy = false;
    _progress = null;
    notifyListeners();
  }

  /// 开始推歌（电台）：用当前推荐替换当前队列并从 [fromIndex] 起播。
  Future<void> startRadio({int fromIndex = 0}) async {
    if (_explicitBusy) return;
    if (_active == null) {
      await ensureRecommendations();
    }
    final batch = _active;
    if (batch == null || batch.items.isEmpty) return;
    final clamped = fromIndex.clamp(0, batch.items.length - 1).toInt();
    final uri = batch.items[clamped].track.id.uri;
    _radioStoppedByUser = false;
    if (isQueued(uri)) {
      await _playbackProvider.playLocalQueueItemById(uri);
      _trackedUri = uri;
      return;
    }

    _explicitBusy = true;
    _lastError = null;
    _setStatus(AiDjStatus.preparing);
    notifyListeners();
    try {
      _resetRadioSession();
      await _playbackProvider.playDomainTracks(
        [for (final item in batch.items) item.track],
        clamped,
        contextName: kAiDjContextName,
      );
      _registerSessionTracks(batch.items);
      _queuedCount = batch.items.length - clamped;
      _setStatus(AiDjStatus.playing);
      _lastError = null;
    } catch (e) {
      _lastError = _failureOf(e);
      _setStatus(AiDjStatus.error);
      _logger.severe('AI 推歌：起播失败', e);
    } finally {
      _explicitBusy = false;
      notifyListeners();
    }
  }

  /// 播放推荐中的某一首：已在队列则跳转，否则从该首接管队列。
  Future<void> playRecommendation(int index) => startRadio(fromIndex: index);

  /// 「全部加入队列」：把当前推荐里还没入队的曲目追加到队尾（不打断播放）。
  Future<void> enqueueRecommendations() async {
    final batch = _active;
    if (batch == null || batch.items.isEmpty || _explicitBusy) return;
    final missing = _missingFromQueue(batch.items);
    if (missing.isEmpty) return;
    _explicitBusy = true;
    _lastError = null;
    notifyListeners();
    try {
      await _playbackProvider
          .enqueueDomainTracks([for (final item in missing) item.track]);
      _registerSessionTracks(missing);
      _queuedCount += missing.length;
    } catch (e) {
      _lastError = _failureOf(e);
      _logger.severe('AI 推歌：加入队列失败', e);
    } finally {
      _explicitBusy = false;
      notifyListeners();
    }
  }

  /// 手动「补一批到队尾」：显式操作（可显示进度），但**不切换 active**。
  Future<void> feedMore() async {
    if (_explicitBusy) return;
    if (_status != AiDjStatus.playing && _status != AiDjStatus.error) return;
    final batch = await _runExplicitGeneration(
      origin: AiDjOrigin.manualFeed,
      count: _preferences.batchSize,
    );
    if (batch != null) {
      if (_status == AiDjStatus.error) _setStatus(AiDjStatus.playing);
    }
  }

  /// 单曲「换一首」：重新生成一首替换当前推荐项；已在队列则原位跟随替换。
  Future<void> replaceRecommendation(int index) async {
    final batch = _active;
    if (batch == null ||
        index < 0 ||
        index >= batch.items.length ||
        _explicitBusy ||
        _replacingUri != null) {
      return;
    }
    final target = batch.items[index];
    _replacingUri = target.track.id.uri;
    _lastError = null;
    notifyListeners();
    try {
      _collectNewLikes();
      final generated = await _recommendationService.generate(
        config: _config!,
        count: 1,
        preferences: _snapshotPreferences(),
        skippedLabels: mergedSkippedLabels,
        likedLabels: mergedLikedLabels,
        excludeLabels: [for (final item in batch.items) item.source.label],
      );
      if (generated.items.isEmpty) {
        throw const SourceFailure(
          kind: FailureKind.unknown,
          message: '换一首没有生成可播放的曲目',
          l10nKey: 'aiDjNothingResolved',
          retryable: true,
        );
      }
      final latest = _active;
      if (latest == null || latest.id != batch.id) return;
      final items = List<ResolvedRecommendation>.of(latest.items);
      if (index >= items.length) return;
      items[index] = generated.items.first;
      _active = latest.copyWith(items: items);
      await _storeActive(_active!);
      if (_queuedUris().contains(target.track.id.uri)) {
        await _playbackProvider.replaceQueueTrack(
            target.track, generated.items.first.track);
      }
    } on SourceFailure catch (failure) {
      if (failure.kind == FailureKind.cancelled) return;
      _lastError = failure;
      _logger.warning('AI 推歌：换一首失败 ${failure.message}');
    } catch (e) {
      _lastError = _failureOf(e);
      _logger.severe('AI 推歌：换一首失败', e);
    } finally {
      _replacingUri = null;
      notifyListeners();
    }
  }

  /// 未解析项「重新找一次」：只重新搜索，不重新调 LLM。
  Future<void> retryUnresolved() async {
    final batch = _active;
    if (batch == null || batch.unresolved.isEmpty || _explicitBusy) return;
    final token = AiGenerationCancelToken();
    final epoch = ++_generationEpoch;
    _cancelToken = token;
    _explicitBusy = true;
    _progress = AiDjProgress(
      phase: AiDjPhase.resolving,
      startedAt: DateTime.now(),
      total: batch.unresolved.length,
    );
    notifyListeners();
    try {
      final updated = await _recommendationService.resolveUnresolved(
        batch: batch,
        preferences: _snapshotPreferences(),
        cancelToken: token,
        onProgress: (progress) {
          if (epoch != _generationEpoch || token.isCancelled) return;
          _progress = progress;
          notifyListeners();
        },
      );
      if (epoch != _generationEpoch || token.isCancelled) return;
      _active = updated;
      await _storeActive(updated);
    } on SourceFailure catch (failure) {
      if (failure.kind != FailureKind.cancelled && epoch == _generationEpoch) {
        _lastError = failure;
      }
    } catch (e) {
      if (epoch == _generationEpoch) _lastError = _failureOf(e);
      _logger.warning('AI 推歌：重新找未解析失败 $e');
    } finally {
      if (epoch == _generationEpoch) {
        _explicitBusy = false;
        _progress = null;
        _cancelToken = null;
        notifyListeners();
      }
    }
  }

  /// 「不感兴趣」：从当前推荐移除 + 长期记忆（下一批不再推荐），可撤销。
  Future<void> markNotInterested(String uri) async {
    final batch = _active;
    if (batch == null) return;
    final index = batch.items.indexWhere((item) => item.track.id.uri == uri);
    if (index < 0) return;
    final item = batch.items[index];
    final label = item.source.label;
    if (!_skippedLabels.contains(label)) _skippedLabels.add(label);
    _feedback = _feedback.addSkipped(label);
    _notInterested.insert(0, _NotInterestedItem(index: index, item: item));
    final items = List<ResolvedRecommendation>.of(batch.items)..removeAt(index);
    _active = batch.copyWith(items: items);
    _preferencesRevision++;
    await _storeActive(_active!);
    await _settingsStore.saveFeedbackMemory(_feedback);
    notifyListeners();
  }

  /// 撤销「不感兴趣」：原位插回列表并解除排除（长期记忆同步移除）。
  Future<void> undoNotInterested(String uri) async {
    final position =
        _notInterested.indexWhere((entry) => entry.item.track.id.uri == uri);
    if (position < 0) return;
    final entry = _notInterested.removeAt(position);
    final label = entry.item.source.label;
    _skippedLabels.remove(label);
    _feedback = _feedback.removeSkipped(label);
    final batch = _active;
    if (batch != null) {
      final items = List<ResolvedRecommendation>.of(batch.items);
      items.insert(entry.index.clamp(0, items.length), entry.item);
      _active = batch.copyWith(items: items);
      await _storeActive(_active!);
    }
    _preferencesRevision++;
    await _settingsStore.saveFeedbackMemory(_feedback);
    notifyListeners();
  }

  /// 「多来点这种」：加入种子，下一批成功生成后消费；失败/重启前保留。
  Future<void> addSeed(String label) async {
    final value = label.trim();
    if (value.isEmpty) return;
    _feedback = _feedback.addSeed(value);
    _preferencesRevision++;
    await _settingsStore.saveFeedbackMemory(_feedback);
    notifyListeners();
  }

  Future<void> removeSeed(String label) async {
    _feedback = _feedback.removeSeed(label);
    _preferencesRevision++;
    await _settingsStore.saveFeedbackMemory(_feedback);
    notifyListeners();
  }

  /// 清空长期记忆（确认由页面负责）。
  Future<void> clearFeedbackMemory() async {
    _feedback = AiFeedbackMemory.empty;
    _skippedLabels.clear();
    _likedLabels.clear();
    _preferencesRevision++;
    await _settingsStore.saveFeedbackMemory(_feedback);
    notifyListeners();
  }

  /// 历史「播放这批」：加载 → 设为 active → 强制替换队列并起播。
  ///
  /// 功能关闭时按普通队列播放（不启动自动补歌）。
  Future<void> playHistoryBatch(String id) async {
    final batch = await loadHistoryBatch(id);
    if (batch == null || batch.items.isEmpty || _explicitBusy) return;
    _radioStoppedByUser = false;
    await _switchActive(batch);
    _explicitBusy = true;
    notifyListeners();
    try {
      _resetRadioSession();
      await _playbackProvider.playDomainTracks(
        [for (final item in batch.items) item.track],
        0,
        contextName: _enabled ? kAiDjContextName : null,
      );
      _registerSessionTracks(batch.items);
      _queuedCount = batch.items.length;
      if (_enabled) {
        _setStatus(AiDjStatus.playing);
      } else {
        _setStatus(AiDjStatus.off);
      }
    } catch (e) {
      _lastError = _failureOf(e);
      _logger.severe('AI 推歌：播放历史批次失败', e);
    } finally {
      _explicitBusy = false;
      notifyListeners();
    }
  }

  /// 历史「加入队列」：只追加未入队曲目，不切换 active。
  Future<void> enqueueHistoryBatch(String id) async {
    final batch = await loadHistoryBatch(id);
    if (batch == null || _explicitBusy) return;
    final missing = _missingFromQueue(batch.items);
    if (missing.isEmpty) return;
    _explicitBusy = true;
    notifyListeners();
    try {
      await _playbackProvider
          .enqueueDomainTracks([for (final item in missing) item.track]);
      _registerSessionTracks(missing);
      _queuedCount += missing.length;
    } catch (e) {
      _lastError = _failureOf(e);
      _logger.severe('AI 推歌：历史批次加入队列失败', e);
    } finally {
      _explicitBusy = false;
      notifyListeners();
    }
  }

  /// 历史「设为当前」：只切换浏览列表，不动队列。
  Future<void> setActiveBatch(String id) async {
    final batch = await loadHistoryBatch(id);
    if (batch == null) return;
    await _switchActive(batch);
    notifyListeners();
  }

  /// 历史「删除」：只删历史记录，不动正在播放的队列。
  Future<void> deleteHistoryBatch(String id) async {
    final wasActive = _active?.id == id;
    final result = await _store.deleteBatch(id);
    if (!result.ok) {
      _logger.warning('AI 推歌：删除历史批次失败，保留内存状态');
      return;
    }
    final index = result.index;
    _historyEntries = index.entries;
    _historyCache.remove(id);
    if (wasActive) {
      _notInterested.clear();
      final fallbackId = index.activeBatchId;
      if (fallbackId == null) {
        _active = null;
      } else {
        final fallback = await loadHistoryBatch(fallbackId);
        _active = fallback;
      }
    }
    notifyListeners();
  }

  /// 清空历史：默认保留 active（只删记录之外的历史与批次键）。
  Future<void> clearHistory() async {
    final result = await _store.clearHistory();
    if (!result.ok) {
      _logger.warning('AI 推歌：清空历史失败，保留内存状态');
      return;
    }
    _historyEntries = result.index.entries;
    final activeId = _active?.id;
    _historyCache.removeWhere((id, _) => id != activeId);
    notifyListeners();
  }

  /// 按需加载历史详情（不切换 active）。
  Future<AiDjBatch?> loadHistoryBatch(String id) async {
    if (_active?.id == id) return _active;
    final cached = _historyCache[id];
    if (cached != null) return cached;
    final stored = await _store.loadBatch(id);
    if (stored == null) return null;
    final batch = _restoreBatch(stored);
    _historyCache[id] = batch;
    if (_historyCache.length > _historyCacheLimit) {
      _historyCache.remove(_historyCache.keys.first);
    }
    return batch;
  }

  Future<void> _switchActive(AiDjBatch batch) async {
    _active = batch;
    _notInterested.clear();
    _historyCache[batch.id] = batch;
    await _store.setActive(batch.id);
    notifyListeners();
  }

  /// 退出推歌（电台）。默认保留当前队列继续播放（清空由调用方显式传 false）。
  ///
  /// 功能启用状态与推荐列表不受影响（退出队列 ≠ 关闭功能）。
  Future<void> stop({bool keepQueue = true}) async {
    _radioStoppedByUser = true;
    if (_status == AiDjStatus.off) return;
    _cancelAutoFeed();
    _setStatus(AiDjStatus.off);
    _explicitBusy = false;
    _lastError = null;
    _trackedUri = null;
    notifyListeners();
    if (!keepQueue) {
      await _playbackProvider.stopLocalPlayback();
    }
  }

  /// 播放快照变化：跳过判定 + 低水位静默补歌。
  ///
  /// 播放被停止或队列换成本地内容时只结束「电台」，功能保持启用。
  void onPlaybackChanged() {
    if (_adoptRestoredRadioIfNeeded()) notifyListeners();
    if (_status != AiDjStatus.playing) return;
    final snapshot = _playbackProvider.snapshot;
    if (snapshot.current == null) {
      // 播放被外部停止：电台结束（不报错），功能与列表保持。
      _setStatus(AiDjStatus.off);
      _trackedUri = null;
      notifyListeners();
      return;
    }
    _trackSwitch(snapshot);
    // 低水位补歌只在「当前队列就是 AI 推荐队列」时触发：用户换听别的
    // 内容不应继续喂 AI 歌。
    if (!_isRadioQueue(snapshot)) {
      _setStatus(AiDjStatus.off);
      _trackedUri = null;
      notifyListeners();
      return;
    }
    final upcoming = snapshot.queue.length - snapshot.currentIndex - 1;
    if (upcoming <= lowWatermark) {
      _maybeAutoFeed(snapshot);
    }
  }

  /// 进度 tick：记录当前 AI 曲目到达的最大位置（跳过判定用）。
  void onPositionChanged() {
    final uri = _trackedUri;
    if (uri == null) return;
    final entry = _sessionTracks[uri];
    if (entry == null) return;
    final positionMs = _playbackProvider.currentPosition.inMilliseconds;
    if (positionMs > entry.maxPositionMs) entry.maxPositionMs = positionMs;
  }

  Future<AiDjBatch?> _runExplicitGeneration({
    required AiDjOrigin origin,
    required int count,
  }) async {
    final makeActive = origin == AiDjOrigin.refresh;
    final appendToQueue = origin == AiDjOrigin.manualFeed;
    if (!hasConfig) return null;
    if (origin == AiDjOrigin.manualFeed &&
        _status != AiDjStatus.playing &&
        _status != AiDjStatus.error) {
      return null;
    }
    // 显式优先：取消在途静默任务，并用新 epoch 丢弃晚到结果。
    _cancelAutoFeed();
    final token = AiGenerationCancelToken();
    final epoch = ++_generationEpoch;
    _cancelToken = token;
    _explicitBusy = true;
    _lastError = null;
    _progress = AiDjProgress(
      phase: AiDjPhase.profile,
      startedAt: DateTime.now(),
    );
    notifyListeners();
    try {
      _collectNewLikes();
      final snapshot = _snapshotPreferences();
      final batch = await _recommendationService.generate(
        config: _config!,
        count: count,
        preferences: snapshot,
        skippedLabels: mergedSkippedLabels,
        likedLabels: mergedLikedLabels,
        excludeLabels: const [],
        cancelToken: token,
        onProgress: (progress) {
          if (epoch != _generationEpoch || token.isCancelled) return;
          _progress = progress;
          notifyListeners();
        },
      );
      if (epoch != _generationEpoch || token.isCancelled) return null;
      if (batch.items.isEmpty) {
        throw const SourceFailure(
          kind: FailureKind.unknown,
          message: '本批没有可播放的曲目',
          l10nKey: 'aiDjNothingResolved',
          retryable: true,
        );
      }
      final stamped = _stampBatch(batch, origin, snapshot);
      if (appendToQueue) {
        await _playbackProvider.enqueueDomainTracks(
          [for (final item in stamped.items) item.track],
        );
        _registerSessionTracks(stamped.items);
        _queuedCount += stamped.items.length;
      }
      if (makeActive) {
        _active = stamped;
        await _store.saveBatch(_toStored(stamped), makeActive: true);
      } else {
        await _store.saveBatch(_toStored(stamped));
      }
      _rememberHistory(stamped);
      _lastSentPrompt = stamped.prompt;
      _lastRawResponse = stamped.rawResponse;
      await _consumeSeeds();
      if (origin != AiDjOrigin.autoFeed) {
        _autoFeedHalted = false;
        _autoFeedFailures = 0;
        _autoFeedError = null;
      }
      return stamped;
    } on SourceFailure catch (failure) {
      if (failure.kind == FailureKind.cancelled ||
          epoch != _generationEpoch ||
          token.isCancelled) {
        return null;
      }
      _lastError = failure;
      _logger.warning('AI 推歌：${origin.storageValue} 生成失败 ${failure.message}');
      return null;
    } catch (e) {
      if (epoch != _generationEpoch || token.isCancelled) return null;
      _lastError = _failureOf(e);
      _logger.severe('AI 推歌：${origin.storageValue} 生成失败', e);
      return null;
    } finally {
      if (epoch == _generationEpoch) {
        _explicitBusy = false;
        _progress = null;
        _cancelToken = null;
        notifyListeners();
      }
    }
  }

  /// 静默补歌：不设置进度 / busy / 状态，不切换 active。
  Future<void> _autoFeed() async {
    if (!hasConfig || !_enabled || !_preferences.autoFeed || _autoFeedHalted) {
      return;
    }
    if (_explicitBusy || _autoFeedInFlight) return;
    final before = _playbackProvider.snapshot;
    final token = AiGenerationCancelToken();
    _autoCancelToken = token;
    _autoFeedInFlight = true;
    try {
      _collectNewLikes();
      final snapshot = _snapshotPreferences();
      final batch = await _recommendationService.generate(
        config: _config!,
        count: snapshot.batchSize,
        preferences: snapshot,
        skippedLabels: mergedSkippedLabels,
        likedLabels: mergedLikedLabels,
        excludeLabels: const [],
        cancelToken: token,
      );
      if (token.isCancelled) return;
      if (batch.items.isEmpty) {
        throw const SourceFailure(
          kind: FailureKind.unknown,
          message: '本批没有可播放的曲目',
          l10nKey: 'aiDjNothingResolved',
          retryable: true,
        );
      }
      final stamped = _stampBatch(batch, AiDjOrigin.autoFeed, snapshot);
      await _playbackProvider
          .enqueueDomainTracks([for (final item in stamped.items) item.track]);
      if (token.isCancelled) return;
      await _store.saveBatch(_toStored(stamped));
      _rememberHistory(stamped);
      _registerSessionTracks(stamped.items);
      _queuedCount += stamped.items.length;
      _autoFeedFailures = 0;
      _autoFeedError = null;
      await _consumeSeeds();
      // 队列已经播完：从新追加的第一首静默续播（不提示、不改 active）。
      final after = _playbackProvider.snapshot;
      final oldLastIndex = before.queue.length - 1;
      if (after.current != null &&
          !after.isPlaying &&
          after.currentIndex >= oldLastIndex &&
          stamped.items.isNotEmpty) {
        await _playbackProvider
            .playLocalQueueItemById(stamped.items.first.track.id.uri);
      }
      notifyListeners();
    } on SourceFailure catch (failure) {
      if (failure.kind == FailureKind.cancelled || token.isCancelled) return;
      _recordAutoFeedFailure(failure);
    } catch (e) {
      if (token.isCancelled) return;
      _recordAutoFeedFailure(_failureOf(e));
    } finally {
      if (identical(_autoCancelToken, token)) _autoCancelToken = null;
      _autoFeedInFlight = false;
    }
  }

  void _maybeAutoFeed(PlaybackSnapshot snapshot) {
    if (!_enabled || !_preferences.autoFeed || _autoFeedHalted) return;
    if (_status != AiDjStatus.playing) return;
    if (_explicitBusy || _autoFeedInFlight || _autoCancelToken != null) return;
    if (!_isRadioQueue(snapshot)) return;
    unawaited(_autoFeed());
  }

  void _recordAutoFeedFailure(SourceFailure failure) {
    _autoFeedFailures++;
    _autoFeedError = failure;
    _logger.warning(
      'AI 推歌：静默补歌失败（第 $_autoFeedFailures 次）${failure.message}',
    );
    if (_autoFeedFailures >= maxConsecutiveFailures) {
      // 连续失败停止自动补歌：不打断播放、不弹提示，只留内部错误状态。
      _autoFeedHalted = true;
    }
    notifyListeners();
  }

  AiPreferences _snapshotPreferences() =>
      _preferences.copyWith(seeds: _feedback.seeds);

  AiDjBatch _stampBatch(
    AiDjBatch batch,
    AiDjOrigin origin,
    AiPreferences preferences,
  ) {
    final id = batch.id.trim().isEmpty
        ? DateTime.now().microsecondsSinceEpoch.toString()
        : batch.id;
    return batch.copyWith(
      id: id,
      origin: origin,
      preferences: preferences,
    );
  }

  Future<void> _storeActive(AiDjBatch batch) async {
    await _store.saveBatch(_toStored(batch), makeActive: true);
    _rememberHistory(batch);
  }

  void _rememberHistory(AiDjBatch batch) {
    final entry = AiDjHistoryEntry(
      id: batch.id,
      generatedAt: batch.generatedAt,
      itemCount: batch.items.length,
      unresolvedCount: batch.unresolved.length,
      origin: batch.origin,
      preferences: batch.preferences,
    );
    _historyEntries = [
      entry,
      for (final existing in _historyEntries)
        if (existing.id != entry.id) existing,
    ]..sort((a, b) => b.generatedAt.compareTo(a.generatedAt));
    _historyCache[batch.id] = batch;
    _trimMemoryHistory();
  }

  void _trimMemoryHistory() {
    final result = trimAiDjHistory(
      _historyEntries,
      activeBatchId: _active?.id,
      now: DateTime.now(),
    );
    _historyEntries = result.kept;
    final known = {for (final entry in result.kept) entry.id};
    _historyCache.removeWhere((id, _) => !known.contains(id));
  }

  Future<void> _consumeSeeds() async {
    if (_feedback.seeds.isEmpty) return;
    _feedback = _feedback.withSeeds(const []);
    await _settingsStore.saveFeedbackMemory(_feedback);
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

  /// 当前播放队列是否就是 AI 推荐队列（上下文名判定，含恢复态）。
  bool _isRadioQueue(PlaybackSnapshot snapshot) =>
      snapshot.context?.name == kAiDjContextName;

  Set<String> _queuedUris() => {
        for (final track in _playbackProvider.snapshot.queue) track.id.uri,
      };

  List<ResolvedRecommendation> _missingFromQueue(
    List<ResolvedRecommendation> items,
  ) {
    final queued = _queuedUris();
    return [
      for (final item in items)
        if (!queued.contains(item.track.id.uri)) item,
    ];
  }

  void _resetRadioSession() {
    _skippedLabels.clear();
    _likedLabels.clear();
    _sessionTracks.clear();
    _trackedUri = null;
    _queuedCount = 0;
  }

  void _registerSessionTracks(List<ResolvedRecommendation> items) {
    for (final item in items) {
      final uri = item.track.id.uri;
      _sessionTracks[uri] = _SessionTrack(
        label: item.source.label,
        sourceKey: item.track.id.sourceKey,
        songId: item.track.id.id,
        durationMs: item.track.duration?.inMilliseconds ?? 0,
      );
    }
  }

  /// 会话内新收藏的曲目（喜欢 = 收藏），只回流一次并写入长期记忆。
  List<String> _collectNewLikes({bool mark = true}) {
    final liked = <String>[];
    for (final entry in _sessionTracks.values) {
      if (entry.likedReported) continue;
      if (_libraryProvider.isFavorite(entry.sourceKey, entry.songId)) {
        liked.add(entry.label);
        if (!mark) continue;
        entry.likedReported = true;
        _likedLabels.add(entry.label);
        _feedback = _feedback.addLiked(entry.label);
      }
    }
    if (mark && liked.isNotEmpty) {
      _preferencesRevision++;
      unawaited(_settingsStore.saveFeedbackMemory(_feedback));
    }
    return liked;
  }

  void _trackSwitch(PlaybackSnapshot snapshot) {
    final uri = snapshot.current?.id.uri;
    if (_trackedUri != null && uri != _trackedUri) {
      _classifyOutcome(_trackedUri!);
    }
    if (uri != _trackedUri) {
      _trackedUri = uri;
      final entry = uri == null ? null : _sessionTracks[uri];
      if (entry != null &&
          entry.durationMs <= 0 &&
          snapshot.duration > Duration.zero) {
        entry.durationMs = snapshot.duration.inMilliseconds;
      }
    }
  }

  void _classifyOutcome(String uri) {
    final entry = _sessionTracks[uri];
    if (entry == null) return;
    final durationMs = entry.durationMs;
    final atEnd = durationMs > 0 &&
        entry.maxPositionMs >= durationMs - completionToleranceMs;
    if (atEnd) return; // 听完：正向默认，不额外回流。
    final threshold = PlayStatisticsLimits.qualifiedThresholdMs(durationMs);
    if (entry.maxPositionMs < threshold &&
        !_skippedLabels.contains(entry.label)) {
      _skippedLabels.add(entry.label);
    }
  }

  SourceFailure _failureOf(Object error) =>
      error is SourceFailure ? error : SourceFailure.from(error);

  static List<String> _unique(List<String> labels) {
    final seen = <String>{};
    return [
      for (final label in labels)
        if (label.trim().isNotEmpty && seen.add(label)) label,
    ];
  }

  bool _disposed = false;

  /// dispose 后不再发通知（未 await 的预取/补歌可能晚于 dispose）。
  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelToken?.cancel();
    _cancelAutoFeedToken();
    super.dispose();
  }
}
