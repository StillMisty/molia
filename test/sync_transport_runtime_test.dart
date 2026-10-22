import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_control_plane.dart';
import 'package:molia/data/sync/sync_engine.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/data/sync/sync_transport_runtime.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/ports/sync_transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/sync_test_support.dart';

/// 传输运行时：启动 / 停止 / 生命周期 / 公告的唯一所有者。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late MemorySyncSecretStore secrets;
  late SyncStateStore state;
  late FakeSightingTransport lan;
  late SyncTransportRuntime runtime;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    secrets = MemorySyncSecretStore();
    state = SyncStateStore(
      preferences: prefs,
      secrets: secrets,
      clock: () => 7000,
      deviceId: 'devA',
    );
    await state.init();
    await state.writePassphrase('ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789');
    lan = FakeSightingTransport();
    runtime = SyncTransportRuntime(state: state, transports: {'lan': lan});
  });

  test('ensureRunning 只启动已启用传输且幂等', () async {
    await runtime.ensureRunning();
    expect(lan.isRunning, isFalse, reason: '未启用 = 总闸关着');

    await state.setTransportEnabled(SyncTransportKind.lan, true);
    await runtime.ensureRunning();
    expect(lan.isRunning, isTrue);
    expect(lan.startCount, 1);

    await runtime.ensureRunning();
    expect(lan.startCount, 1, reason: '已运行不重复 start');
  });

  test('stop / stopAll 只停运行中的传输', () async {
    await state.setTransportEnabled(SyncTransportKind.lan, true);
    await runtime.ensureRunning();

    await runtime.stop(SyncTransportKind.lan);
    expect(lan.isRunning, isFalse);

    await runtime.ensureRunning();
    expect(lan.isRunning, isTrue);
    await runtime.stopAll();
    expect(lan.isRunning, isFalse);
  });

  test('生命周期只通知已启用且实现 SyncLanLifecycle 的传输', () async {
    await runtime.onAppResumed();
    runtime.onAppHidden();
    expect(lan.resumeCalls, 0);
    expect(lan.hiddenCalls, 0);

    await state.setTransportEnabled(SyncTransportKind.lan, true);
    await runtime.onAppResumed();
    runtime.onAppHidden();
    expect(lan.resumeCalls, 1);
    expect(lan.hiddenCalls, 1);

    await runtime.announceLocalChange(SyncTransportKind.lan);
    expect(lan.announceCalls, 1);
  });

  test('引擎与控制面共享同一运行时：启动只发生一次', () async {
    await state.setTransportEnabled(SyncTransportKind.lan, true);
    final engine = SyncEngine(
      state: state,
      stamps: state.stampIssuer,
      adapters: const [],
      transports: {'lan': lan},
      runtime: runtime,
      clock: () => DateTime.fromMillisecondsSinceEpoch(7000),
    );
    final control = SyncControlPlane(
      state: state,
      transports: {'lan': lan},
      runtime: runtime,
    );
    addTearDown(control.dispose);
    addTearDown(engine.dispose);

    await engine.init();
    await control.startTransports();
    expect(lan.startCount, 1);

    // 引擎轮次里的 ensure 看到已在运行，不再重复启动。
    await engine.syncNow(trigger: SyncTrigger.manual);
    expect(lan.startCount, 1);
  });
}
