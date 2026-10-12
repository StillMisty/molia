/// AI 推歌控制器：**今日推荐列表** + **推歌会话（电台）** 的唯一状态机。
///
/// 定位（对齐「个性推荐」）：推荐列表是常驻、可浏览的内容——
/// 持久化在 [AiRecommendationStore]，任何时刻可播、可换、可反馈；
/// 「推歌会话」只是把列表喂进播放队列的自动化：
/// - `enabled`：功能启用（持久化；退出队列不关功能）；
/// - `status`：电台状态（off / preparing / playing / error）；
/// - 低水位续推只在「当前播放队列就是 AI 队列」时触发。
///
/// 组合根接线（main.dart）：
/// - `PlaybackProvider.addListener(aiDjProvider.onPlaybackChanged)`；
/// - `PlaybackProvider.position.addListener(aiDjProvider.onPositionChanged)`。
///
/// 行为：
/// - 批次 20 首；会话剩余 ≤5 首后台续推（先吃列表剩余，吃完了生成新批）；
/// - 跳过 = 曲目被切走时到达位置 < min(30s, 50%×时长)（复用统计口径），
///   只做曲目级排除；喜欢 = 收藏（生成时检查会话内曲目是否已收藏）；
/// - 生成失败保留当前队列继续播放；连续 3 次失败自动停止续推；
/// - 「不感兴趣」= 从列表移除 + 会话排除（可撤销）；
/// - 缓存有效期（`aiDjCacheTtlDays`）只影响续推是否消费旧列表：过期则生成
///   新批替换缓存，不弹提示、不打断播放。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

