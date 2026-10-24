import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/data/settings/settings_registry.dart';
import 'package:molia/data/sync/adapters/prefs_sync_adapter.dart';
import 'package:molia/data/sync/sync_control_plane.dart';
import 'package:molia/data/sync/sync_engine.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/ports/sync_transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/sync_test_support.dart';

/// 多设备名册处置：失联标记、从本机移除（只清名册 / 地址簿，不撤销授权）、
/// 显式清理远端文件（不做自动删除）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late SyncStateStore state;
  late FakeSyncTransport transport;
  late SyncEngine engine;
  late SyncControlPlane control;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    final secrets = MemorySyncSecretStore();
    state = SyncStateStore(
      preferences: prefs,
      secrets: secrets,
      clock: () => DateTime.now().millisecondsSinceEpoch,
    );
    await state.init();
    await state.setTransportEnabled(SyncTransportKind.lan, true);
    await state.writePassphrase('ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789');
    transport = FakeSyncTransport();
    control = SyncControlPlane(state: state, transports: {'lan': transport});
    engine = SyncEngine(
      state: state,
      stamps: state.stampIssuer,
      adapters: [
        PrefsSyncAdapter(
          state: state,
          settings: SettingsRegistry(
            keys: const [kThemeMode],
            preferences: prefs,
            secrets: secrets,
          ),
        ),
      ],
      transports: {'lan': transport},
    );
    await engine.init();
  });

  tearDown(() async {
    control.dispose();
    engine.dispose();
  });

  /// 往名册里注入一台设备（`lastSeenAt` 可控：失联阈值 = 180 天）。
  void seedPeer(String deviceId, {required int lastSeenAt}) {
    state.recordRound(SyncRoundReport(
      trigger: SyncTrigger.timer,
      startedAt: 0,
      finishedAt: 1,
      outcome: SyncOutcome.ok,
      peers: [
        SyncPeerState(
          deviceId: deviceId,
          name: deviceId,
          transport: SyncTransportKind.lan,
          lastSeenAt: lastSeenAt,
          cursorSeq: 3,
          ackedSeq: 3,
        ),
      ],
    ));
  }

  test('失联判定：超过阈值标记，未超阈值不标记', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    seedPeer('ghost', lastSeenAt: now - SyncPeerState.lostThresholdMs - 1000);
    seedPeer('alive', lastSeenAt: now);

    final peers = state.peers;
    expect(
        peers.firstWhere((p) => p.deviceId == 'ghost').isLostAt(now), isTrue);
    expect(
        peers.firstWhere((p) => p.deviceId == 'alive').isLostAt(now), isFalse);
    // 名册不自动删除失联设备：处置动作由用户显式选择。
    expect(peers, hasLength(2));
  });

  test('接触即更新最近接触：未变跳过（探测应答）的对端不误标失联', () async {
    final ancient = DateTime.now().millisecondsSinceEpoch -
        SyncPeerState.lostThresholdMs -
        1000;
    seedPeer('ghost', lastSeenAt: ancient);
    expect(state.peers.single.isLostAt(state.nowMs()), isTrue);

    // 本轮没有拉到任何内容（未变跳过 / 仅探测应答），但传输报告接触过它。
    transport.seenIdsOverride = ['ghost'];
    await engine.syncNow();

    final peer = state.peers.single;
    expect(peer.isLostAt(state.nowMs()), isFalse, reason: '接触即续期');
    expect(peer.lastSeenAt, greaterThan(ancient));
    expect(peer.lastPullAt, 0, reason: '没有数据流转，不算一次拉取');
  });

  test('移除设备：名册与地址簿一并清理，跨重启保持（离线设备）', () async {
    seedPeer('ghost', lastSeenAt: state.nowMs());
    await state.addManualPeer(
      const ManualPeer(host: '192.168.1.23', deviceId: 'ghost'),
    );
    expect(state.peers, hasLength(1));

    // provider 编排：先清引擎内存名册，再清状态。
    engine.forgetPeer('ghost');
    await control.removePeer('ghost');

    expect(state.peers, isEmpty);
    expect(state.manualPeers, isEmpty);
    await state.commit();

    final reloaded =
        SyncStateStore(preferences: prefs, secrets: MemorySyncSecretStore());
    await reloaded.init();
    expect(reloaded.peers, isEmpty, reason: '移除后重启不出现');
    expect(reloaded.manualPeers, isEmpty);
  });

  test('移除不是屏蔽：设备仍在线时下一轮重新出现', () async {
    seedPeer('ghost', lastSeenAt: state.nowMs());
    engine.forgetPeer('ghost');
    await control.removePeer('ghost');
    expect(state.peers, isEmpty);

    // 下一轮仍能发现它：第一轮压住在途快照，第二轮照常写回。
    transport.seenIdsOverride = const ['ghost'];
    await engine.syncNow();
    expect(
      state.peers.where((peer) => peer.deviceId == 'ghost'),
      isEmpty,
      reason: '删除当轮不被在途报告写回',
    );
    await engine.syncNow();
    expect(
      state.peers.where((peer) => peer.deviceId == 'ghost'),
      isNotEmpty,
      reason: '没有持久化屏蔽：在线设备会被重新发现',
    );
  });

  test('显式清理远端文件：调用各启用传输，返回结果不做自动删除', () async {
    transport.deleteRemoteResult = true;
    final result = await control.cleanupRemote('ghost');

    expect(result.removed, isTrue);
    expect(result.error, isNull);
    expect(transport.deletedRemotes, ['ghost']);

    // 没有可清理内容（局域网直连 / 已清理过）：removed = false，不是错误。
    transport.deleteRemoteResult = false;
    final again = await control.cleanupRemote('ghost');
    expect(again.removed, isFalse);
    expect(again.error, isNull);
  });

  test('清理远端文件失败：如实上报 delete_remote_failed（不吞成「没有可清理」）', () async {
    transport.deleteRemoteThrows = true;
    final result = await control.cleanupRemote('ghost');

    expect(result.removed, isFalse);
    expect(result.error?.code, SyncIssueCode.deleteRemoteFailed);
    expect(result.error?.args['peer'], 'ghost');
    // 原始异常只进 detail（UI 不展示）。
    expect(result.error?.detail, contains('清理失败（测试注入）'));
  });
}
