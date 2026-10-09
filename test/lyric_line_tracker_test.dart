import 'package:flutter_test/flutter_test.dart';
import 'package:molia/models/lyric_line.dart';
import 'package:molia/services/lyrics_display/lyric_line_tracker.dart';
import 'package:molia/services/lyrics_display/lyrics_display_settings.dart';

/// 行跟踪：position → 当前行 / 扩展行 / 后续行（策略全在 tracker）。
void main() {
  const tracker = LyricLineTracker();
  const lines = [
    LyricLine(Duration(seconds: 2), 'two'),
    LyricLine(Duration(seconds: 5), 'five'),
    LyricLine(Duration(seconds: 10), 'ten'),
    LyricLine(Duration(seconds: 15), 'fifteen'),
  ];
  const translations = ['二', '五', '', ''];
  const romas = ['', 'go', '', 'juu'];
  const title = '歌名';

  TrackedLine track(
    Duration position, {
    int offsetMs = 0,
    bool translation = true,
    bool roma = false,
    bool synced = true,
    UnsyncedBehavior unsynced = UnsyncedBehavior.title,
    int maxLines = 3,
  }) =>
      tracker.track(
        lines: lines,
        translations: translations,
        romas: romas,
        isSynced: synced,
        position: position,
        title: title,
        offsetMs: offsetMs,
        translationEnabled: translation,
        romaEnabled: roma,
        unsyncedBehavior: unsynced,
        maxLines: maxLines,
      );

  test('同步歌词：按 position 命中当前行与后续行', () {
    final result = track(const Duration(seconds: 6));
    expect(result.index, 1);
    expect(result.line, 'five');
    expect(result.upcoming, ['ten', 'fifteen']);
  });

  test('首行之前返回空行（前奏）', () {
    final result = track(const Duration(seconds: 1));
    expect(result.index, -1);
    expect(result.line, '');
    expect(result.upcoming, isEmpty);
  });

  test('正值偏移让歌词提前显示', () {
    expect(track(const Duration(seconds: 4)).index, 0);
    expect(track(const Duration(seconds: 4), offsetMs: 1000).index, 1);
  });

  test('扩展行按开关独立组装，缺失的扩展文本不占位', () {
    expect(track(const Duration(seconds: 5)).extended, ['五']);
    expect(track(const Duration(seconds: 5), roma: true).extended, ['五', 'go']);
    expect(
      track(const Duration(seconds: 5), translation: false, roma: true)
          .extended,
      ['go'],
    );
    expect(track(const Duration(seconds: 11)).extended, isEmpty);
  });

  test('maxLines 控制后续行数量（1 = 只显示当前行）', () {
    expect(track(const Duration(seconds: 6), maxLines: 1).upcoming, isEmpty);
    expect(
      track(const Duration(seconds: 6), maxLines: 2).upcoming,
      ['ten'],
    );
  });

  test('未同步歌词：按策略显示歌名 / 隐藏 / 首行', () {
    final byTitle = track(const Duration(seconds: 6), synced: false);
    expect(byTitle.line, title);
    expect(byTitle.index, -1);

    final hidden = track(
      const Duration(seconds: 6),
      synced: false,
      unsynced: UnsyncedBehavior.hide,
    );
    expect(hidden.line, '');

    final firstLine = track(
      const Duration(seconds: 6),
      synced: false,
      unsynced: UnsyncedBehavior.firstLine,
    );
    expect(firstLine.line, 'two');
    expect(firstLine.index, 0);
  });

  test('空歌词返回空结果', () {
    final result = tracker.track(
      lines: const [],
      translations: const [],
      romas: const [],
      isSynced: true,
      position: const Duration(seconds: 5),
      title: title,
      offsetMs: 0,
      translationEnabled: true,
      romaEnabled: true,
      unsyncedBehavior: UnsyncedBehavior.title,
      maxLines: 3,
    );
    expect(result.line, '');
    expect(result.index, -1);
  });
}
