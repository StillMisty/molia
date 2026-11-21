/// 统计投影模块的接口测试：窗口、日历、7×24 矩阵与海报输入。
///
/// 所有用例都显式构造 `StatisticsWindow`，不读墙钟——模块本身也不允许读，
/// 这样跨午夜 / 跨年的边界才能在任意时间稳定复现。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/play_statistics.dart';
import 'package:molia/services/statistics/listening_statistics.dart';

ListeningStatisticsSnapshot _snapshot({
  int? firstPlayedAt,
  List<DayListened> daily = const [],
  List<WeekdayHourListened> byWeekdayHour = const [],
  List<PlayStatTrackEntry> topTracks = const [],
  List<PlayStatArtistEntry> topArtists = const [],
  List<SourceListened> sources = const [],
  int totalListenedMs = 0,
  int qualifiedPlayCount = 0,
  int uniqueTrackCount = 0,
}) {
  return ListeningStatisticsSnapshot(
    summary: PlayStatisticsSummary(
      playCount: 1,
      qualifiedPlayCount: qualifiedPlayCount,
      totalListenedMs: totalListenedMs,
      uniqueTrackCount: uniqueTrackCount,
      completionRate: 0.5,
      skipRate: 0.1,
      firstPlayedAt: firstPlayedAt,
    ),
    topTracks: topTracks,
    topArtists: topArtists,
    daily: daily,
    byWeekdayHour: byWeekdayHour,
    sources: sources,
  );
}

ListeningStatisticsView _view(DateTime now) => ListeningStatisticsView.from(
  _snapshot(),
  StatisticsWindow(range: PlayStatisticsRange.week, now: now),
);

