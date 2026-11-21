import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/data/settings/settings_registry.dart';
import 'package:molia/data/sync/adapters/prefs_sync_adapter.dart';
import 'package:molia/data/sync/sync_engine.dart';
import 'package:molia/data/sync/sync_round_queue.dart';
import 'package:molia/data/sync/sync_scheduler.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/ports/sync_transport.dart';
import 'package:molia/services/battery_probe.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/sync_test_support.dart';

/// 轮次队列：唯一的排队 / 串行 / 交付判定。
///
/// 覆盖「零对端 / 纯探测不算交付」「手动轮能清待发」「按请求合并外发与类别
/// 范围」「在途永不重叠」「轮内标脏不被本轮清掉」，以及真实引擎 + 真实调度器
/// 共享同一队列的跨层用例（只在传输边界用假传输）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SyncRoundQueue', () {
    late _RecordingExecutor executor;
    late SyncRoundQueue queue;

    setUp(() {
      executor = _RecordingExecutor();
      queue = SyncRoundQueue(
        runRound: executor.run,
        enabledCategories: () => SyncCategory.values.toSet(),
      );
    });

    test('零对端轮不是交付：待发类别原样保留', () async {
      executor.contact = false;
      queue.markLocalChange(categories: {SyncCategory.settings});

      final report = await queue.run(
        trigger: SyncTrigger.timer,
        push: true,
        antiEntropy: false,
      );
      final delivery = queue.classify(report!, push: true);

      expect(report.outcome, SyncOutcome.noPeers);
      expect(delivery.delivered, isFalse);
      expect(delivery.categories, isEmpty);
      expect(queue.dirtyCategories, {
        SyncCategory.settings,
      }, reason: '没有对端收到任何东西，不能清掉待发标记');
    });

    test('只看到对端、没有推送 / 未变跳过：不算交付', () async {
      executor.pushCounts = false;
      queue.markLocalChange(categories: {SyncCategory.settings});

      final report = await queue.run(
        trigger: SyncTrigger.timer,
        push: true,
        antiEntropy: false,
      );

      expect(report!.outcome, SyncOutcome.ok);
      expect(report.peersSeen, 1);
      expect(
        queue
            .classify(report, push: true, dirtyAtStart: {SyncCategory.settings})
            .delivered,
        isFalse,
        reason: '纯 peersSeen 没有证据说明本机改动已到达对端',
      );
      expect(queue.dirtyCategories, {SyncCategory.settings});
    });

    test('未变跳过（skippedUnchanged）视为已交付：清掉待发', () async {
      executor.pushCounts = false;
      executor.skipCounts = true;
      queue.markLocalChange(categories: {SyncCategory.settings});

      await queue.run(
        trigger: SyncTrigger.timer,
        push: true,
        antiEntropy: false,
      );

      expect(queue.dirtyCategories, isEmpty, reason: '对端已是最新（未变跳过）说明本地改动此前已到达');
    });

    test('手动轮真正交付后清掉待发类别（含低优先级即时标记）', () async {
      queue.markLocalChange(categories: {SyncCategory.settings});
      queue.markLocalChange(
        categories: {SyncCategory.session},
        immediate: false,
      );
      expect(queue.hasImmediate, isTrue);

      await queue.run(
        trigger: SyncTrigger.manual,
        push: true,
        antiEntropy: false,
      );

      expect(queue.dirtyCategories, isEmpty);
      expect(queue.hasImmediate, isFalse);
    });

    test('失败轮 / 只拉不推的轮次都不算交付', () async {
      queue.markLocalChange(categories: {SyncCategory.settings});
      executor.fail = true;

      await queue.run(
        trigger: SyncTrigger.timer,
        push: true,
        antiEntropy: false,
      );
      expect(queue.dirtyCategories, {SyncCategory.settings}, reason: '失败轮下轮重试');

      executor.fail = false;
      await queue.run(
        trigger: SyncTrigger.resume,
        push: false,
        antiEntropy: false,
      );
      expect(queue.dirtyCategories, {
        SyncCategory.settings,
      }, reason: '只拉不推没有外发动作');
    });

    test('类别范围只清本轮交付的类别（蜂窝小类别轮保留大类别）', () async {
      queue.markLocalChange();
      final small = {
        SyncCategory.settings,
        SyncCategory.sources,
        SyncCategory.playlists,
      };

      await queue.run(
        trigger: SyncTrigger.debounce,
        push: true,
        antiEntropy: false,
        onlyCategories: small,
      );

      expect(
        queue.dirtyCategories,
        SyncCategory.values.toSet().difference(small),
        reason: '历史 / 统计 / 封面等大类别等 Wi-Fi 轮',
      );
    });

    test('关闭类别动态过滤：不需要先跑一轮或 prune', () {
      var enabled = SyncCategory.values.toSet();
      final scoped = SyncRoundQueue(
        runRound: executor.run,
        enabledCategories: () => enabled,
      );
      scoped.markLocalChange(categories: {SyncCategory.settings});
      scoped.markLocalChange(
        categories: {SyncCategory.history},
        immediate: false,
      );

      enabled = {SyncCategory.settings};
      expect(scoped.dirtyCategories, {SyncCategory.settings});
      expect(scoped.dirty, isTrue);
      expect(scoped.hasImmediate, isTrue);

      enabled = {};
      expect(scoped.dirtyCategories, isEmpty);
      expect(scoped.dirty, isFalse);
      expect(scoped.hasImmediate, isFalse);
    });

    test('轮内新标记的类别不被本轮交付清掉，下一轮才清', () async {
      executor.gate = Completer<void>();
      queue.markLocalChange(categories: {SyncCategory.settings});

      final first = queue.run(
        trigger: SyncTrigger.timer,
        push: true,
        antiEntropy: false,
      );
      await pumpEventQueue();
      // 本轮快照之后用户又改了同一类别。
      queue.markLocalChange(categories: {SyncCategory.settings});
      executor.gate!.complete();
      await first;

      expect(queue.dirtyCategories, {
        SyncCategory.settings,
      }, reason: '轮内改动发生在快照之后，不能被本轮交付清掉');

      executor.gate = null;
      await queue.run(
        trigger: SyncTrigger.manual,
        push: true,
        antiEntropy: false,
      );
      expect(queue.dirtyCategories, isEmpty, reason: '补跑轮重新收集后才清');
    });

    test('没有在途轮次时 enqueue / schedule 显式抛 StateError', () {
      expect(
        () => queue.enqueue(trigger: SyncTrigger.manual, push: true),
        throwsStateError,
      );
      expect(
        () => queue.schedule(trigger: SyncTrigger.incoming, push: false),
        throwsStateError,
      );
      expect(queue.running, isFalse);
    });

    test('在途自动轮 + 手动请求：合并成一次补跑，不并发', () async {
      executor.gate = Completer<void>();

      final auto = queue.run(
        trigger: SyncTrigger.timer,
        push: true,
        antiEntropy: false,
      );
      await pumpEventQueue();
      expect(executor.maxConcurrent, 1);

      final manual = queue.run(
        trigger: SyncTrigger.manual,
        push: false,
        antiEntropy: true,
        onlyCategories: {SyncCategory.settings},
      );
      final discovery = queue.enqueue(
        trigger: SyncTrigger.discovery,
        push: false,
      );
      await pumpEventQueue();
      expect(executor.calls, hasLength(1), reason: '在途轮未结束不跑第二轮');

      executor.gate!.complete();
      final reports = await Future.wait([auto, manual, discovery]);

      expect(executor.calls, hasLength(2), reason: '自动 + 手动只补跑一轮');
      expect(executor.maxConcurrent, 1, reason: '轮次从不重叠');
      expect(executor.calls[1].trigger, SyncTrigger.manual, reason: '手动优先');
      expect(
        executor.calls[1].push,
        isTrue,
        reason: '手动请求固定推送，即使入参是 pull-only',
      );
      expect(executor.calls[1].onlyCategories, isNull, reason: '手动请求固定全部启用类别');
      expect(executor.calls[1].antiEntropy, isTrue, reason: 'anti-entropy 取或');
      expect(reports[1], same(reports[2]), reason: '同一补跑轮共享报告');
      expect(queue.running, isFalse);
    });

    test('入站 pull-only 轮在途 + 手动请求：补跑轮推送全部类别', () async {
      executor.gate = Completer<void>();

      final inbound = queue.run(
        trigger: SyncTrigger.incoming,
        push: false,
        antiEntropy: false,
      );
      await pumpEventQueue();
      expect(executor.calls.single.push, isFalse);

      final manual = queue.run(
        trigger: SyncTrigger.manual,
        push: true,
        antiEntropy: false,
      );
      executor.gate!.complete();
      await inbound;
      await manual;

      expect(executor.calls, hasLength(2));
      expect(executor.calls[1].trigger, SyncTrigger.manual);
      expect(executor.calls[1].push, isTrue, reason: '入站轮不能把手动轮压成只拉');
      expect(executor.calls[1].onlyCategories, isNull);
    });

    test('蜂窝小类别轮在途 + 手动请求：补跑轮覆盖全部类别', () async {
      executor.gate = Completer<void>();
      final small = {SyncCategory.settings, SyncCategory.session};

      final cellular = queue.run(
        trigger: SyncTrigger.debounce,
        push: true,
        antiEntropy: false,
        onlyCategories: small,
      );
      await pumpEventQueue();

      final manual = queue.run(
        trigger: SyncTrigger.manual,
        push: true,
        antiEntropy: false,
        onlyCategories: {SyncCategory.settings},
      );
      executor.gate!.complete();
      await cellular;
      await manual;

      expect(executor.calls, hasLength(2));
      expect(executor.calls[1].push, isTrue);
      expect(
        executor.calls[1].onlyCategories,
        isNull,
        reason: '手动轮不套用调度器的蜂窝小类别范围',
      );
    });

    test('非手动补跑：外发取或、范围取并集（null 全部优先）', () async {
      executor.gate = Completer<void>();

      final first = queue.run(
        trigger: SyncTrigger.timer,
        push: false,
        antiEntropy: false,
        onlyCategories: {SyncCategory.settings},
      );
      await pumpEventQueue();
      final second = queue.enqueue(
        trigger: SyncTrigger.network,
        push: true,
        onlyCategories: {SyncCategory.history},
      );
      final third = queue.enqueue(
        trigger: SyncTrigger.check,
        push: false,
        onlyCategories: {SyncCategory.settings},
      );
      executor.gate!.complete();
      await first;
      await Future.wait([second, third]);

      expect(executor.calls[1].push, isTrue);
      expect(executor.calls[1].onlyCategories, {
        SyncCategory.history,
        SyncCategory.settings,
      });

      executor.gate = Completer<void>();
      final fourth = queue.run(
        trigger: SyncTrigger.debounce,
        push: true,
        antiEntropy: false,
        onlyCategories: {SyncCategory.settings},
      );
      await pumpEventQueue();
      final fifth = queue.enqueue(
        trigger: SyncTrigger.check,
        push: true,
        onlyCategories: null,
      );
      final sixth = queue.enqueue(
        trigger: SyncTrigger.timer,
        push: false,
        onlyCategories: {SyncCategory.settings},
      );
      executor.gate!.complete();
      await fourth;
      await Future.wait([fifth, sixth]);

      expect(
        executor.calls[3].onlyCategories,
        isNull,
        reason: '范围「全部」优先，不能被先到的窄范围收窄',
      );
    });

    test('补跑轮抛异常：本轮与轮内到达的等待者都收到错误', () async {
      executor.gate = Completer<void>();
      executor.throwOnCall = 2;

      final first = queue.run(
        trigger: SyncTrigger.timer,
        push: true,
        antiEntropy: false,
      );
      final firstError = expectLater(first, throwsA(isA<StateError>()));
      await pumpEventQueue();

      final one = queue.enqueue(trigger: SyncTrigger.manual, push: true);
      final two = queue.enqueue(trigger: SyncTrigger.discovery, push: false);
      final oneError = expectLater(one, throwsA(isA<StateError>()));
      final twoError = expectLater(two, throwsA(isA<StateError>()));

      executor.gate!.complete();
      await Future.wait([firstError, oneError, twoError]);

      expect(queue.running, isFalse, reason: '异常后队列必须释放');
    });
  });

  group('引擎 + 调度器共用队列', () {
    late SharedPreferences prefs;
    late SyncStateStore state;
    late _GatedPushTransport transport;
    late SyncEngine engine;
    late SyncScheduler scheduler;

    Future<SyncScheduler> startScheduler({
      Duration activeDebounce = const Duration(seconds: 4),
    }) async {
      scheduler = SyncScheduler(
        host: engine,
        queue: engine.roundQueue,
        state: state,
        cellularProbe: () async => false,
        batteryProbe: () async => BatterySnapshot.unknown,
        activeDebounce: activeDebounce,
      );
      await scheduler.start();
      return scheduler;
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      state = SyncStateStore(
        preferences: prefs,
        secrets: MemorySyncSecretStore(),
        clock: () => 7000,
      );
      await state.init();
      await state.writePassphrase('ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789');
      await state.setTransportEnabled(SyncTransportKind.lan, true);
      transport = _GatedPushTransport();
      engine = SyncEngine(
        state: state,
        stamps: state.stampIssuer,
        adapters: [
          PrefsSyncAdapter(
            state: state,
            settings: SettingsRegistry(
              keys: const [kThemeMode],
              preferences: prefs,
              secrets: MemorySyncSecretStore(),
            ),
          ),
        ],
        transports: {SyncTransportKind.lan: transport},
        inboundWindow: const Duration(milliseconds: 10),
      );
      await engine.init();
      scheduler = await startScheduler();
    });

    tearDown(() {
      scheduler.dispose();
      engine.dispose();
    });

    SyncEnvelope remoteTheme(String value) => SyncEnvelope(
      deviceId: 'devB',
      deviceName: 'B',
      producedAt: 5000,
      records: {
        SyncCategory.settings: [
          SyncRecord(
            key: 'theme_mode',
            version: const SyncVersion(physical: 5000, deviceId: 'devB'),
            data: {'v': value},
          ),
        ],
      },
    );

    test('调度器标脏 → 零对端检查轮不清 → 手动轮交付后清', () async {
      scheduler.notifyLocalChange(categories: {SyncCategory.settings});
      expect(scheduler.dirtyCategories, {SyncCategory.settings});

      await scheduler.checkNow();
      expect(state.log.single.outcome, SyncOutcome.noPeers);
      expect(scheduler.dirtyCategories, {
        SyncCategory.settings,
      }, reason: '零对端轮不能算交付');

      transport.available.add(remoteTheme('dark'));
      await engine.syncNow(trigger: SyncTrigger.manual, antiEntropy: true);

      expect(state.log.first.outcome, SyncOutcome.ok);
      expect(
        scheduler.dirtyCategories,
        isEmpty,
        reason: '手动轮经同一队列交付，能清调度器标的待发类别',
      );
    });

    test('自动轮在途 + 手动请求：一轮补跑、从不并发', () async {
      scheduler.notifyLocalChange(categories: {SyncCategory.settings});
      transport.available.add(remoteTheme('dark'));

      final gate = Completer<void>();
      var active = 0;
      var maxActive = 0;
      transport.onPull = () async {
        active++;
        if (active > maxActive) maxActive = active;
        await gate.future;
        active--;
      };

      final check = scheduler.checkNow();
      await pumpEventQueue();
      expect(engine.syncing, isTrue);

      final manual = engine.syncNow(trigger: SyncTrigger.manual);
      await pumpEventQueue();

      gate.complete();
      await check;
      final report = await manual;

      expect(state.log, hasLength(2), reason: '自动 + 手动只多跑一轮');
      expect(state.log.first.trigger, SyncTrigger.manual, reason: '手动优先');
      expect(report!.trigger, SyncTrigger.manual);
      expect(maxActive, 1, reason: '在途轮次从不重叠');
      expect(scheduler.dirtyCategories, isEmpty);
    });

    test('同步关闭后在途轮次上的请求返回 null，不再并入补跑', () async {
      final gate = Completer<void>();
      transport.onPull = () async {
        await gate.future;
      };

      final first = engine.syncNow(trigger: SyncTrigger.timer);
      await pumpEventQueue();
      expect(engine.syncing, isTrue);

      await state.setTransportEnabled(SyncTransportKind.lan, false);
      expect(await engine.syncNow(trigger: SyncTrigger.manual), isNull);

      transport.onPull = null;
      gate.complete();
      await first;

      expect(state.log, hasLength(1), reason: '关闭后不再补跑');
      expect(engine.syncing, isFalse);
    });

    test('手动轮在途时的本地变更：去抖补跑并真正推送', () async {
      scheduler.dispose();
      scheduler = await startScheduler(activeDebounce: Duration.zero);
      // 有一个可达对端：轮次结论才会是 ok / noChanges（而不是 noPeers）。
      transport.peersSeenOverride = 1;
      transport.seenIdsOverride = const ['devB'];

      final gate = Completer<void>();
      final pushing = Completer<void>();
      transport
        ..pushGate = gate
        ..pushEntered = pushing;

      final manual = engine.syncNow(trigger: SyncTrigger.manual);
      // 推送发生在本轮 collect / 刷新之后：到这里再写，保证本轮快照早于这次改动。
      await pushing.future;
      expect(engine.syncing, isTrue);

      await prefs.setString('theme_mode', 'dark');
      scheduler.notifyLocalChange(categories: {SyncCategory.settings});
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(engine.syncing, isTrue, reason: '补跑仍在等手动轮结束');

      transport.pushGate = null;
      gate.complete();
      final report = await manual;

      expect(state.log, hasLength(2), reason: '手动 + 一次去抖补跑');
      expect(report!.trigger, SyncTrigger.debounce);
      expect(
        state.log.first.trigger,
        SyncTrigger.debounce,
        reason: '补跑由轮内本地变更触发',
      );
      expect(transport.maxActivePushes, 1, reason: '在途轮次从不重叠（推送不并发）');
      expect(scheduler.dirtyCategories, isEmpty, reason: '补跑真正推送后清标记');
      expect(
        transport.pushed.last
            .recordsOf(SyncCategory.settings)
            .any(
              (record) =>
                  record.key == 'theme_mode' && record.data?['v'] == 'dark',
            ),
        isTrue,
        reason: '补跑轮推送了轮内写入的新值',
      );
    });
  });
}

