import 'package:flutter/foundation.dart';

import '../../models/lyric_line.dart';
import 'lyric_timing_policy.dart';
import 'lyrics_display_settings.dart' show UnsyncedBehavior;

/// 行跟踪结果：当前行 + 扩展行（翻译/罗马音）+ 后续行。
///
/// [index] 为当前主行下标；-1 表示没有当前行（前奏 / 无词 / 隐藏策略）。
class TrackedLine {
  final int index;
  final String line;
  final List<String> extended;
  final List<String> upcoming;

  /// 当前行的逐字时间轴（可空 = 该行没有逐字数据）。
  final List<LyricWord>? words;

  /// 当前行的时间轴（毫秒；-1 = 未知）。
  ///
  /// 桌面歌词用它给「跟随进度」的横向滚动做线性外推（无逐字数据时）；
  /// [lineEndMs] 取下一行时间戳（最后一行回退到末词结束），未知为 -1。
  final int lineStartMs;
  final int lineEndMs;

  const TrackedLine({
    this.index = -1,
    this.line = '',
    this.extended = const [],
    this.upcoming = const [],
    this.words,
    this.lineStartMs = -1,
    this.lineEndMs = -1,
  });

  @override
  bool operator ==(Object other) =>
      other is TrackedLine &&
      other.index == index &&
      other.line == line &&
      _listEquals(other.extended, extended) &&
      _listEquals(other.upcoming, upcoming) &&
      listEquals(other.words, words) &&
      other.lineStartMs == lineStartMs &&
      other.lineEndMs == lineEndMs;

  @override
  int get hashCode => Object.hash(
        index,
        line,
        Object.hashAll(extended),
        Object.hashAll(upcoming),
        words == null ? null : Object.hashAll(words!),
        lineStartMs,
        lineEndMs,
      );

  static bool _listEquals(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// 歌词行跟踪：position + lines → 当前行 / 扩展行 / 后续行（纯逻辑）。
///
/// 所有展示策略（偏移、未同步回退、扩展行开关、后续行数量）都在这里应用，
/// 输出端只负责渲染，不再各自计算。
class LyricLineTracker {
  const LyricLineTracker();

  TrackedLine track({
    required List<LyricLine> lines,
    required List<String> translations,
    required List<String> romas,
    required bool isSynced,
    required Duration position,
    required String title,
    required int offsetMs,
    required bool translationEnabled,
    required bool romaEnabled,
    required UnsyncedBehavior unsyncedBehavior,
    required int maxLines,
  }) {
    if (lines.isEmpty) return const TrackedLine();

    // 时间策略（偏移 / 未同步行号）只有一份实现：这里只决定输出侧
    // 「歌名 / 隐藏」的内容替换，行号仍由策略给出。
    final policy = LyricTimingPolicy(
      offsetMs: offsetMs,
      unsyncedBehavior: unsyncedBehavior,
    );
    if (!isSynced) {
      switch (unsyncedBehavior) {
        case UnsyncedBehavior.hide:
          return const TrackedLine();
        case UnsyncedBehavior.title:
          return TrackedLine(index: -1, line: title);
        case UnsyncedBehavior.firstLine:
          final index = policy.lineIndexAt(lines, position, isSynced: false);
          return TrackedLine(
            index: index,
            line: lines[index].text,
            extended: policy.extendedLinesAt(
              index,
              translations,
              romas,
              translationEnabled: translationEnabled,
              romaEnabled: romaEnabled,
            ),
            upcoming: _upcoming(lines, index, maxLines),
            words: lines[index].words,
          );
      }
    }

    // 正值 = 歌词提前显示：有效进度向后平移后再查表。
    final index = policy.lineIndexAt(lines, position, isSynced: isSynced);
    if (index < 0) {
      // 前奏（还没到第一句）：没有当前行可显示，把最前面的若干句作为
      // 「即将到来」下发——悬浮窗不至于整段空着，第一句开始后回到正常
      // 当前行 + 后续行；此时没有当前行占用行位，预览可占满 maxLines。
      return TrackedLine(upcoming: _introPreview(lines, maxLines));
    }

    // 行时间轴：终点取下一行时间戳；最后一行回退到末词结束；非法值归一为未知。
    final words = lines[index].words;
    final startMs = lines[index].timestamp.inMilliseconds;
    var endMs = index + 1 < lines.length
        ? lines[index + 1].timestamp.inMilliseconds
        : -1;
    if (endMs <= startMs && words != null && words.isNotEmpty) {
      endMs = words.last.end.inMilliseconds;
    }
    if (endMs <= startMs) endMs = -1;

    return TrackedLine(
      index: index,
      line: lines[index].text,
      extended: policy.extendedLinesAt(
        index,
        translations,
        romas,
        translationEnabled: translationEnabled,
        romaEnabled: romaEnabled,
      ),
      upcoming: _upcoming(lines, index, maxLines),
      words: words,
      lineStartMs: startMs,
      lineEndMs: endMs,
    );
  }

  static List<String> _upcoming(
      List<LyricLine> lines, int index, int maxLines) {
    if (maxLines <= 1) return const [];
    final result = <String>[];
    for (var i = index + 1;
        i < lines.length && result.length < maxLines - 1;
        i++) {
      result.add(lines[i].text);
    }
    return result;
  }

  /// 前奏预览：位置还没到第一句时，展示最前面的 [maxLines] 句（没有当前行
  /// 占用行位，因此可占满 [maxLines]）。
  static List<String> _introPreview(List<LyricLine> lines, int maxLines) {
    if (maxLines <= 0) return const [];
    final result = <String>[];
    for (final line in lines) {
      if (line.text.isEmpty) continue;
      result.add(line.text);
      if (result.length >= maxLines) break;
    }
    return result;
  }
}
