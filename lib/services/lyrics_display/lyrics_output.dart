import 'package:flutter/foundation.dart';

import '../../models/lyric_line.dart';
import 'lyrics_display_settings.dart';

/// 输出能力：平台是否支持 / 权限是否就绪。
///
/// 「启用态」由配置决定（`LyricsDisplayProvider` 按配置决定是否投送），
/// 输出自身只报告平台与权限事实。
enum LyricsOutputCapability { unsupported, needsPermission, ready }

/// 输出端唯一标识（与配置分组一一对应）。
abstract final class LyricsOutputIds {
  static const desktop = 'desktop_overlay';
  static const media = 'media_metadata';
}

/// 一次投送的完整行数据（策略已应用，接收端直接展示）。
@immutable
class LyricsPresentation {
  final String trackId;
  final String title;
  final String line;
  final List<String> extended;
  final List<String> upcoming;
  final bool isPlaying;
  final bool hasLyrics;

  /// 当前行的逐字时间轴（可空 = 该行无逐字数据，按整行着色）。
  final List<LyricWord>? words;

  /// 本次投送时的有效播放位置（毫秒，已叠加歌词偏移）。
  ///
  /// 桌面歌词用它给逐字渐染做插值基准；位置变化会让 presentation 变化，
  /// 从而在播放中以位置通道的频率（≤4Hz）刷新悬浮窗。
  final int positionMs;

  /// [positionMs] 生效的墙上时刻（毫秒，同设备壁钟；0 = 未知）。
  ///
  /// 输出端据此补偿「采样 → 渲染」之间的传输延迟（主线程繁忙时通道投递会
  /// 变慢）：`锚点 = positionMs + (now − positionAtEpochMs)`。不给这个字段
  /// 时只能按到达时刻外推，延迟抖动会直接变成可见的回跳。
  final int positionAtEpochMs;

  /// 横向滚动的映射方式：true = 跟随已唱边界（逐字）；false = 按
  /// [lineStartMs]/[lineEndMs] 线性匀速。
  ///
  /// 由配置（`desktop.scrollMode`）决定，Dart 侧算好跨度后下发；颜色渐染
  /// 两种模式都仍走逐字时间轴，不受影响。
  final bool scrollFollowsSinging;

  /// 横向滚动的线性映射跨度（毫秒；-1 = 未知）。
  ///
  /// 无逐字数据时是当前行时间轴；匀速模式（[scrollFollowsSinging] 为 false）
  /// 且该行有逐字数据时，Dart 侧换成「首词开始 → 末词结束」的演唱跨度
  /// （终点越过切行时刻时夹到行尾），避免尾奏空档把文本拖走、也保证切行前
  /// 滚完。跟随演唱模式下这是行时间轴兜底口径，见 `CurrentLineView`。
  final int lineStartMs;
  final int lineEndMs;

  const LyricsPresentation({
    required this.trackId,
    required this.title,
    required this.line,
    this.extended = const [],
    this.upcoming = const [],
    required this.isPlaying,
    required this.hasLyrics,
    this.words,
    this.positionMs = 0,
    this.positionAtEpochMs = 0,
    this.scrollFollowsSinging = true,
    this.lineStartMs = -1,
    this.lineEndMs = -1,
  });

  @override
  bool operator ==(Object other) =>
      other is LyricsPresentation &&
      other.trackId == trackId &&
      other.title == title &&
      other.line == line &&
      listEquals(other.extended, extended) &&
      listEquals(other.upcoming, upcoming) &&
      other.isPlaying == isPlaying &&
      other.hasLyrics == hasLyrics &&
      listEquals(other.words, words) &&
      other.positionMs == positionMs &&
      other.positionAtEpochMs == positionAtEpochMs &&
      other.scrollFollowsSinging == scrollFollowsSinging &&
      other.lineStartMs == lineStartMs &&
      other.lineEndMs == lineEndMs;

  @override
  int get hashCode => Object.hash(
        trackId,
        title,
        line,
        Object.hashAll(extended),
        Object.hashAll(upcoming),
        isPlaying,
        hasLyrics,
        words == null ? null : Object.hashAll(words!),
        positionMs,
        positionAtEpochMs,
        scrollFollowsSinging,
        lineStartMs,
        lineEndMs,
      );
}

/// 桌面悬浮窗控制条可触发的动作。
enum LyricsOutputAction {
  playPause,
  previous,
  next,
  toggleTranslation,
  lock,
  close,
}

/// 歌词输出端接口：桌面悬浮窗 / 媒体元数据 / 未来的桌面窗口输出。
///
/// 契约：
/// - [start] 幂等：按当前配置使输出进入/退出启用态（含权限检查）；
/// - [apply] 只在行/状态变化时由调度方调用；
/// - [clear] 表示当前无曲目或输出被关闭时的清空；
/// - [stop] 释放平台资源。
abstract class LyricsOutput {
  String get id;

  LyricsOutputCapability get capability;

  Future<void> start(LyricsDisplaySettings settings);

  Future<void> apply(LyricsPresentation presentation);

  Future<void> clear();

  Future<void> stop();
}

/// 能上报用户交互的输出（桌面悬浮窗控制条）。
abstract class InteractiveLyricsOutput implements LyricsOutput {
  Stream<LyricsOutputAction> get actions;
}
