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
/// 覆盖「零对端不算交付」「手动轮能清待发」「自动 + 手动合并成一次补跑」
/// 「在途永不重叠」，以及一个真实引擎 + 真实调度器共享同一队列的跨层用例
/// （只在传输边界用假传输）。
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

    test('关闭类别直接丢弃待发标记，不等待失败轮', () async {
      var enabled = SyncCategory.values.toSet();
      final scoped = SyncRoundQueue(
        runRound: executor.run,
        enabledCategories: () => enabled,
      );
      scoped.markLocalChange();
      enabled = {SyncCategory.settings};

      scoped.pruneDisabledCategories();

      expect(scoped.dirtyCategories, {SyncCategory.settings});
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
        push: true,
        antiEntropy: true,
      );
      final discovery = queue.enqueue(trigger: SyncTrigger.discovery);
      await pumpEventQueue();
      expect(executor.calls, hasLength(1), reason: '在途轮未结束不跑第二轮');

      executor.gate!.complete();
      final reports = await Future.wait([auto, manual, discovery]);

      expect(executor.calls, hasLength(2), reason: '自动 + 手动只补跑一轮');
      expect(executor.maxConcurrent, 1, reason: '轮次从不重叠');
      expect(executor.calls[1].trigger, SyncTrigger.manual, reason: '手动优先');
      expect(executor.calls[1].antiEntropy, isTrue, reason: 'anti-entropy 取或');
      expect(reports[1], same(reports[2]), reason: '同一补跑轮共享报告');
      expect(queue.running, isFalse);
    });
  });

  group('引擎 + 调度器共用队列', () {
    late SharedPreferences prefs;
    late SyncStateStore state;
    late FakeSightingTransport transport;
    late SyncEngine engine;
    late SyncScheduler scheduler;

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
      transport = FakeSightingTransport();
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
      scheduler = SyncScheduler(
        host: engine,
        queue: engine.roundQueue,
        state: state,
        cellularProbe: () async => false,
        batteryProbe: () async => BatterySnapshot.unknown,
      );
      await scheduler.start();
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
  });
}

/// 可注入报告 / 门的执行器：记录调用顺序与并发峰值。
class _RecordingExecutor {
  final List<SyncQueuedRound> calls = [];
  Completer<void>? gate;
  bool fail = false;
  bool contact = true;
  int _active = 0;
  int maxConcurrent = 0;

  Future<SyncRoundReport> run(SyncQueuedRound round) async {
    calls.add(round);
    _active++;
    if (_active > maxConcurrent) maxConcurrent = _active;
    try {
      final wait = gate;
      if (wait != null) await wait.future;
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
            pushed: fail || !contact ? 0 : 1,
            failedPushes: fail ? 1 : 0,
          ),
        ],
      );
    } finally {
      _active--;
    }
  }
}
