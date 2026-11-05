import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_backup.dart';
import 'package:molia/data/sync/sync_control_plane.dart';
import 'package:molia/data/sync/sync_engine.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/ports/sync_transport.dart';
import 'package:molia/providers/sync_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/sync_test_support.dart';

/// 手动地址表单的唯一命令：地址入簿 → 附近设备探测 → 立即接触。
///
/// 只断言 provider 编排（顺序与结果映射），传输 / 配对都是内存假实现。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('新增 + 探测成功：只提示已发出探测，不再跑接触轮', () async {
    final harness = await _buildHarness();
    harness.pairing.probeResult = true;

    final outcome = await harness.provider.saveManualPeer(
      host: '[192.168.1.7]',
      probePort: 47825,
      name: '  书房 ',
    );

    expect(outcome, SyncManualPeerOutcome.probeSent);
    expect(harness.pairing.probes, [(host: '192.168.1.7', probePort: 47825)]);
    expect(harness.transport.pullCount, 0, reason: '探测路径不进入接触轮');
    final entry = harness.provider.manualPeers.single;
    expect(entry.host, '192.168.1.7', reason: '地址先归一（去方括号）');
    expect(entry.name, '书房', reason: '名称统一 trim');
    expect(entry.probePort, 47825);
  });

  test('新增 + 同步关闭：地址已入簿，接触按「稍后」返回', () async {
    final harness = await _buildHarness(enableTransport: false);

    final outcome = await harness.provider.saveManualPeer(
      host: '192.168.1.8',
      probePort: 47825,
    );

    expect(outcome, SyncManualPeerOutcome.contactQueued);
    expect(harness.provider.manualPeers.single.host, '192.168.1.8');
    expect(harness.transport.pullCount, 0, reason: '没有启用传输，不跑轮次');
  });

  test('编辑地址 + 接触成功：保留身份与已学端口，返回 updated', () async {
    final harness = await _buildHarness();
    await harness.state.addManualPeer(
      const ManualPeer(
        host: '10.0.0.9',
        name: '旧名',
        probePort: 47825,
        httpPort: 51234,
        deviceId: 'devB',
      ),
    );
    final editing = harness.provider.manualPeers.single;
    harness.transport.seenIdsOverride = const ['devB'];

    final outcome = await harness.provider.saveManualPeer(
      host: '10.0.0.10',
      probePort: 50000,
      name: ' 新名 ',
      editing: editing,
    );

    expect(outcome, SyncManualPeerOutcome.updated);
    final moved = harness.provider.manualPeers.single;
    expect(moved.host, '10.0.0.10');
    expect(moved.name, '新名');
    expect(moved.probePort, 50000);
    expect(moved.deviceId, 'devB', reason: '改地址不改身份');
    expect(moved.httpPort, 51234, reason: '已学到的端点端口保留');
  });

  test('本轮明确没连上：返回 unreachable，地址仍留在簿里', () async {
    final harness = await _buildHarness();

    final outcome = await harness.provider.saveManualPeer(
      host: '10.0.0.11',
      probePort: 47825,
    );

    expect(outcome, SyncManualPeerOutcome.unreachable);
    expect(harness.provider.manualPeers.single.host, '10.0.0.11');
    expect(harness.transport.pullCount, 1, reason: '已跑接触轮');
  });

  test('重复添加已配对地址：接触成功返回 updated，不新增第二条', () async {
    final harness = await _buildHarness();
    await harness.state.addManualPeer(
      const ManualPeer(host: '10.0.0.12', name: '旧名', deviceId: 'devB'),
    );
    harness.pairing.probeResult = true;
    harness.transport.seenIdsOverride = const ['devB'];

    final outcome = await harness.provider.saveManualPeer(
      host: '10.0.0.12',
      probePort: 47825,
      name: '新名',
    );

    expect(outcome, SyncManualPeerOutcome.updated);
    expect(harness.provider.manualPeers, hasLength(1));
    expect(harness.provider.manualPeers.single.name, '新名');
    expect(harness.transport.pullCount, 1, reason: '已配对地址跳过探测即返回');
  });
}

Future<
  ({
    SyncProvider provider,
    SyncStateStore state,
    FakeSyncTransport transport,
    FakeSyncPairingPort pairing,
  })
>
_buildHarness({bool enableTransport = true}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final state = SyncStateStore(
    preferences: prefs,
    secrets: MemorySyncSecretStore(),
    deviceId: 'devA',
  );
  await state.init();
  await state.writePassphrase('ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789');
  if (enableTransport) {
    await state.setTransportEnabled(SyncTransportKind.lan, true);
  }
  final transport = FakeSyncTransport();
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
  final pairing = FakeSyncPairingPort();
  final provider = SyncProvider(
    engine: engine,
    controlPlane: control,
    backup: backup,
    pairing: pairing,
  );
  addTearDown(engine.dispose);
  addTearDown(control.dispose);
  addTearDown(provider.dispose);
  return (
    provider: provider,
    state: state,
    transport: transport,
    pairing: pairing,
  );
}
