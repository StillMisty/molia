import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/play_statistics_repository.dart';
import 'package:molia/domain/models/annual_report.dart';

import 'support/memory_database.dart';
import 'support/sync_test_support.dart';

/// 年度窗口：左闭右开、错误事件排除、专辑 / 歌手 / 首末边界。
void main() {
  late MoliaDatabase db;
  late PlayStatisticsRepository repository;
  final start = DateTime(2026, 1, 1);
  final end = DateTime(2027, 1, 1);

  setUp(() async {
    db = openMemoryDatabase();
    repository = PlayStatisticsRepository(
      databaseProvider: () => db,
      statisticsSync: testStatisticsSyncStore(() => db),
    );
  });

  tearDown(() async {
    await repository.dispose();
    await db.close();
  });

  Future<int> insert({
    required DateTime startedAt,
    String songId = 'song1',
    String title = 'Song 1',
    String artist = 'Artist A',
    String album = 'Album A',
    int listenedMs = 100000,
    String? endReason = 'completed',
  }) => insertPlayEvent(
    db,
    songId: songId,
    title: title,
    artist: artist,
    album: album,
    startedAt: startedAt.millisecondsSinceEpoch,
    endedAt: startedAt.millisecondsSinceEpoch + listenedMs,
    listenedMs: listenedMs,
    maxPositionMs: listenedMs,
    endReason: endReason,
  );

  test('年初边界：1 月 1 日归新年，前 1ms 归旧年', () async {
    await insert(
      startedAt: start.subtract(const Duration(milliseconds: 1)),
      songId: 'old',
    );
    await insert(startedAt: start, songId: 'new');
    await insert(startedAt: end, songId: 'outside');

    final report = await repository.annualSnapshot(
      since: start.millisecondsSinceEpoch,
      until: end.millisecondsSinceEpoch,
    );
    expect(report.summary.playCount, 1, reason: '只有 1 月 1 日那条属于 2026');
    expect(report.topTracks.single.songId, 'new');
  });

  test('错误事件不计入任何年度数字', () async {
    await insert(startedAt: DateTime(2026, 5, 1), songId: 'ok');
    await insert(
      startedAt: DateTime(2026, 5, 2),
      songId: 'bad',
      endReason: 'error',
    );

    final report = await repository.annualSnapshot(
      since: start.millisecondsSinceEpoch,
      until: end.millisecondsSinceEpoch,
    );
    expect(report.summary.playCount, 1);
    expect(report.summary.totalListenedMs, 100000);
    expect(report.sources.single.playCount, 1);
    expect(report.topTracks.map((entry) => entry.songId), ['ok']);
  });

  test('Top 专辑按时长 / 次数排序并排除空专辑名', () async {
    await insert(startedAt: DateTime(2026, 2, 1), songId: 'a1', album: 'A');
    await insert(startedAt: DateTime(2026, 2, 2), songId: 'a2', album: 'A');
    await insert(
      startedAt: DateTime(2026, 2, 3),
      songId: 'b1',
      album: 'B',
      listenedMs: 300000,
    );
    await insert(startedAt: DateTime(2026, 2, 4), songId: 'n1', album: '  ');

    final albums = await repository.topAlbums(
      since: start.millisecondsSinceEpoch,
      until: end.millisecondsSinceEpoch,
    );
    expect(albums.map((entry) => entry.album), ['A', 'B']);
    expect(albums.first.playCount, 2);
  });

  test('去重歌手沿用既有拆分规则', () async {
    await insert(startedAt: DateTime(2026, 3, 1), songId: 's1', artist: 'A, B');
    await insert(startedAt: DateTime(2026, 3, 2), songId: 's2', artist: 'B/C');
    await insert(startedAt: DateTime(2026, 3, 3), songId: 's3', artist: '  ');

    expect(
      await repository.distinctArtistCount(
        since: start.millisecondsSinceEpoch,
        until: end.millisecondsSinceEpoch,
      ),
      3,
    );
  });

  test('首末播放取窗口边界，且跳过错误事件', () async {
    await insert(
      startedAt: DateTime(2026, 1, 2, 8),
      songId: 'first',
      title: 'First',
      artist: 'A',
    );
    await insert(
      startedAt: DateTime(2026, 6, 1, 8),
      songId: 'bad',
      endReason: 'error',
    );
    await insert(
      startedAt: DateTime(2026, 12, 30, 8),
      songId: 'last',
      title: 'Last',
      artist: 'B',
    );

    final first = await repository.firstCountablePlay(
      since: start.millisecondsSinceEpoch,
      until: end.millisecondsSinceEpoch,
    );
    final last = await repository.lastCountablePlay(
      since: start.millisecondsSinceEpoch,
      until: end.millisecondsSinceEpoch,
    );
    expect(first?.title, 'First');
    expect(first?.artist, 'A');
    expect(last?.title, 'Last');
    expect(last?.artist, 'B');
  });

  test('全部历史读取保持原行为（不带窗口时仍含所有年份）', () async {
    await insert(startedAt: DateTime(2025, 12, 31, 23));
    await insert(startedAt: DateTime(2026, 1, 1));
    expect((await repository.summary()).playCount, 2);
    expect((await repository.listenedByDay()).length, 2);
  });

  test('年度快照的按月聚合与首末日期一致', () async {
    await insert(startedAt: DateTime(2026, 1, 1, 9), songId: 'a');
    await insert(startedAt: DateTime(2026, 8, 15, 9), songId: 'b');
    final snapshot = await repository.annualSnapshot(
      since: start.millisecondsSinceEpoch,
      until: end.millisecondsSinceEpoch,
    );
    final report = buildAnnualReport(
      year: 2026,
      data: snapshot,
      now: DateTime(2027, 1, 2),
      knownSourceNames: const {'wy': '网易云'},
    );
    expect(report.monthlyListenedMs[0], 100000);
    expect(report.monthlyListenedMs[7], 100000);
    expect(report.firstPlay?.title, 'Song 1');
    expect(report.asOfToday, isFalse);
    expect(report.hasData, isTrue);
  });
}
