import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_scheduler.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/ports/sync_transport.dart';
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
    Stream<void>? networkChanges,
    Stream<void>? peerSightings,
    List<Duration> reconnectLadder = const [
      Duration(seconds: 5),
      Duration(seconds: 20),
      Duration(seconds: 60),
      Duration(seconds: 180),
    ],
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
      networkChanges: networkChanges,
      peerSightings: peerSightings,
      reconnectLadder: reconnectLadder,
    );
    return (scheduler: scheduler, host: host);
  }

  /// 在 fake_async 里同步地把状态写成「LAN 启用 + 一个已验证端点」。
  void enableLanPeer(FakeAsync async) {
    unawaited(state.setTransportEnabled(SyncTransportKind.lan, true));
    async.flushMicrotasks();
    unawaited(state.rememberLanEndpoint(const LanPeerEndpoint(
      deviceId: 'devB',
      host: '192.168.1.23',
      httpPort: 40000,
      probePort: 47825,
      verifiedAt: 1,
    )));
    async.flushMicrotasks();
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

  test('checkNow：正常跑一轮 check（push），即使环境允许也不做 anti-entropy', () {
    fakeAsync((async) {
      final env = build(
        async,
        battery: const BatterySnapshot(level: 80, charging: true),
      );
      unawaited(env.scheduler.start());
      async.flushMicrotasks();

      unawaited(env.scheduler.checkNow());
      async.flushMicrotasks();

      expect(env.host.rounds, hasLength(1));
      expect(env.host.rounds.single.trigger, SyncTrigger.check);
      expect(env.host.rounds.single.push, isTrue);
      expect(
        env.host.lastAntiEntropy,
        isFalse,
        reason: '打开页面的检查轮不做全量兜底（只有 manual 自动允许）',
      );
      env.scheduler.dispose();
    });
  });

  test('checkNow：同步关闭时不跑', () {
    fakeAsync((async) {
      final env = build(async);
      env.host.enabled = false;
      unawaited(env.scheduler.start());
      async.flushMicrotasks();

      unawaited(env.scheduler.checkNow());
      async.flushMicrotasks();
      expect(env.host.rounds, isEmpty);
      env.scheduler.dispose();
    });
  });

  test('checkNow：省电等级不跑（自动检查受策略约束）', () {
    fakeAsync((async) {
      final env = build(
        async,
        battery: const BatterySnapshot(level: 10),
      );
      unawaited(env.scheduler.start());
      async.flushMicrotasks();
      expect(env.scheduler.powerSaveActive, isTrue);

      unawaited(env.scheduler.checkNow());
      async.flushMicrotasks();
      expect(env.host.rounds, isEmpty);

      // 手动同步仍不受限制（检查轮不能把「手动」一起关掉）。
      unawaited(env.scheduler.syncNow());
      async.flushMicrotasks();
      expect(env.host.rounds.single.trigger, SyncTrigger.manual);
      env.scheduler.dispose();
    });
  });

  test('checkNow：移动数据「暂停自动同步」时不跑', () {
    fakeAsync((async) {
      unawaited(state.setCellularPolicy(SyncCellularPolicy.pause));
      final env = build(async, cellular: true);
      unawaited(env.scheduler.start());
      async.flushMicrotasks();

      unawaited(env.scheduler.checkNow());
      async.flushMicrotasks();
      expect(env.host.rounds, isEmpty);
      env.scheduler.dispose();
    });
  });

  test('checkNow：已有轮次在跑时不排队', () {
    fakeAsync((async) {
      final env = build(async);
      env.host.roundGate = Completer<void>();
      unawaited(env.scheduler.start());
      async.flushMicrotasks();

      unawaited(env.scheduler.syncNow());
      async.flushMicrotasks();
      unawaited(env.scheduler.checkNow());
      async.flushMicrotasks();
      expect(env.host.rounds, isEmpty, reason: '手动轮仍在等 gate');

      env.host.roundGate!.complete();
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
      expect(
          SyncScheduler.smallCategories, isNot(contains(SyncCategory.covers)),
          reason: '封面图片体积大，蜂窝下等 Wi-Fi');
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

  test('蜂窝小类别轮只清已外发类别：历史 / 统计 / 封面留到 Wi-Fi 轮', () {
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
      // 小类别已外发；历史 / 统计 / 封面仍未外发（等 Wi-Fi）。
      expect(
        scheduler.dirtyCategories,
        {
          SyncCategory.statistics,
          SyncCategory.history,
          SyncCategory.covers,
        },
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

  test('网络变化：1.5s 去抖后跑 network 轮；事件来源是原始 connectivity 流', () {
    fakeAsync((async) {
      final network = StreamController<void>.broadcast();
      final env = build(async, networkChanges: network.stream);
      addTearDown(network.close);
      unawaited(env.scheduler.start());
      async.flushMicrotasks();

      network.add(null);
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 1400));
      expect(env.host.rounds, isEmpty, reason: '去抖窗口内不跑');

      async.elapse(const Duration(milliseconds: 200));
      expect(env.host.rounds, hasLength(1));
      expect(env.host.rounds.single.trigger, SyncTrigger.network);
      expect(env.host.rounds.single.push, isTrue);
      expect(env.scheduler.idleBackoff, const Duration(minutes: 10),
          reason: '换网重置空闲退避');
      env.scheduler.dispose();
    });
  });

  test('网络变化：后台 / 蜂窝不排轮次、不 arm 阶梯、零定时器', () {
    fakeAsync((async) {
      final network = StreamController<void>.broadcast();
      addTearDown(network.close);

      // 后台：忽略网络事件。
      final hidden = build(async, networkChanges: network.stream);
      unawaited(hidden.scheduler.start());
      async.flushMicrotasks();
      hidden.scheduler.onAppHidden();
      async.flushMicrotasks();
      network.add(null);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 10));
      expect(hidden.host.rounds, isEmpty);
      expect(hidden.scheduler.hasPendingTimer, isFalse);
      hidden.scheduler.dispose();

      // 蜂窝：不跑网络轮，也不 arm 重连阶梯（0 广播）。
      final cellular = build(
        async,
        cellular: true,
        networkChanges: network.stream,
      );
      unawaited(cellular.scheduler.start());
      async.flushMicrotasks();
      network.add(null);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 10));
      expect(cellular.host.rounds, isEmpty, reason: '蜂窝 0 广播 / 0 轮次');
      cellular.scheduler.dispose();
    });
  });

  test('对端公告：1s 去抖 + 10s 冷却（窗口内多次只跑一轮）', () {
    fakeAsync((async) {
      final sightings = StreamController<void>.broadcast();
      final env = build(async, peerSightings: sightings.stream);
      addTearDown(sightings.close);
      unawaited(env.scheduler.start());
      async.flushMicrotasks();

      sightings.add(null);
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 900));
      expect(env.host.rounds, isEmpty);
      async.elapse(const Duration(milliseconds: 200));
      expect(env.host.rounds, hasLength(1));
      expect(env.host.rounds.single.trigger, SyncTrigger.discovery);

      // 冷却期内再次公告：延后到 10s 冷却结束，不在窗口内重复跑。
      sightings.add(null);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      expect(env.host.rounds, hasLength(1), reason: '冷却未到不跑');
      async.elapse(const Duration(milliseconds: 8500));
      expect(env.host.rounds, hasLength(1), reason: '仍在 10s 冷却内');
      async.elapse(const Duration(seconds: 1));
      expect(env.host.rounds, hasLength(2));
      expect(env.host.rounds.last.trigger, SyncTrigger.discovery);
      env.scheduler.dispose();
    });
  });

  test('重连阶梯：5s / 20s / 60s / 180s；contactedLan 立即取消', () {
    fakeAsync((async) {
      enableLanPeer(async);
      final env = build(async);
      env.host.contacted = false;
      unawaited(env.scheduler.start());
      async.flushMicrotasks();

      unawaited(env.scheduler.onNetworkChanged());
      async.flushMicrotasks();
      // 1.5s 网络轮 + 5s 阶梯第一档。
      async.elapse(const Duration(milliseconds: 1500));
      expect(env.host.rounds, hasLength(1));
      expect(env.host.rounds.single.trigger, SyncTrigger.network);

      async.elapse(const Duration(milliseconds: 3500));
      expect(env.host.rounds, hasLength(2));
      expect(env.host.rounds.last.trigger, SyncTrigger.discovery);

      async.elapse(const Duration(seconds: 20));
      expect(env.host.rounds, hasLength(3), reason: '第二档 20s');
      async.elapse(const Duration(seconds: 60));
      expect(env.host.rounds, hasLength(4), reason: '第三档 60s');

      // 下一档（180s）接触到 LAN 对端：阶梯立即取消，不再有后续轮次。
      env.host.contactedLan = true;
      async.elapse(const Duration(seconds: 180));
      expect(env.host.rounds, hasLength(5), reason: '第四档 180s');
      env.host.contactedLan = false;
      // 空闲唤醒（≥10 分钟）会允许重新 arm；这里只验证取消后不再有阶梯轮次。
      async.elapse(const Duration(minutes: 5));
      expect(env.host.rounds, hasLength(5), reason: 'contactedLan 后取消阶梯');
      env.scheduler.dispose();
    });
  });

  test('重连阶梯：后台取消且零定时器；手动同步不 arm', () {
    fakeAsync((async) {
      enableLanPeer(async);
      final env = build(async);
      env.host.contacted = false;
      unawaited(env.scheduler.start());
      async.flushMicrotasks();

      unawaited(env.scheduler.onNetworkChanged());
      async.flushMicrotasks();
      expect(env.scheduler.hasPendingTimer, isTrue);

      env.scheduler.onAppHidden();
      async.flushMicrotasks();
      expect(env.scheduler.hasPendingTimer, isFalse, reason: '后台零定时');
      async.elapse(const Duration(hours: 1));
      expect(env.host.rounds, isEmpty);

      // 回前台 + 手动同步：resume 轮允许重新 arm，manual 自己不再 arm。
      env.scheduler.onAppVisible();
      async.flushMicrotasks();
      // resume 轮零对端 → 阶梯重新 arm；先取消它，验证 manual 不 arm。
      env.scheduler.onAppHidden();
      async.flushMicrotasks();
      unawaited(env.scheduler.syncNow());
      async.flushMicrotasks();
      expect(env.host.rounds.last.trigger, SyncTrigger.manual);
      env.scheduler.dispose();
    });
  });

  test('回前台 resume 零对端：即使没有本地变更（push=false）也重新 arm 阶梯', () {
    fakeAsync((async) {
      enableLanPeer(async);
      final env = build(async);
      env.host.contacted = false;
      unawaited(env.scheduler.start());
      async.flushMicrotasks();

      env.scheduler.onAppHidden();
      async.flushMicrotasks();
      env.scheduler.onAppVisible();
      async.flushMicrotasks();
      expect(env.host.rounds, hasLength(1));
      expect(env.host.rounds.single.trigger, SyncTrigger.resume);
      expect(env.host.rounds.single.push, isFalse, reason: '无本地变更只拉不推');

      // resume 轮的零对端接触结果仍会 arm 阶梯。
      async.elapse(const Duration(seconds: 5));
      expect(env.host.rounds, hasLength(2));
      expect(env.host.rounds.last.trigger, SyncTrigger.discovery);
      env.scheduler.dispose();
    });
  });

  test('启动后首轮零对端：同样 arm 重连阶梯', () {
    fakeAsync((async) {
      enableLanPeer(async);
      final env = build(async);
      env.host.contacted = false;
      unawaited(env.scheduler.start());
      async.flushMicrotasks();

      unawaited(env.scheduler.syncStartup());
      async.flushMicrotasks();
      expect(env.host.rounds, hasLength(1));
      expect(env.host.rounds.single.trigger, SyncTrigger.startup);

      async.elapse(const Duration(seconds: 5));
      expect(env.host.rounds, hasLength(2));
      expect(env.host.rounds.last.trigger, SyncTrigger.discovery);
      env.scheduler.dispose();
    });
  });

  test('轮次串行：上一轮未结束时公告 pending，结束后补一轮', () {
    fakeAsync((async) {
      final env = build(async);
      unawaited(env.scheduler.start());
      async.flushMicrotasks();

      env.host.roundGate = Completer<void>();
      unawaited(env.scheduler.syncNow());
      async.flushMicrotasks();
      expect(env.host.rounds, isEmpty, reason: '手动轮正在跑');

      env.scheduler.notifyPeerSighted();
      async.elapse(const Duration(seconds: 1));
      expect(env.host.rounds, isEmpty, reason: '不并发跑第二轮');

      env.host.roundGate!.complete();
      async.flushMicrotasks();
      expect(env.host.rounds, hasLength(1));
      expect(env.host.rounds.single.trigger, SyncTrigger.manual);

      // pending 的公告在本轮结束后重新走 1s 去抖并补跑。
      async.elapse(const Duration(seconds: 1));
      expect(env.host.rounds, hasLength(2));
      expect(env.host.rounds.last.trigger, SyncTrigger.discovery);
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

  /// 下一轮报告是否接触到对端（默认 true = 不触发零对端阶梯）。
  bool contacted = true;

  /// 下一轮是否接触到局域网对端（阶梯取消判据）。
  bool contactedLan = false;

  /// 非空时 `runSyncRound` 先等这个 Completer（验证串行守卫）。
  Completer<void>? roundGate;

  /// 最近一轮的 anti-entropy 开关（验证环境策略）。
  bool lastAntiEntropy = false;

  @override
  bool get syncEnabled => enabled;

  @override
  Future<SyncRunOutcome> runSyncRound({
    required SyncTrigger trigger,
    required bool push,
    required bool antiEntropy,
    Set<SyncCategory>? onlyCategories,
  }) async {
    final gate = roundGate;
    if (gate != null) await gate.future;
    rounds.add((trigger: trigger, push: push, categories: onlyCategories));
    lastAntiEntropy = antiEntropy;
    final failed = failNext;
    failNext = false;
    return SyncRunOutcome(
      categories: onlyCategories ?? {for (final c in SyncCategory.values) c},
      delivered: !failed,
      contacted: contacted,
      contactedLan: contactedLan,
    );
  }
}
