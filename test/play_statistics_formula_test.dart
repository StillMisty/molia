/// 有效播放口径的对照测试：同一批 fixture 行，SQL 谓词与 Dart 判定必须一致。
///
/// 口径唯一在领域层（[PlayStatisticsLimits.qualifiedThresholdMs]）：SQL 谓词与
/// Dart 判定都从它派生。任何一侧改了阈值而另一侧没跟上，本测试红。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/database_helper.dart';
import 'package:molia/data/play_statistics_repository.dart';
import 'package:molia/domain/models/play_statistics.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Database db;
  late PlayStatisticsRepository repository;

  /// 边界样本：(listenedMs, durationMs) —— 每条覆盖一个门槛分支。
  const cases = <(int, int?)>[
    (30000, null), // 时长未知：门槛 30s（恰好达标）
    (29999, null), // 差 1ms
    (30000, 60000), // 长曲：门槛封顶 30s（恰好达标）
    (29999, 60000),
    (25000, 50000), // 50s：门槛 25s（恰好达标）
    (24999, 50000),
    (500, 1000), // 1s：门槛 500ms（恰好达标）
    (499, 1000),
    (501, 1001), // 奇数时长：门槛向上取整（500.5 → 501）
    (500, 1001),
    (30000, 0), // 非法时长：30s 兜底
    (0, -5),
  ];

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: DatabaseHelper.dbVersion,
        onCreate: (database, version) => DatabaseHelper.createSchema(database),
      ),
    );
    repository = PlayStatisticsRepository(databaseProvider: () async => db);
    var index = 0;
    for (final (listenedMs, durationMs) in cases) {
      index++;
      await db.insert('play_events', {
        'sourceKey': 'wy',
        'songId': 'case$index',
        'title': 'Case $index',
        'artist': 'Artist',
        'album': '',
        'coverUrl': null,
        'durationMs': durationMs,
        'raw': jsonEncode(<String, Object?>{'id': index}),
        'startedAt': 1000 + index,
        'endedAt': 2000 + index,
        'listenedMs': listenedMs,
        'maxPositionMs': listenedMs,
        'endReason': 'completed',
      });
    }
  });

  tearDown(() async {
    await repository.dispose();
    await db.close();
  });

  test('SQL 谓词与领域口径一致（fixture 驱动）', () async {
    final expected = cases
        .where((sample) => PlayStatisticsLimits.isQualified(
              listenedMs: sample.$1,
              durationMs: sample.$2,
            ))
        .length;

    final summary = await repository.summary();
    expect(summary.playCount, cases.length, reason: '全部是已收尾的非 error 事件');
    expect(summary.qualifiedPlayCount, expected, reason: 'SQL 谓词口径');
  });

  test('Dart 判定（日历聚合）与 SQL 谓词同口径', () async {
    final summary = await repository.summary();
    final daily = await repository.listenedByDay();
    final dartCount = daily.fold<int>(0, (sum, day) => sum + day.playCount);
    expect(
      dartCount,
      summary.qualifiedPlayCount,
      reason: 'SQL 与 Dart 两条路径必须给出同一个有效播放数',
    );
  });

  test('口径阈值本身的边界（纯函数）', () {
    expect(PlayStatisticsLimits.qualifiedThresholdMs(null), 30000);
    expect(PlayStatisticsLimits.qualifiedThresholdMs(0), 30000);
    expect(PlayStatisticsLimits.qualifiedThresholdMs(-5), 30000);
    expect(PlayStatisticsLimits.qualifiedThresholdMs(1000), 500);
    expect(PlayStatisticsLimits.qualifiedThresholdMs(1001), 501,
        reason: '奇数时长向上取整（等价 SQL 的 >= duration*0.5）');
    expect(PlayStatisticsLimits.qualifiedThresholdMs(60000), 30000,
        reason: '封顶 30s');
    expect(PlayStatisticsLimits.qualifiedThresholdMs(50000), 25000);
    expect(
      PlayStatisticsLimits.isQualified(listenedMs: 30000, durationMs: null),
      isTrue,
    );
    expect(
      PlayStatisticsLimits.isQualified(listenedMs: 29999, durationMs: null),
      isFalse,
    );
  });
}
