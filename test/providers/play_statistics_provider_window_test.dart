/// provider 窗口一致性：一次加载只读一次时钟，窗口 / 投影 / 年度入口同源。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/play_statistics_repository.dart';
import 'package:molia/domain/models/play_statistics.dart';
import 'package:molia/providers/play_statistics_provider.dart';

import '../support/memory_database.dart';
import '../support/sync_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MoliaDatabase db;
  late PlayStatisticsRepository repository;

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

  test('跨午夜：一次加载只读一次时钟，窗口 / 视图 / 高亮一致', () async {
    final first = DateTime(2031, 1, 1, 23, 59, 59);
    final second = DateTime(2031, 1, 2, 0, 0, 1);
    final third = DateTime(2031, 1, 3, 12);
    final times = [first, second, third];
    var reads = 0;
    final provider = PlayStatisticsProvider(
      repository: repository,
      clock: () {
        // 同一次加载读第二次会越界：直接把「多次读墙钟」变成测试失败。
        if (reads >= times.length) {
          fail('一次加载只能读取一次时钟');
        }
        return times[reads++];
      },
    );
    addTearDown(provider.dispose);

    final startedAt = first.subtract(const Duration(days: 1));
    await insertPlayEvent(
      db,
      songId: 's1',
      title: 'Track',
      startedAt: startedAt.millisecondsSinceEpoch,
      endedAt: startedAt.millisecondsSinceEpoch + 120000,
      listenedMs: 120000,
      maxPositionMs: 120000,
      endReason: 'completed',
    );

    await provider.setRange(PlayStatisticsRange.week);

    expect(reads, 1, reason: '一次加载只取一次 now');
    final window = provider.window!;
    expect(window.range, PlayStatisticsRange.week);
    expect(window.now, first);
    expect(window.start, first.subtract(const Duration(days: 7)));
    expect(provider.rangeStart, window.start);
    expect(provider.view!.window, same(window));
    expect(provider.view!.today, DateTime(2031, 1, 1));
    expect(provider.view!.windowStart, window.start);
    expect(provider.view!.firstDay, DateTime(2030, 12, 31));

    await provider.refresh();

    expect(reads, 2, reason: '刷新也是一次完整加载');
    expect(provider.window!.now, second);
    expect(provider.view!.today, DateTime(2031, 1, 2));
    expect(
      provider.view!.windowStart,
      second.subtract(const Duration(days: 7)),
      reason: '高亮起点跟着同一次加载的窗口移动',
    );

    await provider.setRange(PlayStatisticsRange.all);

    expect(reads, 3);
    expect(provider.window!.now, third);
    expect(provider.rangeStart, isNull);
    expect(provider.view!.windowStart, isNull);
    expect(provider.view!.today, DateTime(2031, 1, 3));
  });
}
