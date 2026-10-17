import '../../models/play_mode.dart';
import 'equality.dart';
import 'failure.dart';
import 'track.dart';

/// 播放后端种类（当前仅本地 just_audio 后端；any-listen 为预留）。
enum PlaybackBackendKind { local, anyListen }

/// 播放上下文（名称/类型/封面）。
class PlaybackContext {
  final String? name;

  /// 本地音源固定为 'lx'。
  final String? type;
  final String? uri;
  final Uri? artwork;

  const PlaybackContext({this.name, this.type, this.uri, this.artwork});

  @override
  bool operator ==(Object other) =>
      other is PlaybackContext &&
      other.name == name &&
      other.type == type &&
      other.uri == uri &&
      other.artwork == artwork;

  @override
  int get hashCode => Object.hash(name, type, uri, artwork);

  @override
  String toString() => 'PlaybackContext($type, $name)';
}

/// 一次加载请求：曲目队列 + 起始下标 + 上下文。
class PlaybackRequest {
  final List<Track> tracks;
  final int startIndex;
  final PlaybackContext? context;
  final String? preferredQuality;

  const PlaybackRequest({
    required this.tracks,
    this.startIndex = 0,
    this.context,
    this.preferredQuality,
  });

  @override
  bool operator ==(Object other) =>
      other is PlaybackRequest &&
      deepEquals(other.tracks, tracks) &&
      other.startIndex == startIndex &&
      other.context == context &&
      other.preferredQuality == preferredQuality;

  @override
  int get hashCode =>
      Object.hash(deepHash(tracks), startIndex, context, preferredQuality);
}

/// 播放后端的状态快照（低频事件驱动）。
///
/// [position] 为高频字段：facade 会把它拆到独立的 `position` 通道，
/// 不参与低频快照的相等性比较（见 DefaultPlaybackFacade）。
class BackendSnapshot {
  final Track? current;

  /// 完整队列（记录回放需要按下标或 id 查找）。
  final List<Track> queue;
  final int currentIndex;

  /// 按当前模式解析出的下一首（shuffle 时由后端随机决定，界面预览用）。
  final Track? next;

  /// 可展示的上一首：实际播放顺序最近一首 → 队列前一位；无 / 与当前曲目
  /// 同 id 为 null（队首的「重播当前」不算上一首）。
  final Track? previous;

  /// 实际播放顺序中当前曲目之后的曲目（shuffle 为洗牌排列的剩余；
  /// 队列面板「接下来」展示用）。
  final List<Track> upNext;

  final bool isPlaying;
  final bool isLoading;
  final Duration position;
  final Duration duration;
  final PlayMode mode;
  final PlaybackContext? context;
  final SourceFailure? error;

  const BackendSnapshot({
    this.current,
    this.queue = const [],
    this.currentIndex = -1,
    this.next,
    this.previous,
    this.upNext = const [],
    this.isPlaying = false,
    this.isLoading = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.mode = PlayMode.sequential,
    this.context,
    this.error,
  });

  static const BackendSnapshot empty = BackendSnapshot();

  @override
  bool operator ==(Object other) =>
      other is BackendSnapshot &&
      other.current == current &&
      deepEquals(other.queue, queue) &&
      other.currentIndex == currentIndex &&
      other.next == next &&
      other.previous == previous &&
      deepEquals(other.upNext, upNext) &&
      other.isPlaying == isPlaying &&
      other.isLoading == isLoading &&
      other.position == position &&
      other.duration == duration &&
      other.mode == mode &&
      other.context == context &&
      other.error == error;

  @override
  int get hashCode => Object.hash(
        current,
        deepHash(queue),
        currentIndex,
        next,
        previous,
        deepHash(upNext),
        isPlaying,
        isLoading,
        position,
        duration,
        mode,
        context,
        error,
      );
}

/// 对 UI 暴露的播放快照（低频）：曲目/队列/播放中/模式/后端/错误。
///
/// 不含 position：进度走 [PlaybackFacade.position] 独立通道。
class PlaybackSnapshot {
  final Track? current;

  /// 完整队列（记录回放使用的稳定顺序）。
  final List<Track> queue;
  final int currentIndex;

  /// 按当前模式解析出的下一首（界面「下一首封面」预览用）。
  final Track? next;

  /// 可展示的上一首：实际播放顺序最近一首 → 队列前一位；无 / 与当前曲目
  /// 同 id 为 null（恢复态为会话队列下标回退的近似）。
  final Track? previous;

  /// 实际播放顺序中当前曲目之后的曲目（shuffle 为洗牌排列的剩余；
  /// 队列面板「接下来」展示用）。
  final List<Track> upNext;

  final bool isPlaying;
  final bool isLoading;
  final Duration duration;
  final PlayMode mode;
  final PlaybackContext? context;
  final PlaybackBackendKind backend;
  final SourceFailure? error;

  const PlaybackSnapshot({
    this.current,
    this.queue = const [],
    this.currentIndex = -1,
    this.next,
    this.previous,
    this.upNext = const [],
    this.isPlaying = false,
    this.isLoading = false,
    this.duration = Duration.zero,
    this.mode = PlayMode.sequential,
    this.context,
    this.backend = PlaybackBackendKind.local,
    this.error,
  });

  static const PlaybackSnapshot empty = PlaybackSnapshot();

  @override
  bool operator ==(Object other) =>
      other is PlaybackSnapshot &&
      other.current == current &&
      deepEquals(other.queue, queue) &&
      other.currentIndex == currentIndex &&
      other.next == next &&
      other.previous == previous &&
      deepEquals(other.upNext, upNext) &&
      other.isPlaying == isPlaying &&
      other.isLoading == isLoading &&
      other.duration == duration &&
      other.mode == mode &&
      other.context == context &&
      other.backend == backend &&
      other.error == error;

  @override
  int get hashCode => Object.hash(
        current,
        deepHash(queue),
        currentIndex,
        next,
        previous,
        deepHash(upNext),
        isPlaying,
        isLoading,
        duration,
        mode,
        context,
        backend,
        error,
      );
}
