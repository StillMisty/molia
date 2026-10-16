import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:molia/data/library_repository.dart';
import 'package:molia/data/sync/sync_stamp.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/models/library.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_database.dart';
import 'support/sync_test_support.dart';

/// 版本戳发号器测试（HLC-lite）：严格单调、吸收超前戳、重启不倒退、
/// 首次初始化 ≥ 全库最大戳、同毫秒不撞车。对应 ADR-0003 v2 §2。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late int now;
  late SyncVersion? persisted;
  late SyncStampIssuer issuer;

  setUp(() {
    now = 1000;
    persisted = null;
    issuer = SyncStampIssuer(
      clock: () => now,
      deviceId: () => 'devA',
      onAdvanced: (value) => persisted = value,
    );
  });

  test('同毫秒取号：counter 递增，不撞车且严格递增', () {
    final first = issuer.next();
    final second = issuer.next();
    final third = issuer.next();

    expect(first, const SyncVersion(physical: 1000, deviceId: 'devA'));
    expect(second.physical, 1000);
    expect(second.counter, 1);
    expect(third.counter, 2);
    expect(first.isNewerThan(second), isFalse);
    expect(second.isNewerThan(first), isTrue);
    expect(third.isNewerThan(second), isTrue);
  });

  test('时钟前进：physical 前进、counter 归零', () {
    issuer.next();
    now = 1001;
    final next = issuer.next();
    expect(next.physical, 1001);
    expect(next.counter, 0);
  });

  test('时钟回拨：physical 不回退、counter 递增（严格递增）', () {
    final before = issuer.next(); // (1000, 0)
    now = 500;
    final after = issuer.next();
    expect(after.physical, 1000);
    expect(after.counter, 1);
    expect(after.isNewerThan(before), isTrue);
  });

  test('吸收超前戳：本机下一次写入必胜', () {
    // 对端时钟 +1 小时，观测后本机（时钟正常）立刻编辑。
    issuer.observe(const SyncVersion(physical: 1000 + 3600 * 1000, deviceId: 'devB'));
    final next = issuer.next();
    expect(
      next.isNewerThan(
        const SyncVersion(physical: 1000 + 3600 * 1000, deviceId: 'devB'),
      ),
      isTrue,
    );
    expect(next.physical, 1000 + 3600 * 1000);
    expect(next.counter, 1);
  });

  test('吸收滞后戳：不改变基线', () {
    final before = issuer.next(); // 1000/0
    issuer.observe(const SyncVersion(physical: 500, deviceId: 'devB'));
    final after = issuer.next();
    expect(after.physical, before.physical);
    expect(after.counter, before.counter + 1);
  });

  test('吸收超前戳记 warning（含对端设备）', () async {
    final logger = Logger('molia.sync');
    logger.level = Level.ALL;
    final records = <LogRecord>[];
    final subscription = logger.onRecord.listen(records.add);
    addTearDown(subscription.cancel);

    issuer.observe(const SyncVersion(physical: 999999, deviceId: 'devB'));
    await Future<void>.delayed(Duration.zero);

    expect(records, isNotEmpty);
    expect(records.single.level, Level.WARNING);
    expect(records.single.message, contains('超前'));
    expect(records.single.message, contains('devB'));
  });

  test('重启（重建发号器）后基线不倒退', () {
    final before = issuer.next();
    // 持久化基线 = 最近一次发布的戳（SyncStateStore 的 onAdvanced）。
    final restored = SyncStampIssuer(
      clock: () => now, // 重启后时钟仍是同一个（或更早）
      deviceId: () => 'devA',
    )..seed(persisted ?? SyncVersion.zero);
    now = 0; // 极端：重启后时钟归零
    final after = restored.next();
    expect(after.isNewerThan(before), isTrue);
  });

  test('首次初始化：基线 ≥ 全库最大戳（seed 吸收库内最大值）', () {
    now = 1000;
    issuer.seed(const SyncVersion(physical: 9999, counter: 3));
    final next = issuer.next();
    expect(
      next.isNewerThan(const SyncVersion(physical: 9999, counter: 3)),
      isTrue,
    );
  });

  test('seed 取 max(当前时钟, 已知最大值)', () {
    now = 5000;
    issuer.seed(const SyncVersion(physical: 1000, counter: 7));
    final next = issuer.next();
    expect(next.physical, 5000);
    expect(
      next.isNewerThan(const SyncVersion(physical: 5000, counter: 0)),
      isTrue,
    );
  });

  test('基线跟随发号前进并回调持久化', () {
    issuer.next();
    expect(persisted?.physical, 1000);
    expect(issuer.baseline.physical, 1000);
    expect(issuer.baseline.counter, 0);
  });

  group('持久化与初始化', () {
    test('重启（重建 SyncStateStore / 发号器）后基线不倒退', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      now = 1000;
      final state = SyncStateStore(
        preferences: prefs,
        secrets: MemorySyncSecretStore(),
        clock: () => now,
        deviceId: 'devA',
      );
      await state.init();
      final before = state.stampIssuer.next();
      await state.save();

      // 重启后时钟回拨：基线从持久化状态恢复，不倒退。
      now = 0;
      final rebuilt = SyncStateStore(
        preferences: prefs,
        secrets: MemorySyncSecretStore(),
        clock: () => now,
        deviceId: 'devA',
      );
      await rebuilt.init();
      final after = rebuilt.stampIssuer.next();
      expect(after.isNewerThan(before), isTrue);
      expect(after.physical, before.physical);
      expect(after.counter, greaterThan(before.counter));
    });

    test('首次初始化 ≥ 全库最大戳：库内超前戳不会压制新写入', () async {
      final db = openMemoryDatabase();
      addTearDown(db.close);
      var dbClock = 500000;
      final repo = LibraryRepository(
        databaseProvider: () => db,
        deviceIdProvider: () => 'devA',
        clock: () => dbClock,
      );
      addTearDown(repo.dispose);
      await repo.addHistoryEntry(PlayHistoryEntry(
        sourceKey: 'wy',
        songId: 's1',
        title: 'Song',
        playedAt: 100,
      ));
      final dbMax = await repo.maxVersion();
      expect(dbMax.physical, greaterThanOrEqualTo(500000));

      // 重建发号器（模拟重启 + 时钟回拨）：基线从库内最大戳恢复。
      final restored = SyncStampIssuer(
        clock: () => 1000,
        deviceId: () => 'devA',
      )..seed(dbMax);
      final next = restored.next();
      expect(next.isNewerThan(dbMax), isTrue);

      // 新写入让库内最大戳继续前进（maxVersion 覆盖五张表）。
      dbClock = 1000; // 时钟回拨的设备
      await repo.addHistoryEntry(PlayHistoryEntry(
        sourceKey: 'wy',
        songId: 's2',
        title: 'Song 2',
        playedAt: 200,
      ));
      final advanced = await repo.maxVersion();
      expect(advanced.isNewerThan(dbMax), isTrue);
    });

    test('SyncStateStore 同时持久化设置登记哈希与版本', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      now = 1000;
      final state = SyncStateStore(
        preferences: prefs,
        secrets: MemorySyncSecretStore(),
        clock: () => now,
        deviceId: 'devA',
      );
      await state.init();
      final version = state.stampIssuer.next();
      state.putSettingStamp('theme_mode', SyncStamp(hash: 'h', version: version));
      await state.save();

      final rebuilt = SyncStateStore(
        preferences: prefs,
        secrets: MemorySyncSecretStore(),
        clock: () => now,
        deviceId: 'devA',
      );
      await rebuilt.init();
      expect(rebuilt.settingStamps['theme_mode']?.hash, 'h');
      expect(rebuilt.settingStamps['theme_mode']?.version, version);
      expect(rebuilt.stampIssuer.baseline.physical, version.physical);
    });
  });
}
