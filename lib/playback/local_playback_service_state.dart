/// 本地播放服务的低频快照（从 `local_playback_service.dart` 拆出，控制单文件体积）。
library;

import 'package:flutter/foundation.dart';

import '../domain/models/play_mode.dart';
import '../sources/source_track.dart';

/// 只收**低频、UI 可见**的播放事实：队列 / 当前曲目 / 播放态 / 装载态 /
/// 播放模式 / 上下文 / 错误 / 时长 / 本次音质。高频值与内部实现不进快照：
/// - 播放进度（`position`）继续走 `PlaybackEngine` 的独立 `position` 通道
///   （≥250ms 去重、≤4Hz），不为它多发通知；
/// - 淡变包络 / duck / 音量写入只作用于平台播放器，服务本来就不广播它们；
/// - 队列 / 播放顺序 / 洗牌排列的版本号是快照投影缓存键，不是展示状态。
@immutable
class LocalPlaybackServiceState {
  const LocalPlaybackServiceState({
    required this.queueTracks,
    required this.currentIndex,
    required this.currentSourceTrack,
    required this.contextName,
    required this.mode,
    required this.isPlaying,
    required this.isLoading,
    required this.duration,
    required this.currentQuality,
    required this.lastError,
  });

  /// 当前队列（不可变视图）。
  final List<SourceTrack> queueTracks;

  /// 当前曲目在队列中的下标（-1 = 无曲目）。
  final int currentIndex;

  /// 当前真实播放曲目（null = 无曲目 / 尚未起播）。
  final SourceTrack? currentSourceTrack;

  /// 最近一次 `playTracks` 传入的上下文名。
  final String? contextName;

  /// 当前播放模式。
  final PlayMode mode;

  /// 是否正在出声（`completed` 视为暂停）。
  final bool isPlaying;

  /// 是否正在装载新源 / 重新取链。
  final bool isLoading;

  /// 当前曲目时长（优先播放器解析值）。
  final Duration duration;

  /// 当前曲目本次播放选用的音质（null = 尚未取链）。
  final String? currentQuality;

  /// 最近一次播放失败的原始错误（未归一化；UI 不直接展示）。
  final Object? lastError;

  /// 是否有可播放曲目。
  bool get hasTrack => currentSourceTrack != null;
}
