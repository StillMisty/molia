import '../../models/lyric_line.dart';
import 'lyrics_display_settings.dart' show UnsyncedBehavior;

/// 行跟踪结果：当前行 + 扩展行（翻译/罗马音）+ 后续行。
///
/// [index] 为当前主行下标；-1 表示没有当前行（前奏 / 无词 / 隐藏策略）。
class TrackedLine {
  final int index;
  final String line;
  final List<String> extended;
  final List<String> upcoming;

  const TrackedLine({
    this.index = -1,
    this.line = '',
    this.extended = const [],
    this.upcoming = const [],
  });

  @override
  bool operator ==(Object other) =>
      other is TrackedLine &&
      other.index == index &&
      other.line == line &&
      _listEquals(other.extended, extended) &&
      _listEquals(other.upcoming, upcoming);

  @override
  int get hashCode =>
      Object.hash(index, line, Object.hashAll(extended), Object.hashAll(upcoming));

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

    if (!isSynced) {
      switch (unsyncedBehavior) {
        case UnsyncedBehavior.hide:
          return const TrackedLine();
        case UnsyncedBehavior.title:
          return TrackedLine(index: -1, line: title);
        case UnsyncedBehavior.firstLine:
          return TrackedLine(
            index: 0,
            line: lines.first.text,
            extended: _extendedAt(
              0,
              translations,
              romas,
              translationEnabled: translationEnabled,
              romaEnabled: romaEnabled,
            ),
            upcoming: _upcoming(lines, 0, maxLines),
          );
      }
    }

    // 正值 = 歌词提前显示：有效进度向后平移后再查表。
    final effectivePosition = position + Duration(milliseconds: offsetMs);
    final index = lyricLineIndexAt(lines, effectivePosition);
    if (index < 0) return const TrackedLine();

    return TrackedLine(
      index: index,
      line: lines[index].text,
      extended: _extendedAt(
        index,
        translations,
        romas,
        translationEnabled: translationEnabled,
        romaEnabled: romaEnabled,
      ),
      upcoming: _upcoming(lines, index, maxLines),
    );
  }

  static List<String> _extendedAt(
    int index,
    List<String> translations,
    List<String> romas, {
    required bool translationEnabled,
    required bool romaEnabled,
  }) {
    final result = <String>[];
    if (translationEnabled &&
        index < translations.length &&
        translations[index].isNotEmpty) {
      result.add(translations[index]);
    }
    if (romaEnabled && index < romas.length && romas[index].isNotEmpty) {
      result.add(romas[index]);
    }
    return result;
  }

  static List<String> _upcoming(List<LyricLine> lines, int index, int maxLines) {
    if (maxLines <= 1) return const [];
    final result = <String>[];
    for (var i = index + 1; i < lines.length && result.length < maxLines - 1; i++) {
      result.add(lines[i].text);
    }
    return result;
  }
}
