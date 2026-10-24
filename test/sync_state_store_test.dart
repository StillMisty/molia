import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/settings_secret_store.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/ports/sync_transport.dart';
import 'package:shared_preferences/shared_preferences.dart';
// 仅测试用：模拟平台写入返回 false（不是 lib 的依赖）。
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

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

  test('设备身份独立持久化：状态 JSON 损坏、prefs 键丢失都能恢复', () async {
    final prefs = await SharedPreferences.getInstance();
    final secrets = MemorySyncSecretStore();
    final store = SyncStateStore(
      preferences: prefs,
      secrets: secrets,
      clock: () => 1000,
    );
    await store.init();
    final id = store.deviceId;
    expect(id, isNotEmpty);
    expect(prefs.getString(SyncStateStore.deviceIdKey), id);
    // 安全存储备份是首帧后的动作：显式触发一次再断言（见 backupDeviceId）。
    await store.backupDeviceId();
    expect(secrets.values[SyncStateStore.deviceIdKey], id);

    // 大状态 JSON 损坏：身份从小键恢复，不生成新设备。
    await prefs.setString(SyncStateStore.stateKey, '{broken');
    final recovered = SyncStateStore(
      preferences: prefs,
      secrets: secrets,
      clock: () => 1000,
    );
    await recovered.init();
    expect(recovered.deviceId, id);

    // 状态 JSON 与小键都丢：安全存储备份仍能恢复同一身份。
    await prefs.remove(SyncStateStore.stateKey);
    await prefs.remove(SyncStateStore.deviceIdKey);
    final fromSecret = SyncStateStore(
      preferences: prefs,
      secrets: secrets,
      clock: () => 1000,
    );
    await fromSecret.init();
    expect(fromSecret.deviceId, id);
  });

  test('身份从状态 JSON 回填到独立键与安全存储', () async {
    final prefs = await SharedPreferences.getInstance();
    final secrets = MemorySyncSecretStore();
    await prefs.setString(
      SyncStateStore.stateKey,
      '{"v":2,"deviceId":"devA","transports":[]}',
    );
    await prefs.setBool(SyncStateStore.derivedResetKey, true);
    final store = SyncStateStore(
      preferences: prefs,
      secrets: secrets,
      clock: () => 1000,
    );
    await store.init();
    await store.backupDeviceId();

    expect(store.freshInstall, isFalse, reason: '新 key 已存在且派生清理标记已完成 = 不是首次清理');
    expect(store.deviceId, 'devA');
    expect(prefs.getString(SyncStateStore.deviceIdKey), 'devA');
    expect(secrets.values[SyncStateStore.deviceIdKey], 'devA');
  });

  test('旧命名空间完全不读：旧 key 存在也按全新安装处理', () async {
    final prefs = await SharedPreferences.getInstance();
    final secrets = MemorySyncSecretStore();
    await prefs.setString(
      'sync_state_v1',
      '{"v":2,"deviceId":"devA","enabled":true,"transports":["lan"]}',
    );
    await prefs.setString('sync_device_id_v1', 'devA');
    await secrets.write('sync_passphrase_v1', 'OLD-PASS');
    await secrets.write('sync_webdav_password_v1', 'old-webdav');

    final store = SyncStateStore(
      preferences: prefs,
      secrets: secrets,
      clock: () => 1000,
    );
    await store.init();

    expect(store.freshInstall, isTrue);
    expect(store.deviceId, isNotEmpty);
    expect(store.deviceId, isNot('devA'), reason: '旧身份不读，生成新身份');
    expect(store.enabled, isFalse, reason: '同步关闭 = 全新安装行为');
    expect(await store.readPassphrase(), isNull, reason: '旧口令不读');
    expect(await store.readWebdavPassword(), isNull, reason: '旧密码不读');
    expect(prefs.getString(SyncStateStore.stateKey), isNotNull);
    // 旧 key 不删、不改、不迁移。
    expect(prefs.getString('sync_state_v1'), isNotNull);
    expect(prefs.getString('sync_device_id_v1'), 'devA');
    expect(secrets.values['sync_passphrase_v1'], 'OLD-PASS');
    expect(secrets.values['sync_webdav_password_v1'], 'old-webdav');
  });

  test('派生清理标记缺失：即使新 key 已存在也仍需清理；写入后跨实例保持', () async {
    final first = await freshStore();
    expect(first.freshInstall, isTrue);

    // init 已写入 sync_state_v2，但派生清理标记还没写：模拟进程在清理前被杀。
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(SyncStateStore.stateKey), isNotNull);
    expect(prefs.getBool(SyncStateStore.derivedResetKey), isNull);
    final pending = await freshStore();
    expect(pending.freshInstall, isTrue);

    await pending.markFreshHandled();
    expect(prefs.getBool(SyncStateStore.derivedResetKey), isTrue);

    final handled = await freshStore();
    expect(handled.freshInstall, isFalse);
  });

  test('自定义封面类别默认关闭；封面登记 / 墓碑跨实例持久化', () async {
    final first = await freshStore();
    expect(first.categories[SyncCategory.covers], isFalse);
    expect(first.isCategoryEnabled(SyncCategory.covers), isFalse);
    first.putCoverStamp(
      'wy:1',
      const SyncStamp(
        hash: 'h-cover',
        version: SyncVersion(physical: 2000, counter: 1),
      ),
    );
    first.putCoverTombstone(
      'wy:2',
      const SyncStamp(version: SyncVersion(physical: 2001)),
    );
    await first.commit();

    final reloaded = await freshStore();
    expect(reloaded.coverStamps['wy:1']!.hash, 'h-cover');
    expect(reloaded.coverStamps['wy:1']!.version.physical, 2000);
    expect(reloaded.coverTombstones['wy:2']!.version.physical, 2001);
    expect(reloaded.isCategoryEnabled(SyncCategory.covers), isFalse,
        reason: '缺失 / 旧状态都按默认关闭');

    await reloaded.setCategory(SyncCategory.covers, true);
    final enabled = await freshStore();
    expect(enabled.isCategoryEnabled(SyncCategory.covers), isTrue);
  });

  test('所有身份备份都不存在时才生成新 id，之后跨实例保持', () async {
    final prefs = await SharedPreferences.getInstance();
    final secrets = MemorySyncSecretStore();
    final store = SyncStateStore(
      preferences: prefs,
      secrets: secrets,
      clock: () => 1000,
    );
    await store.init();
    final id = store.deviceId;
    expect(id, isNotEmpty);

    final reloaded = SyncStateStore(
      preferences: prefs,
      secrets: secrets,
      clock: () => 1000,
    );
    await reloaded.init();
    expect(reloaded.deviceId, id);
  });

  test('移除设备：名册与地址簿一并清理，不写屏蔽标记', () async {
    final store = await freshStore();
    store.recordRound(SyncRoundReport(
      trigger: SyncTrigger.timer,
      startedAt: 0,
      finishedAt: 1,
      outcome: SyncOutcome.ok,
      peers: const [SyncPeerState(deviceId: 'devB', name: 'B')],
    ));
    await store.addManualPeer(
      const ManualPeer(host: '192.168.1.23', deviceId: 'devB'),
    );
    await store
        .addManualPeer(const ManualPeer(host: '10.0.0.9', deviceId: 'devC'));

    await store.removePeer('devB');
    expect(store.peers.where((peer) => peer.deviceId == 'devB'), isEmpty);
    expect(
      store.manualPeers.where((peer) => peer.deviceId == 'devB'),
      isEmpty,
      reason: '该设备的地址簿条目一并移除',
    );
    expect(
      store.manualPeers.where((peer) => peer.deviceId == 'devC'),
      hasLength(1),
      reason: '其它设备不受影响',
    );
  });

  test('重置旧组状态：清空观测并持久化，地址簿保留、移除标记不再压制', () async {
    final store = await freshStore();
    store.recordRound(SyncRoundReport(
      trigger: SyncTrigger.timer,
      startedAt: 0,
      finishedAt: 5,
      outcome: SyncOutcome.ok,
      peers: const [SyncPeerState(deviceId: 'devB', name: 'B')],
      transports: const [
        SyncTransportReport(
          kind: SyncTransportKind.lan,
          running: true,
          enabled: true,
          pulled: 1,
        ),
      ],
    ));
    await store.rememberLanEndpoint(const LanPeerEndpoint(
      deviceId: 'devB',
      host: '192.168.1.23',
      httpPort: 40000,
      verifiedAt: 4,
    ));
    store.markPeerConnectNotified('devB');
    await store.addManualPeer(
      const ManualPeer(host: '192.168.1.23', deviceId: 'devB'),
    );
    // 留下「刚移除」标记（另一台设备）：重置后不应再压制重新发现。
    await store.removePeer('devX');

    await store.resetGroupState();

    expect(store.peers, isEmpty);
    expect(store.lanEndpoints, isEmpty);
    expect(store.transportLastSuccessAt(SyncTransportKind.lan), 0);
    expect(store.isPeerConnectNotified('devB'), isFalse);
    expect(store.manualPeers.single.host, '192.168.1.23');

    store.recordRound(SyncRoundReport(
      trigger: SyncTrigger.timer,
      startedAt: 6,
      finishedAt: 7,
      outcome: SyncOutcome.ok,
      peers: const [SyncPeerState(deviceId: 'devX')],
    ));
    expect(store.peers.single.deviceId, 'devX', reason: '移除标记随旧组一并清空，重新发现立即入册');

    await store.commit();
    final reloaded = await freshStore();
    expect(reloaded.peers, hasLength(1));
    expect(reloaded.lanEndpoints, isEmpty, reason: '清空结果已持久化');
    expect(reloaded.transportLastSuccessAt(SyncTransportKind.lan), 0);
    expect(reloaded.isPeerConnectNotified('devB'), isFalse);
    expect(reloaded.manualPeers.single.host, '192.168.1.23');
  });

  test('名册 lastSuccessAt：持久化往返；旧状态缺字段按 0 兼容兜底', () async {
    final store = await freshStore();
    store.recordRound(SyncRoundReport(
      trigger: SyncTrigger.timer,
      startedAt: 500,
      finishedAt: 1000,
      outcome: SyncOutcome.ok,
      peers: const [
        SyncPeerState(
          deviceId: 'devB',
          lastSeenAt: 900,
          lastSuccessAt: 800,
          lastPullAt: 700,
        ),
      ],
    ));
    await store.commit();

    final reloaded = await freshStore();
    expect(reloaded.peers.single.lastSuccessAt, 800);

    // 旧 JSON 没有 lastSuccessAt：0 = 未知，派生值取数据时间与最后尝试中
    // 较新者（900 是后来探测成功的证据，不能被 700 的数据时间盖过）。
    final old = SyncPeerState.fromJson({
      'deviceId': 'devC',
      'lastSeenAt': 900,
      'lastPullAt': 700,
    })!;
    expect(old.lastSuccessAt, 0);
    expect(old.effectiveLastSuccessAt, 900);
    // 只有数据时间（没有尝试记录）：仍按最近数据流转兜底。
    final dataOnly = SyncPeerState.fromJson({
      'deviceId': 'devE',
      'lastPullAt': 700,
    })!;
    expect(dataOnly.effectiveLastSuccessAt, 700);
    // 只有尝试、没有失败记录：旧名册按「最后尝试」兜底，不显示成从未连上。
    final legacy = SyncPeerState.fromJson({
      'deviceId': 'devD',
      'lastSeenAt': 900,
    })!;
    expect(legacy.effectiveLastSuccessAt, 900);
  });

  test('失联按最后一次成功接触计算，失败尝试不续命', () {
    const now = 2 * SyncPeerState.lostThresholdMs;
    final failedRecently = SyncPeerState(
      deviceId: 'devB',
      lastSeenAt: now,
      lastSuccessAt: now - SyncPeerState.lostThresholdMs - 1,
      lastError: const SyncIssue(code: SyncIssueCode.peerReadFailed),
    );
    expect(failedRecently.isLostAt(now), isTrue);

    final succeededRecently = SyncPeerState(
      deviceId: 'devC',
      lastSeenAt: now - SyncPeerState.lostThresholdMs - 1,
      lastSuccessAt: now,
    );
    expect(succeededRecently.isLostAt(now), isFalse);
  });

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

  test('更新地址：身份与已学端口保留；目标地址已有条目时并入', () async {
    final store = await freshStore();
    await store.addManualPeer(const ManualPeer(
      host: '192.168.1.23',
      deviceId: 'devB',
      name: '书房',
      probePort: 47825,
      httpPort: 40000,
    ));
    await store.addManualPeer(const ManualPeer(host: '192.168.1.99'));

    await store.moveManualPeer(
      '192.168.1.23',
      toHost: '192.168.1.99',
      probePort: 47825,
      name: '书房',
    );

    expect(store.manualPeers, hasLength(1), reason: '同一地址不重复入簿');
    final moved = store.manualPeers.single;
    expect(moved.host, '192.168.1.99');
    expect(moved.deviceId, 'devB', reason: '改的是「设备在哪」，不是「是谁」');
    expect(moved.httpPort, 40000, reason: '已学到的端点端口保留');
    expect(moved.name, '书房');
  });

  test('首次连通标记：登记后持久化；设备从本机移除时清掉', () async {
    final store = await freshStore();
    await store.addManualPeer(
        const ManualPeer(host: '192.168.1.23', deviceId: 'devB'));
    await store.addManualPeer(
        const ManualPeer(host: '2409:8a55::9', deviceId: 'devB'));

    expect(store.isPeerConnectNotified('devB'), isFalse);
    store.markPeerConnectNotified('devB');
    await store.commit();
    final reloaded = await freshStore();
    expect(reloaded.isPeerConnectNotified('devB'), isTrue, reason: '跨实例保持');

    // 还有一条地址：标记保留（设备仍在地址簿里）。
    await reloaded.removeManualPeer('192.168.1.23');
    expect(reloaded.isPeerConnectNotified('devB'), isTrue);

    // 从本机移除设备：标记清掉，重新配对值得再提示一次。
    await reloaded.removePeer('devB');
    expect(reloaded.isPeerConnectNotified('devB'), isFalse);
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

    await store.commit();
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

  test('平台拒绝写入：保持脏标记、不计数，下一次提交重试成功', () async {
    SharedPreferences.resetStatic();
    final platform = _FailingPrefsStore();
    SharedPreferencesStorePlatform.instance = platform;
    addTearDown(() => SharedPreferences.setMockInitialValues({}));

    final prefs = await SharedPreferences.getInstance();
    final store = SyncStateStore(
      preferences: prefs,
      secrets: MemorySyncSecretStore(),
      clock: () => 1000,
    );
    // 先把首装状态提交干净，建立写盘计数基线。
    await store.init();
    await store.commit();
    final writesBefore = store.persistedWrites;

    store.recordRound(const SyncRoundReport(
      trigger: SyncTrigger.timer,
      startedAt: 1,
      finishedAt: 2,
      outcome: SyncOutcome.noChanges,
    ));
    platform.fail = true;
    await store.commit();

    expect(
      store.persistedWrites,
      writesBefore,
      reason: '平台返回 false 不能算成功写盘',
    );
    expect(platform.failures, greaterThan(0));

    platform.fail = false;
    await store.commit();

    expect(
      store.persistedWrites,
      writesBefore + 1,
      reason: '脏标记保留，下一次提交重试成功',
    );
  });

  test('已知端点：持久化往返（host / 端口 / 验证时间）', () async {
    final store = await freshStore();
    await store.rememberLanEndpoint(const LanPeerEndpoint(
      deviceId: 'devB',
      host: '192.168.1.23',
      httpPort: 40000,
      probePort: 47825,
      verifiedAt: 1234,
    ));
    await store.commit();

    final reloaded = await freshStore();
    expect(reloaded.lanEndpoints, hasLength(1));
    final endpoint = reloaded.lanEndpoints.single;
    expect(endpoint.deviceId, 'devB');
    expect(endpoint.host, '192.168.1.23');
    expect(endpoint.httpPort, 40000);
    expect(endpoint.probePort, 47825);
    expect(endpoint.verifiedAt, 1234);
  });

  test('已知端点：同一设备更新地址与验证时间，保留新观测没带的探测端口', () async {
    final store = await freshStore();
    await store.rememberLanEndpoint(const LanPeerEndpoint(
      deviceId: 'devB',
      host: '192.168.1.23',
      httpPort: 40000,
      probePort: 47825,
      verifiedAt: 1,
    ));
    await store.rememberLanEndpoint(const LanPeerEndpoint(
      deviceId: 'devB',
      host: '192.168.1.99',
      httpPort: 40001,
      verifiedAt: 2,
    ));

    final endpoint = store.lanEndpoints.single;
    expect(endpoint.host, '192.168.1.99');
    expect(endpoint.httpPort, 40001);
    expect(endpoint.probePort, 47825, reason: '新观测没带探测端口时保留旧值');
    expect(endpoint.verifiedAt, 2);
  });

  test('已知端点：仅 verifiedAt 前进只更新内存，不立即写盘', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = await freshStore();
    const endpoint = LanPeerEndpoint(
      deviceId: 'devB',
      host: '192.168.1.23',
      httpPort: 40000,
      probePort: 47825,
      verifiedAt: 1,
    );
    await store.rememberLanEndpoint(endpoint);
    await store.commit();
    final rawBefore = prefs.getString(SyncStateStore.stateKey);
    expect(rawBefore, isNotNull);

    await store.rememberLanEndpoint(endpoint.copyWith(verifiedAt: 2));

    expect(store.lanEndpoints.single.verifiedAt, 2, reason: '内存已更新');
    expect(
      prefs.getString(SyncStateStore.stateKey),
      rawBefore,
      reason: '仅验证时间前进不标脏（依赖引擎轮末 commit）',
    );

    // 轮末提交后跨实例可见。
    await store.commit();
    final reloaded = await freshStore();
    expect(reloaded.lanEndpoints.single.verifiedAt, 2);
  });

  test('已知端点：上限 32，按 verifiedAt 淘汰最旧', () async {
    final store = await freshStore();
    for (var i = 0; i < SyncStateStore.lanEndpointLimit + 8; i++) {
      await store.rememberLanEndpoint(LanPeerEndpoint(
        deviceId: 'dev$i',
        host: '192.168.1.${i + 1}',
        httpPort: 40000,
        probePort: 47825,
        verifiedAt: i + 1,
      ));
    }

    expect(store.lanEndpoints, hasLength(SyncStateStore.lanEndpointLimit));
    final ids = store.lanEndpoints.map((endpoint) => endpoint.deviceId).toSet();
    expect(ids.contains('dev0'), isFalse, reason: '最旧的 8 条被淘汰');
    expect(ids.contains('dev7'), isFalse);
    expect(ids.contains('dev8'), isTrue);
    expect(ids.contains('dev39'), isTrue);

    await store.commit();
    final reloaded = await freshStore();
    expect(reloaded.lanEndpoints, hasLength(SyncStateStore.lanEndpointLimit));
  });

  test('已知端点：180 天未验证随名册淘汰，近期验证保留', () async {
    final store = await freshStore();
    await store.rememberLanEndpoint(const LanPeerEndpoint(
      deviceId: 'old',
      host: '192.168.1.23',
      httpPort: 40000,
      verifiedAt: 1000,
    ));
    await store.rememberLanEndpoint(const LanPeerEndpoint(
      deviceId: 'fresh',
      host: '192.168.1.24',
      httpPort: 40000,
      verifiedAt: 1000 + SyncStateStore.lanEndpointRetentionMs,
    ));

    store.recordRound(SyncRoundReport(
      trigger: SyncTrigger.timer,
      startedAt: 0,
      finishedAt: 1000 + SyncStateStore.lanEndpointRetentionMs + 1,
      outcome: SyncOutcome.noChanges,
    ));

    expect(store.lanEndpoints.map((endpoint) => endpoint.deviceId), ['fresh']);
  });

  test('移除设备：已验证端点一并清理', () async {
    final store = await freshStore();
    await store.rememberLanEndpoint(const LanPeerEndpoint(
      deviceId: 'devB',
      host: '192.168.1.23',
      httpPort: 40000,
      verifiedAt: 1,
    ));

    await store.removePeer('devB');
    expect(store.lanEndpoints, isEmpty);
  });

  test('已知端点：不可路由地址 / 非法端口 / 空设备 id 丢弃', () async {
    final store = await freshStore();
    for (final endpoint in const [
      LanPeerEndpoint(
        deviceId: 'loopback',
        host: '127.0.0.1',
        httpPort: 40000,
        verifiedAt: 1,
      ),
      LanPeerEndpoint(
        deviceId: 'linkLocal',
        host: 'fe80::1',
        httpPort: 40000,
        verifiedAt: 1,
      ),
      LanPeerEndpoint(
        deviceId: 'hostname',
        host: 'example.com',
        httpPort: 40000,
        verifiedAt: 1,
      ),
      LanPeerEndpoint(
        deviceId: 'noPort',
        host: '192.168.1.23',
        httpPort: 0,
        verifiedAt: 1,
      ),
      LanPeerEndpoint(
        deviceId: 'badPort',
        host: '192.168.1.23',
        httpPort: 70000,
        verifiedAt: 1,
      ),
      LanPeerEndpoint(
        deviceId: '',
        host: '192.168.1.23',
        httpPort: 40000,
        verifiedAt: 1,
      ),
      LanPeerEndpoint(
        deviceId: 'badProbe',
        host: '192.168.1.23',
        httpPort: 40000,
        probePort: 70000,
        verifiedAt: 1,
      ),
      LanPeerEndpoint(
        deviceId: 'noVerifiedAt',
        host: '192.168.1.23',
        httpPort: 40000,
        verifiedAt: 0,
      ),
    ]) {
      await store.rememberLanEndpoint(endpoint);
    }
    expect(store.lanEndpoints, isEmpty);
  });

  test('已知端点：读取状态 JSON 时丢弃非法条目', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(SyncStateStore.derivedResetKey, true);
    await prefs.setString(
      SyncStateStore.stateKey,
      '{"v":2,"deviceId":"devA","lanEndpoints":['
      '{"deviceId":"ok","host":"192.168.1.23","httpPort":40000,"verifiedAt":1},'
      '{"deviceId":"bad","host":"127.0.0.1","httpPort":40000,"verifiedAt":1},'
      '{"deviceId":"bad2","host":"192.168.1.24","httpPort":0,"verifiedAt":1},'
      '{"deviceId":"missingVerified","host":"192.168.1.25","httpPort":40000},'
      '{"deviceId":"zeroVerified","host":"192.168.1.26","httpPort":40000,'
      '"verifiedAt":0}'
      ']}',
    );

    final store = await freshStore();
    expect(store.lanEndpoints, hasLength(1));
    expect(store.lanEndpoints.single.deviceId, 'ok');
  });

  // 安全存储读取容错（回归：WSLg / 容器等无系统钥匙串的环境里 libsecret
  // 抛异常，未捕获会打断 `main()` 的 `runApp` 之前部分，桌面端表现为
  // 「窗口已显示但没有首帧」的永久黑窗，见 pitfalls #31）。
  const store = SecureSettingsSecretStore();

  test('读取失败降级为「未设置」：返回 null，不抛异常', () async {
    // 单测环境没有 libsecret 平台实现：修复前这里会抛 MissingPluginException。
    expect(await store.read('sync_passphrase_v2'), isNull);
  });

  test('写入仍然抛出：用户主动操作要知道没存进去', () async {
    await expectLater(
      store.write('sync_passphrase_v2', 'secret'),
      throwsA(isA<Exception>()),
    );
  });

  test('SyncStateStore.readPassphrase 在无钥匙串时同样返回 null', () async {
    final state = SyncStateStore(secrets: store, deviceId: 'test-device');
    expect(await state.readPassphrase(), isNull);
    expect(await state.readWebdavPassword(), isNull);
  });
}

/// 可控的 prefs 平台：`fail = true` 时写入返回 false（不落盘）。
class _FailingPrefsStore extends InMemorySharedPreferencesStore {
  _FailingPrefsStore() : super.empty();

  bool fail = false;
  int failures = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (fail) {
      failures++;
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}
