import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/annual_report.dart';
import 'package:molia/domain/models/annual_report_entry.dart';
import 'package:molia/domain/models/play_statistics.dart';

PlayStatisticsSummary _summary({
  int playCount = 1,
  int qualified = 1,
  int listenedMs = 60000,
  int uniqueTracks = 1,
  int? firstPlayedAt,
}) => PlayStatisticsSummary(
  playCount: playCount,
  qualifiedPlayCount: qualified,
  totalListenedMs: listenedMs,
  uniqueTrackCount: uniqueTracks,
  completionRate: 0,
  skipRate: 0,
  firstPlayedAt: firstPlayedAt,
);

AnnualStatisticsSnapshot _snapshot({
  PlayStatisticsSummary? summary,
  List<PlayStatTrackEntry> topTracks = const [],
  List<PlayStatArtistEntry> topArtists = const [],
  List<PlayStatAlbumEntry> topAlbums = const [],
  List<SourceListened> sources = const [],
  List<DayListened> daily = const [],
  int uniqueArtistCount = 0,
  AnnualPlayMoment? firstPlay,
  AnnualPlayMoment? lastPlay,
}) => AnnualStatisticsSnapshot(
  summary: summary ?? _summary(),
  topTracks: topTracks,
  topArtists: topArtists,
  topAlbums: topAlbums,
  sources: sources,
  daily: daily,
  uniqueArtistCount: uniqueArtistCount,
  firstPlay: firstPlay,
  lastPlay: lastPlay,
);

