import 'dart:async';

import '../../models/play_mode.dart';
import '../models/playback.dart';
import '../models/track.dart';
import 'state_listenable.dart';

/// 播放引擎对外暴露的小接口：协调者、provider 与播放观察者只依赖它。
///
/// 实现是唯一的 `PlaybackEngine`（本地 just_audio 链路）；UI 不直接持有它。
abstract interface class PlaybackFacade {
  /// 低频快照：曲目/队列/模式/错误（值变才发）。
  StateListenable<PlaybackSnapshot> get snapshot;

  /// 高频进度（内部 ≥250ms 变化才发）：只让进度条/歌词订阅。
  StateListenable<Duration> get position;

  /// 当前曲目自然播完的事件（自动切歌前发出）。
  ///
  /// 定时关闭的「播完当前歌曲」用：熄屏时进度通道可能停更，不能靠它判断
  /// 曲末。
  Stream<Track> get trackCompletions;

  /// 当前曲目自然播完后停止，不自动切下一首（定时关闭用）。
  void setStopAfterCurrentTrack(bool enabled);

  Future<void> playTracks(PlaybackRequest request);

  /// 在已加载队列内按下标跳转。
  Future<void> playQueueIndex(int index);

  /// 以指定音质重新取链当前曲目，保持进度与播放态。
  ///
  /// 只影响本次播放，不改变队列 / 进度 / 模式，也不写入持久化会话。
  Future<void> setCurrentQuality(String quality);

  /// 追加曲目到当前队列末尾（不打断当前播放）：顺序模式立即可达；
  /// 随机模式下本轮排列不变，追加项在本轮结束后纳入新一轮洗牌。
  Future<void> enqueueTracks(List<Track> tracks);

  /// 只更新队列中同 id 曲目的元数据（标题等）：不重新取链、不打断播放。
  Future<void> updateQueueTrackMetadata(String trackUri, Track track);

  /// 移动队列中的一项；返回是否真的改变（越界 / 当前曲目 / 随机模式 false）。
  Future<bool> moveQueueIndex(int from, int to);

  /// 移除队列中的一项；返回是否真的改变（越界 / 当前曲目 false）。
  Future<bool> removeQueueIndex(int index);

  Future<void> toggle();

  /// 起播（幂等）：命令面用它表达系统媒体「播放」键，避免先查状态再 toggle
  /// 的竞态（暂停中途到达的播放键不能反而暂停）。
  Future<void> play();

  /// 暂停（幂等）。定时关闭等「必须停下、不能被 toggle 成播放」的路径用它：
  /// 与用户操作竞态时，toggle 语义可能把刚暂停的播放重新拉起。
  Future<void> pause();

  Future<void> seek(Duration position);
  Future<void> next();
  Future<void> previous();
  Future<void> setMode(PlayMode mode);

  /// 应用内音量 0..1（不含静音状态，静音由 provider 层表达）。
  Future<void> setVolume(double volume);

  /// 暂停淡出是否还在进行（此时快照仍是 playing）。
  ///
  /// 命令面用它区分「真的在播」与「已经在淡出」：后者收到播放键要反向
  /// 淡入，而不是把第二次按键当暂停。
  bool get pauseTransitioning;

  /// 用户暂停 / 播放时的淡入淡出时长；[Duration.zero] = 关闭。
  ///
  /// 只影响之后的过渡，正在跑的淡变保持原时长。用户音量仍归 provider /
  /// [setVolume] 所有，包络只是播放器上的音频细节。
  void setFadeDuration(Duration duration);

  /// 智能随机开关：只降低最近听过曲目的出现概率，不排除。
  void setSmartShuffle(bool enabled);

  /// 定时关闭倒计时 / 播完当前曲的专用淡出（固定时长，与淡入淡出设置无关）。
  ///
  /// 只降音量、不暂停：到点暂停仍由命令面单独下发，最后几秒取消定时
  /// 才能只撤销淡出、不和一次待执行的暂停赛跑。
  void startSleepFade(Duration duration);

  /// 撤销睡眠淡出；[restore] 为 true 时按普通淡变时长回到用户音量。
  ///
  /// 完成前就收到曲末 / 用户取消时，[restore] 为 false 让随后的暂停立即
  /// 落地（保持静音，不再补第二次淡出）。
  void cancelSleepFade({bool restore = true});

  Future<void> stop();

  /// 原地更新队列曲目封面（音源补图；低频快照通知，值变才发）。
  Future<void> updateTrackArtwork(String trackUri, Uri? artwork);

  /// 换源：原地替换队列中 [trackUri] 的曲目（按 id 匹配全部命中项）。
  ///
  /// 命中当前播放曲目时重新取链并从头播放（新源音频时长/偏移不可假设）；
  /// 其余命中项只替换数据，下次播放自然走新源。
  Future<void> replaceQueueTrack(String trackUri, Track newTrack);
}
