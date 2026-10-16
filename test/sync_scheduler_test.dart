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

  test('空闲等级（蜂窝）：无本地变更不广播、不发 PROPFIND，退避 10→20→40→60 封顶', () {
    fakeAsync((async) {
      final env = build(async, cellular: true);
      unawaited(env.scheduler.start());
      async.flushMicrotasks();

      // 交互窗口（1 分钟）过后进入空闲等级。
      async.elapse(const Duration(minutes: 2));
      expect(env.scheduler.level, SyncLevel.idle);
      expect(env.scheduler.idleBackoff, const Duration(minutes: 10));

      async.elapse(const Duration(minutes: 10));
      expect(env.host.rounds, isEmpty, reason: '蜂窝 + 无本地变更不广播');
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

  test('空闲等级（非蜂窝 / 桌面）：无本地变更也周期性探测与拉取', () {
    fakeAsync((async) {
      // 电量未知 = 桌面（外部供电等价）；非蜂窝网络。
      final env = build(async, battery: BatterySnapshot.unknown);
      unawaited(env.scheduler.start());
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 2));
      expect(env.scheduler.level, SyncLevel.idle);
      expect(env.scheduler.powerSaveActive, isFalse);

      async.elapse(const Duration(minutes: 10));
      expect(env.host.rounds, hasLength(1));
      expect(env.host.rounds.single.trigger, SyncTrigger.timer);
      expect(env.host.rounds.single.push, isTrue);
      expect(env.host.rounds.single.categories, isNull);

      // 周期继续（退避回到起点后再来一轮），远端变化在空闲期也能收敛。
      async.elapse(const Duration(minutes: 10));
      expect(env.host.rounds, hasLength(2));
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

  test('空闲唤醒重新探测环境：切到蜂窝后不再无变更拉取', () {
    fakeAsync((async) {
      var cellular = false;
      final host = RecordingSyncSchedulerHost();
      final scheduler = SyncScheduler(
        host: host,
        state: state,
        cellularProbe: () async => cellular,
        batteryProbe: () async => BatterySnapshot.unknown,
        clock: () => DateTime.fromMillisecondsSinceEpoch(
          async.elapsed.inMilliseconds,
        ),
      );
      addTearDown(scheduler.dispose);
      unawaited(scheduler.start());
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 2));
      expect(scheduler.level, SyncLevel.idle);

      // 非蜂窝：唤醒即校验（跑一轮，退避回起点）。
      async.elapse(const Duration(minutes: 10));
      expect(host.rounds, hasLength(1));
      expect(scheduler.idleBackoff, const Duration(minutes: 10));

      // 切到移动数据：下一次唤醒探测到蜂窝 → 无本地变更不发轮次，退避翻倍。
      cellular = true;
      async.elapse(const Duration(minutes: 10));
      expect(host.rounds, hasLength(1));
      expect(scheduler.idleBackoff, const Duration(minutes: 20));
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

      // 启动后首轮同样被省电等级拦住。
      unawaited(env.scheduler.syncStartup());
      async.flushMicrotasks();
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

  test('蜂窝小类别轮只清已外发类别：历史 / 统计留到 Wi-Fi 轮', () {
    fakeAsync((async) {
      var cellular = true;
      final host = RecordingSyncSchedulerHost();
      final scheduler = SyncScheduler(
        host: host,
        state: state,
        cellularProbe: () async => cellular,
        batteryProbe: () async => BatterySnapshot.unknown,
        clock: () => DateTime.fromMillisecondsSinceEpoch(
          async.elapsed.inMilliseconds,
        ),
      );
      addTearDown(scheduler.dispose);
      unawaited(scheduler.start());
      async.flushMicrotasks();

      scheduler.notifyLocalChange();
      async.elapse(const Duration(seconds: 5));
      expect(host.rounds.single.categories, SyncScheduler.smallCategories);
      // 小类别已外发；历史 / 统计仍未外发（等 Wi-Fi）。
      expect(
        scheduler.dirtyCategories,
        {SyncCategory.statistics, SyncCategory.history},
      );

      // 切回 Wi-Fi：下一次去抖轮覆盖全部类别并清空待发标记。
      cellular = false;
      unawaited(scheduler.refreshEnvironment());
      async.flushMicrotasks();
      scheduler.notifyInteraction();
      async.elapse(const Duration(seconds: 5));
      expect(host.rounds, hasLength(2));
      expect(host.rounds.last.categories, isNull);
      expect(scheduler.dirtyCategories, isEmpty);
    });
  });

  test('失败轮保留待发标记：下轮重试同一类别', () {
    fakeAsync((async) {
      final env = build(async);
      unawaited(env.scheduler.start());
      async.flushMicrotasks();

      env.host.failNext = true;
      env.scheduler.notifyLocalChange(categories: {SyncCategory.settings});
      async.elapse(const Duration(seconds: 5));
      expect(env.host.rounds, hasLength(1));
      expect(env.scheduler.dirtyCategories, {SyncCategory.settings});

      env.scheduler.notifyInteraction();
      async.elapse(const Duration(seconds: 5));
      expect(env.host.rounds, hasLength(2));
      expect(env.scheduler.dirtyCategories, isEmpty);
      env.scheduler.dispose();
    });
  });

  test('低优先级变更只标记待发：不排去抖轮次，等下次自然唤醒', () {
    fakeAsync((async) {
      final env = build(async);
      unawaited(env.scheduler.start());
      async.flushMicrotasks();

      env.scheduler.notifyLocalChange(
        categories: {SyncCategory.session},
        immediate: false,
      );
      async.elapse(const Duration(minutes: 5));
      expect(env.host.rounds, isEmpty, reason: '高频写入不触发即时轮次');
      expect(env.scheduler.dirtyCategories, {SyncCategory.session});

      // 高优先级变更到来：去抖一轮覆盖全部启用类别。
      env.scheduler.notifyLocalChange(categories: {SyncCategory.settings});
      async.elapse(const Duration(seconds: 5));
      expect(env.host.rounds, hasLength(1));
      expect(env.scheduler.dirtyCategories, isEmpty);
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

  /// 下一轮报告失败（验证待发标记保留）。
  bool failNext = false;

  @override
  bool get syncEnabled => enabled;

  @override
  Future<SyncRunOutcome> runSyncRound({
    required SyncTrigger trigger,
    required bool push,
    Set<SyncCategory>? onlyCategories,
  }) async {
    rounds.add((trigger: trigger, push: push, categories: onlyCategories));
    final failed = failNext;
    failNext = false;
    return SyncRunOutcome(
      categories: onlyCategories ?? {for (final c in SyncCategory.values) c},
      delivered: !failed,
    );
  }
}
