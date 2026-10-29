import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/play_statistics_repository.dart';
import 'package:molia/data/stats_payload_codec.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/services/play_statistics_service.dart';
import '../support/sync_test_support.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/memory_database.dart';
import '../support/settings_test_support.dart';

/// 听歌统计采集服务测试：真实仓库（drift in-memory）+ 假时钟，
/// 以脚本化快照 / 进度序列逐条驱动六条边界规则。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MoliaDatabase db;
  late PlayStatisticsRepository repository;
  late PlayStatisticsService service;
  late DateTime now;

  Track trackOf(
    String id, {
    Duration duration = const Duration(seconds: 100),
    String title = 'Song',
    String artist = 'Artist',
    Map<String, Object?> payload = const {},
  }) =>
      Track(
        id: TrackId('wy', id),
        title: title,
        artists: [Artist(name: artist)],
        album: 'Album',
        duration: duration,
        origin: TrackOrigin.builtin,
        payload: payload,
      );

  PlaybackSnapshot snapshotOf(
    Track? current, {
    bool playing = true,
    SourceFailure? error,
  }) =>
      PlaybackSnapshot(
        current: current,
        isPlaying: playing,
        duration: current?.duration ?? Duration.zero,
        error: error,
      );

  /// 从 [from] 到 [to] 按 1s 步进驱动进度 tick（正常前进，全部计入时长）。
  void tickRange(Duration from, Duration to) {
    for (var ms = from.inMilliseconds; ms <= to.inMilliseconds; ms += 1000) {
      service.onPosition(Duration(milliseconds: ms));
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = openMemoryDatabase();
    repository = PlayStatisticsRepository(
      databaseProvider: () => db,
      statisticsSync: testStatisticsSyncStore(() => db),
    );
    now = DateTime(2026, 1, 1, 12);
    service = PlayStatisticsService(
      settings: testSettingsRegistry(),
      repository: repository,
      clock: () => now,
    );
    await service.init();
  });

  tearDown(() async {
    await repository.dispose();
    await db.close();
  });

  Future<List<Map<String, Object?>>> rows() async {
    await service.pendingWrites;
    final rows = await playEventRows(db);
    return rows..sort((a, b) => (a['id']! as int).compareTo(b['id']! as int));
  }

  group('开事件与累计', () {
    test('真正出声才开事件（首个 position > 0 的 tick）', () async {
      final track = trackOf('a');
      service.onSnapshot(snapshotOf(track));
      service.onPosition(Duration.zero);

      expect(await rows(), isEmpty, reason: 'position == 0 不开事件');

      service.onPosition(const Duration(milliseconds: 300));
      final opened = await rows();

      expect(opened, hasLength(1));
      expect(opened.single['endedAt'], isNull);
      expect(opened.single['startedAt'], now.millisecondsSinceEpoch);
      expect(opened.single['songId'], 'a');
      // 载荷按 gzip 存 BLOB：断言解码后的 JSON。
      expect(decodeStatsPayload(opened.single['raw']), '{}');
    });

    test('正常前进计入时长；seek 快进不计入但动作落盘', () async {
      final track = trackOf('a');
      service.onSnapshot(snapshotOf(track));
      tickRange(const Duration(milliseconds: 300),
          const Duration(milliseconds: 2300));

      // seek 是动作：跳变不计入收听时长，但落盘一次（不是周期写）。
      service.onPosition(const Duration(seconds: 60));
      final opened = await rows();

      expect(opened.single['listenedMs'], 2000, reason: '2s 正常前进，跳变不计');
      expect(opened.single['maxPositionMs'], 60000);
    });

    test('播放途中不写库，只有动作 flush 才落盘', () async {
      final track = trackOf('a');
      service.onSnapshot(snapshotOf(track));
      tickRange(const Duration(seconds: 1), const Duration(seconds: 3));

      // 播放 tick 不落盘：库里仍是开始事件时的 0。
      await service.pendingWrites;
      expect(
        (await playEventRows(db)).single['listenedMs'],
        0,
        reason: '普通进度 tick 不写库',
      );

      // 时间过去也不是动作。
      now = now.add(const Duration(seconds: 30));
      service.onPosition(const Duration(seconds: 4));
      await service.pendingWrites;
      expect(
        (await playEventRows(db)).single['listenedMs'],
        0,
        reason: '没有动作不写库',
      );

      await service.flush();
      expect((await playEventRows(db)).single['listenedMs'], 3000);
    });
  });

  group('收尾规则', () {
    test('手动切歌 → skipped；新行等首个出声 tick', () async {
      final trackA = trackOf('a');
      final trackB = trackOf('b');
      service.onSnapshot(snapshotOf(trackA));
      tickRange(const Duration(seconds: 1), const Duration(seconds: 21));

      service.onSnapshot(snapshotOf(trackB));
      var all = await rows();
      expect(all, hasLength(1));
      expect(all.single['endReason'], 'skipped');
      expect(all.single['listenedMs'], 20000);

      service.onPosition(const Duration(milliseconds: 300));
      all = await rows();
      expect(all, hasLength(2));
      expect(all[1]['songId'], 'b');
      expect(all[1]['endedAt'], isNull);
    });

    test('自然播完接下一首 → completed', () async {
      final trackA = trackOf('a', duration: const Duration(seconds: 10));
      final trackB = trackOf('b');
      service.onSnapshot(snapshotOf(trackA));
      tickRange(const Duration(seconds: 1), const Duration(seconds: 10));

      service.onSnapshot(snapshotOf(trackB));
      final all = await rows();

      expect(all.single['endReason'], 'completed');
      expect(all.single['maxPositionMs'], 10000);
    });

    test('单曲循环 seek(0) → 每遍一行（第一遍 completed）', () async {
      final track = trackOf('loop', duration: const Duration(seconds: 10));
      service.onSnapshot(snapshotOf(track));
      tickRange(const Duration(seconds: 1), const Duration(seconds: 10));

      // 播完回卷：位置回到开头，仍在播放。
      service.onPosition(const Duration(milliseconds: 200));
      service.onPosition(const Duration(milliseconds: 1200));
      await service.flush();
      final all = await rows();

      expect(all, hasLength(2));
      expect(all[0]['endReason'], 'completed');
      expect(all[1]['endedAt'], isNull);
      expect(all[1]['listenedMs'], 1000);
    });

    test('拖动回开头 → restart', () async {
      final track = trackOf('a');
      service.onSnapshot(snapshotOf(track));
      tickRange(const Duration(seconds: 1), const Duration(seconds: 21));

      service.onPosition(const Duration(milliseconds: 200));
      final all = await rows();

      expect(all, hasLength(2));
      expect(all[0]['endReason'], 'restart');
      expect(all[1]['endedAt'], isNull);
    });

    test('暂停不切断、恢复继续同一行', () async {
      final track = trackOf('a');
      service.onSnapshot(snapshotOf(track));
      service.onPosition(const Duration(milliseconds: 300));
      service.onPosition(const Duration(milliseconds: 800));

      now = now.add(const Duration(seconds: 20));
      service.onSnapshot(snapshotOf(track, playing: false));
      var all = await rows();
      expect(all, hasLength(1));
      expect(all.single['endedAt'], isNull, reason: '暂停不切断事件');
      expect(all.single['listenedMs'], 500, reason: '暂停时强制落盘');

      service.onSnapshot(snapshotOf(track));
      service.onPosition(const Duration(seconds: 1));
      service.onPosition(const Duration(milliseconds: 1500));
      service.onPosition(const Duration(seconds: 2));

      // 恢复后的普通 tick 不写库；再暂停 / flush 才落盘累计值。
      await service.pendingWrites;
      expect(
        (await playEventRows(db)).single['listenedMs'],
        500,
        reason: '播放途中沿用暂停时的落盘值',
      );
      await service.flush();

      all = await rows();
      expect(all, hasLength(1), reason: '恢复后仍是同一行');
      expect(all.single['listenedMs'], 1500);
      expect(all.single['endedAt'], isNull);
    });

    test('队列末尾自然结束（isPlaying 落 false）→ completed', () async {
      final track = trackOf('a', duration: const Duration(seconds: 10));
      service.onSnapshot(snapshotOf(track));
      tickRange(const Duration(seconds: 1), const Duration(seconds: 10));

      service.onSnapshot(snapshotOf(track, playing: false));
      final all = await rows();

      expect(all.single['endReason'], 'completed');
    });

    test('停止/清空队列（current 为 null）→ stopped', () async {
      final track = trackOf('a');
      service.onSnapshot(snapshotOf(track));
      tickRange(const Duration(seconds: 1), const Duration(seconds: 3));

      service.onSnapshot(PlaybackSnapshot.empty);
      final all = await rows();

      expect(all.single['endReason'], 'stopped');
      expect(all.single['listenedMs'], 2000);
    });

    test('播放错误 → error', () async {
      final track = trackOf('a');
      service.onSnapshot(snapshotOf(track));
      tickRange(const Duration(seconds: 1), const Duration(seconds: 3));

      service.onSnapshot(snapshotOf(
        track,
        playing: false,
        error: const SourceFailure(
          kind: FailureKind.playback,
          message: 'boom',
        ),
      ));
      final all = await rows();

      expect(all.single['endReason'], 'error');
      expect(all.single['listenedMs'], 2000);
    });

    test('错误快照不产生事件（取链失败没播起来）', () async {
      final track = trackOf('a');
      service.onSnapshot(snapshotOf(
        track,
        playing: false,
        error: const SourceFailure(
          kind: FailureKind.network,
          message: 'resolve failed',
        ),
      ));

      expect(await rows(), isEmpty);
    });
  });

  group('采集开关', () {
    test('关闭时收尾当前事件并停止采集，重新开启后恢复', () async {
      final track = trackOf('a');
      service.onSnapshot(snapshotOf(track));
      tickRange(const Duration(milliseconds: 300), const Duration(seconds: 3));

      await service.setEnabled(false);
      var all = await rows();
      expect(all.single['endReason'], 'stopped');

      service.onPosition(const Duration(seconds: 5));
      service.onSnapshot(snapshotOf(trackOf('b')));
      expect(await rows(), hasLength(1), reason: '关闭期间不采集');

      expect(service.enabled, isFalse);
      await service.setEnabled(true);
      service.onSnapshot(snapshotOf(trackOf('b')));
      service.onPosition(const Duration(milliseconds: 300));
      all = await rows();
      expect(all, hasLength(2));
      expect(all[1]['songId'], 'b');
    });

    test('开启状态从 SharedPreferences 读取（默认开）', () async {
      SharedPreferences.setMockInitialValues({
        kPlayStatisticsEnabled.name: false,
      });
      final another = PlayStatisticsService(
        settings: testSettingsRegistry(),
        repository: repository,
        clock: () => now,
      );
      await another.init();
      expect(another.enabled, isFalse);
    });
  });
}
