/// 统计投影模块的接口测试：窗口、日历、7×24 矩阵与海报输入。
///
/// 所有用例都显式构造 `ListeningStatisticsWindow`，不读墙钟——模块本身也不允许读，
/// 这样跨午夜 / 跨年的边界才能在任意时间稳定复现。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/domain/models/play_statistics.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/statistics/statistics_models.dart';
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
  ListeningStatisticsWindow(range: PlayStatisticsRange.week, now: now),
);

void main() {
  group('ListeningStatisticsWindow', () {
    test('周 / 月 / 全部的起点与查询毫秒来自同一个 now', () {
      final now = DateTime(2031, 1, 2, 23, 59, 59);
      final week = ListeningStatisticsWindow(
        range: PlayStatisticsRange.week,
        now: now,
      );
      final month = ListeningStatisticsWindow(
        range: PlayStatisticsRange.month,
        now: now,
      );
      final all = ListeningStatisticsWindow(
        range: PlayStatisticsRange.all,
        now: now,
      );

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
        ListeningStatisticsWindow(
          range: PlayStatisticsRange.week,
          now: DateTime(2031, 1, 2, 12),
        ),
      );

      expect(view.calendarValues(duration: true)[DateTime(2031, 1, 1)], 5000);
      expect(view.calendarValues(duration: false)[DateTime(2031, 1, 1)], 2);
      expect(view.calendarValues(duration: true)[DateTime(2030, 12, 31)], 8000);
      expect(view.calendarValues(duration: false)[DateTime(2030, 12, 31)], 3);
    });

    test('7×24 矩阵稠密并按维度取值', () {
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
          ],
        ),
        ListeningStatisticsWindow(
          range: PlayStatisticsRange.week,
          now: DateTime(2031, 1, 2, 12),
        ),
      );

      final duration = view.weekdayHourValues(duration: true);
      final count = view.weekdayHourValues(duration: false);
      expect(duration, hasLength(7));
      for (final row in duration) {
        expect(row, hasLength(24));
      }
      expect(duration[0][0], 1000);
      expect(duration[2][5], 2000);
      expect(count[0][0], 3);
      expect(count[2][5], 4);
      expect(
        duration.fold<int>(0, (sum, row) => sum + row.fold(0, (a, b) => a + b)),
        3000,
      );
    });

    test('非法 weekday / hour 行逐项跳过（损坏数据降级）', () {
      const cases = [(-1, 4), (7, 4), (3, -1), (3, 24)];
      for (final (weekday, hour) in cases) {
        final view = ListeningStatisticsView.from(
          _snapshot(
            byWeekdayHour: [
              WeekdayHourListened(
                weekday: weekday,
                hour: hour,
                listenedMs: 9000,
                playCount: 9,
              ),
            ],
          ),
          ListeningStatisticsWindow(
            range: PlayStatisticsRange.week,
            now: DateTime(2031, 1, 2, 12),
          ),
        );

        final duration = view.weekdayHourValues(duration: true);
        final count = view.weekdayHourValues(duration: false);
        expect(
          duration.fold<int>(
            0,
            (sum, row) => sum + row.fold(0, (a, b) => a + b),
          ),
          0,
          reason: 'weekday=$weekday hour=$hour 不应落格',
        );
        expect(
          count.fold<int>(0, (sum, row) => sum + row.fold(0, (a, b) => a + b)),
          0,
        );
      }
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
        ListeningStatisticsWindow(
          range: PlayStatisticsRange.week,
          now: DateTime(2031, 1, 2, 0, 0, 1),
        ),
      );

      expect(view.firstDay, DateTime(2030, 12, 31));
      expect(
        view.firstPlayedAt,
        DateTime(2030, 12, 31, 18, 30),
        reason: '首播事实保留时间分量，年度覆盖起点直接消费它',
      );
      expect(view.today, DateTime(2031, 1, 2));
      expect(view.window.start, DateTime(2030, 12, 26, 0, 0, 1));
    });

    test('没有首播记录时起始日退回窗口今天，首播事实为空', () {
      final view = _view(DateTime(2031, 1, 2, 12));
      expect(view.firstPlayedAt, isNull);
      expect(view.firstDay, DateTime(2031, 1, 2));
      expect(view.window.start, DateTime(2030, 12, 26, 12));
    });

    test('跨年窗口：首播事实 / 日历起点 / 年度入口共用同一窗口', () {
      final firstPlayedAt = DateTime(2030, 12, 31, 23, 30);
      final now = DateTime(2031, 1, 1, 0, 15);
      final view = ListeningStatisticsView.from(
        _snapshot(
          firstPlayedAt: firstPlayedAt.millisecondsSinceEpoch,
          daily: [
            DayListened(
              day: DateTime(2030, 12, 31),
              listenedMs: 5000,
              playCount: 2,
            ),
          ],
        ),
        ListeningStatisticsWindow(range: PlayStatisticsRange.week, now: now),
      );

      expect(view.firstPlayedAt, firstPlayedAt);
      expect(view.firstDay, DateTime(2030, 12, 31));
      expect(view.today, DateTime(2031, 1, 1));
      // 1 月：上一年有数据时推上一年，且用高强调。
      expect(view.annualEntry.featuredYear, 2030);
      expect(view.annualEntry.prominent, isTrue);
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
        ListeningStatisticsWindow(
          range: PlayStatisticsRange.week,
          now: DateTime(2031, 1, 2, 12),
        ),
      );

      expect(view.posterWeekdayHour, hasLength(168));
      expect(view.posterWeekdayHour[6 * 24 + 23], 7000);
      expect(
        view.posterWeekdayHour.fold<int>(0, (sum, value) => sum + value),
        7000,
        reason: '非法 hour=24 不落格',
      );
      expect(view.snapshot.topTracks, [track]);
      expect(view.snapshot.sources.single.sourceKey, 'wy');
    });
  });

  group('海报输入', () {
    test('直接消费视图投影，星期标签重排为周一开头', () {
      final l10n = lookupAppLocalizations(const Locale('zh'));
      final view = ListeningStatisticsView.from(
        _snapshot(
          totalListenedMs: 9000,
          qualifiedPlayCount: 3,
          uniqueTrackCount: 1,
          topTracks: const [
            PlayStatTrackEntry(
              sourceKey: 'wy',
              songId: 's1',
              title: '晴天',
              artist: '周杰伦',
              playCount: 3,
              listenedMs: 9000,
              lastPlayedAt: 0,
            ),
          ],
          sources: const [
            SourceListened(sourceKey: 'wy', listenedMs: 9000, playCount: 3),
          ],
          byWeekdayHour: const [
            WeekdayHourListened(
              weekday: 2,
              hour: 5,
              listenedMs: 2000,
              playCount: 4,
            ),
          ],
        ),
        ListeningStatisticsWindow(
          range: PlayStatisticsRange.week,
          now: DateTime(2031, 1, 2, 12),
        ),
      );

      final data = buildListeningStatsPosterData(
        l10n: l10n,
        view: view,
        narrowWeekdays: const ['日', '一', '二', '三', '四', '五', '六'],
        sourceName: (key) => '平台$key',
      );

      expect(data.rangeLabel, l10n.statsRangeWeek);
      expect(data.weekdayLabels, ['一', '二', '三', '四', '五', '六', '日']);
      expect(data.weekdayHour, hasLength(168));
      expect(data.weekdayHour[2 * 24 + 5], 2000);
      expect(data.playsLabel, '3');
      expect(data.platformLabel, contains('平台wy'));
    });
  });
}
