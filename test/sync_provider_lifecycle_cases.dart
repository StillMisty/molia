import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_backup.dart';
import 'package:molia/data/sync/sync_control_plane.dart';
import 'package:molia/data/sync/sync_engine.dart';
import 'package:molia/data/sync/sync_scheduler.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/data/sync/transport/local_network_permission.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/ports/sync_transport.dart';
import 'package:molia/providers/sync_provider.dart';
import 'package:molia/services/battery_probe.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/sync_test_support.dart';

/// 应用生命周期接线：退后台必须先让传输停止发现，再跑 pause 轮。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('退后台：先隐藏传输，pause 轮不再广播（只走已知端点 HTTP）', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final state = SyncStateStore(
      preferences: prefs,
      secrets: MemorySyncSecretStore(),
      deviceId: 'devA',
    );
    await state.init();
    await state.writePassphrase('ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789');
    await state.setTransportEnabled(SyncTransportKind.lan, true);

    final transport = _OrderTransport();
    await transport.start();
    final engine = SyncEngine(
      state: state,
      stamps: state.stampIssuer,
      adapters: const [],
      transports: {SyncTransportKind.lan: transport},
    );
    await engine.init();
    final control = SyncControlPlane(
      state: state,
      transports: {SyncTransportKind.lan: transport},
    );
    final backup = SyncBackup(
      state: state,
      adapters: const [],
      stamps: state.stampIssuer,
      collect: engine.collectRecords,
    );
    final scheduler = SyncScheduler(
      host: engine,
      state: state,
      cellularProbe: () async => false,
      batteryProbe: () async => BatterySnapshot.unknown,
    );
    final provider = SyncProvider(
      engine: engine,
      controlPlane: control,
      backup: backup,
      scheduler: scheduler,
    );
    addTearDown(engine.dispose);
    addTearDown(control.dispose);
    addTearDown(provider.dispose);

    // 有本地变更才会在退后台时跑 pause 轮。
    provider.notifyLocalChange();
    provider.onAppHidden();

    await transport.pulled.future.timeout(const Duration(seconds: 2));
    expect(transport.hiddenCalls, 1);
    expect(
      transport.hiddenAtPull,
      1,
      reason: 'pause 轮开始时传输已进入后台：该轮不得广播',
    );
  });

  test('回前台复查权限：已开局域网且刚授权时启动传输，不再次请求', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final state = SyncStateStore(
      preferences: prefs,
      secrets: MemorySyncSecretStore(),
      deviceId: 'devA',
    );
    await state.init();
    await state.setTransportEnabled(SyncTransportKind.lan, true);
    final transport = FakeSyncTransport();
    final engine = SyncEngine(
      state: state,
      stamps: state.stampIssuer,
      adapters: const [],
      transports: {SyncTransportKind.lan: transport},
    );
    final control = SyncControlPlane(
      state: state,
      transports: {SyncTransportKind.lan: transport},
    );
    final backup = SyncBackup(
      state: state,
      adapters: const [],
      stamps: state.stampIssuer,
      collect: engine.collectRecords,
    );
    var checked = 0;
    var requested = 0;
    final permission = LocalNetworkPermission(
      needsPermission: true,
      check: () async {
        checked++;
        return LocalNetworkPermissionStatus.granted;
      },
      request: () async {
        requested++;
        return LocalNetworkPermissionStatus.granted;
      },
    );
    final provider = SyncProvider(
      engine: engine,
      controlPlane: control,
      backup: backup,
      lanPermission: permission,
    );
    addTearDown(engine.dispose);
    addTearDown(control.dispose);
    addTearDown(provider.dispose);

    await provider.onAppResumed();

    expect(checked, 1, reason: '回前台只复查状态');
    expect(requested, 0, reason: '已授权不应再弹权限窗');
    expect(transport.isRunning, isTrue, reason: '授权后立刻恢复局域网传输');
  });

  test('打开传输后立即跑一次 check 轮；关闭传输不触发', () async {
    final built = await _buildProviderWithScheduler();
    addTearDown(built.provider.dispose);
    addTearDown(built.control.dispose);
    addTearDown(built.engine.dispose);

    final pulled = Completer<void>();
    built.transport.onPull = () async {
      if (!pulled.isCompleted) pulled.complete();
    };
    await built.provider.setTransportEnabled(SyncTransportKind.lan, true);
    await pulled.future.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(built.provider.lastReport?.trigger, SyncTrigger.check);
    final beforeClose = built.transport.pullCount;
    await built.provider.setTransportEnabled(SyncTransportKind.lan, false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      built.transport.pullCount,
      beforeClose,
      reason: '关闭传输不触发检查轮',
    );
  });

  test('requestLanPermission 授权成功后自动启用并立即检查', () async {
    var requested = 0;
    final permission = LocalNetworkPermission(
      needsPermission: true,
      check: () async => LocalNetworkPermissionStatus.denied,
      request: () async {
        requested++;
        return LocalNetworkPermissionStatus.granted;
      },
    );
    final built = await _buildProviderWithScheduler(permission: permission);
    addTearDown(built.provider.dispose);
    addTearDown(built.control.dispose);
    addTearDown(built.engine.dispose);

    final pulled = Completer<void>();
    built.transport.onPull = () async {
      if (!pulled.isCompleted) pulled.complete();
    };
    expect(await built.provider.requestLanPermission(), isTrue);
    await pulled.future.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(requested, 1);
    expect(
      built.provider.enabledTransports,
      contains(SyncTransportKind.lan),
    );
    expect(built.provider.lastReport?.trigger, SyncTrigger.check);
  });

  test('保存 WebDAV 配置：启用且已配置才检查，关闭 / 未配置不触发', () async {
    final built = await _buildProviderWithScheduler(
      kind: SyncTransportKind.webdav,
    );
    addTearDown(built.provider.dispose);
    addTearDown(built.control.dispose);
    addTearDown(built.engine.dispose);

    // 未启用：保存配置和密码不触发检查轮。
    await built.provider.saveWebdavConfig(
      const WebDavConfig(baseUrl: 'https://dav.example.com/dav'),
      'secret',
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(built.transport.pullCount, 0);
    expect(built.provider.webdav.isConfigured, isTrue);

    // 启用但配置为空：仍不触发（没有可跑的地址）。
    await built.control.setTransportEnabled(SyncTransportKind.webdav, true);
    await built.provider.saveWebdavConfig(const WebDavConfig(), 'secret');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(built.transport.pullCount, 0);

    // 启用且已配置：保存后立即跑一次 check 轮。
    final pulled = Completer<void>();
    built.transport.onPull = () async {
      if (!pulled.isCompleted) pulled.complete();
    };
    await built.provider.saveWebdavConfig(
      const WebDavConfig(baseUrl: 'https://dav.example.com/dav'),
      'secret',
    );
    await pulled.future.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(built.provider.lastReport?.trigger, SyncTrigger.check);
  });

  test('回前台：局域网关闭且从未申请过时不查询权限，避免误显示警告', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final state = SyncStateStore(
      preferences: prefs,
      secrets: MemorySyncSecretStore(),
      deviceId: 'devA',
    );
    await state.init();
    final transport = FakeSyncTransport();
    final engine = SyncEngine(
      state: state,
      stamps: state.stampIssuer,
      adapters: const [],
      transports: {SyncTransportKind.lan: transport},
    );
    final control = SyncControlPlane(
      state: state,
      transports: {SyncTransportKind.lan: transport},
    );
    final backup = SyncBackup(
      state: state,
      adapters: const [],
      stamps: state.stampIssuer,
      collect: engine.collectRecords,
    );
    var checked = 0;
    final permission = LocalNetworkPermission(
      needsPermission: true,
      check: () async {
        checked++;
        return LocalNetworkPermissionStatus.denied;
      },
    );
    final provider = SyncProvider(
      engine: engine,
      controlPlane: control,
      backup: backup,
      lanPermission: permission,
    );
    addTearDown(engine.dispose);
    addTearDown(control.dispose);
    addTearDown(provider.dispose);

    await provider.onAppResumed();

    expect(checked, 0, reason: '没开局域网、也没申请过，不应主动查询');
    expect(permission.needsUserAction, isFalse);
  });
}

