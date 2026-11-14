/// AI 电台会话：状态机（off/preparing/playing/error）+ 曲目跟踪 + 队列操作。
///
/// 这里只持有「会话态」与从 live 快照派生的判定：起播后登记、切歌跳过判定、
/// 退出 / 外部停止、低水位是否该补歌、队列操作互斥位、静默补歌失败计数。
/// 生成编排与通知仍归 [AiDjProvider]；本类不依赖 ChangeNotifier，状态落定后
/// 由 provider 统一通知，避免状态机内部再广播一份。
library;

import '../domain/models/ai_dj.dart';
import '../domain/models/failure.dart';
import '../domain/models/play_statistics.dart';
import '../domain/models/playback.dart';
import '../services/ai/ai_radio_queue.dart';
import '../services/ai/ai_text.dart';
import 'library_provider.dart';
import 'playback_provider.dart';

/// 会话内一首 AI 曲目的跟踪状态（跳过 / 喜欢判定）。
class AiSessionTrack {
  AiSessionTrack({
    required this.label,
    required this.promptKey,
    required this.sourceKey,
    required this.songId,
    required this.durationMs,
  });

  final String label;

  /// 提示词 / 本地去重用的规范化键（模型原始 title+artist）。
  final String promptKey;
  final String sourceKey;
  final String songId;
  int durationMs;
  int maxPositionMs = 0;

  /// 已计入「喜欢」反馈，避免重复回流。
  bool likedReported = false;
}

class AiRadioSession {
  AiRadioSession({
    required this._playbackProvider,
    required this._libraryProvider,
    required this._onSkip,
  });

  /// 队列剩余曲目 ≤ 此值时静默补歌。
  static const int lowWatermark = 5;

  /// 连续失败达到此值时停止自动补歌（保留当前队列继续播放）。
  static const int maxConsecutiveFailures = 3;

  /// 完整播放容差（与统计口径一致）。
  static const int completionToleranceMs = 1000;

  final PlaybackProvider _playbackProvider;
  final LibraryProvider _libraryProvider;
  final void Function(String label) _onSkip;

  final Map<String, AiSessionTrack> _sessionTracks = {};

  AiDjStatus _status = AiDjStatus.off;
  String? _trackedUri;

  /// 队列操作（起播 / 加入 / 历史播放）的互斥位；生成忙碌位在 executor。
  bool _queueBusy = false;

  /// 用户显式 stop 后，恢复的 AI 队列不再自动接管（start/播放历史清除）。
  bool _stoppedByUser = false;

  int _autoFeedFailures = 0;
  bool _autoFeedHalted = false;
  SourceFailure? _autoFeedError;

  AiDjStatus get status => _status;
  bool get isFeeding =>
      _status == AiDjStatus.preparing || _status == AiDjStatus.playing;
  bool get queueBusy => _queueBusy;
  String? get trackedUri => _trackedUri;
  bool get stoppedByUser => _stoppedByUser;

  Iterable<AiSessionTrack> get sessionTracks => _sessionTracks.values;

  int get autoFeedFailures => _autoFeedFailures;
  bool get autoFeedHalted => _autoFeedHalted;
  SourceFailure? get autoFeedError => _autoFeedError;

  /// 会话内仍在队列「当前及之后」的 AI 曲目数（从 live 快照派生）。
  int get queuedCount => _radioQueue.queuedAmong(_sessionTracks.keys);

  AiRadioQueue get _radioQueue => AiRadioQueue.of(_playbackProvider.snapshot);

  /// 列表项是否已在播放队列。
  bool isQueued(String uri) => _radioQueue.contains(uri);

  /// 当前播放队列是否就是 AI 推荐队列（上下文名判定，含恢复态）。
  bool isRadioQueue(PlaybackSnapshot snapshot) =>
      snapshot.context?.name == kAiDjContextName;

  /// 只保留还不在队列里的项（不改变入参顺序）。
  List<ResolvedRecommendation> missingFromQueue(
    Iterable<ResolvedRecommendation> items,
  ) => _radioQueue.missing(items, (item) => item.track.id.uri);

