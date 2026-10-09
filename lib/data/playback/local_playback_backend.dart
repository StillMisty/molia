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
/// composition root（main.dart）注入 `SourceManager.resolveUrl` 的适配实现。
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

/// 本地播放后端：组合 [LocalPlaybackService]（服务本体不改），
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

  final _BackendStateNotifier _state =
      _BackendStateNotifier(BackendSnapshot.empty);

  /// `SourceTrack` → `Track` 的身份缓存：队列内同一曲目对象复用同一 Track，
  /// 保证快照 `==` 去重稳定、避免每次通知重建领域对象。
  final Map<SourceTrack, Track> _trackCache = Map<SourceTrack, Track>.identity();

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
      );

  /// 本地是当前唯一后端：恒可处理。
  @override
  bool canHandle(Track track) => true;

  @override
  StateListenable<BackendSnapshot> get state => _state;

  // 解析器端口

  /// 领域解析：Track + 音质 → PlayableStream。
  Future<PlayableStream> resolveStream(Track track, [AudioQuality? quality]) =>
      _resolver(track, quality);

  /// 旧服务解析器适配（`LocalPlaybackService` 的 `SourceUrlResolver`）：
  /// SourceTrack → Track → PlayableStream → URL 字符串。
  ///
  /// main.dart 用 late 绑定把服务的解析回调接到本方法上，
  /// 保证取链统一走领域解析器端口（阶段 2 可在其上叠加缓存/去重）。
  Future<String> resolveLegacyUrl(SourceTrack track, {String? quality}) async {
    final stream = await _resolver(
      _toTrack(track),
      (quality == null || quality.isEmpty) ? null : AudioQuality(type: quality),
    );
    return stream.uri.toString();
  }

  // 控制委托

  @override
  Future<void> load(PlaybackRequest request) async {
    if (request.tracks.isEmpty) return;
    _trackCache.clear();
    final legacyTracks =
        [for (final track in request.tracks) sourceTrackFromTrack(track)];
    final index = request.startIndex.clamp(0, legacyTracks.length - 1);
    await _service.playTracks(
      legacyTracks,
      index,
      contextName: request.context?.name,
    );
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

  /// 可选能力：本地后端暂不支持（阶段 4+ 按需实现）。
  @override
  Future<bool> toggleFavorite(Track track) async => throw const SourceFailure(
        kind: FailureKind.unsupported,
        message: '本地播放后端暂不支持收藏',
      );

  /// 可选能力：本地后端暂不支持（阶段 4+ 按需实现）。
  @override
  Future<void> setVolume(double value) async => throw const SourceFailure(
        kind: FailureKind.unsupported,
        message: '本地播放后端暂不支持音量控制',
      );

  void dispose() {
    _service.removeListener(_onServiceChanged);
    _state.dispose();
  }

  // 状态映射

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

    final queue = <Track>[
      for (final source in _service.queueTracks) _toTrack(source),
    ];
    final current = currentSource == null ? null : _toTrack(currentSource);

    final upcoming = <Track>[];
    if (index >= 0) {
      for (var i = index + 1; i < queue.length; i++) {
        upcoming.add(queue[i]);
      }
    }
    final upNext = <Track>[
      for (final source in _service.upNextTracks) _toTrack(source),
    ];

    final duration = current == null
        ? Duration.zero
        : (_service.duration > Duration.zero
            ? _service.duration
            : (current.duration ?? Duration.zero));

    final nextSource = _service.nextSourceTrack;
    final history = <Track>[
      for (final source in _service.historyTracks) _toTrack(source),
    ];

    return BackendSnapshot(
      current: current,
      queue: List<Track>.unmodifiable(queue),
      currentIndex: index,
      next: nextSource == null ? null : _toTrack(nextSource),
      upcoming: List<Track>.unmodifiable(upcoming),
      upNext: List<Track>.unmodifiable(upNext),
      history: List<Track>.unmodifiable(history),
      isPlaying: _service.isPlaying,
      isLoading: _service.isLoading,
      position: _service.position,
      duration: duration,
      mode: _service.mode,
      context: _readContext(),
      error: _readError(),
    );
  }

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
