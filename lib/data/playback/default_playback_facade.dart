import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../domain/models/failure.dart';
import '../../domain/models/playback.dart';
import '../../domain/models/track.dart';
import '../../domain/ports/playback_backend.dart';
import '../../domain/ports/playback_facade.dart';
import '../../domain/ports/state_listenable.dart';
import '../../models/play_mode.dart';

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

/// 默认播放 facade：把 [PlaybackBackend] 的状态映射为领域快照，
/// 并拆分高频进度通道；同时提供阶段 1–3 的 Map 形状兼容层。
class DefaultPlaybackFacade implements PlaybackFacade {
  DefaultPlaybackFacade({required PlaybackBackend backend})
      : _backend = backend {
    _backend.state.addListener(_onBackendState);
    _syncFromBackend(initial: true);
  }

  final PlaybackBackend _backend;

  final _SnapshotNotifier _snapshot = _SnapshotNotifier(PlaybackSnapshot.empty);
  final _PositionNotifier _position = _PositionNotifier(Duration.zero);

  final math.Random _random = math.Random();

  /// position 通道最小变化阈值（≥250ms 才发，≤4Hz）。
  static const Duration _positionThreshold = Duration(milliseconds: 250);

  String? _lastPositionTrackUri;

  @override
  StateListenable<PlaybackSnapshot> get snapshot => _snapshot;

  @override
  StateListenable<Duration> get position => _position;

  /// 阶段 1 适配版：只有本地后端。
  @override
  bool get isLocal => true;

  // 控制（委托 backend）

  @override
  Future<void> playTracks(PlaybackRequest request) => _backend.load(request);

  @override
  Future<void> playTrackInContext(Track track,
      {PlaybackContext? context}) async {
    final queue = _snapshot.value.queue;
    final index = queue.indexWhere((item) => item.id == track.id);
    if (index >= 0) {
      await _backend.playQueueIndex(index);
      return;
    }
    await _backend.load(PlaybackRequest(
      tracks: [track],
      startIndex: 0,
      context: context,
    ));
  }

  @override
  Future<void> playQueueIndex(int index) => _backend.playQueueIndex(index);

  @override
  Future<void> toggle() async {
    if (_snapshot.value.isPlaying) {
      await _backend.pause();
    } else {
      await _backend.play();
    }
  }

  @override
  Future<void> seek(Duration position) async {
    await _backend.seek(position);
    // 立即对齐进度通道（拖动结束不跳回）；不触碰低频快照。
    _position.value = position;
  }

  @override
  Future<void> next() => _backend.next();

  @override
  Future<void> previous() => _backend.previous();

  @override
  Future<void> setMode(PlayMode mode) => _backend.setMode(mode);

  @override
  Future<void> stop() => _backend.stop();

  void dispose() {
    _backend.state.removeListener(_onBackendState);
    _snapshot.dispose();
    _position.dispose();
  }

  // 状态映射

  void _onBackendState() => _syncFromBackend();

  void _syncFromBackend({bool initial = false}) {
    final backend = _backend.state.value;

    // 1) 高频进度通道：换曲/首次直接对齐，其余 ≥250ms 变化才发。
    //    绝不触发快照通知（进度不参与 notifyListeners）。
    final currentUri = backend.current?.id.uri;
    if (initial || currentUri != _lastPositionTrackUri) {
      _lastPositionTrackUri = currentUri;
      _position.value = backend.position;
    } else if ((backend.position - _position.value).abs() >=
        _positionThreshold) {
      _position.value = backend.position;
    }

    // 2) 低频快照：不含 position，值变才发（合并本地播放的重复事件）。
    final index = backend.currentIndex;
    final history = index > 0
        ? backend.queue.sublist(0, index)
        : const <Track>[];
    final next = PlaybackSnapshot(
      current: backend.current,
      queue: backend.queue,
      currentIndex: index,
      upcoming: backend.upcoming,
      history: history,
      isPlaying: backend.isPlaying,
      isLoading: backend.isLoading,
      duration: backend.duration,
      mode: backend.mode,
      context: backend.context,
      backend: _backend.kind,
      error: backend.error == null ? null : SourceFailure.from(backend.error!),
    );
    if (next != _snapshot.value) {
      _snapshot.value = next;
    }
  }

