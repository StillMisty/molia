import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_control_plane.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/ports/sync_transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/sync_test_support.dart';

/// 同步控制面：身份 / 类别 / 传输开关与运行状态 / 手动地址簿 / 口令生命周期。
///
/// 引擎测试只关心「跑一轮」；这里覆盖 UI 面必须自己保证的状态迁移与通知
/// （改状态 → 起停传输 → notifyListeners 同进同退）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late MemorySyncSecretStore secrets;
  late SyncStateStore state;
  late FakeSightingTransport lan;
  late SyncControlPlane control;
  var now = 7000;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    secrets = MemorySyncSecretStore();
    now = 7000;
    state = SyncStateStore(
      preferences: prefs,
      secrets: secrets,
      clock: () => now,
      deviceId: 'devA',
    );
    await state.init();
    await state.writePassphrase('ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789');
    lan = FakeSightingTransport();
    control = SyncControlPlane(state: state, transports: {'lan': lan});
  });

  tearDown(() => control.dispose());

  test('观测面镜像状态存储：身份 / 类别 / 开关 / 地址簿 / 时钟', () {
    expect(control.enabled, isFalse);
    expect(control.deviceId, 'devA');
    expect(control.deviceName, isNotEmpty);
    expect(control.categories.values.every((on) => on), isTrue);
    expect(control.enabledTransports, isEmpty);
    expect(control.webdav.isConfigured, isFalse);
    expect(control.manualPeers, isEmpty);
    expect(control.lastSyncAt, 0);
    expect(control.log, isEmpty);
    expect(control.peers, isEmpty);
    expect(control.activity, isEmpty);
    expect(control.lanHttpPort, 0);
    expect(control.cellularPolicy, SyncCellularPolicy.auto);
    expect(control.nowMs(), 7000);
    expect(control.transportLastSuccessAt('lan'), 0);
  });

  test('hasEstablishedGroup：名册非空即成立', () {
    expect(control.hasEstablishedGroup, isFalse);
    state.recordRound(const SyncRoundReport(
      trigger: SyncTrigger.manual,
      startedAt: 1,
      finishedAt: 2,
      outcome: SyncOutcome.noChanges,
      peers: [SyncPeerState(deviceId: 'devB')],
    ));
    expect(control.hasEstablishedGroup, isTrue);
  });

  test('hasEstablishedGroup：任一路传输成功接触过对端也成立', () {
    expect(control.hasEstablishedGroup, isFalse);
    state.recordRound(const SyncRoundReport(
      trigger: SyncTrigger.manual,
      startedAt: 1,
      finishedAt: 2,
      outcome: SyncOutcome.ok,
      transports: [
        SyncTransportReport(
          kind: SyncTransportKind.lan,
          running: true,
          enabled: true,
          pulled: 1,
        ),
      ],
    ));
    expect(control.transportLastSuccessAt(SyncTransportKind.lan), 2);
    expect(control.hasEstablishedGroup, isTrue);
  });

  test('init 幂等；写入类操作改状态并通知一次', () async {
    var notifications = 0;
    control.addListener(() => notifications++);

    await control.init();
    await control.init();
    expect(notifications, 1, reason: '重复 init 不重复通知');

    await control.setCategory(SyncCategory.settings, false);
    expect(control.categories[SyncCategory.settings], isFalse);
    expect(state.categories[SyncCategory.settings], isFalse);

    await control.setDeviceName('书房');
    expect(control.deviceName, '书房');
    expect(state.deviceName, '书房');

    await control.setWebdavConfig(
      const WebDavConfig(baseUrl: 'https://dav.example.com', username: 'u'),
    );
    expect(control.webdav.baseUrl, 'https://dav.example.com');

    await control.setCellularPolicy(SyncCellularPolicy.pause);
    expect(control.cellularPolicy, SyncCellularPolicy.pause);
    expect(state.cellularPolicy, SyncCellularPolicy.pause);

    expect(notifications, 5);
  });

  test('传输开关：开启启动、重复开启幂等、关闭停止', () async {
    expect(control.enabled, isFalse);
    expect(lan.isRunning, isFalse);

    await control.setTransportEnabled(SyncTransportKind.lan, true);
    expect(control.enabled, isTrue);
    expect(control.enabledTransports, {SyncTransportKind.lan});
    expect(lan.isRunning, isTrue);
    expect(lan.startCount, 1);

    // 重复开启不重启（start 幂等由控制面守住）。
    await control.setTransportEnabled(SyncTransportKind.lan, true);
    expect(lan.startCount, 1);

    await control.setTransportEnabled(SyncTransportKind.lan, false);
    expect(control.enabled, isFalse);
    expect(lan.isRunning, isFalse);
  });

  test('startTransports 只启动已启用的传输；未启用时不动', () async {
    await control.startTransports();
    expect(lan.isRunning, isFalse, reason: '两路都关 = 同步停摆');

    await state.setTransportEnabled(SyncTransportKind.lan, true);
    await control.startTransports();
    expect(lan.isRunning, isTrue);

    final started = lan.startCount;
    await control.startTransports();
    expect(lan.startCount, started, reason: '重复调用不重启');
  });

  test('传输状态：未知 kind 返回 null，停止时给出启动类失败原因', () async {
    expect(control.transportStatus('nope'), isNull);

    final disabled = control.transportStatus(SyncTransportKind.lan)!;
    expect(disabled.enabled, isFalse);
    expect(disabled.running, isFalse);
    expect(disabled.error, isNull);

    await control.setTransportEnabled(SyncTransportKind.lan, true);
    await lan.stop();
    lan.unavailableReason = SyncUnavailableReason.startFailed;
    lan.unavailableDetail = 'SocketException: 端口占用';

    final failed = control.transportStatus(SyncTransportKind.lan)!;
    expect(failed.enabled, isTrue);
    expect(failed.running, isFalse);
    expect(failed.unavailableReason, SyncUnavailableReason.startFailed);
    expect(failed.error?.code, SyncUnavailableReason.startFailed);
    expect(failed.error?.detail, contains('SocketException'));
  });

  test('探测端口按局域网传输分族暴露', () {
    expect(control.lanDiscoveryPorts, (v4: 0, v6: 0));
    lan.discoveryPortsOverride = (v4: 47825, v6: 47826);
    expect(control.lanDiscoveryPorts, (v4: 47825, v6: 47826));
  });

  test('手动地址簿：添加 / 更新 / 删除', () async {
    expect(
      await control.addManualPeer(const ManualPeer(host: '192.168.1.23')),
      isTrue,
    );
    expect(
      await control.addManualPeer(
        const ManualPeer(host: '192.168.1.23', name: '书房'),
      ),
      isFalse,
      reason: '同一地址按地址合并',
    );
    expect(control.manualPeers.single.name, '书房');

    await control.moveManualPeer('192.168.1.23', toHost: '192.168.1.24');
    expect(control.manualPeers.single.host, '192.168.1.24');

    await control.removeManualPeer('192.168.1.24');
    expect(control.manualPeers, isEmpty);
  });

  test('移除设备与远端清理：只经启用传输动作', () async {
    state.recordRound(SyncRoundReport(
      trigger: SyncTrigger.timer,
      startedAt: 0,
      finishedAt: 1,
      outcome: SyncOutcome.ok,
      peers: const [SyncPeerState(deviceId: 'ghost', name: '幽灵')],
    ));
    await control.addManualPeer(
      const ManualPeer(host: '192.168.1.23', deviceId: 'ghost'),
    );
    expect(control.peers, hasLength(1));

    var notifications = 0;
    control.addListener(() => notifications++);
    await control.removePeer('ghost');
    expect(control.peers, isEmpty, reason: '名册条目被移除');
    expect(control.manualPeers, isEmpty, reason: '地址簿条目一并移除');
    expect(notifications, 1);

    // 未启用传输不动作（与旧引擎语义一致：没有通道就没有远端可清）。
    expect((await control.cleanupRemote('ghost')).removed, isFalse);
    expect(lan.deletedRemotes, isEmpty);

    await control.setTransportEnabled(SyncTransportKind.lan, true);
    lan.deleteRemoteResult = true;
    final result = await control.cleanupRemote('ghost');
    expect(result.removed, isTrue);
    expect(result.error, isNull);
    expect(lan.deletedRemotes, ['ghost']);

    lan.deleteRemoteThrows = true;
    final failed = await control.cleanupRemote('ghost');
    expect(failed.removed, isFalse);
    expect(failed.error?.code, SyncIssueCode.deleteRemoteFailed);
  });

  test('口令生命周期：读取 / 生成 / 保存 / 重置与打码', () async {
    expect(await control.readPassphrase(), isNotNull);
    expect(control.passphrase, isNotNull);
    expect(control.maskedPassphrase, startsWith('ABCD-'));
    expect(control.maskedPassphrase, contains('*'));
    expect(control.maskedPassphrase, isNot(contains('EFGH')));

    final reset = await control.resetPassphrase();
    expect(control.passphrase, reset);
    expect(await state.readPassphrase(), reset);
    expect(reset, isNot('ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789'));

    await control.setPassphrase('ZZZZ-YYYY-XXXX-WWWW-VVVV-UUUU-3333-2222');
    expect(control.passphrase, 'ZZZZ-YYYY-XXXX-WWWW-VVVV-UUUU-3333-2222');
    expect(
      await state.readPassphrase(),
      'ZZZZ-YYYY-XXXX-WWWW-VVVV-UUUU-3333-2222',
    );
  });

  test('ensurePassphrase：已有口令不重新生成，缺失时生成并通知', () async {
    final existing = await control.ensurePassphrase();
    expect(
      existing,
      'ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789',
      reason: '已有口令原样返回',
    );

    final freshState = SyncStateStore(
      preferences: prefs,
      secrets: MemorySyncSecretStore(),
      clock: () => now,
      deviceId: 'devC',
    );
    final freshControl = SyncControlPlane(state: freshState, transports: {});
    addTearDown(freshControl.dispose);
    var notifications = 0;
    freshControl.addListener(() => notifications++);
    final generated = await freshControl.ensurePassphrase();
    expect(generated, isNotEmpty);
    expect(freshControl.passphrase, generated);
    expect(await freshState.readPassphrase(), generated);
    expect(notifications, 1);
  });

  test('WebDAV 密码读写走安全存储', () async {
    expect(await control.readWebdavPassword(), isNull);
    await control.writeWebdavPassword('dav-secret');
    expect(await control.readWebdavPassword(), 'dav-secret');
    expect(
        secrets.values[SyncStateStore.webdavPasswordSecretKey], 'dav-secret');
  });

  test('生命周期：只对已启用且实现 SyncLanLifecycle 的传输调用', () async {
    // 未启用：不动作（总闸关着就不碰传输运行时）。
    await control.onAppResumed();
    control.onAppHidden();
    expect(lan.resumeCalls, 0);
    expect(lan.hiddenCalls, 0);

    await control.setTransportEnabled(SyncTransportKind.lan, true);
    await control.onAppResumed();
    control.onAppHidden();
    expect(lan.resumeCalls, 1);
    expect(lan.hiddenCalls, 1);
  });
}