  /// 开始一次接管：清空曲目跟踪并进入准备态（本轮反馈由反馈账本清）。
  void start() {
    reset();
    _status = AiDjStatus.preparing;
  }

  /// 清空当前会话的曲目跟踪（起播 / 播放历史批次前）。
  void reset() {
    _sessionTracks.clear();
    _trackedUri = null;
  }

  /// 退出电台：状态归零并停止跟踪；不清队列，也不清曲目记录。
  void stop() {
    _status = AiDjStatus.off;
    _trackedUri = null;
  }

  void markPreparing() => _status = AiDjStatus.preparing;
  void markPlaying() => _status = AiDjStatus.playing;
  void markError() => _status = AiDjStatus.error;
  void markOff() => _status = AiDjStatus.off;

  void clearTracked() => _trackedUri = null;

  /// 已在队时直接跳到该首：只更新跟踪目标，不改电台状态。
  void markTracked(String uri) => _trackedUri = uri;

  void markStoppedByUser() => _stoppedByUser = true;
  void clearStoppedByUser() => _stoppedByUser = false;

  void beginQueueOperation() => _queueBusy = true;
  void endQueueOperation() => _queueBusy = false;

  /// 冷启动 / 切回 AI 队列时接管电台；返回是否接管（含登记整条队列）。
  ///
  /// [canAdopt] 由 provider 给（启用 + 已配置 + 已确认），本类只管会话态。
  bool adoptIfNeeded(PlaybackSnapshot snapshot, {required bool canAdopt}) {
    if (_status != AiDjStatus.off || _stoppedByUser) return false;
    if (!canAdopt) return false;
    final current = snapshot.current;
    if (current == null || !isRadioQueue(snapshot)) return false;
    _status = AiDjStatus.playing;
    _trackedUri = current.id.uri;
    _registerSnapshotTracks(snapshot);
    return true;
  }

  /// 播放快照变化：切歌判定 + 外部停止 / 换听别的队列时结束电台。
  ///
  /// 返回是否发生了需要聚合通知的状态变化；低水位补歌由 [ensureFeed]
  /// 单独决定，调用方在通知之后再启动生成。
  bool onSnapshot(PlaybackSnapshot snapshot) {
    if (_status != AiDjStatus.playing) return false;
    if (snapshot.current == null) {
      // 播放被外部停止：电台结束（不报错），功能与列表保持。
      stop();
      return true;
    }
    _trackSwitch(snapshot);
    // 低水位补歌只在「当前队列就是 AI 推荐队列」时触发：用户换听别的
    // 内容不应继续喂 AI 歌。
    if (!isRadioQueue(snapshot)) {
      stop();
      return true;
    }
    return false;
  }

  /// 进度 tick：记录当前 AI 曲目到达的最大位置（跳过判定用）。
  void onPosition(Duration position) {
    final uri = _trackedUri;
    if (uri == null) return;
    final entry = _sessionTracks[uri];
    if (entry == null) return;
    final positionMs = position.inMilliseconds;
    if (positionMs > entry.maxPositionMs) entry.maxPositionMs = positionMs;
  }

  /// 是否该触发静默补歌（只做判定，生成由 provider 启动）。
  bool ensureFeed(
    PlaybackSnapshot snapshot, {
    required bool canAutoFeed,
    required bool busy,
  }) {
    if (!canAutoFeed || busy) return false;
    if (_status != AiDjStatus.playing) return false;
    if (!isRadioQueue(snapshot)) return false;
    return AiRadioQueue.of(snapshot).upcoming <= lowWatermark;
  }

  /// 生成批次追加：只入队缺失项；整批登记跟踪（即使全在队，也要用本批标签）。
  ///
  /// 返回实际追加的项，供「补歌完成时队列已播完」的静默续播判断。
  Future<List<ResolvedRecommendation>> appendGenerated(
    Iterable<ResolvedRecommendation> items,
  ) async {
    final list = items.toList(growable: false);
    final missing = missingFromQueue(list);
    if (missing.isNotEmpty) await _enqueue(missing);
    registerTracks(list);
    return missing;
  }

