import '../../models/play_mode.dart';
import '../models/playback.dart';
import '../models/track.dart';
import 'state_listenable.dart';

/// 对 UI 暴露的唯一播放入口：UI 不区分“本地/远程”。
///
/// 阶段 1 适配版：只有本地后端，[isLocal] 恒 true。
abstract interface class PlaybackFacade {
  /// 低频快照：曲目/队列/模式/后端/错误（值变才发）。
  StateListenable<PlaybackSnapshot> get snapshot;

  /// 高频进度（内部 ≥250ms 变化才发）：只让进度条/歌词订阅。
  StateListenable<Duration> get position;

  /// 是否处于“本地流”播放（当前恒 true）。
  bool get isLocal;

  Future<void> playTracks(PlaybackRequest request);

  /// 在上下文中播放单曲：队列内已存在则跳转，否则以单曲队列加载。
  Future<void> playTrackInContext(Track track, {PlaybackContext? context});

  /// 在已加载队列内按下标跳转（旧 `playQueueIndex` 语义）。
  Future<void> playQueueIndex(int index);

  Future<void> toggle();
  Future<void> seek(Duration position);
  Future<void> next();
  Future<void> previous();
  Future<void> setMode(PlayMode mode);
  Future<void> stop();
}