  // 兼容层：与 LocalPlaybackService.currentTrackMap / nextTrackMap /
  // upcomingTrackMaps 的形状完全一致（UI 零改动前提；阶段 5 删除）。

  @override
  Map<String, dynamic>? get compatCurrentTrack {
    final state = _snapshot.value;
    final track = state.current;
    if (track == null) return null;
    final id = track.id.uri;
    return {
      'is_playing': state.isPlaying,
      // progress_ms 每次访问都刷新（本阶段接受旧重建开销，阶段 4 迁移 UI）。
      'progress_ms': _position.value.inMilliseconds,
      'item': {
        'id': 'lx:$id',
        'name': track.title,
        'duration_ms': state.duration.inMilliseconds,
        'artists': [
          {'name': _artistName(track)},
        ],
        'album': {'name': track.album ?? '', 'images': _imagesFor(track)},
        'uri': 'lx:$id',
      },
      'context': {
        'type': 'lx',
        'name': state.context?.name ?? '',
        'uri': 'lx:${state.context?.name ?? ''}',
      },
      'device': {
        'id': 'local',
        'name': 'Molia',
        'is_active': true,
      },
      'source': 'lx',
    };
  }

  @override
  Map<String, dynamic>? get compatNextTrack {
    final state = _snapshot.value;
    final index = _nextIndexForCompat(state);
    if (index < 0) return null;
    final track = state.queue[index];
    final isCurrent = track.id == state.current?.id;
    return _queueItemMap(
      track,
      isNext: true,
      duration: isCurrent ? state.duration : null,
    );
  }

  @override
  List<Map<String, dynamic>> get compatUpcoming {
    final state = _snapshot.value;
    if (state.queue.isEmpty || state.currentIndex < 0) return const [];
    final result = <Map<String, dynamic>>[];
    for (var i = state.currentIndex + 1; i < state.queue.length; i++) {
      result.add(_queueItemMap(state.queue[i]));
    }
    return result;
  }

  /// 复刻 `LocalPlaybackService._nextIndex(auto: false)` 的语义
  /// （随机模式下每次取值不同，与旧实现一致）。
  int _nextIndexForCompat(PlaybackSnapshot state) {
    final length = state.queue.length;
    if (length == 0) return -1;
    if (state.mode == PlayMode.shuffle) {
      if (length == 1) return state.currentIndex;
      var next = _random.nextInt(length);
      if (next == state.currentIndex) {
        next = (next + 1) % length;
      }
      return next;
    }
    if (state.currentIndex + 1 < length) return state.currentIndex + 1;
    return -1;
  }

  Map<String, dynamic> _queueItemMap(
    Track track, {
    bool isNext = false,
    Duration? duration,
  }) {
    final id = track.id.uri;
    return {
      'id': id,
      'uri': 'lx:$id',
      'name': track.title,
      'type': 'track',
      'is_next': isNext,
      'artists': [
        {'name': _artistName(track)},
      ],
      'album': {'images': _imagesFor(track)},
      'duration_ms': (duration ?? track.duration ?? Duration.zero).inMilliseconds,
    };
  }

  String _artistName(Track track) {
    final name = track.artists.isEmpty ? '' : track.artists.first.name;
    return name.isEmpty ? '未知歌手' : name;
  }

  List<Map<String, dynamic>> _imagesFor(Track track) {
    final artwork = track.artwork;
    if (artwork == null) return const [];
    final url = artwork.uri.toString();
    if (url.isEmpty) return const [];
    return [
      {'url': url},
    ];
  }
}