/// 可注入报告 / 门的执行器：记录调用顺序与并发峰值。
class _RecordingExecutor {
  final List<SyncQueuedRound> calls = [];
  Completer<void>? gate;
  bool fail = false;
  bool contact = true;
  bool pushCounts = true;
  bool skipCounts = false;
  int throwOnCall = -1;
  int _active = 0;
  int maxConcurrent = 0;

  Future<SyncRoundReport> run(SyncQueuedRound round) async {
    calls.add(round);
    _active++;
    if (_active > maxConcurrent) maxConcurrent = _active;
    try {
      final wait = gate;
      if (wait != null) await wait.future;
      if (calls.length == throwOnCall) {
        throw StateError('补跑轮失败（测试注入）');
      }
      final now = 7000 + calls.length;
      final seen = contact ? 1 : 0;
      return SyncRoundReport(
        trigger: round.trigger,
        startedAt: now,
        finishedAt: now,
        outcome: fail
            ? SyncOutcome.failed
            : (contact ? SyncOutcome.ok : SyncOutcome.noPeers),
        transports: [
          SyncTransportReport(
            kind: SyncTransportKind.lan,
            enabled: true,
            running: true,
            peersSeen: seen,
            pushed: fail || !contact || !pushCounts ? 0 : 1,
            skippedUnchanged: skipCounts ? 1 : 0,
            failedPushes: fail ? 1 : 0,
          ),
        ],
      );
    } finally {
      _active--;
    }
  }
}

/// 推送可门的假传输：验证「轮内写入」发生在快照之后、补跑才带上新值。
class _GatedPushTransport extends FakeSightingTransport {
  Completer<void>? pushGate;
  Completer<void>? pushEntered;
  int activePushes = 0;
  int maxActivePushes = 0;

  @override
  Future<SyncPushResult> push(
    SyncEnvelope envelope, {
    SyncRoundWindow? window,
  }) async {
    activePushes++;
    if (activePushes > maxActivePushes) maxActivePushes = activePushes;
    final entered = pushEntered;
    if (entered != null && !entered.isCompleted) entered.complete();
    try {
      final gate = pushGate;
      if (gate != null) await gate.future;
      return await super.push(envelope, window: window);
    } finally {
      activePushes--;
    }
  }
}
