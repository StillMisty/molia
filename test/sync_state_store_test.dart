import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/settings_secret_store.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/sync_test_support.dart';

/// 同步本地存储测试面：状态存储（蜂窝策略持久化 / 活动记录上限）与安全存储
/// 读取容错。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<SyncStateStore> freshStore() async {
    final store = SyncStateStore(
      preferences: await SharedPreferences.getInstance(),
      secrets: MemorySyncSecretStore(),
      clock: () => 1000,
    );
    await store.init();
    return store;
  }

  test('传输开关默认两路都关，且没有独立总开关', () async {
    final store = await freshStore();
    // 装机默认：不启动监听 / 不广播（用户开开关才算启用同步）。
    expect(store.enabledTransports, isEmpty);
    expect(store.enabled, isFalse);

    // 任一传输开启 = 启用同步；总闸就是传输集合本身。
    await store.setTransportEnabled('lan', true);
    expect(store.enabled, isTrue);
    await store.setTransportEnabled('lan', false);
    expect(store.enabled, isFalse);
  });

  test('旧状态迁移：enabled=false 的老用户升级后同步保持关闭', () async {
    // 旧版写入：总开关关着，但 transports 默认已含 lan。
    await SharedPreferences.getInstance().then((prefs) => prefs.setString(
          SyncStateStore.stateKey,
          '{"v":2,"deviceId":"devA","enabled":false,"transports":["lan"]}',
        ));

    final store = await freshStore();
    expect(store.enabledTransports, isEmpty,
        reason: '总开关关过：transport 里的默认值不是启用信号');
    expect(store.enabled, isFalse);
  });

  test('旧状态迁移：enabled=true 的原有开启用户保持开启', () async {
    await SharedPreferences.getInstance().then((prefs) => prefs.setString(
          SyncStateStore.stateKey,
          '{"v":2,"deviceId":"devA","enabled":true,"transports":["lan"]}',
        ));

    final store = await freshStore();
    expect(store.enabledTransports, contains('lan'));
    expect(store.enabled, isTrue);
  });

  test('蜂窝策略默认 auto，写入后跨实例保持', () async {
    final store = await freshStore();
    expect(store.cellularPolicy, SyncCellularPolicy.auto);

    await store.setCellularPolicy(SyncCellularPolicy.pause);

    final reloaded = await freshStore();
    expect(reloaded.cellularPolicy, SyncCellularPolicy.pause);
  });

  test('未知策略值回落到 auto', () async {
    final store = SyncStateStore(
      preferences: await SharedPreferences.getInstance(),
      secrets: MemorySyncSecretStore(),
      clock: () => 1000,
    );
    await store.init();
    expect(SyncCellularPolicy.parse('unknown'), SyncCellularPolicy.auto);
    expect(SyncCellularPolicy.parse(null), SyncCellularPolicy.auto);
  });

  test('活动记录：每轮追加、跨实例保持、超上限截断', () async {
    final store = await freshStore();
    expect(store.activity, isEmpty);

    for (var i = 0; i < 25; i++) {
      store.recordRound(SyncRoundReport(
        trigger: SyncTrigger.timer,
        startedAt: 1000 + i,
        finishedAt: 1000 + i,
        outcome: SyncOutcome.ok,
        applied: i,
      ));
    }
    // 展示日志只留 20 条，活动记录保留全部 25 条（观测面窗口不截断）。
    expect(store.log, hasLength(SyncStateStore.logLimit));
    expect(store.activity, hasLength(25));
    expect(store.activity.first.applied, 24);

    await store.save();
    final reloaded = await freshStore();
    expect(reloaded.activity, hasLength(25));
    expect(reloaded.activity.first.at, 1024);
  });

  test('活动记录：超过上限时丢弃最旧的', () async {
    final store = await freshStore();
    for (var i = 0; i < SyncStateStore.activityLimit + 5; i++) {
      store.recordRound(SyncRoundReport(
        trigger: SyncTrigger.timer,
        startedAt: i,
        finishedAt: i,
        outcome: SyncOutcome.noChanges,
      ));
    }
    expect(store.activity, hasLength(SyncStateStore.activityLimit));
    expect(store.activity.first.at, SyncStateStore.activityLimit + 4);
    expect(store.activity.last.at, 5);
  });

  // 安全存储读取容错（回归：WSLg / 容器等无系统钥匙串的环境里 libsecret
  // 抛异常，未捕获会打断 `main()` 的 `runApp` 之前部分，桌面端表现为
  // 「窗口已显示但没有首帧」的永久黑窗，见 pitfalls #31）。
  const store = SecureSettingsSecretStore();

  test('读取失败降级为「未设置」：返回 null，不抛异常', () async {
    // 单测环境没有 libsecret 平台实现：修复前这里会抛 MissingPluginException。
    expect(await store.read('sync_passphrase_v1'), isNull);
  });

  test('写入仍然抛出：用户主动操作要知道没存进去', () async {
    await expectLater(
      store.write('sync_passphrase_v1', 'secret'),
      throwsA(isA<Exception>()),
    );
  });

  test('SyncStateStore.readPassphrase 在无钥匙串时同样返回 null', () async {
    final state = SyncStateStore(secrets: store, deviceId: 'test-device');
    expect(await state.readPassphrase(), isNull);
    expect(await state.readWebdavPassword(), isNull);
  });
}
