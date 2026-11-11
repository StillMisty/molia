import 'package:flutter/foundation.dart';

import '../../domain/models/failure.dart';
import '../../domain/models/playback.dart';
import '../../domain/models/track.dart';
import '../../domain/ports/playback_facade.dart';
import '../../domain/ports/state_listenable.dart';
import '../../models/play_mode.dart';
import '../../playback/local_playback_service.dart';
import '../../playback/queue_projection.dart';
import '../../sources/source_track.dart';
import '../mapping/track_mapper.dart';

/// 领域端口的 ValueNotifier 实现：同一对象同时满足
/// `StateListenable<T>`（domain）与 Flutter `ValueListenable<T>`。
class _SnapshotNotifier extends ValueNotifier<PlaybackSnapshot>
    implements StateListenable<PlaybackSnapshot> {
  _SnapshotNotifier(super.value);
}

class _PositionNotifier extends ValueNotifier<Duration>
    implements StateListenable<Duration> {
  _PositionNotifier(super.value);
}

/// 播放引擎：把 [LocalPlaybackService] 的队列 / 播放态映射为领域快照，
/// 并直接实现 [PlaybackFacade] 的全部命令。
///
/// 为什么只剩这一层：服务已经拥有队列、播放顺序与投影，旧后端只是把服务
/// 状态重新包一遍，facade 又把后端的快照再映射一遍。两层纯转发既让每个
/// 命令改三处，也让 position 在两种快照里各走一遍。现在命令、快照映射与
/// 高频进度通道只在这里实现一次；协调者与 provider 仍只依赖领域端口。
class PlaybackEngine implements PlaybackFacade {
  PlaybackEngine({required this._service}) {
    _service.addListener(_onServiceChanged);
    _publish(initial: true);
  }

  final LocalPlaybackService _service;

  final _SnapshotNotifier _snapshot = _SnapshotNotifier(PlaybackSnapshot.empty);
  final _PositionNotifier _position = _PositionNotifier(Duration.zero);

  /// position 通道最小变化阈值（≥250ms 才发，≤4Hz）。
  static const Duration _positionThreshold = Duration(milliseconds: 250);

  String? _lastPositionTrackUri;

  /// `SourceTrack` → `Track` 的身份缓存：队列内同一曲目对象复用同一 Track，
  /// 保证快照 `==` 去重稳定、避免每次通知重建领域对象。
  final Map<SourceTrack, Track> _trackCache =
      Map<SourceTrack, Track>.identity();

  /// 队列到领域 [Track] 的映射缓存，按 [LocalPlaybackService.queueRevision]
  /// 失效。
  ///
  /// 位置 tick / 播放态变化同样会重建快照，但队列内容没变：复用同一份
  /// List 省掉 O(N) 的映射与包装，也让快照 `==` 的深比较走对象相等的快路径。
  List<Track>? _cachedQueue;
  int? _cachedQueueRevision;

  /// 队列投影缓存：位置 tick 不改变投影输入，命中后复用同一份
  /// `QueueProjection`（含 upNext / upNextIndices），不再跑 O(N) 推导。
  final QueueProjectionCache<SourceTrack> _projectionCache =
      QueueProjectionCache<SourceTrack>();

  /// 与投影同键的领域 `upNext` 映射；复用同一 List 实例让快照 `==` 的
  /// 深比较走 `identical` 短路。
  List<Track> _cachedUpNext = const [];

  String? _cachedErrorRaw;
  SourceFailure? _cachedError;

  /// 身份缓存条目数（测试观察用）：队列 revision 变化后应只剩当前队列。
  @visibleForTesting
  int get trackCacheLength => _trackCache.length;

  @override
  StateListenable<PlaybackSnapshot> get snapshot => _snapshot;

  @override
  StateListenable<Duration> get position => _position;

  @override
  Stream<Track> get trackCompletions => _service.trackCompletions.map(_toTrack);

  @override
  void setStopAfterCurrentTrack(bool enabled) =>
      _service.setStopAfterCurrentTrack(enabled);

  @override
  Future<void> playTracks(PlaybackRequest request) async {
    if (request.tracks.isEmpty) return;
    _trackCache.clear();
    final sourceTracks = [
      for (final track in request.tracks) sourceTrackFromTrack(track),
    ];
    final index = request.startIndex.clamp(0, sourceTracks.length - 1);
    await _service.playTracks(
      sourceTracks,
      index,
      contextName: request.context?.name,
      shuffleIndices: request.shuffleIndices,
    );
    _publish();
  }

