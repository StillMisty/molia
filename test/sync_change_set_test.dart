import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/library_repository.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/data/settings/settings_registry.dart';
import 'package:molia/data/sync/adapters/history_sync_adapter.dart';
import 'package:molia/data/sync/adapters/prefs_sync_adapter.dart';
import 'package:molia/data/sync/sync_adapter.dart';
import 'package:molia/data/sync/sync_engine.dart';
import 'package:molia/data/sync/sync_known_store.dart';
import 'package:molia/data/sync/sync_scheduler.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/domain/ports/sync_known_store.dart';
import 'package:molia/services/battery_probe.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_database.dart';
import 'support/sync_test_support.dart';

/// 变更集应用测试：合并后只把**版本变化**的胜者交给适配器。
///
/// 验收口径：空闲轮适配器 apply 调用数 0；单条变更只交付该记录；日志计数
/// 与变更量一致且不随库大小增长；登记跨重启保持（sync_known 落库）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late MemorySyncSecretStore secrets;
  late SyncStateStore state;
  late FakeSyncTransport transport;
  late RecordingSyncAdapter adapter;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    secrets = MemorySyncSecretStore();
    state = SyncStateStore(
      preferences: prefs,
      secrets: secrets,
      clock: () => 7000,
    );
    await state.init();
    await state.writePassphrase('ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789');
    await state.setEnabled(true);
    transport = FakeSyncTransport();
    adapter = RecordingSyncAdapter();
  });

  SyncEnvelope remoteEnvelope(List<SyncRecord> records) => SyncEnvelope(
        deviceId: 'devB',
        deviceName: 'B',
        producedAt: 5000,
        records: {SyncCategory.settings: records},
      );

  SyncRecord setting(String key, int physical) => SyncRecord(
        key: key,
        version: SyncVersion(physical: physical, deviceId: 'devB'),
        data: {'v': 'x'},
      );

  SyncEngine engine({SyncKnownStore? known}) => SyncEngine(
        state: state,
        stamps: state.stampIssuer,
        adapters: [adapter],
        transports: {'lan': transport},
        known: known,
      );

  test('空闲轮：适配器 apply 调用数 0（本地视图即登记基线）', () async {
    final sync = engine();
    addTearDown(sync.dispose);

    transport.peersSeenOverride = 1;
    // 首轮建立本地视图基线；之后才是空闲轮。
    await sync.syncNow();
    adapter.reset();
    final report = await sync.syncNow();

    expect(report!.outcome, SyncOutcome.noChanges);
    expect(adapter.applyCalls, 0);
    expect(adapter.lastRecordCount, 0);
    expect(report.applied, 0);
  });

  test('单条变更：只有该记录进入 apply，计数不随库大小增长', () async {
    final sync = engine();
    addTearDown(sync.dispose);

    // 远端 60 条记录：首轮全量交付（登记为空）。
    final all = [for (var i = 0; i < 60; i++) setting('key-$i', 1000)];
    transport.available.add(remoteEnvelope(all));
    await sync.syncNow();
    expect(adapter.lastRecordCount, 60);
    expect(sync.lastReport!.applied, 60);

    // 空闲轮：没有任何记录进入 apply。
    adapter.reset();
    await sync.syncNow();
    expect(adapter.applyCalls, 0);
    expect(sync.lastReport!.applied, 0);

    // 单条变更：只交付这一条。
    adapter.reset();
    transport.available
      ..clear()
      ..add(remoteEnvelope([
        ...all.take(59),
        setting('key-30', 2000),
      ]));
    final report = await sync.syncNow();

    expect(adapter.applyCalls, 1);
    expect(adapter.lastRecordCount, 1);
    expect(adapter.lastKeys, ['key-30']);
    expect(report!.applied, 1);
    expect(state.log.first.applied, 1);
  });

  test('适配器落地失败：不登记，下一轮重试同一记录', () async {
    final sync = engine();
    addTearDown(sync.dispose);

    adapter.failNext = true;
    transport.available.add(remoteEnvelope([setting('key-1', 1000)]));
    final failed = await sync.syncNow();
    expect(failed!.applied, 0);
    expect(failed.applyFailures, 1);

    adapter.reset();
    transport.available
      ..clear()
      ..add(remoteEnvelope([setting('key-1', 1000)]));
    await sync.syncNow();
    expect(adapter.lastKeys, ['key-1']);
    expect(sync.lastReport!.applied, 1);
  });

  test('登记跨重启保持（sync_known 落库）：重启后不重放', () async {
    final db = openMemoryDatabase();
    addTearDown(db.close);
    final known = SyncKnownRepository(databaseProvider: () => db);

    final first = engine(known: known);
    addTearDown(first.dispose);
    transport.available.add(remoteEnvelope([setting('key-1', 1000)]));
    await first.syncNow();
    expect(adapter.lastKeys, ['key-1']);

    // 模拟重启：同一份登记 + 新的引擎实例。
    adapter.reset();
    final second = engine(
      known: SyncKnownRepository(databaseProvider: () => db),
    );
    addTearDown(second.dispose);
    await second.syncNow();
    expect(adapter.applyCalls, 0);
  });

  test('真实适配器（设置）：远端胜者只交付一次，重复轮不重复应用', () async {    final prefsAdapter = PrefsSyncAdapter(
      state: state,
      settings: SettingsRegistry(
        keys: const [kThemeMode],
        preferences: prefs,
        secrets: secrets,
      ),
    );
    final sync = SyncEngine(
      state: state,
      stamps: state.stampIssuer,
      adapters: [prefsAdapter],
      transports: {'lan': transport},
    );
    addTearDown(sync.dispose);

    transport.available.add(remoteEnvelope([
      SyncRecord(
        key: 'theme_mode',
        version: const SyncVersion(physical: 5000, deviceId: 'devB'),
        data: const {'v': 'dark'},
      ),
    ]));
    await sync.syncNow();
    expect(prefs.getString('theme_mode'), 'dark');

    // 对端再次给出同一版本：登记一致 → 不进入 apply，本地值不被重写。
    prefs.setString('theme_mode', 'light');
    transport.available
      ..clear()
      ..add(remoteEnvelope([
        SyncRecord(
          key: 'theme_mode',
          version: const SyncVersion(physical: 5000, deviceId: 'devB'),
          data: const {'v': 'dark'},
        ),
      ]));
    await sync.syncNow();
    expect(prefs.getString('theme_mode'), 'light');
  });

  test('墓碑清理联动：旧墓碑重放不重新落地（登记保留、复活不撤销）', () async {    final db = openMemoryDatabase();
    addTearDown(db.close);
    final repository = LibraryRepository(
      databaseProvider: () => db,
      clock: () => state.nowMs(),
      stamps: state.stampIssuer,
    );
    addTearDown(repository.dispose);
    final sync = SyncEngine(
      state: state,
      stamps: state.stampIssuer,
      adapters: [HistorySyncAdapter(repository: repository)],
      transports: {'lan': transport},
      known: SyncKnownRepository(databaseProvider: () => db),
    );
    addTearDown(sync.dispose);

    final key = SyncRecordKeys.history('wy', 's1');
    final tombstone = SyncRecord.tombstone(
      key: key,
      version: const SyncVersion(physical: 2000, deviceId: 'devB'),
      deletedAt: 2000,
    );
    transport.available.add(remoteEnvelope([tombstone]));
    await sync.syncNow();

    // 本地复活（播放晚于删除：真实时间判定）→ 墓碑被清理。
    await repository.addHistoryEntry(PlayHistoryEntry(
      sourceKey: 'wy',
      songId: 's1',
      title: 'Song',
      raw: const {},
      playedAt: 3000,
    ));
    expect(await repository.syncExportTombstones(['history']), isEmpty);

    // 对端重放同一条旧墓碑：登记保留（不因墓碑清理删除），复活的行不被撤销。
    transport.available
      ..clear()
      ..add(remoteEnvelope([tombstone]));
    final report = await sync.syncNow();

    expect(report!.applied, 0);
    expect((await repository.listHistory()).map((e) => e.songId), contains('s1'));
  });

  test('空闲等级端到端：不拉取 / 不推送 / 不落地 / 0 字节', () {
    fakeAsync((async) {
      // 引擎与调度器共用 fake_async 时钟。
      DateTime clock() => DateTime.fromMillisecondsSinceEpoch(
            async.elapsed.inMilliseconds,
          );
      final sync = SyncEngine(
        state: state,
        stamps: state.stampIssuer,
        adapters: [adapter],
        transports: {'lan': transport},
        clock: clock,
      );
      addTearDown(sync.dispose);
      final scheduler = SyncScheduler(
        host: sync,
        state: state,
        cellularProbe: () async => false,
        batteryProbe: () async => BatterySnapshot.unknown,
        isPlaying: () => false,
        clock: clock,
      );
      addTearDown(scheduler.dispose);
      unawaited(scheduler.start());
      async.flushMicrotasks();

      // 交互窗口过后进入空闲；整个空闲期（10 + 20 分钟两次唤醒）不做任何
      // 网络动作：无轮次 = 无广播、无拉取、无推送、无落地。
      async.elapse(const Duration(minutes: 2));
      expect(scheduler.level, SyncLevel.idle);
      async.elapse(const Duration(minutes: 30));

      expect(transport.pullCount, 0);
      expect(transport.pushed, isEmpty);
      expect(adapter.applyCalls, 0);
      expect(sync.lastReport, isNull);
      // 两次空闲唤醒（10 → 20 分钟）各翻倍一次退避，但没有发任何轮次。
      expect(scheduler.idleBackoff, const Duration(minutes: 40));

      // 本地变更：活跃去抖后跑一轮（拉取 + 推送各一次）。
      scheduler.notifyLocalChange();
      async.elapse(const Duration(seconds: 5));
      expect(transport.pullCount, 1);
      expect(transport.pushed, hasLength(1));
    });
  });
}

/// 记录 apply 交付内容的假适配器（按记录数返回 applied）。
class RecordingSyncAdapter implements SyncAdapter {
  int applyCalls = 0;
  int lastRecordCount = 0;
  List<String> lastKeys = [];
  bool failNext = false;

  void reset() {
    applyCalls = 0;
    lastRecordCount = 0;
    lastKeys = [];
  }

  @override
  Set<SyncCategory> get categories => const {SyncCategory.settings};

  @override
  bool get ready => true;

  @override
  Future<Map<SyncCategory, List<SyncRecord>>> collect() async => const {};

  @override
  Future<SyncApplyOutcome> apply(
    Map<SyncCategory, List<SyncRecord>> records,
  ) async {
    applyCalls++;
    if (failNext) {
      failNext = false;
      throw StateError('应用失败（测试注入）');
    }
    final all = [for (final list in records.values) ...list];
    lastRecordCount = all.length;
    lastKeys = [for (final record in all) record.key];
    return SyncApplyOutcome(applied: all.length);
  }
}
