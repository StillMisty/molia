import 'package:flutter/foundation.dart';

import '../../domain/models/failure.dart';
import '../../domain/models/playback.dart';
import '../../domain/models/track.dart';
import '../../domain/ports/music_source.dart' show PlayableStream;
import '../../domain/ports/playback_backend.dart';
import '../../domain/ports/state_listenable.dart';
import '../../models/play_mode.dart';
import '../../playback/local_playback_service.dart';
import '../../sources/source_track.dart';
import '../mapping/track_mapper.dart';

/// 领域解析器端口：把 [Track] 解析为本地可播流。
///
/// composition root（main.dart）注入 `LocalPlaybackChain.resolveStream` 的适配实现。
typedef PlaybackStreamResolver = Future<PlayableStream> Function(
  Track track,
  AudioQuality? quality,
);

/// 领域端口的 ValueNotifier 实现：同一对象同时满足
/// `StateListenable<T>`（domain）与 Flutter `ValueListenable<T>`。
class _BackendStateNotifier extends ValueNotifier<BackendSnapshot>
    implements StateListenable<BackendSnapshot> {
  _BackendStateNotifier(super.value);
}

/// 本地播放后端：组合 [LocalPlaybackService]，
/// 把服务状态映射为领域 [BackendSnapshot]，并把控制委托给服务。
class LocalPlaybackBackend implements PlaybackBackend {
  LocalPlaybackBackend({
    required LocalPlaybackService service,
    required PlaybackStreamResolver resolver,
  })  : _service = service,
        _resolver = resolver {
    _service.addListener(_onServiceChanged);
    _state.value = _buildSnapshot();
  }

  final LocalPlaybackService _service;
  final PlaybackStreamResolver _resolver;

  final _BackendStateNotifier _state = _BackendStateNotifier(
    BackendSnapshot.empty,
  );

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

  String? _cachedErrorRaw;
  SourceFailure? _cachedError;

  @override
  PlaybackBackendKind get kind => PlaybackBackendKind.local;

  @override
  PlaybackCapabilities get capabilities => const PlaybackCapabilities(
        seek: true,
        next: true,
        previous: true,
        queue: true,
        setMode: true,
        volume: true,
      );

  /// 本地是当前唯一后端：恒可处理。
  @override
  bool canHandle(Track track) => true;

  @override
  StateListenable<BackendSnapshot> get state => _state;

  @override
  Stream<Track> get trackCompletions => _service.trackCompletions.map(_toTrack);

  @override
  void setStopAfterCurrentTrack(bool enabled) =>
      _service.setStopAfterCurrentTrack(enabled);

  /// 领域解析：Track + 音质 → PlayableStream。
  Future<PlayableStream> resolveStream(Track track, [AudioQuality? quality]) =>
      _resolver(track, quality);

  @override
  Future<void> load(PlaybackRequest request) async {
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
    );
    _emit();
  }

  @override
  Future<void> enqueueTracks(List<Track> tracks) async {
    if (tracks.isEmpty) return;
    final sourceTracks = [
      for (final track in tracks) sourceTrackFromTrack(track),
    ];
    await _service.enqueueTracks(sourceTracks);
    _emit();
  }

  @override
  Future<void> play() async {
    if (_service.hasTrack && !_service.isPlaying) {
      await _service.toggle();
    }
    _emit();
  }

  @override
  Future<void> pause() async {
    if (_service.isPlaying) {
      await _service.toggle();
    }
    _emit();
  }

  @override
  Future<void> seek(Duration position) async {
    await _service.seek(position);
    _emit();
  }

  @override
  Future<void> next() async {
    await _service.skipToNext();
    _emit();
  }

  @override
  Future<void> previous() async {
    await _service.skipToPrevious();
    _emit();
  }

  @override
  Future<void> setMode(PlayMode mode) async {
    await _service.setMode(mode);
    _emit();
  }

  @override
  Future<void> stop() async {
    _trackCache.clear();
    await _service.stop();
    _emit();
  }

  @override
  Future<void> playQueueIndex(int index) async {
    await _service.playQueueIndex(index);
    _emit();
  }

  /// 可选能力：本地后端暂不支持。
  @override
  Future<bool> toggleFavorite(Track track) async => throw const SourceFailure(
        kind: FailureKind.unsupported,
        message: '本地播放后端暂不支持收藏',
      );

  /// 应用内音量：委托 [LocalPlaybackService.setVolume]。
  @override
  Future<void> setVolume(double value) => _service.setVolume(value);

  /// 音源补图：原地更新队列曲目封面（新 SourceTrack 触发领域映射重建）。
  @override
  Future<void> updateTrackArtwork(String trackUri, Uri? artwork) async {
    _service.updateTrackArtwork(trackUri, artwork?.toString());
    _emit();
  }

  /// 换源：把队列中 [trackUri] 的曲目替换为 [newTrack]（服务重置当前曲目
  /// 播放时同步发出新快照）。
  @override
  Future<void> replaceQueueTrack(String trackUri, Track newTrack) async {
    await _service.replaceQueueTrack(trackUri, sourceTrackFromTrack(newTrack));
    _emit();
  }

  void dispose() {
    _service.removeListener(_onServiceChanged);
    _state.dispose();
  }

  void _onServiceChanged() => _emit();

  /// 值未变不发（`BackendSnapshot` 手写 ==）。
  void _emit() {
    final next = _buildSnapshot();
    if (next != _state.value) {
      _state.value = next;
    }
  }

  BackendSnapshot _buildSnapshot() {
    final currentSource = _service.currentSourceTrack;
    final index = _service.currentIndex;

    // 一次投影复用 next / previous / upNext：三个 getter 各自都会重算整份
    // 投影（shuffle 下含 O(N) 的排列查找与 upNext 列表），位置 tick 触发
    // 的快照重建里连算三次纯属浪费。
    final projection = _service.queueProjection;
    final current = currentSource == null ? null : _toTrack(currentSource);

    final upNext = <Track>[
      for (final source in projection.upNext) _toTrack(source),
    ];

    final duration = current == null
        ? Duration.zero
        : (_service.duration > Duration.zero
            ? _service.duration
            : (current.duration ?? Duration.zero));

    return BackendSnapshot(
      current: current,
      queue: _queueTracks(),
      currentIndex: index,
      next: _toTrackOrNull(projection.next),
      previous: _toTrackOrNull(projection.previous),
      upNext: List<Track>.unmodifiable(upNext),
      isPlaying: _service.isPlaying,
      isLoading: _service.isLoading,
      position: _service.position,
      duration: duration,
      mode: _service.mode,
      context: _readContext(),
      error: _readError(),
    );
  }

  /// 队列内容未变时复用上一份领域映射（判定依据见 `queueRevision`）。
  List<Track> _queueTracks() {
    final revision = _service.queueRevision;
    final cached = _cachedQueue;
    if (cached != null && revision == _cachedQueueRevision) return cached;
    final queue = List<Track>.unmodifiable([
      for (final source in _service.queueTracks) _toTrack(source),
    ]);
    _cachedQueue = queue;
    _cachedQueueRevision = revision;
    return queue;
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