  /// 入队命令：调用方已筛出缺失项；追加成功后只登记实际入队的曲目。
  Future<void> enqueueTracks(Iterable<ResolvedRecommendation> items) async {
    final list = items.toList(growable: false);
    if (list.isEmpty) return;
    await _enqueue(list);
    registerTracks(list);
  }

  /// 「换一首」原位顶替队列曲目，并让会话跟踪跟到新曲目。
  Future<void> replaceQueuedTrack(
    ResolvedRecommendation target,
    ResolvedRecommendation replacement,
  ) async {
    await _playbackProvider.replaceQueueTrack(target.track, replacement.track);
    // 队列里的旧曲目已被顶替：排队数 / 跳过判定要从 live 快照重新派生。
    registerTracks([replacement]);
  }

  /// 登记一批曲目（同一 uri 覆盖为最新标签）。
  void registerTracks(Iterable<ResolvedRecommendation> items) {
    for (final item in items) {
      final uri = item.track.id.uri;
      _sessionTracks[uri] = AiSessionTrack(
        label: item.source.label,
        promptKey: aiTrackKey(item.source.title, item.source.artist),
        sourceKey: item.track.id.sourceKey,
        songId: item.track.id.id,
        durationMs: item.track.duration?.inMilliseconds ?? 0,
      );
    }
  }

  /// 会话内未回流的收藏曲目（喜欢 = 收藏）。
  List<String> pendingLikeLabels() => [
    for (final entry in _sessionTracks.values)
      if (!entry.likedReported &&
          _libraryProvider.isFavorite(entry.sourceKey, entry.songId))
        entry.label,
  ];

  /// 标记这些标签对应的会话曲目已回流，避免下一批重复计入。
  void markLikesReported(Iterable<String> labels) {
    final pending = labels.toSet();
    if (pending.isEmpty) return;
    for (final entry in _sessionTracks.values) {
      if (pending.contains(entry.label)) entry.likedReported = true;
    }
  }

  /// 记录一次静默补歌失败；返回累计次数供日志使用。
  int recordAutoFeedFailure(SourceFailure failure) {
    _autoFeedFailures++;
    _autoFeedError = failure;
    if (_autoFeedFailures >= maxConsecutiveFailures) {
      // 连续失败停止自动补歌：不打断播放、不弹提示，只留内部错误状态。
      _autoFeedHalted = true;
    }
    return _autoFeedFailures;
  }

  /// 生成成功后清除失败计数与错误（不解除「已停止」）。
  void clearAutoFeedFailure() {
    _autoFeedFailures = 0;
    _autoFeedError = null;
  }

  /// 手动恢复 / 重新开启自动补歌：清除失败计数、错误与停止态。
  void resetAutoFeed() {
    _autoFeedFailures = 0;
    _autoFeedError = null;
    _autoFeedHalted = false;
  }

  Future<void> _enqueue(List<ResolvedRecommendation> items) => _playbackProvider
      .enqueueDomainTracks([for (final item in items) item.track]);

  void _registerSnapshotTracks(PlaybackSnapshot snapshot) {
    _sessionTracks.clear();
    for (final track in snapshot.queue) {
      final artist = track.artistLabel;
      _sessionTracks[track.id.uri] = AiSessionTrack(
        label: artist.isEmpty ? track.title : '${track.title} - $artist',
        promptKey: aiTrackKey(track.title, artist),
        sourceKey: track.id.sourceKey,
        songId: track.id.id,
        durationMs: track.duration?.inMilliseconds ?? 0,
      );
    }
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
    final atEnd =
        durationMs > 0 &&
        entry.maxPositionMs >= durationMs - completionToleranceMs;
    if (atEnd) return; // 听完：正向默认，不额外回流。
    final threshold = PlayStatisticsLimits.qualifiedThresholdMs(durationMs);
    if (entry.maxPositionMs < threshold) _onSkip(entry.label);
  }
}
