/// AI 推歌模式控制器：模式状态机 + 播放协调 + 反馈回流。
///
/// 组合根接线（main.dart）：
/// - `PlaybackProvider.addListener(aiDjProvider.onPlaybackChanged)`；
/// - `PlaybackProvider.position.addListener(aiDjProvider.onPositionChanged)`。
///
/// 行为：
/// - 批次 20 首；队列剩余 ≤5 首时后台生成下一批并 `enqueueDomainTracks`；
/// - 跳过 = 曲目被切走时到达位置 < min(30s, 50%×时长)（复用统计口径），
///   只做曲目级排除；喜欢 = 收藏（生成时检查会话内曲目是否已收藏）；
/// - 生成失败保留当前队列继续播放；连续 3 次失败自动停止续推；
/// - 退出模式保留队列继续播（清空队列由调用方显式传 keepQueue: false）。
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
import '../services/ai/ai_pending_batch_store.dart';
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

class AiDjProvider extends ChangeNotifier {
  AiDjProvider({
    required PlaybackProvider playbackProvider,
    required LibraryProvider libraryProvider,
    required AiRecommendationGenerator recommendationService,
    required AiSettingsStore settingsStore,
    AiPendingBatchStore? pendingStore,
  })  : _playbackProvider = playbackProvider,
        _libraryProvider = libraryProvider,
        _recommendationService = recommendationService,
        _settingsStore = settingsStore,
        _pendingStore = pendingStore ?? AiPendingBatchStore();

  final PlaybackProvider _playbackProvider;
  final LibraryProvider _libraryProvider;
  final AiRecommendationGenerator _recommendationService;
  final AiSettingsStore _settingsStore;
  final AiPendingBatchStore _pendingStore;
  final Logger _logger = Logger();

  /// 每批推荐数量。
  static const int batchSize = 20;

  /// 待播批次缓存有效期（发现页打开不重复花 token）。
  static const Duration pendingTtl = Duration(hours: 12);

  /// 队列剩余曲目 ≤ 此值时续推。
  static const int lowWatermark = 5;

  /// 连续失败达到此值时自动停止续推（保留当前队列）。
  static const int maxConsecutiveFailures = 3;

  /// 完整播放容差（与统计口径一致）。
  static const int completionToleranceMs = 1000;

  LlmConfig? _config;
  bool _consentGranted = false;
  AiDjStatus _status = AiDjStatus.off;
  AiDjBatch? _currentBatch;
  AiDjBatch? _pendingBatch;
  SourceFailure? _lastError;
  bool _busy = false;
  int _queuedCount = 0;
  int _failureCount = 0;

  /// 模式状态的可监听出口（播放页徽标等轻量订阅者用；与 [status] 同步）。
  final ValueNotifier<AiDjStatus> statusListenable =
      ValueNotifier<AiDjStatus>(AiDjStatus.off);

  final List<String> _skippedLabels = [];
  final List<String> _likedLabels = [];
  final Map<String, _SessionTrack> _sessionTracks = {};
  String? _trackedUri;

  LlmConfig? get config => _config;
  bool get hasConfig => _config != null;
  bool get consentGranted => _consentGranted;

  AiDjStatus get status => _status;

  void _setStatus(AiDjStatus value) {
    _status = value;
    statusListenable.value = value;
  }

  bool get isActive =>
      _status == AiDjStatus.preparing || _status == AiDjStatus.playing;
  bool get isBusy => _busy;
  AiDjBatch? get currentBatch => _currentBatch;
  SourceFailure? get lastError => _lastError;

  /// 待播批次（发现页 carousel 展示的"下一批"；播放时入队）。
  AiDjBatch? get pendingBatch => _pendingBatch;
  bool get hasPendingBatch =>
      _pendingBatch != null && _pendingBatch!.items.isNotEmpty;

  /// 待播批次是否过期（超 [pendingTtl]，开页时静默替换）。
  bool get pendingExpired {
    final batch = _pendingBatch;
    return batch != null && !_isFresh(batch);
  }