import '../data/mapping/track_mapper.dart';
import '../domain/models/ai_dj.dart';
import '../domain/models/failure.dart';
import '../domain/models/play_statistics.dart';
import '../domain/models/playback.dart';
import '../domain/models/track.dart';
import '../services/ai/ai_recommendation_store.dart';
import '../services/ai/ai_recommendation_service.dart';
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

  /// 已计入「收藏」反馈，避免重复回流。
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
  })  : _playbackProvider = playbackProvider,
        _libraryProvider = libraryProvider,
        _recommendationService = recommendationService,
        _settingsStore = settingsStore,
        _store = recommendationStore ?? AiRecommendationStore();

  final PlaybackProvider _playbackProvider;
  final LibraryProvider _libraryProvider;
  final AiRecommendationGenerator _recommendationService;
  final AiSettingsStore _settingsStore;
  final AiRecommendationStore _store;
  final Logger _logger = Logger();

  /// 每批推荐数量。
  static const int batchSize = 20;

  /// 队列剩余曲目 ≤ 此值时续推。
  static const int lowWatermark = 5;

  /// 连续失败达到此值时自动停止续推（保留当前队列）。
  static const int maxConsecutiveFailures = 3;

  /// 完整播放容差（与统计口径一致）。
  static const int completionToleranceMs = 1000;

  LlmConfig? _config;
  bool _consentGranted = false;

  /// 功能启用（持久化）：与「推歌会话」解耦——退出队列不关功能。
  bool _enabled = false;

  /// 推荐列表缓存有效期（天；0 = 永久）。
  int _cacheTtlDays = kAiDefaultCacheTtlDays;

  /// 今日推荐列表（持久化；「换一批」替换）。
  AiDjBatch? _list;
  AiDjStatus _status = AiDjStatus.off;
  SourceFailure? _lastError;
  bool _busy = false;
  int _queuedCount = 0;
  int _failureCount = 0;

  final List<String> _skippedLabels = [];
  final List<String> _likedLabels = [];
  final List<_NotInterestedItem> _notInterested = [];
  final Map<String, _SessionTrack> _sessionTracks = {};
  String? _trackedUri;

  LlmConfig? get config => _config;
  bool get hasConfig => _config != null;
  bool get consentGranted => _consentGranted;

  /// 功能启用（发现页推荐区与页面列表的显示条件）。
  bool get enabled => _enabled;

  /// 电台状态（off = 未接管播放；功能可以仍处于启用）。
  AiDjStatus get status => _status;

  void _setStatus(AiDjStatus value) {
    _status = value;
  }

  /// 电台是否生效（生成中 / 推歌中）。
  bool get isFeeding =>
      _status == AiDjStatus.preparing || _status == AiDjStatus.playing;

  bool get isBusy => _busy;

  /// 今日推荐列表（可能为空：未生成 / 已清空）。
  AiDjBatch? get recommendations => _list;
  bool get hasRecommendations => _list != null && _list!.items.isNotEmpty;
  DateTime? get lastUpdatedAt => _list?.generatedAt;

  /// 列表缓存有效期（天；0 = 永久）。
  int get cacheTtlDays => _cacheTtlDays;

  /// 列表是否已过缓存有效期（只影响续推是否消费它，不做提示）。
  bool get isRecommendationsExpired {
    final batch = _list;
    if (batch == null) return false;
    return _isExpired(batch);
  }

  SourceFailure? get lastError => _lastError;

  /// 会话内已入队的 AI 曲目总数。
  int get queuedCount => _queuedCount;

  /// 自动判定 + 手动「不感兴趣」的跳过项（回流到下一批 prompt）。
  List<String> get skippedLabels => List.unmodifiable(_skippedLabels);
  List<String> get likedLabels => List.unmodifiable(_likedLabels);

  /// 手动「不感兴趣」项（可撤销）。
  List<ResolvedRecommendation> get notInterestedItems =>
      List.unmodifiable([for (final entry in _notInterested) entry.item]);

  /// 列表项是否已在播放队列（页面标记「队列中」）。
  bool isQueued(String uri) => _playbackProvider.snapshot.queue
      .any((track) => track.id.uri == uri);

  Future<void> init() async {
    _config = await _settingsStore.readConfig();
    _consentGranted = await _settingsStore.hasConsent();
    _enabled = await _settingsStore.readEnabled();
    _cacheTtlDays = await _settingsStore.readCacheTtlDays();
    final stored = await _store.load();
    if (stored != null) _list = _restoreList(stored);
    notifyListeners();
  }

  Future<void> saveConfig(LlmConfig config) async {
    await _settingsStore.saveConfig(config);
    _config = config;
    _lastError = null; // 新配置：允许自动生成/重试
    notifyListeners();
  }

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
      return await _recommendationService.summarizeUpstream();
    } catch (e) {
      _logger.w('AI 推歌：上行摘要失败 $e');
      return null;
    }
  }

  /// 功能开关：只控制「推荐可用」，不接管播放（播放全部/点某首才进电台）。
  ///
  /// 关闭时停止续推（保留当前队列），列表缓存保留（再次开启即回来）。
  Future<void> setEnabled(bool value) async {
    if (value == _enabled) return;
    _enabled = value;
    await _settingsStore.saveEnabled(value);
    if (!value) {
      _status = AiDjStatus.off;
      _trackedUri = null;
    }
    notifyListeners();
    if (value) await ensureRecommendations();
  }

  /// 设置推荐列表缓存有效期（天；0 = 永久）。
  Future<void> setCacheTtlDays(int days) async {
    if (!kAiCacheTtlDayOptions.contains(days) || days == _cacheTtlDays) return;
    _cacheTtlDays = days;
    await _settingsStore.saveCacheTtlDays(days);
    notifyListeners();
  }

  /// 确保有可浏览的推荐列表。
  ///
  /// 仅在「启用 + 已配置 + 已确认 + 列表缺失 + 上次没有失败」时生成：
  /// 不跨天自动换批（不静默消耗 token），失败后也不自动重试。
  Future<void> ensureRecommendations() async {
    if (!_enabled || !hasConfig || !_consentGranted) return;
    if (_list != null) return;
    if (_lastError != null) return;
    await refreshRecommendations();
  }

  /// 「换一批」：生成并替换推荐列表（后台持久化）。
  ///
  /// 推歌中只替换"下一批来源"，不打断当前播放；「不感兴趣」记录随之清空。
  Future<void> refreshRecommendations() async {
    if (!hasConfig || _busy) return;
    _busy = true;
    _lastError = null;
    notifyListeners();
    try {
      final batch = await _generate();
      if (batch.isEmpty) {
        throw const SourceFailure(
          kind: FailureKind.unknown,
          message: '本批没有可播放的曲目',
          l10nKey: 'aiDjNothingResolved',
          retryable: true,
        );
      }
      _list = batch;
      _notInterested.clear();
      _failureCount = 0;
      await _store.save(batch);
    } catch (e) {
      _lastError = _failureOf(e);
      _logger.e('AI 推歌：生成推荐列表失败', error: e);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 开始推歌（电台）：用推荐列表替换当前队列并从 [fromIndex] 起播。
  ///
  /// 列表缺失时先生成（显式用户动作）。该曲已在队列中时只做跳转，
  /// 不替换队列。
  Future<void> startRadio({int fromIndex = 0}) async {
    if (_busy) return;
    if (_list == null) {
      await ensureRecommendations();
    }
    final list = _list;
    if (list == null || list.items.isEmpty) return;
    final clamped = fromIndex.clamp(0, list.items.length - 1).toInt();
    final uri = list.items[clamped].track.id.uri;
    if (isQueued(uri)) {
      await _playbackProvider.playLocalQueueItemById(uri);
      _trackedUri = uri;
      return;
    }

    _busy = true;
    _lastError = null;
    _setStatus(AiDjStatus.preparing);
    notifyListeners();
    try {
      _resetRadioSession();
      await _playbackProvider.playDomainTracks(
        [for (final item in list.items) item.track],
        clamped,
        contextName: kAiDjContextName,
      );
      _registerSessionTracks(list.items);
      _queuedCount = list.items.length - clamped;
      _setStatus(AiDjStatus.playing);
      _failureCount = 0;
      _lastError = null;
    } catch (e) {
      _lastError = _failureOf(e);
      _setStatus(AiDjStatus.error);
      _logger.e('AI 推歌：起播失败', error: e);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 播放列表中的某一首：已在队列则跳转，否则从该首接管队列。
  Future<void> playRecommendation(int index) => startRadio(fromIndex: index);

  /// 「全部加入队列」：把推荐列表里还没入队的曲目追加到队尾（不打断播放）。
  Future<void> enqueueRecommendations() async {
    final list = _list;
    if (list == null || list.items.isEmpty || _busy) return;
    final queued = _queuedUris();
    final missing = [
      for (final item in list.items)
        if (!queued.contains(item.track.id.uri)) item,
    ];
    if (missing.isEmpty) return;
    _busy = true;
    _lastError = null;
    notifyListeners();
    try {
      await _playbackProvider
          .enqueueDomainTracks([for (final item in missing) item.track]);
      _registerSessionTracks(missing);
      _queuedCount += missing.length;
      _failureCount = 0;
    } catch (e) {
      _lastError = _failureOf(e);
      _logger.e('AI 推歌：加入队列失败', error: e);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 单曲「换一首」：重新生成一首替换列表项；已在队列则原位跟随替换。
  Future<void> replaceRecommendation(int index) async {
    final list = _list;
    if (list == null || index < 0 || index >= list.items.length || _busy) {
      return;
    }
    final target = list.items[index];
    _busy = true;
    _lastError = null;
    notifyListeners();
    try {
      final generated = await _recommendationService.generate(
        config: _config!,
        count: 1,
        skippedLabels: List.of(_skippedLabels),
        likedLabels: [..._likedLabels, ..._collectNewLikes()],
        excludeLabels: [for (final item in list.items) item.source.label],
      );
      final replacement =
          generated.items.isNotEmpty ? generated.items.first : null;
      if (replacement == null) {
        throw const SourceFailure(
          kind: FailureKind.unknown,
          message: '换一首没有生成可播放的曲目',
          l10nKey: 'aiDjNothingResolved',
          retryable: true,
        );
      }
      final items = List<ResolvedRecommendation>.of(list.items);
      items[index] = replacement;
      _list = list.copyWith(items: items);
      await _store.save(_list!);
      if (_queuedUris().contains(target.track.id.uri)) {
        await _playbackProvider
            .replaceQueueTrack(target.track, replacement.track);
      }
      _failureCount = 0;
    } catch (e) {
      _lastError = _failureOf(e);
      _logger.e('AI 推歌：换一首失败', error: e);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 「不感兴趣」：从推荐列表移除 + 会话排除（下一批不再推荐），可撤销。
  Future<void> markNotInterested(String uri) async {
    final list = _list;
    if (list == null) return;
    final index = list.items.indexWhere((item) => item.track.id.uri == uri);
    if (index < 0) return;
    final item = list.items[index];
    if (!_skippedLabels.contains(item.source.label)) {
      _skippedLabels.add(item.source.label);
    }
    _notInterested.insert(0, _NotInterestedItem(index: index, item: item));
    final items = List<ResolvedRecommendation>.of(list.items)..removeAt(index);
    _list = list.copyWith(items: items);
    await _store.save(_list!);
    notifyListeners();
  }

  /// 撤销「不感兴趣」：原位插回列表并解除排除。
  Future<void> undoNotInterested(String uri) async {
    final position =
        _notInterested.indexWhere((entry) => entry.item.track.id.uri == uri);
    if (position < 0) return;
    final entry = _notInterested.removeAt(position);
    _skippedLabels.remove(entry.item.source.label);
    final list = _list;
    if (list != null) {
      final items = List<ResolvedRecommendation>.of(list.items);
      items.insert(entry.index.clamp(0, items.length), entry.item);
      _list = list.copyWith(items: items);
      await _store.save(_list!);
    }
    notifyListeners();
  }

  /// 继续推一批（手动「加入队列」/ 低水位自动续推）：追加到队尾。
  Future<void> feedMore() async {
    if (_busy) return;
    if (_status != AiDjStatus.playing && _status != AiDjStatus.error) return;
    _busy = true;
    if (_status == AiDjStatus.error) _setStatus(AiDjStatus.playing);
    notifyListeners();
    var appended = false;
    try {
      final batch = await _nextBatchForAppend();
      if (batch == null || batch.items.isEmpty) {
        throw const SourceFailure(
          kind: FailureKind.unknown,
          message: '本批没有可播放的曲目',
          l10nKey: 'aiDjNothingResolved',
          retryable: true,
        );
      }
      await _playbackProvider
          .enqueueDomainTracks([for (final item in batch.items) item.track]);
      _registerSessionTracks(batch.items);
      _queuedCount += batch.items.length;
      _failureCount = 0;
      _lastError = null;
      appended = true;
    } catch (e) {
      _failureCount++;
      _lastError = _failureOf(e);
      _logger.e('AI 推歌：续推失败（第 $_failureCount 次）', error: e);
      if (_failureCount >= maxConsecutiveFailures) {
        // 自动停止续推（保留当前队列继续播放；功能与列表保持启用）。
        _setStatus(AiDjStatus.off);
        _trackedUri = null;
      }
    } finally {
      _busy = false;
      notifyListeners();
    }
    if (appended) notifyListeners();
  }

  /// 退出推歌（电台）。默认保留当前队列继续播放（清空由调用方显式传 false）。
  ///
  /// 功能启用状态与推荐列表不受影响（退出队列 ≠ 关闭功能）。
  Future<void> stop({bool keepQueue = true}) async {
    if (_status == AiDjStatus.off) return;
    _setStatus(AiDjStatus.off);
    _busy = false;
    _failureCount = 0;
    _lastError = null;
    _trackedUri = null;
    notifyListeners();
    if (!keepQueue) {
      await _playbackProvider.stopLocalPlayback();
    }
  }

  /// 播放快照变化：跳过判定 + 低水位续推。
  ///
  /// 播放被停止或队列换成本地内容时只结束「电台」，功能保持启用。
  void onPlaybackChanged() {
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
    // 低水位续推只在「当前队列就是 AI 推荐队列」时触发：用户换听别的
    // 内容不应继续喂 AI 歌。
    if (!_isRadioQueue(snapshot)) {
      _setStatus(AiDjStatus.off);
      _trackedUri = null;
      notifyListeners();
      return;
    }
    final upcoming = snapshot.queue.length - snapshot.currentIndex - 1;
    if (upcoming <= lowWatermark && !_busy) {
      unawaited(feedMore());
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

  /// 当前播放队列是否就是 AI 推荐队列（上下文名判定，含恢复态）。
  bool _isRadioQueue(PlaybackSnapshot snapshot) =>
      snapshot.context?.name == kAiDjContextName;

  Set<String> _queuedUris() => {
        for (final track in _playbackProvider.snapshot.queue) track.id.uri,
      };

  Future<AiDjBatch> _generate() => _recommendationService.generate(
        config: _config!,
        count: batchSize,
        skippedLabels: List.of(_skippedLabels),
        likedLabels: [..._likedLabels, ..._collectNewLikes()],
      );

  /// 续推取批：未过期的列表里还有未入队曲目 → 先吃列表；否则生成新批
  /// 并替换持久化列表（过期列表不再被消费，但不删除、不提示）。
  Future<AiDjBatch?> _nextBatchForAppend() async {
    final list = _list;
    if (list != null && !_isExpired(list)) {
      final queued = _queuedUris();
      final remaining = [
        for (final item in list.items)
          if (!queued.contains(item.track.id.uri)) item,
      ];
      if (remaining.isNotEmpty) {
        return AiDjBatch(
          items: remaining,
          unresolved: list.unresolved,
          generatedAt: list.generatedAt,
        );
      }
    }
    final generated = await _generate();
    if (generated.items.isEmpty) return null;
    _list = generated;
    _notInterested.clear();
    await _store.save(generated);
    return generated;
  }

  bool _isExpired(AiDjBatch batch) {
    if (_cacheTtlDays <= 0) return false;
    return DateTime.now().difference(batch.generatedAt) >
        Duration(days: _cacheTtlDays);
  }

  /// 启动时恢复持久化的推荐列表（raw 原样）。
  AiDjBatch _restoreList(StoredAiBatch stored) {
    return AiDjBatch(
      items: [
        for (final item in stored.items)
          ResolvedRecommendation(
            source: AiRecommendation(
              title: item.title,
              artist: item.artist,
              reason: item.reason,
            ),
            track: _trackFromStored(item),
          ),
      ],
      unresolved: stored.unresolved,
      generatedAt: stored.generatedAt,
    );
  }

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

  void _resetRadioSession() {
    _skippedLabels.clear();
    _likedLabels.clear();
    _sessionTracks.clear();
    _trackedUri = null;
    _queuedCount = 0;
    _failureCount = 0;
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

  /// 会话内新收藏的曲目（喜欢 = 收藏），只回流一次。
  List<String> _collectNewLikes() {
    final liked = <String>[];
    for (final entry in _sessionTracks.values) {
      if (entry.likedReported) continue;
      if (_libraryProvider.isFavorite(entry.sourceKey, entry.songId)) {
        entry.likedReported = true;
        liked.add(entry.label);
        _likedLabels.add(entry.label);
      }
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
    final threshold = durationMs <= 0
        ? PlayStatisticsLimits.qualifiedMinListenedMs
        : math.min(
            PlayStatisticsLimits.qualifiedMinListenedMs,
            (durationMs * 0.5).floor(),
          );
    if (entry.maxPositionMs < threshold &&
        !_skippedLabels.contains(entry.label)) {
      _skippedLabels.add(entry.label);
    }
  }

  SourceFailure _failureOf(Object error) =>
      error is SourceFailure ? error : SourceFailure.from(error);

  bool _disposed = false;

  /// dispose 后不再发通知（未 await 的预取/续推可能晚于 dispose）。
  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
