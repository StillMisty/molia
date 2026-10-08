import '../../models/play_mode.dart';
import '../models/failure.dart';
import '../models/playback.dart';
import '../models/track.dart';
import 'state_listenable.dart';

export '../models/playback.dart' show PlaybackBackendKind;

/// 播放后端能力位。
class PlaybackCapabilities {
  final bool seek;
  final bool next;
  final bool previous;
  final bool queue;
  final bool setMode;
  final bool favorite;
  final bool volume;
  final bool transferDevice;

  const PlaybackCapabilities({
    this.seek = false,
    this.next = false,
    this.previous = false,
    this.queue = false,
    this.setMode = false,
    this.favorite = false,
    this.volume = false,
    this.transferDevice = false,
  });

  @override
  bool operator ==(Object other) =>
      other is PlaybackCapabilities &&
      other.seek == seek &&
      other.next == next &&
      other.previous == previous &&
      other.queue == queue &&
      other.setMode == setMode &&
      other.favorite == favorite &&
      other.volume == volume &&
      other.transferDevice == transferDevice;

  @override
  int get hashCode => Object.hash(seek, next, previous, queue, setMode, favorite,
      volume, transferDevice);
}

/// 播放后端：事件驱动状态 + 控制委托。UI 不直接依赖，由 facade 选择/转发。
abstract interface class PlaybackBackend {
  PlaybackBackendKind get kind;
  PlaybackCapabilities get capabilities;

  /// 能否处理该曲目（本地后端恒 true；远程后端按 origin 判断）。
  bool canHandle(Track track);

  /// 事件驱动快照（低频即可），不保证每次 position 变化都发。
  StateListenable<BackendSnapshot> get state;

  Future<void> load(PlaybackRequest request);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> next();
  Future<void> previous();
  Future<void> setMode(PlayMode mode);
  Future<void> stop();

  /// 可选能力：在已加载队列内按下标跳转（本地后端支持）。
  /// 不支持时抛 `SourceFailure(kind: unsupported)`。
  Future<void> playQueueIndex(int index) => throw const SourceFailure(
        kind: FailureKind.unsupported,
        message: '当前播放后端不支持队列跳转',
      );

  /// 可选能力：收藏切换。不支持时抛 `SourceFailure(kind: unsupported)`。
  Future<bool> toggleFavorite(Track track) => throw const SourceFailure(
        kind: FailureKind.unsupported,
        message: '当前播放后端不支持收藏',
      );

  /// 可选能力：设置音量。不支持时抛 `SourceFailure(kind: unsupported)`。
  Future<void> setVolume(double value) => throw const SourceFailure(
        kind: FailureKind.unsupported,
        message: '当前播放后端不支持音量控制',
      );
}