Future<
    ({
      FakeSyncTransport transport,
      SyncEngine engine,
      SyncControlPlane control,
      SyncScheduler scheduler,
      SyncProvider provider,
    })> _buildProviderWithScheduler({
  LocalNetworkPermission? permission,
  String kind = SyncTransportKind.lan,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final state = SyncStateStore(
    preferences: prefs,
    secrets: MemorySyncSecretStore(),
    deviceId: 'devA',
  );
  await state.init();
  final transport = FakeSyncTransport(kind: kind);
  final engine = SyncEngine(
    state: state,
    stamps: state.stampIssuer,
    adapters: const [],
    transports: {kind: transport},
  );
  await engine.init();
  final control = SyncControlPlane(
    state: state,
    transports: {kind: transport},
  );
  final backup = SyncBackup(
    state: state,
    adapters: const [],
    stamps: state.stampIssuer,
    collect: engine.collectRecords,
  );
  final scheduler = SyncScheduler(
    host: engine,
    state: state,
    cellularProbe: () async => false,
    batteryProbe: () async => BatterySnapshot.unknown,
  );
  final provider = SyncProvider(
    engine: engine,
    controlPlane: control,
    backup: backup,
    scheduler: scheduler,
    lanPermission: permission,
  );
  await provider.init();
  return (
    transport: transport,
    engine: engine,
    control: control,
    scheduler: scheduler,
    provider: provider,
  );
}

/// 记录 pull 时传输是否已经被隐藏的假传输。
class _OrderTransport extends FakeSightingTransport {
  final Completer<void> pulled = Completer<void>();
  int hiddenAtPull = -1;

  @override
  Future<SyncPullResult> pull([
    SyncPullRequest request = SyncPullRequest.none,
  ]) {
    hiddenAtPull = hiddenCalls;
    if (!pulled.isCompleted) pulled.complete();
    return super.pull(request);
  }
}
