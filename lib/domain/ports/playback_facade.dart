import '../../models/play_mode.dart';
import '../models/playback.dart';
import '../models/track.dart';
import 'state_listenable.dart';

/// 对 UI 暴露的唯一播放入口：UI 不区分“本地/远程”。
///
/// 当前只有本地后端，[isLocal] 恒 true。
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

  /// 在已加载队列内按下标跳转。
  Future<void> playQueueIndex(int index);

  /// 追加曲目到当前队列末尾（不打断当前播放）：顺序模式立即可达；
  /// 随机模式下本轮排列不变，追加项在本轮结束后纳入新一轮洗牌。
  Future<void> enqueueTracks(List<Track> tracks);

  Future<void> toggle();

  /// 暂停（幂等）。定时关闭等「必须停下、不能被 toggle 成播放」的路径用它：
  /// 与用户操作竞态时，toggle 语义可能把刚暂停的播放重新拉起。
  Future<void> pause();

  Future<void> seek(Duration position);
  Future<void> next();
  Future<void> previous();
  Future<void> setMode(PlayMode mode);
  Future<void> stop();

  /// 原地更新队列曲目封面（音源补图；低频快照通知，值变才发）。
  Future<void> updateTrackArtwork(String trackUri, Uri? artwork);

  /// 换源：原地替换队列中 [trackUri] 的曲目（按 id 匹配全部命中项）。
  ///
  /// 命中当前播放曲目时重新取链并从头播放（新源音频时长/偏移不可假设）；
  /// 其余命中项只替换数据，下次播放自然走新源。
  Future<void> replaceQueueTrack(String trackUri, Track newTrack);
}
