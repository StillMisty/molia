import '../../models/play_mode.dart';
import 'equality.dart';
import 'failure.dart';
import 'track.dart';

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

  /// 恢复态展示过的本轮洗牌排列（队列下标）。
  ///
  /// null = 后端自己新洗牌；仅在 shuffle 模式生效。恢复播放带上它，后端的
  /// `next` / `upNext` 才与冷启动恢复快照同源，不会在接管瞬间换下一首。
  final List<int>? shuffleIndices;

  const PlaybackRequest({
    required this.tracks,
    this.startIndex = 0,
    this.context,
    this.preferredQuality,
    this.shuffleIndices,
  });

  @override
  bool operator ==(Object other) =>
      other is PlaybackRequest &&
      deepEquals(other.tracks, tracks) &&
      other.startIndex == startIndex &&
      other.context == context &&
      other.preferredQuality == preferredQuality &&
      deepEquals(other.shuffleIndices, shuffleIndices);

  @override
  int get hashCode => Object.hash(
    deepHash(tracks),
    startIndex,
    context,
    preferredQuality,
    deepHash(shuffleIndices),
  );
}

/// 对 UI 暴露的播放快照（低频）：曲目/队列/播放中/模式/错误。
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

  /// 可展示的再上一首：实际播放顺序次近一首 → 「上一首」的队列前一位。
  ///
  /// 封面左槽向后拖动时提前渲染「再上一首」用；恢复态没有播放顺序栈，
  /// 按队列回退口径近似。
  final Track? previousOfPrevious;

  /// 实际播放顺序中当前曲目之后的曲目（shuffle 为洗牌排列的剩余；
  /// 队列面板「接下来」展示用）。
  final List<Track> upNext;

  /// [upNext] 在 [queue] 中的真实下标（shuffle / 回绕时与面板行号不同）。
  final List<int> upNextIndices;

  final bool isPlaying;
  final bool isLoading;
  final Duration duration;
  final PlayMode mode;
  final PlaybackContext? context;

  /// 当前曲目本次播放选用的音质（解析请求值，不是实际码率）；
  /// 恢复态 / 尚未取链时为 null。
  final String? quality;
  final SourceFailure? error;

  const PlaybackSnapshot({
    this.current,
    this.queue = const [],
    this.currentIndex = -1,
    this.next,
    this.previous,
    this.previousOfPrevious,
    this.upNext = const [],
    this.upNextIndices = const [],
    this.isPlaying = false,
    this.isLoading = false,
    this.duration = Duration.zero,
    this.mode = PlayMode.listLoop,
    this.context,
    this.quality,
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
      other.previousOfPrevious == previousOfPrevious &&
      deepEquals(other.upNext, upNext) &&
      deepEquals(other.upNextIndices, upNextIndices) &&
      other.isPlaying == isPlaying &&
      other.isLoading == isLoading &&
      other.duration == duration &&
      other.mode == mode &&
      other.context == context &&
      other.quality == quality &&
      other.error == error;

  @override
  int get hashCode => Object.hash(
    current,
    deepHash(queue),
    currentIndex,
    next,
    previous,
    previousOfPrevious,
    deepHash(upNext),
    deepHash(upNextIndices),
    isPlaying,
    isLoading,
    duration,
    mode,
    context,
    quality,
    error,
  );
}