  /// 会话内已入队的 AI 曲目总数。
  int get queuedCount => _queuedCount;
  List<String> get skippedLabels => List.unmodifiable(_skippedLabels);
  List<String> get likedLabels => List.unmodifiable(_likedLabels);

  Future<void> init() async {
    _config = await _settingsStore.readConfig();
    _consentGranted = await _settingsStore.hasConsent();
    _pendingBatch = await _restorePendingBatch();
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

  /// 开启模式：生成第一批并从第 0 首起播（替换当前队列）。
  Future<void> start() async {
    if (_status == AiDjStatus.preparing || _status == AiDjStatus.playing) {
      return;
    }
    final config = _config;
    if (config == null) {
      _lastError = const SourceFailure(
        kind: FailureKind.unauthorized,
        message: '未配置 AI 服务',
        l10nKey: 'aiDjNotConfigured',
      );
      _setStatus(AiDjStatus.error);
      notifyListeners();
      return;
    }

    _setStatus(AiDjStatus.preparing);
    _lastError = null;
    _busy = true;
    notifyListeners();
    var played = false;
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
      _resetSession(batch);
      await _playbackProvider.playDomainTracks(
        [for (final item in batch.items) item.track],
        0,
        contextName: kAiDjContextName,
      );
      _registerSessionTracks(batch.items);
      _setStatus(AiDjStatus.playing);
      _failureCount = 0;
      played = true;
    } catch (e) {
      _lastError = _failureOf(e);
      _setStatus(AiDjStatus.error);
      _logger.e('AI 推歌：首批生成失败', error: e);
    } finally {
      _busy = false;
      notifyListeners();
    }
    // 起播后预取"下一批"：carousel 持续有内容、低水位续推无等待。
    if (played) unawaited(_prefetchPending());
  }

  /// 发现页 carousel 打开时调用：配置 + 隐私确认齐备且缓存缺失/过期时
  /// 静默生成一批（12h 内不重复花 token）。
  ///
  /// 上次生成失败后**不自动重试**（由错误卡的「重试」显式触发，
  /// 避免每次 rebuild 都刷请求的失败循环）。
  Future<void> ensurePendingBatch() async {
    if (!hasConfig || !_consentGranted) return;
    if (_lastError != null) return;
    final batch = _pendingBatch;
    if (batch != null && _isFresh(batch)) return;
    await _prefetchPending();
  }

  /// 「换一批」：替换待播批次（推歌中只换"下一批"，不打断当前播放）。
  Future<void> refreshPendingBatch() => _prefetchPending();

  /// 点击 carousel 卡片：从第 [index] 首开始播放，AI 接管队列。
  ///
  /// - 该曲已在队列（推歌中）→ 直接跳转；
  /// - 否则整批入队并从该首起播（替换当前队列），模式置「推歌中」。
  Future<void> playFromPending(int index) async {
    final batch = _pendingBatch;
    if (batch == null || index < 0 || index >= batch.items.length) return;
    final uri = batch.items[index].track.id.uri;

    final queue = _playbackProvider.snapshot.queue;
    if (queue.any((track) => track.id.uri == uri)) {
      await _playbackProvider.playLocalQueueItemById(uri);
      return;
    }
    if (_busy) return;
    _busy = true;
    notifyListeners();
    try {
      _resetSession(batch);
      await _playbackProvider.playDomainTracks(
        [for (final item in batch.items) item.track],
        index,
        contextName: kAiDjContextName,
      );
      _registerSessionTracks(batch.items);
      _setStatus(AiDjStatus.playing);
      _failureCount = 0;
      _lastError = null;
      await _clearPending();
    } catch (e) {
      _lastError = _failureOf(e);
      _setStatus(AiDjStatus.error);
      _logger.e('AI 推歌：从推荐流起播失败', error: e);
    } finally {
      _busy = false;
      notifyListeners();
    }
    unawaited(_prefetchPending());
  }