void main() {
  group('年度聚合', () {
    test('12 个月桶零填充，边界按本地月份归属', () {
      final report = buildAnnualReport(
        year: 2026,
        now: DateTime(2027, 2, 1),
        knownSourceNames: const {'wy': '网易云'},
        data: _snapshot(
          summary: _summary(listenedMs: 3000),
          daily: [
            DayListened(
              day: DateTime(2026, 1, 1),
              listenedMs: 1000,
              playCount: 1,
            ),
            DayListened(
              day: DateTime(2026, 12, 31),
              listenedMs: 2000,
              playCount: 1,
            ),
            DayListened(
              day: DateTime(2027, 1, 1),
              listenedMs: 9999,
              playCount: 1,
            ),
          ],
        ),
      );
      expect(report.monthlyListenedMs, hasLength(12));
      expect(report.monthlyListenedMs.first, 1000);
      expect(report.monthlyListenedMs.last, 2000);
      expect(report.monthlyListenedMs.sublist(1, 11), everyElement(0));
    });

    test('最长连续天数：计数间隔，不跨年，零时长日不延长', () {
      final report = buildAnnualReport(
        year: 2026,
        now: DateTime(2027, 3, 1),
        knownSourceNames: const {},
        data: _snapshot(
          daily: [
            DayListened(
              day: DateTime(2026, 3, 1),
              listenedMs: 1000,
              playCount: 1,
            ),
            DayListened(
              day: DateTime(2026, 3, 2),
              listenedMs: 2000,
              playCount: 1,
            ),
            DayListened(day: DateTime(2026, 3, 3), listenedMs: 0, playCount: 1),
            DayListened(
              day: DateTime(2026, 3, 4),
              listenedMs: 3000,
              playCount: 1,
            ),
            DayListened(
              day: DateTime(2026, 3, 5),
              listenedMs: 4000,
              playCount: 1,
            ),
            DayListened(
              day: DateTime(2026, 12, 31),
              listenedMs: 5000,
              playCount: 1,
            ),
          ],
        ),
      );
      expect(report.streak.days, 2);
      expect(report.streak.start, DateTime(2026, 3, 1));
      expect(report.streak.end, DateTime(2026, 3, 2));
    });

    test('平台占比与未知平台合并为 other', () {
      final report = buildAnnualReport(
        year: 2026,
        now: DateTime(2027, 1, 2),
        knownSourceNames: const {'wy': '网易云'},
        data: _snapshot(
          summary: _summary(listenedMs: 1000),
          sources: const [
            SourceListened(sourceKey: 'wy', listenedMs: 800, playCount: 2),
            SourceListened(sourceKey: 'ghost', listenedMs: 200, playCount: 1),
          ],
        ),
      );
      expect(report.platforms.map((entry) => entry.sourceKey), ['wy', 'other']);
      expect(report.platforms.first.share, closeTo(0.8, 0.0001));
      expect(report.platforms.last.share, closeTo(0.2, 0.0001));
    });

    test('空年份没有数据，不渲染假零图表', () {
      final report = buildAnnualReport(
        year: 2026,
        now: DateTime(2027, 2, 1),
        knownSourceNames: const {},
        data: _snapshot(
          summary: _summary(playCount: 0, qualified: 0, listenedMs: 0),
        ),
      );
      expect(report.hasData, isFalse);
      expect(report.monthlyListenedMs, everyElement(0));
      expect(report.firstPlay, isNull);
      expect(report.platforms, isEmpty);
    });

    test('当前年标记截至今天；关闭记录时提示 recordingOff', () {
      final report = buildAnnualReport(
        year: 2026,
        now: DateTime(2026, 11, 14),
        knownSourceNames: const {},
        recordingEnabled: false,
        data: _snapshot(
          summary: _summary(
            firstPlayedAt: DateTime(2026, 1, 1).millisecondsSinceEpoch,
          ),
          daily: [
            DayListened(
              day: DateTime(2026, 1, 1),
              listenedMs: 1000,
              playCount: 1,
            ),
          ],
        ),
      );
      expect(report.asOfToday, isTrue);
      expect(report.notice, AnnualReportNotice.recordingOff);
    });

    test('正常完整的一年不因首末日期不是 1/1、12/31 而提示部分覆盖', () {
      final report = buildAnnualReport(
        year: 2025,
        now: DateTime(2026, 2, 1),
        knownSourceNames: const {},
        data: _snapshot(
          summary: _summary(
            firstPlayedAt: DateTime(2025, 1, 5).millisecondsSinceEpoch,
          ),
          daily: [
            DayListened(
              day: DateTime(2025, 1, 5),
              listenedMs: 1000,
              playCount: 1,
            ),
            DayListened(
              day: DateTime(2025, 12, 28),
              listenedMs: 1000,
              playCount: 1,
            ),
          ],
        ),
      );
      expect(report.notice, AnnualReportNotice.none);
    });

    test('往年覆盖不完整时提示 partialCoverage', () {
      final report = buildAnnualReport(
        year: 2025,
        now: DateTime(2026, 2, 1),
        knownSourceNames: const {},
        data: _snapshot(
          summary: _summary(
            firstPlayedAt: DateTime(2025, 6, 1).millisecondsSinceEpoch,
          ),
          daily: [
            DayListened(
              day: DateTime(2025, 6, 1),
              listenedMs: 1000,
              playCount: 1,
            ),
            DayListened(
              day: DateTime(2025, 8, 1),
              listenedMs: 1000,
              playCount: 1,
            ),
          ],
        ),
      );
      expect(report.notice, AnnualReportNotice.partialCoverage);
      expect(report.coverageStart, DateTime(2025, 6, 1));
      expect(report.coverageEnd, DateTime(2025, 8, 1));
    });

    test('Top 50 保留完整列表，页面只取前 5', () {
      final tracks = [
        for (var index = 0; index < 60; index++)
          PlayStatTrackEntry(
            sourceKey: 'wy',
            songId: 's$index',
            title: 'Track $index',
            playCount: 60 - index,
            listenedMs: 1000,
            lastPlayedAt: 0,
          ),
      ];
      final report = buildAnnualReport(
        year: 2026,
        now: DateTime(2027, 1, 1),
        knownSourceNames: const {},
        data: _snapshot(topTracks: tracks),
      );
      expect(report.topTracks, hasLength(50));
      expect(report.pageTopTracks, hasLength(5));
    });
  });

  group('年度入口', () {
    List<DayListened> days(Iterable<int> years) => [
      for (final year in years)
        DayListened(day: DateTime(year, 6, 1), listenedMs: 1000, playCount: 1),
    ];

    test('没有年份时隐藏', () {
      final entry = AnnualReportEntry.fromDaily(
        const [],
        now: DateTime(2026, 12, 1),
      );
      expect(entry.isVisible, isFalse);
    });

    test('1 月优先上一年，12 月优先当年，其余取最新', () {
      final january = AnnualReportEntry.fromDaily(
        days([2024, 2025]),
        now: DateTime(2026, 1, 5),
      );
      expect(january.featuredYear, 2025);
      expect(january.prominent, isTrue);

      final december = AnnualReportEntry.fromDaily(
        days([2025, 2026]),
        now: DateTime(2026, 12, 5),
      );
      expect(december.featuredYear, 2026);
      expect(december.prominent, isTrue);

      final june = AnnualReportEntry.fromDaily(
        days([2024, 2025]),
        now: DateTime(2026, 6, 5),
      );
      expect(june.featuredYear, 2025);
      expect(june.prominent, isFalse);
    });

    test('1 月没有上一年数据时回退最新一年', () {
      final entry = AnnualReportEntry.fromDaily(
        days([2024]),
        now: DateTime(2026, 1, 5),
      );
      expect(entry.featuredYear, 2024);
    });
  });

  group('年度歌单', () {
    test('截断到 Top 50，缺失载荷仍生成条目', () {
      final tracks = [
        for (var index = 0; index < 55; index++)
          PlayStatTrackEntry(
            sourceKey: 'wy',
            songId: 's$index',
            title: 'Track $index',
            playCount: 1,
            listenedMs: 1000,
            lastPlayedAt: 0,
          ),
      ];
      final report = buildAnnualReport(
        year: 2026,
        now: DateTime(2027, 1, 1),
        knownSourceNames: const {},
        data: _snapshot(topTracks: tracks),
      );
      final playlist = buildAnnualPlaylistTracks(report, addedAt: 123);
      expect(playlist, hasLength(50));
      expect(playlist.first.raw, isEmpty);
      expect(playlist.first.addedAt, 123);
      expect(playlist.last.songId, 's49');
    });

    test('空年份不产生歌单条目', () {
      final report = buildAnnualReport(
        year: 2026,
        now: DateTime(2027, 1, 1),
        knownSourceNames: const {},
        data: _snapshot(
          summary: _summary(playCount: 0, qualified: 0, listenedMs: 0),
        ),
      );
      expect(buildAnnualPlaylistTracks(report, addedAt: 1), isEmpty);
    });
  });
}
