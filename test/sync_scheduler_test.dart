import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_scheduler.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/services/battery_probe.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/sync_test_support.dart';

/// 同步调度器测试：注入 clock / 网络类型 / 电量探针（fake_async 驱动定时器）。
///
/// 覆盖：等级切换（活跃 / 空闲 / 后台 / 省电）、空闲退避封顶、无本地变更
/// 不发轮次、充电 + Wi-Fi 的 anti-entropy、蜂窝小类别与暂停策略、后台零定时。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SyncStateStore state;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    state = SyncStateStore(
      preferences: await SharedPreferences.getInstance(),
      secrets: MemorySyncSecretStore(),
      clock: () => 0,
    );
  });

  ({
    SyncScheduler scheduler,
    RecordingSyncSchedulerHost host,
  }) build(
    FakeAsync async, {
    bool playing = false,
    bool cellular = false,
    BatterySnapshot battery = BatterySnapshot.unknown,
  }) {
    final host = RecordingSyncSchedulerHost();
    final scheduler = SyncScheduler(
      host: host,
      state: state,
      cellularProbe: () async => cellular,
      batteryProbe: () async => battery,
      isPlaying: () => playing,
      clock: () => DateTime.fromMillisecondsSinceEpoch(
        async.elapsed.inMilliseconds,
      ),
    );
    return (scheduler: scheduler, host: host);
  }

  test('活跃等级：数据变更去抖 4s 后跑一轮（触发原因 debounce）', () {
    fakeAsync((async) {
      final env = build(async);
      unawaited(env.scheduler.start());
      async.flushMicrotasks();
      expect(env.scheduler.level, SyncLevel.active);

      env.scheduler.notifyLocalChange();
      async.elapse(const Duration(seconds: 3));
      expect(env.host.rounds, isEmpty, reason: '去抖窗口内不发轮次');

      async.elapse(const Duration(seconds: 2));
      expect(env.host.rounds, hasLength(1));
      expect(env.host.rounds.single.trigger, SyncTrigger.debounce);
      expect(env.host.rounds.single.push, isTrue);
      expect(env.host.rounds.single.categories, isNull);
      env.scheduler.dispose();
    });
  });

  test('空闲等级：无本地变更不广播、不发 PROPFIND，退避 10→20→40→60 封顶', () {
    fakeAsync((async) {
      final env = build(async);
      unawaited(env.scheduler.start());
      async.flushMicrotasks();

      // 交互窗口（1 分钟）过后进入空闲等级。
      async.elapse(const Duration(minutes: 2));
      expect(env.scheduler.level, SyncLevel.idle);
      expect(env.scheduler.idleBackoff, const Duration(minutes: 10));

      async.elapse(const Duration(minutes: 10));
      expect(env.host.rounds, isEmpty, reason: '无本地变更不广播');
      expect(env.scheduler.idleBackoff, const Duration(minutes: 20));

      async.elapse(const Duration(minutes: 20));
      expect(env.scheduler.idleBackoff, const Duration(minutes: 40));
      async.elapse(const Duration(minutes: 40));
      expect(env.scheduler.idleBackoff, const Duration(minutes: 60));
      async.elapse(const Duration(minutes: 60));
      expect(env.scheduler.idleBackoff, const Duration(minutes: 60),
          reason: '退避封顶 60 分钟');
      expect(env.host.rounds, isEmpty);
      env.scheduler.dispose();
    });
  });

  test('充电 + Wi-Fi：空闲唤醒跑 anti-entropy 全量校验（无需本地变更）', () {
    fakeAsync((async) {
      final env = build(
        async,
        battery: const BatterySnapshot(level: 80, charging: true),
      );
      unawaited(env.scheduler.start());
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 2));
      expect(env.scheduler.level, SyncLevel.idle);

      async.elapse(const Duration(minutes: 10));
      expect(env.host.rounds, hasLength(1));
      expect(env.host.rounds.single.trigger, SyncTrigger.timer);
      expect(env.host.rounds.single.categories, isNull);
      env.scheduler.dispose();
    });
  });

  test('空闲唤醒重新探测环境：插上电源后允许 anti-entropy', () {
    fakeAsync((async) {
      var battery = const BatterySnapshot(level: 50);
      final host = RecordingSyncSchedulerHost();
      final scheduler = SyncScheduler(
        host: host,
        state: state,
        cellularProbe: () async => false,
        batteryProbe: () async => battery,
        clock: () => DateTime.fromMillisecondsSinceEpoch(
          async.elapsed.inMilliseconds,
        ),
      );
      unawaited(scheduler.start());
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 2));
      expect(scheduler.level, SyncLevel.idle);

      // 未充电：唤醒只翻倍退避，不发轮次。
      async.elapse(const Duration(minutes: 10));
      expect(host.rounds, isEmpty);
      expect(scheduler.idleBackoff, const Duration(minutes: 20));

      // 插上电源：下一次唤醒探测到充电 + Wi-Fi → anti-entropy 跑一轮。
      battery = const BatterySnapshot(level: 50, charging: true);
      async.elapse(const Duration(minutes: 20));
      expect(host.rounds, hasLength(1));
      expect(host.rounds.single.trigger, SyncTrigger.timer);
      scheduler.dispose();
    });
  });

  test('省电等级：低电量未充电暂停自动，仅手点可用', () {
    fakeAsync((async) {
      final env = build(
        async,
        battery: const BatterySnapshot(level: 10),
      );
      unawaited(env.scheduler.start());
      async.flushMicrotasks();
      expect(env.scheduler.level, SyncLevel.powerSave);
      expect(env.scheduler.hasPendingTimer, isFalse, reason: '省电等级零定时');

      env.scheduler.notifyLocalChange();
      async.elapse(const Duration(hours: 3));
      expect(env.host.rounds, isEmpty);

      // 手动同步不受省电限制。
      unawaited(env.scheduler.syncNow());
      async.flushMicrotasks();
      expect(env.host.rounds, hasLength(1));
      expect(env.host.rounds.single.trigger, SyncTrigger.manual);
      env.scheduler.dispose();
    });
  });

  test('后台等级：零定时唤醒；退后台尽力推一次、回前台拉一次', () {
    fakeAsync((async) {
      final env = build(async);
      unawaited(env.scheduler.start());
      async.flushMicrotasks();

      env.scheduler.notifyLocalChange();
      env.scheduler.onAppHidden();
      async.flushMicrotasks();
      expect(env.scheduler.level, SyncLevel.background);
      expect(env.scheduler.hasPendingTimer, isFalse, reason: '后台零定时');
      expect(env.host.rounds, hasLength(1));
      expect(env.host.rounds.single.trigger, SyncTrigger.pause);
      expect(env.host.rounds.single.push, isTrue);

      // 后台长时间停留：没有任何唤醒。
      async.elapse(const Duration(hours: 5));
      expect(env.host.rounds, hasLength(1));
      expect(env.scheduler.hasPendingTimer, isFalse);

      env.scheduler.onAppVisible();
      async.flushMicrotasks();
      expect(env.host.rounds, hasLength(2));
      expect(env.host.rounds.last.trigger, SyncTrigger.resume);
      expect(env.scheduler.level, SyncLevel.active);
      env.scheduler.dispose();
    });
  });

  test('移动数据（auto）：只同步小类别', () {
    fakeAsync((async) {
      final env = build(async, cellular: true);
      unawaited(env.scheduler.start());
      async.flushMicrotasks();

      env.scheduler.notifyLocalChange();
      async.elapse(const Duration(seconds: 5));
      expect(env.host.rounds, hasLength(1));
      expect(env.host.rounds.single.categories,
          SyncScheduler.smallCategories);
      env.scheduler.dispose();
    });
  });

  test('移动数据（pause）：暂停自动同步，仅手点可用', () {
    fakeAsync((async) {
      unawaited(state.setCellularPolicy(SyncCellularPolicy.pause));
      final env = build(async, cellular: true);
      unawaited(env.scheduler.start());
      async.flushMicrotasks();

      env.scheduler.notifyLocalChange();
      async.elapse(const Duration(hours: 2));
      expect(env.host.rounds, isEmpty);
      expect(env.scheduler.hasPendingTimer, isFalse);

      unawaited(env.scheduler.syncNow());
      async.flushMicrotasks();
      expect(env.host.rounds, hasLength(1));
      expect(env.host.rounds.single.trigger, SyncTrigger.manual);
      expect(env.host.rounds.single.categories, isNull);
      env.scheduler.dispose();
    });
  });
}

/// 记录每轮请求的假宿主（不做任何真实同步）。
class RecordingSyncSchedulerHost implements SyncSchedulerHost {
  final List<
      ({
        SyncTrigger trigger,
        bool push,
        Set<SyncCategory>? categories,
      })> rounds = [];

  bool enabled = true;

  @override
  bool get syncEnabled => enabled;

  @override
  Future<void> runSyncRound({
    required SyncTrigger trigger,
    required bool push,
    Set<SyncCategory>? onlyCategories,
  }) async {
    rounds.add((trigger: trigger, push: push, categories: onlyCategories));
  }
}