  /// 继续推一批（手动「再来一批」/ 低水位自动续推）：
  /// 保证有待播批次并追加到队尾，随后预取下一批。
  Future<void> feedMore() async {
    if (_busy) return;
    if (_status != AiDjStatus.playing && _status != AiDjStatus.error) return;
    _busy = true;
    if (_status == AiDjStatus.error) _setStatus(AiDjStatus.playing);
    notifyListeners();
    var appended = false;
    try {
      final batch = await _ensurePendingForAppend();
      if (batch == null || batch.items.isEmpty) {
        throw const SourceFailure(
          kind: FailureKind.unknown,
          message: '本批没有可播放的曲目',
          l10nKey: 'aiDjNothingResolved',
          retryable: true,
        );
      }
      await _playbackProvider.enqueueDomainTracks(
        [for (final item in batch.items) item.track],
      );
      _registerSessionTracks(batch.items);
      _currentBatch = batch;
      _queuedCount += batch.items.length;
      await _clearPending();
      _failureCount = 0;
      _lastError = null;
      appended = true;
    } catch (e) {
      _failureCount++;
      _lastError = _failureOf(e);
      _logger.e('AI 推歌：续推失败（第 $_failureCount 次）', error: e);
      if (_failureCount >= maxConsecutiveFailures) {
        // 自动停止续推（保留当前队列继续播放）。
        _setStatus(AiDjStatus.off);
        _trackedUri = null;
      }
    } finally {
      _busy = false;
      notifyListeners();
    }
    if (appended) unawaited(_prefetchPending());
  }

  /// 退出模式。默认保留当前队列继续播放（清空由调用方显式传 false）。
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

  /// 播放快照变化：跳过判定 + 低水位续推 + 播放停止自动退出。
  void onPlaybackChanged() {
    if (_status != AiDjStatus.playing) return;
    final snapshot = _playbackProvider.snapshot;
    if (snapshot.current == null) {
      // 播放被外部停止：模式随之结束（不报错）。
      _setStatus(AiDjStatus.off);
      _trackedUri = null;
      notifyListeners();
      return;
    }
    _trackSwitch(snapshot);
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

  Future<AiDjBatch> _generate() => _recommendationService.generate(
        config: _config!,
        count: batchSize,
        skippedLabels: List.of(_skippedLabels),
        likedLabels: [..._likedLabels, ..._collectNewLikes()],
      );

  /// 预取待播批次（不 append；carousel 展示与后续续推共用）。
  Future<void> _prefetchPending() async {
    if (!hasConfig || _busy) return;
    _busy = true;
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
      _pendingBatch = batch;
      _lastError = null;
      await _pendingStore.save(batch);
    } catch (e) {
      // 预取失败只影响 carousel 内容，不触发"连续失败停模式"计数。
      _lastError = _failureOf(e);
      _logger.e('AI 推歌：预取推荐失败', error: e);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 续推取批：优先复用未过期的待播批次，否则现场生成。
  Future<AiDjBatch?> _ensurePendingForAppend() async {
    final batch = _pendingBatch;
    if (batch != null && _isFresh(batch)) return batch;
    final generated = await _generate();
    return generated.items.isEmpty ? null : generated;
  }

  Future<void> _clearPending() async {
    _pendingBatch = null;
    await _pendingStore.clear();
  }

  bool _isFresh(AiDjBatch batch) =>
      DateTime.now().difference(batch.generatedAt) < pendingTtl;

  /// 启动时恢复上次缓存的待播批次（离线/重启后 carousel 立即有内容）。
  Future<AiDjBatch?> _restorePendingBatch() async {
    final stored = await _pendingStore.load();
    if (stored == null || stored.items.isEmpty) return null;
    try {
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
    } catch (_) {
      return null;
    }
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

  void _resetSession(AiDjBatch batch) {
    _skippedLabels.clear();
    _likedLabels.clear();
    _sessionTracks.clear();
    _trackedUri = null;
    _currentBatch = batch;
    _queuedCount = batch.items.length;
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
