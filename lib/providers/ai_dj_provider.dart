/// AI 推歌模式控制器：模式状态机 + 播放协调 + 反馈回流。
///
/// 组合根接线（main.dart）：
/// - `PlaybackProvider.addListener(aiDjProvider.onPlaybackChanged)`；
/// - `PlaybackProvider.position.addListener(aiDjProvider.onPositionChanged)`。
///
/// 行为（issue #9 已拍板）：
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

import '../domain/models/ai_dj.dart';
import '../domain/models/failure.dart';
import '../domain/models/play_statistics.dart';
import '../domain/models/playback.dart';
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
  })  : _playbackProvider = playbackProvider,
        _libraryProvider = libraryProvider,
        _recommendationService = recommendationService,
        _settingsStore = settingsStore;

  final PlaybackProvider _playbackProvider;
  final LibraryProvider _libraryProvider;
  final AiRecommendationGenerator _recommendationService;
  final AiSettingsStore _settingsStore;
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
  AiDjStatus _status = AiDjStatus.off;
  AiDjBatch? _currentBatch;
  SourceFailure? _lastError;
  bool _busy = false;
  int _queuedCount = 0;
  int _failureCount = 0;

  final List<String> _skippedLabels = [];
  final List<String> _likedLabels = [];
  final Map<String, _SessionTrack> _sessionTracks = {};
  String? _trackedUri;

  // ---------------------------------------------------------------------------
  // 状态读取
  // ---------------------------------------------------------------------------

  LlmConfig? get config => _config;
  bool get hasConfig => _config != null;
  bool get consentGranted => _consentGranted;

  AiDjStatus get status => _status;
  bool get isActive =>
      _status == AiDjStatus.preparing || _status == AiDjStatus.playing;
  bool get isBusy => _busy;
  AiDjBatch? get currentBatch => _currentBatch;
  SourceFailure? get lastError => _lastError;

  /// 会话内已入队的 AI 曲目总数。
  int get queuedCount => _queuedCount;
  List<String> get skippedLabels => List.unmodifiable(_skippedLabels);
  List<String> get likedLabels => List.unmodifiable(_likedLabels);

  // ---------------------------------------------------------------------------
  // 配置与隐私确认
  // ---------------------------------------------------------------------------

  Future<void> init() async {
    _config = await _settingsStore.readConfig();
    _consentGranted = await _settingsStore.hasConsent();
    notifyListeners();
  }

  Future<void> saveConfig(LlmConfig config) async {
    await _settingsStore.saveConfig(config);
    _config = config;
    notifyListeners();
  }

  Future<void> clearConfig() async {
    await _settingsStore.clearConfig();
    _config = null;
    notifyListeners();
  }

  Future<void> grantConsent() async {
    await _settingsStore.grantConsent();
    _consentGranted = true;
    notifyListeners();
  }

  /// 连接测试（页面「测试连接」按钮）；失败抛 [SourceFailure]。
  Future<void> testConnection(LlmConfig config) =>
      _recommendationService.testConnection(config);

  // ---------------------------------------------------------------------------
  // 模式控制
  // ---------------------------------------------------------------------------

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
      _status = AiDjStatus.error;
      notifyListeners();
      return;
    }

    _status = AiDjStatus.preparing;
    _lastError = null;
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
      _resetSession(batch);
      await _playbackProvider.playDomainTracks(
        [for (final item in batch.items) item.track],
        0,
        contextName: kAiDjContextName,
      );
      _registerSessionTracks(batch.items);
      _status = AiDjStatus.playing;
      _failureCount = 0;
    } catch (e) {
      _lastError = _failureOf(e);
      _status = AiDjStatus.error;
      _logger.e('AI 推歌：首批生成失败', error: e);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 继续推一批（手动「换一批」/ 低水位自动续推）：生成并追加到队尾。
  Future<void> feedMore() async {
    if (_busy) return;
    if (_status != AiDjStatus.playing && _status != AiDjStatus.error) return;
    _busy = true;
    if (_status == AiDjStatus.error) _status = AiDjStatus.playing;
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
      await _playbackProvider.enqueueDomainTracks(
        [for (final item in batch.items) item.track],
      );
      _registerSessionTracks(batch.items);
      _currentBatch = batch;
      _queuedCount += batch.items.length;
      _failureCount = 0;
      _lastError = null;
    } catch (e) {
      _failureCount++;
      _lastError = _failureOf(e);
      _logger.e('AI 推歌：续推失败（第 $_failureCount 次）', error: e);
      if (_failureCount >= maxConsecutiveFailures) {
        // 自动停止续推（保留当前队列继续播放）。
        _status = AiDjStatus.off;
        _trackedUri = null;
      }
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 退出模式。默认保留当前队列继续播放（清空由调用方显式传 false）。
  Future<void> stop({bool keepQueue = true}) async {
    if (_status == AiDjStatus.off) return;
    _status = AiDjStatus.off;
    _busy = false;
    _failureCount = 0;
    _lastError = null;
    _trackedUri = null;
    notifyListeners();
    if (!keepQueue) {
      await _playbackProvider.stopLocalPlayback();
    }
  }

  // ---------------------------------------------------------------------------
  // 播放接线（组合根调用）
  // ---------------------------------------------------------------------------

  /// 播放快照变化：跳过判定 + 低水位续推 + 播放停止自动退出。
  void onPlaybackChanged() {
    if (_status != AiDjStatus.playing) return;
    final snapshot = _playbackProvider.snapshot;
    if (snapshot.current == null) {
      // 播放被外部停止：模式随之结束（不报错）。
      _status = AiDjStatus.off;
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

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  Future<AiDjBatch> _generate() => _recommendationService.generate(
        config: _config!,
        count: batchSize,
        skippedLabels: List.of(_skippedLabels),
        likedLabels: [..._likedLabels, ..._collectNewLikes()],
      );

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
}