  @override
  Future<void> enqueueTracks(List<Track> tracks) async {
    if (tracks.isEmpty) return;
    final sourceTracks = [
      for (final track in tracks) sourceTrackFromTrack(track),
    ];
    await _service.enqueueTracks(sourceTracks);
    _publish();
  }

  /// 队列内移动一项：服务同步维护播放顺序 / 洗牌排列，返回值即是否变化。
  @override
  Future<bool> moveQueueIndex(int from, int to) async {
    final changed = _service.moveQueueIndex(from, to);
    _publish();
    return changed;
  }

  /// 从队列移除一项：当前曲目 / 越界由服务 no-op，返回值即是否变化。
  @override
  Future<bool> removeQueueIndex(int index) async {
    final changed = _service.removeQueueIndex(index);
    _publish();
    return changed;
  }

  @override
  Future<void> play() async {
    if (_service.hasTrack && !_service.isPlaying) {
      await _service.toggle();
    }
    _publish();
  }

  @override
  Future<void> pause() async {
    if (_service.isPlaying) {
      await _service.toggle();
    }
    _publish();
  }

  @override
  Future<void> seek(Duration position) async {
    await _service.seek(position);
    // 立即对齐进度通道（拖动结束不跳回）；不触碰低频快照。
    _position.value = position;
    _publish();
  }

  @override
  Future<void> next() async {
    await _service.skipToNext();
    _publish();
  }

  @override
  Future<void> previous() async {
    await _service.skipToPrevious();
    _publish();
  }

  @override
  Future<void> setMode(PlayMode mode) async {
    await _service.setMode(mode);
    _publish();
  }

  @override
  Future<void> stop() async {
    _trackCache.clear();
    await _service.stop();
    _publish();
  }

  @override
  Future<void> playQueueIndex(int index) async {
    await _service.playQueueIndex(index);
    _publish();
  }

  /// 切换当前曲目音质：服务重新取链并保持进度 / 播放态，快照带新音质。
  @override
  Future<void> setCurrentQuality(String quality) async {
    await _service.setCurrentQuality(quality);
    _publish();
  }

  @override
  Future<void> toggle() async {
    // 与 play / pause 同一判据，但只发布一次：toggle 是单个用户动作，
    // 不应因为复用命令方法而多走一轮快照 / 进度对齐。
    if (_snapshot.value.isPlaying) {
      if (_service.isPlaying) await _service.toggle();
    } else if (_service.hasTrack && !_service.isPlaying) {
      await _service.toggle();
    }
    _publish();
  }

  /// 应用内音量：委托 [LocalPlaybackService.setVolume]。
  ///
  /// 音量是设备本地状态，不属于播放快照：不发布快照、也不碰进度通道。
  @override
  Future<void> setVolume(double value) => _service.setVolume(value);

  /// 音源补图：原地更新队列曲目封面（新 SourceTrack 触发领域映射重建）。
  @override
  Future<void> updateTrackArtwork(String trackUri, Uri? artwork) async {
    _service.updateTrackArtwork(trackUri, artwork?.toString());
    _publish();
  }

  /// 换源：把队列中 [trackUri] 的曲目替换为 [newTrack]（服务重置当前曲目
  /// 播放时同步发出新快照）。
  @override
  Future<void> replaceQueueTrack(String trackUri, Track newTrack) async {
    await _service.replaceQueueTrack(trackUri, sourceTrackFromTrack(newTrack));
    _publish();
  }

  void dispose() {
    _service.removeListener(_onServiceChanged);
    _snapshot.dispose();
    _position.dispose();
  }

  void _onServiceChanged() => _publish();

  /// 单次服务事件 / 命令结束的统一出口：先对齐高频进度，再发布低频快照。
  ///
  /// 两步互不影响：进度通道按阈值去重且不触发快照通知；快照不含 position，
  /// 纯进度 tick 不会让订阅方重建 UI。
  void _publish({bool initial = false}) {
    _syncPosition(initial: initial);
    final next = _buildSnapshot();
    if (next != _snapshot.value) {
      _snapshot.value = next;
    }
  }

