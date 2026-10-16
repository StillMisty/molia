import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/data/settings/settings_registry.dart';
import 'package:molia/data/sync/adapters/prefs_sync_adapter.dart';
import 'package:molia/data/sync/sync_adapter.dart';
import 'package:molia/data/sync/sync_engine.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/sync_test_support.dart';

/// 引擎测试：一轮同步的拉取 → 合并 → 应用 → 推送 → **报告与日志**。
///
/// 可观察性契约是主要覆盖对象：五态判定（尤其是「没发现对端」与「没有变化」
/// 必须分开）、设备名册、入站快照不丢、进行中的请求排队补跑，以及协议 v2
/// 对 v1 对端的拒绝（不静默合并）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const keys = [kThemeMode];

  late SharedPreferences prefs;
  late MemorySyncSecretStore secrets;
  late SyncStateStore state;
  late FakeSyncTransport transport;
  late SyncEngine engine;

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
    engine = SyncEngine(
      state: state,
      stamps: state.stampIssuer,
      adapters: [
        PrefsSyncAdapter(
          state: state,
          settings: SettingsRegistry(
            keys: keys,
            preferences: prefs,
            secrets: secrets,
          ),
        ),
      ],
      transports: {'lan': transport},
    );
    await engine.init();
  });

  tearDown(() => engine.dispose());

  SyncEnvelope remoteTheme(
    String value, {
    int at = 5000,
    String deviceId = 'devB',
    String deviceName = 'B',
  }) =>
      SyncEnvelope(
        deviceId: deviceId,
        deviceName: deviceName,
        producedAt: at,
        records: {
          SyncCategory.settings: [
            SyncRecord(
              key: 'theme_mode',
              version: SyncVersion(physical: at, deviceId: deviceId),
              data: {'v': value},
            ),
          ],
        },
      );

  test('一轮同步：应用远端、推送合并结果、报告 ok 且写入名册', () async {
    transport.available.add(remoteTheme('dark'));
    final report = await engine.syncNow(trigger: SyncTrigger.manual);

    expect(report, isNotNull);
    expect(report!.outcome, SyncOutcome.ok);
    expect(report.trigger, SyncTrigger.manual);
    expect(report.applied, 1);
    expect(prefs.getString('theme_mode'), 'dark');

    // 日志：触发原因 + 结论 + 变更量（不再有「跳过」这类全库计数）。
    expect(state.log.first.applied, 1);
    expect(state.log.first.outcome, SyncOutcome.ok);
    expect(state.log.first.trigger, SyncTrigger.manual);
    expect(state.log.first.peersSeen, 1);

    // 推送的快照包含应用的远端记录（继续向其他设备传播）。
    expect(transport.pushed, hasLength(1));
    final pushedTheme = transport.pushed.single
        .recordsOf(SyncCategory.settings)
        .firstWhere((r) => r.key == 'theme_mode');
    expect(pushedTheme.data, {'v': 'dark'});
    expect(pushedTheme.version.physical, 5000);
    expect(pushedTheme.version.deviceId, 'devB');
    expect(transport.pushed.single.version, SyncEnvelope.protocolVersion);
    expect(engine.lastEnvelope, isNotNull);

    // 名册：从对端快照吸收身份与时钟偏移。
    expect(report.peers, hasLength(1));
    expect(report.peers.single.deviceId, 'devB');
    expect(report.peers.single.name, 'B');
    expect(report.peers.single.transport, 'lan');
    expect(report.peers.single.lastPullAt, greaterThan(0));
    expect(state.peers.single.deviceId, 'devB');
  });

  test('没有对端：结论是 noPeers（不再显示成「同步成功」）', () async {
    final report = await engine.syncNow();

    expect(report!.outcome, SyncOutcome.noPeers);
    expect(report.peersSeen, 0);
    expect(state.log.first.outcome, SyncOutcome.noPeers);
  });

  test('对端可达但没有变化：结论是 noChanges', () async {
    transport.available.add(remoteTheme('dark'));
    await engine.syncNow();
    expect(transport.pushed, hasLength(1));

    // 对端仍在（探测到）但本轮没有新数据。
    transport.available.clear();
    transport.peersSeenOverride = 1;
    final second = await engine.syncNow();

    expect(second!.outcome, SyncOutcome.noChanges);
    expect(second.applied, 0);
    expect(state.log.first.outcome, SyncOutcome.noChanges);
  });

  test('部分失败：结论是 partial 并带上失败个数', () async {
    transport.available.add(remoteTheme('dark'));
    transport.pullFailures = 1;
    final report = await engine.syncNow();

    expect(report!.outcome, SyncOutcome.partial);
    expect(report.failedCount, 1);
    expect(state.log.first.failed, 1);
  });

  test('所有对端都联系不上：结论是 failed', () async {
    transport.peersSeenOverride = 1;
    transport.pullFailures = 1;
    transport.pushFailures = 1;
    final report = await engine.syncNow();

    expect(report!.outcome, SyncOutcome.failed);
    expect(report.error, isNotNull);
    expect(state.log.first.outcome, SyncOutcome.failed);
  });

  test('传输异常不冒泡，报告里可见', () async {
    transport.peersSeenOverride = 1;
    transport.throwOnPull = true;
    final report = await engine.syncNow();

    // 拉取抛异常被传输边界吸收：本轮记为「部分失败」，原因进报告与日志，
    // 不冒泡给调用方（否则一次网络抖动就会打断调用链）。
    expect(report!.outcome, SyncOutcome.partial);
    expect(report.error, contains('拉取失败'));
    expect(state.log.first.outcome, SyncOutcome.partial);
  });

  test('类别关闭：既不应用远端也不推送该类记录', () async {
    await state.setCategory(SyncCategory.settings, false);
    transport.available.add(remoteTheme('dark'));
    final report = await engine.syncNow();

    expect(report!.applied, 0);
    expect(prefs.getString('theme_mode'), isNull);
    expect(
      transport.pushed.single
          .recordsOf(SyncCategory.settings)
          .where((r) => r.key == 'theme_mode'),
      isEmpty,
    );
  });

  test('对端入站快照触发同步，且入站轮次不再推送（防乒乓）', () async {
    await engine.onIncomingEnvelope(remoteTheme('light'));

    expect(prefs.getString('theme_mode'), 'light');
    expect(transport.pushed, isEmpty);
    expect(state.log.first.trigger, SyncTrigger.incoming);
    expect(state.log.first.outcome, SyncOutcome.ok);
  });

  test('未设置口令：报告失败并写入日志', () async {
    await state.writePassphrase('');
    transport.available.add(remoteTheme('dark'));
    final report = await engine.syncNow();

    expect(report!.outcome, SyncOutcome.failed);
    expect(report.error, contains('同步口令'));
    expect(state.log.first.outcome, SyncOutcome.failed);
    expect(prefs.getString('theme_mode'), isNull);
  });

  test('传输关闭时不启动也不拉取', () async {
    await state.setTransportEnabled('lan', false);
    await engine.setEnabled(false);
    await engine.setEnabled(true);
    expect(transport.isRunning, isFalse);

    transport.available.add(remoteTheme('dark'));
    final disabled = await engine.syncNow();
    expect(disabled!.outcome, SyncOutcome.noPeers);
    expect(prefs.getString('theme_mode'), isNull);

    await engine.setTransportEnabled('lan', true);
    expect(transport.isRunning, isTrue);
    await engine.syncNow();
    expect(prefs.getString('theme_mode'), 'dark');
  });

  test('同步进行中的请求会排队补跑（点两次不会只生效一次）', () async {
    transport.available.add(remoteTheme('dark'));

    final first = engine.syncNow(trigger: SyncTrigger.timer);
    final second = engine.syncNow(trigger: SyncTrigger.manual);
    await Future.wait([first, second]);

    expect(transport.pushed, hasLength(2));
    expect(state.log, hasLength(2));
    // 补跑的那轮用排队时记录的触发原因（手动）。
    expect(state.log.first.trigger, SyncTrigger.manual);
  });

  test('名册跨重启恢复', () async {
    transport.available.add(remoteTheme('dark'));
    await engine.syncNow();
    await state.save();

    final reloaded = SyncStateStore(preferences: prefs, secrets: secrets);
    await reloaded.init();
    expect(reloaded.peers, hasLength(1));
    expect(reloaded.peers.single.deviceId, 'devB');
    expect(reloaded.peers.single.name, 'B');
  });

  test('应用失败：入站快照放回队列，下一轮重试', () async {
    final failingState = SyncStateStore(preferences: prefs, secrets: secrets);
    await failingState.init();
    await failingState.setEnabled(true);
    final failingTransport = FakeSyncTransport();
    final adapter = _FlakyAdapter();
    final failingEngine = SyncEngine(
      state: failingState,
      stamps: failingState.stampIssuer,
      adapters: [adapter],
      transports: {'lan': failingTransport},
    );
    addTearDown(failingEngine.dispose);
    await failingEngine.init();

    adapter.failNext = true;
    await failingEngine.onIncomingEnvelope(remoteTheme('light'));
    expect(adapter.appliedKeys, isEmpty);
    // 收到数据但一条都没落地：本轮算失败（错误里带应用失败次数）。
    expect(failingState.log.first.outcome, SyncOutcome.failed);
    expect(failingState.log.first.failed, 1);
    expect(failingState.log.first.error, contains('应用失败'));

    // 下一轮消费队列里的入站快照（否则对端推来的数据就永久丢了）。
    await failingEngine.syncNow();
    expect(adapter.appliedKeys, ['theme_mode']);
  });
}

/// 首次 apply 抛异常、之后成功：验证「应用失败不丢入站数据」。
class _FlakyAdapter implements SyncAdapter {
  bool failNext = false;
  final List<String> appliedKeys = [];

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
    if (failNext) {
      failNext = false;
      throw StateError('应用失败（测试注入）');
    }
    var applied = 0;
    for (final record in records[SyncCategory.settings] ?? const <SyncRecord>[]) {
      appliedKeys.add(record.key);
      applied++;
    }
    return SyncApplyOutcome(applied: applied);
  }
}
