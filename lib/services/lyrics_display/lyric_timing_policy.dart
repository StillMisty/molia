import 'package:flutter/foundation.dart';

import '../../models/lyric_line.dart';
import 'lyrics_display_settings.dart' show UnsyncedBehavior;

/// 应用内歌词页的视觉提前量（正值 = 比真实进度早）。
///
/// 切行有 450ms 的淡入 / 字重 / 内边距过渡，位置通道又只有 ≤4Hz——按精确
/// 时间戳切行时，高亮要等唱到该行之后才开始变化。统一提前 200ms：行首时
/// 过渡已走完大半；逐字渐染的采样间补间（慢一拍）也抵消到视听同步范围内。
///
/// 只作用于应用内歌词页 / 选择页；输出侧仍用 `LyricsDisplaySettings.offsetMs`。
/// 行号查表与 `KaraokeLyricText(lead:)` 必须引用同一常量，否则词高亮与
/// 行高亮会在时间戳附近错开一行。
const Duration kLyricDisplayLead = Duration(milliseconds: 200);

/// 歌词时间策略（纯逻辑）：位置 → 当前行号，以及当前行的扩展行。
///
/// 三个消费面共用同一实现：
/// - 应用内歌词页 / 歌词选择页用 [LyricTimingPolicy.page]（叠加视觉提前量）；
/// - 输出侧（桌面歌词 / 通知 / 蓝牙）用 [LyricTimingPolicy.output]，只叠加
///   用户配置的 [offsetMs]，不叠加页内提前量；
/// - 无时间轴歌词的展示策略（隐藏 / 歌名 / 首行）也在这里统一解释。
///
/// 滚动策略（`lyrics_scroll_policy.dart`）是另一层：本策略只回答「哪一行」，
/// 不决定滚到哪里。
@immutable
class LyricTimingPolicy {
  const LyricTimingPolicy({
    this.lead = Duration.zero,
    this.offsetMs = 0,
    this.unsyncedBehavior = UnsyncedBehavior.title,
  });

  /// 应用内歌词页 / 选择页：固定视觉提前量；未同步歌词不点亮任何行
  /// （[UnsyncedBehavior.title] 在页内只表示「没有当前行」，不显示歌名）。
  static const page = LyricTimingPolicy(lead: kLyricDisplayLead);

  /// 输出侧：只应用用户偏移，不叠加页内提前量。
  const LyricTimingPolicy.output({
    required this.offsetMs,
    required this.unsyncedBehavior,
  }) : lead = Duration.zero;

  /// 视觉提前量（正值 = 提前）。
  final Duration lead;

  /// 用户歌词偏移（正值 = 提前）；输出侧唯一的时间平移来源。
  final int offsetMs;

  /// 无时间轴歌词的展示策略。
  final UnsyncedBehavior unsyncedBehavior;

  /// 有效展示位置 = 真实位置 + 提前量 + 用户偏移（正 = 提前）。
  Duration effectivePosition(Duration position) =>
      position + lead + Duration(milliseconds: offsetMs);

  /// 当前主行下标；-1 = 无当前行（前奏 / 空词 / 未同步按策略不显示）。
  int lineIndexAt(
    List<LyricLine> lines,
    Duration position, {
    required bool isSynced,
  }) {
    if (lines.isEmpty) return -1;
    if (!isSynced) {
      return switch (unsyncedBehavior) {
        UnsyncedBehavior.firstLine => 0,
        UnsyncedBehavior.hide || UnsyncedBehavior.title => -1,
      };
    }
    return lyricLineIndexAt(lines, effectivePosition(position));
  }

  /// 当前行的扩展行文本：翻译在前、罗马音在后，空文本不占位。
  List<String> extendedLinesAt(
    int index,
    List<String> translations,
    List<String> romas, {
    required bool translationEnabled,
    required bool romaEnabled,
  }) {
    final result = <String>[];
    if (translationEnabled &&
        index >= 0 &&
        index < translations.length &&
        translations[index].isNotEmpty) {
      result.add(translations[index]);
    }
    if (romaEnabled &&
        index >= 0 &&
        index < romas.length &&
        romas[index].isNotEmpty) {
      result.add(romas[index]);
    }
    return result;
  }
}
