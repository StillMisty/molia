import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/data/settings/settings_registry.dart';
import 'package:molia/data/sync/adapters/prefs_sync_adapter.dart';
import 'package:molia/data/sync/sync_engine.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/sync_test_support.dart';

/// 引擎测试：一轮同步的拉取 → 合并 → 应用 → 推送 → 日志，类别开关与入站触发。
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
    state = SyncStateStore(preferences: prefs, secrets: secrets);
    await state.init();
    await state.writePassphrase(
        'ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789');
    await state.setEnabled(true);
    transport = FakeSyncTransport();
    engine = SyncEngine(
      state: state,
      adapters: [
        PrefsSyncAdapter(
          state: state,
          settings: SettingsRegistry(
            keys: keys,
            preferences: prefs,
            secrets: secrets,
          ),
          deviceId: () => state.deviceId,
          now: () => 7000,
        ),
      ],
      transports: {'lan': transport},
    );
    await engine.init();
  });

  tearDown(() => engine.dispose());

  SyncEnvelope remoteTheme(String value, {int at = 5000}) => SyncEnvelope(
        deviceId: 'devB',
        deviceName: 'B',
        producedAt: at,
        records: {
          SyncCategory.settings: [
            SyncRecord(
              key: 'theme_mode',
              updatedAt: at,
              updatedBy: 'devB',
              data: {'v': value},
            ),
          ],
        },
      );

  test('一轮同步：应用远端、推送合并结果、记录日志与快照', () async {
    transport.available.add(remoteTheme('dark'));
    final report = await engine.syncNow();

    expect(report.ok, isTrue);
    expect(report.applied, 1);
    expect(prefs.getString('theme_mode'), 'dark');
    expect(state.log.first.applied, 1);
    expect(state.log.first.ok, isTrue);

    // 推送的快照包含应用的远端记录（继续向其他设备传播）。
    expect(transport.pushed, hasLength(1));
    final pushedTheme = transport.pushed.single
        .recordsOf(SyncCategory.settings)
        .firstWhere((r) => r.key == 'theme_mode');
    expect(pushedTheme.data, {'v': 'dark'});
    expect(engine.lastEnvelope, isNotNull);
  });

  test('类别关闭：既不应用远端也不推送该类记录', () async {
    await state.setCategory(SyncCategory.settings, false);
    transport.available.add(remoteTheme('dark'));
    final report = await engine.syncNow();

    expect(report.applied, 0);
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
  });

  test('未设置口令：报告失败并写入日志', () async {
    await state.writePassphrase('');
    transport.available.add(remoteTheme('dark'));
    final report = await engine.syncNow();

    expect(report.ok, isFalse);
    expect(report.error, contains('同步口令'));
    expect(state.lastSyncOk, isFalse);
    expect(prefs.getString('theme_mode'), isNull);
  });

  test('传输关闭时不启动也不拉取', () async {
    await state.setTransportEnabled('lan', false);
    await engine.setEnabled(false);
    await engine.setEnabled(true);
    expect(transport.isRunning, isFalse);

    transport.available.add(remoteTheme('dark'));
    await engine.syncNow();
    expect(prefs.getString('theme_mode'), isNull);

    await engine.setTransportEnabled('lan', true);
    expect(transport.isRunning, isTrue);
    await engine.syncNow();
    expect(prefs.getString('theme_mode'), 'dark');
  });
}
