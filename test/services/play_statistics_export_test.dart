import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/play_statistics.dart';
import 'package:molia/services/play_statistics_export.dart';

/// 导出 JSON 组装测试：字段形状、ISO 时间、明细不含 raw。
void main() {
  test('导出 payload：汇总/榜单/分布齐备，明细不含 raw', () {
    final exportedAt = DateTime(2026, 5, 1, 12);
    final payload = buildPlayStatisticsExport(
      summary: PlayStatisticsSummary(
        playCount: 10,
        qualifiedPlayCount: 8,
        totalListenedMs: 3600000,
        uniqueTrackCount: 6,
        completionRate: 0.7,
        skipRate: 0.2,
        firstPlayedAt: DateTime(2026, 1, 2, 8).millisecondsSinceEpoch,
      ),
      topTracks: [
        PlayStatTrackEntry(
          sourceKey: 'wy',
          songId: '42',
          title: 'Song',
          artist: 'Artist',
          album: 'Album',
          durationMs: 200000,
          raw: const {'secret': 'internal'},
          playCount: 5,
          listenedMs: 1000000,
          lastPlayedAt: DateTime(2026, 4, 30, 20).millisecondsSinceEpoch,
        ),
      ],
      topArtists: const [
        PlayStatArtistEntry(
          artist: 'Artist',
          playCount: 5,
          listenedMs: 1000000,
        ),
      ],
      daily: [
        DayListened(
          day: DateTime(2026, 4, 30),
          listenedMs: 1000000,
          playCount: 5,
        ),
      ],
      hourly: const [HourListened(hour: 20, listenedMs: 1000000, playCount: 5)],
      sources: const [
        SourceListened(sourceKey: 'wy', listenedMs: 1000000, playCount: 5),
      ],
      recentEvents: [
        PlayEvent(
          id: 1,
          sourceKey: 'wy',
          songId: '42',
          title: 'Song',
          artist: 'Artist',
          durationMs: 200000,
          raw: const {'secret': 'internal'},
          startedAt: DateTime(2026, 4, 30, 20).millisecondsSinceEpoch,
          endedAt: DateTime(2026, 4, 30, 20, 3).millisecondsSinceEpoch,
          listenedMs: 180000,
          maxPositionMs: 185000,
          endReason: PlayEventEndReason.completed,
        ),
      ],
      exportedAt: exportedAt,
    );

    expect(payload['app'], 'Molia');
    expect(payload['version'], playStatisticsExportVersion);
    expect(payload['exportedAt'], exportedAt.toIso8601String());
    expect(payload['instructions'], playStatisticsExportInstructions);

    final summary = payload['summary'] as Map<String, dynamic>;
    expect(summary['playCount'], 10);
    expect(summary['qualifiedPlayCount'], 8);
    expect(summary['completionRate'], 0.7);
    expect(summary['firstPlayedAt'], '2026-01-02T08:00:00.000');

    final topTrack = (payload['topTracks'] as List).single as Map;
    expect(topTrack['title'], 'Song');
    expect(topTrack.containsKey('raw'), isFalse, reason: '榜单不含 raw');

    final daily = (payload['dailyListened'] as List).single as Map;
    expect(daily['date'], '2026-04-30');

    final event = (payload['recentEvents'] as List).single as Map;
    expect(event['endReason'], 'completed');
    expect(event.containsKey('raw'), isFalse, reason: '明细不含 raw');
    expect(event['startedAt'], '2026-04-30T20:00:00.000');
  });

  test('空数据导出：空数组 + 空汇总', () {
    final payload = buildPlayStatisticsExport(
      summary: PlayStatisticsSummary.empty,
      topTracks: const [],
      topArtists: const [],
      daily: const [],
      hourly: const [],
      sources: const [],
      recentEvents: const [],
      exportedAt: DateTime(2026, 5, 1),
    );

    expect(payload['topTracks'], isEmpty);
    expect(payload['recentEvents'], isEmpty);
    final summary = payload['summary'] as Map<String, dynamic>;
    expect(summary['firstPlayedAt'], isNull);
    expect(summary['playCount'], 0);
  });
}