void main() {
  group('StatisticsWindow', () {
    test('周 / 月 / 全部的起点与查询毫秒来自同一个 now', () {
      final now = DateTime(2031, 1, 2, 23, 59, 59);
      final week = StatisticsWindow(range: PlayStatisticsRange.week, now: now);
      final month = StatisticsWindow(
        range: PlayStatisticsRange.month,
        now: now,
      );
      final all = StatisticsWindow(range: PlayStatisticsRange.all, now: now);

      expect(week.start, DateTime(2030, 12, 26, 23, 59, 59));
      expect(week.sinceMs, week.start!.millisecondsSinceEpoch);
      expect(week.today, DateTime(2031, 1, 2));

      expect(month.start, DateTime(2030, 12, 3, 23, 59, 59));
      expect(month.sinceMs, month.start!.millisecondsSinceEpoch);

      expect(all.start, isNull);
      expect(all.sinceMs, isNull);
      expect(all.today, DateTime(2031, 1, 2));
    });

    test('today 只由窗口 now 决定（跨午夜仍取同一次读取）', () {
      expect(
        _view(DateTime(2031, 1, 1, 23, 59, 59, 999)).today,
        DateTime(2031, 1, 1),
      );
      expect(
        _view(DateTime(2031, 1, 2, 0, 0, 0, 1)).today,
        DateTime(2031, 1, 2),
      );
    });
  });

  group('ListeningStatisticsView', () {
    test('日历按维度给出时长 / 次数，并可切换', () {
      final view = ListeningStatisticsView.from(
        _snapshot(
          daily: [
            DayListened(
              day: DateTime(2031, 1, 1),
              listenedMs: 5000,
              playCount: 2,
            ),
            DayListened(
              day: DateTime(2030, 12, 31),
              listenedMs: 8000,
              playCount: 3,
            ),
          ],
        ),
        StatisticsWindow(
          range: PlayStatisticsRange.week,
          now: DateTime(2031, 1, 2, 12),
        ),
      );

      expect(view.calendarByDuration[DateTime(2031, 1, 1)], 5000);
      expect(view.calendarByCount[DateTime(2031, 1, 1)], 2);
      expect(view.calendarByDuration[DateTime(2030, 12, 31)], 8000);
      expect(view.calendarByCount[DateTime(2030, 12, 31)], 3);
      expect(view.calendarValues(duration: true), view.calendarByDuration);
      expect(view.calendarValues(duration: false), view.calendarByCount);
    });

    test('7×24 矩阵稠密、按维度取值，非法 weekday / hour 行跳过', () {
      final view = ListeningStatisticsView.from(
        _snapshot(
          byWeekdayHour: const [
            WeekdayHourListened(
              weekday: 0,
              hour: 0,
              listenedMs: 1000,
              playCount: 3,
            ),
            WeekdayHourListened(
              weekday: 2,
              hour: 5,
              listenedMs: 2000,
              playCount: 4,
            ),
            WeekdayHourListened(
              weekday: -1,
              hour: 4,
              listenedMs: 9000,
              playCount: 9,
            ),
            WeekdayHourListened(
              weekday: 7,
              hour: 4,
              listenedMs: 9000,
              playCount: 9,
            ),
            WeekdayHourListened(
              weekday: 3,
              hour: -1,
              listenedMs: 9000,
              playCount: 9,
            ),
            WeekdayHourListened(
              weekday: 3,
              hour: 24,
              listenedMs: 9000,
              playCount: 9,
            ),
          ],
        ),
        StatisticsWindow(
          range: PlayStatisticsRange.week,
          now: DateTime(2031, 1, 2, 12),
        ),
      );

      final duration = view.weekdayHourByDuration;
      final count = view.weekdayHourByCount;
      expect(duration, hasLength(7));
      for (final row in duration) {
        expect(row, hasLength(24));
      }
      expect(duration[0][0], 1000);
      expect(duration[2][5], 2000);
      expect(count[0][0], 3);
      expect(count[2][5], 4);
      // 非法行既不落格也不越界（旧实现只校验 weekday，hour 越界会抛异常）。
      expect(duration[3][0], 0);
      expect(
        duration.fold<int>(0, (sum, row) => sum + row.fold(0, (a, b) => a + b)),
        3000,
      );
      expect(view.weekdayHourValues(duration: true), duration);
      expect(view.weekdayHourValues(duration: false), count);
    });

    test('firstDay 来自全局首播日，today / 高亮起点来自窗口', () {
      final firstPlayedAt = DateTime(
        2030,
        12,
        31,
        18,
        30,
      ).millisecondsSinceEpoch;
      final view = ListeningStatisticsView.from(
        _snapshot(firstPlayedAt: firstPlayedAt),
        StatisticsWindow(
          range: PlayStatisticsRange.week,
          now: DateTime(2031, 1, 2, 0, 0, 1),
        ),
      );

      expect(view.firstDay, DateTime(2030, 12, 31));
      expect(view.today, DateTime(2031, 1, 2));
      expect(view.windowStart, DateTime(2030, 12, 26, 0, 0, 1));
    });

    test('没有首播记录时起始日退回窗口今天', () {
      final view = _view(DateTime(2031, 1, 2, 12));
      expect(view.firstDay, DateTime(2031, 1, 2));
      expect(view.windowStart, DateTime(2030, 12, 26, 12));
    });

    test('海报投影只摊平一次：固定 168 槽、非法行跳过、榜单原样保留', () {
      const track = PlayStatTrackEntry(
        sourceKey: 'wy',
        songId: 's1',
        title: '晴天',
        playCount: 3,
        listenedMs: 9000,
        lastPlayedAt: 0,
      );
      final view = ListeningStatisticsView.from(
        _snapshot(
          topTracks: const [track],
          sources: const [
            SourceListened(sourceKey: 'wy', listenedMs: 9000, playCount: 3),
          ],
          byWeekdayHour: const [
            WeekdayHourListened(
              weekday: 6,
              hour: 23,
              listenedMs: 7000,
              playCount: 7,
            ),
            WeekdayHourListened(
              weekday: 6,
              hour: 24,
              listenedMs: 8000,
              playCount: 8,
            ),
          ],
        ),
        StatisticsWindow(
          range: PlayStatisticsRange.week,
          now: DateTime(2031, 1, 2, 12),
        ),
      );

      expect(view.poster.weekdayHour, hasLength(168));
      expect(view.poster.weekdayHour[6 * 24 + 23], 7000);
      expect(
        view.poster.weekdayHour.fold<int>(0, (sum, value) => sum + value),
        7000,
        reason: '非法 hour=24 不落格',
      );
      expect(view.poster.topTracks, [track]);
      expect(view.poster.sources.single.sourceKey, 'wy');
    });
  });
}