  /// 换曲 / 首次直接对齐，其余 ≥250ms 才发（≤4Hz）。
  void _syncPosition({bool initial = false}) {
    final currentUri = _service.currentSourceTrack?.id;
    if (initial || currentUri != _lastPositionTrackUri) {
      _lastPositionTrackUri = currentUri;
      _position.value = _service.position;
    } else if ((_service.position - _position.value).abs() >=
        _positionThreshold) {
      _position.value = _service.position;
    }
  }

  PlaybackSnapshot _buildSnapshot() {
    final currentSource = _service.currentSourceTrack;
    final index = _service.currentIndex;

    // 一次投影复用 next / previous / previousOfPrevious / upNext：四个 getter
    // 各自都会重算整份投影（shuffle 下含 O(N) 的排列查找与 upNext 列表），
    // 位置 tick 触发的快照重建里重复计算纯属浪费。
    //
    // 投影只由队列内容 / 当前下标 / 模式 / 播放顺序 / 洗牌排列决定；位置与
    // 播放态 tick 命中缓存，不重算、也不重建 upNext 映射。
    final projectionKey = QueueProjectionKey(
      queueRevision: _service.queueRevision,
      currentIndex: index,
      mode: _service.mode,
      playbackOrderRevision: _service.playbackOrderRevision,
      shuffleOrderRevision: _service.shuffleOrderRevision,
    );
    final bool projectionChanged = _projectionCache.key != projectionKey;
    final projection = _projectionCache.resolve(
      key: projectionKey,
      compute: () => _service.queueProjection,
    );
    if (projectionChanged) {
      _cachedUpNext = List<Track>.unmodifiable([
        for (final source in projection.upNext) _toTrack(source),
      ]);
    }
    final current = currentSource == null ? null : _toTrack(currentSource);

    final duration = current == null
        ? Duration.zero
        : (_service.duration > Duration.zero
              ? _service.duration
              : (current.duration ?? Duration.zero));

    return PlaybackSnapshot(
      current: current,
      queue: _queueTracks(),
      currentIndex: index,
      next: _toTrackOrNull(projection.next),
      previous: _toTrackOrNull(projection.previous),
      previousOfPrevious: _toTrackOrNull(projection.previousOfPrevious),
      upNext: _cachedUpNext,
      upNextIndices: projection.upNextIndices,
      isPlaying: _service.isPlaying,
      isLoading: _service.isLoading,
      duration: duration,
      mode: _service.mode,
      context: _readContext(),
      quality: _service.currentQuality,
      error: _readError(),
    );
  }

  /// 队列内容未变时复用上一份领域映射（判定依据见 `queueRevision`）。
  List<Track> _queueTracks() {
    final revision = _service.queueRevision;
    final cached = _cachedQueue;
    if (cached != null && revision == _cachedQueueRevision) return cached;
    final sourceQueue = _service.queueTracks;
    final queue = List<Track>.unmodifiable([
      for (final source in sourceQueue) _toTrack(source),
    ]);
    // 队列整体换掉（播放新列表 / 换源后重建）时，上一份队列的 SourceTrack
    // 身份不会再出现；不清掉这些条目，Track（含 raw payload 引用）会随
    // 播放过的列表数量线性常驻。当前 / 下一首仍在本队列内，映射照常复用。
    _trimTrackCache(sourceQueue);
    _cachedQueue = queue;
    _cachedQueueRevision = revision;
    return queue;
  }

  /// 只保留仍属于 [queue] 的身份缓存条目（按对象身份比较）。
  void _trimTrackCache(List<SourceTrack> queue) {
    if (_trackCache.isEmpty) return;
    final alive = Set<SourceTrack>.identity()..addAll(queue);
    _trackCache.removeWhere((source, _) => !alive.contains(source));
  }

  Track? _toTrackOrNull(SourceTrack? source) =>
      source == null ? null : _toTrack(source);

  Track _toTrack(SourceTrack source) =>
      _trackCache.putIfAbsent(source, () => trackFromSourceTrack(source));

  PlaybackContext? _readContext() {
    final name = _service.contextName;
    if (name == null) return null;
    return PlaybackContext(name: name, type: 'lx', uri: 'lx:$name');
  }

  SourceFailure? _readError() {
    final raw = _service.lastError;
    if (raw == null) {
      _cachedErrorRaw = null;
      _cachedError = null;
      return null;
    }
    if (raw == _cachedErrorRaw) return _cachedError;
    _cachedErrorRaw = raw;
    _cachedError = SourceFailure.from(raw);
    return _cachedError;
  }
}
