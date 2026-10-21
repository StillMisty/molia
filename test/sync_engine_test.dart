import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/data/settings/settings_registry.dart';
import 'package:molia/data/sync/adapters/prefs_sync_adapter.dart';
import 'package:molia/data/sync/sync_adapter.dart';
import 'package:molia/data/sync/sync_control_plane.dart';
import 'package:molia/data/sync/sync_engine.dart';
import 'package:molia/data/sync/sync_journal.dart';
import 'package:molia/data/sync/sync_known_store.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_database.dart';
import 'support/sync_test_support.dart';

/// 引擎测试：一轮同步的拉取 → 合并 → 应用 → 推送 → **报告与日志**。
///
/// 可观察性契约是主要覆盖对象：五态判定（尤其是「没发现对端」与「没有变化」
/// 必须分开）、设备名册、入站快照不丢、进行中的请求排队补跑。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const keys = [kThemeMode];

  late SharedPreferences prefs;
  late MemorySyncSecretStore secrets;
  late SyncStateStore state;
  late FakeSyncTransport transport;
  late SyncEngine engine;
  late SyncControlPlane control;

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
    await state.setTransportEnabled('lan', true);
    transport = FakeSyncTransport();
    control = SyncControlPlane(state: state, transports: {'lan': transport});
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
      // 入站合流窗口缩短：单测不用等默认的 1.5s。
      inboundWindow: const Duration(milliseconds: 10),
    );
    await engine.init();
  });

  tearDown(() {
    control.dispose();
    engine.dispose();
  });

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

    // 日志：触发原因 + 结论 + 本轮变更量。
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

  test('没有对端：结论是 noPeers，与「同步完成」区分', () async {
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

  test('拉取成功但推送全败且无落地：结论是 partial 而不是 failed', () async {
    // 拉到一个空快照：探测到对端、拉取成功，但没有可落地的记录。
    transport.available.add(SyncEnvelope(
      deviceId: 'devB',
      deviceName: 'B',
      producedAt: 5000,
      records: const {},
    ));
    transport.pushFailures = 1;
    final report = await engine.syncNow();

    // 有成功面（拉取）就不是「所有对端都联系不上」；报 push_failed 让用户知道
    // 哪一步坏了。
    expect(report!.outcome, SyncOutcome.partial);
    expect(report.error?.code, SyncIssueCode.pushFailed);
    expect(state.log.first.outcome, SyncOutcome.partial);
  });

  test('noPeers 不吞传输级错误：广播失败仍可见', () async {
    // 传输报告了错误但没有失败对端计数（如局域网广播被网络策略拒绝）。
    transport.pullError =
        const SyncIssue(code: SyncIssueCode.broadcastUnavailable);
    final report = await engine.syncNow();

    expect(report!.outcome, SyncOutcome.noPeers);
    expect(report.error?.code, SyncIssueCode.broadcastUnavailable);
    expect(state.log.first.error?.code, SyncIssueCode.broadcastUnavailable);
  });

  test('WebDAV 目录准备失败：结论是 failed 并带原因', () async {
    // 目录没准备好 = 一个对端都没接触上（failedPeers=1），推送同样失败：
    // 真实语义是整轮失败，不是「没发现对端」。
    transport.pullFailures = 1;
    transport.pullError = const SyncIssue(code: SyncIssueCode.webdavDirFailed);
    transport.pushFailures = 1;
    final report = await engine.syncNow();

    expect(report!.outcome, SyncOutcome.failed);
    expect(report.error?.code, SyncIssueCode.webdavDirFailed);
    expect(state.log.first.error?.code, SyncIssueCode.webdavDirFailed);
  });

  test('拉取动作成功（零快照）+ 推送全败：结论是 partial', () async {
    // WebDAV 首台设备：目录可读、还没有其他设备的快照，PUT 失败。
    // 远端可达是成功面，不能判成「所有对端都不可达」。
    transport.pullContacted = true;
    transport.pushFailures = 1;
    final report = await engine.syncNow();

    expect(report!.outcome, SyncOutcome.partial);
    expect(report.error?.code, SyncIssueCode.pushFailed);
    expect(state.log.first.outcome, SyncOutcome.partial);
  });

  test('名册 lastError：失败保留，成功接触才清除', () async {
    // 第一轮：推送失败 → 名册记 push_failed。
    transport.pushFailures = 1;
    transport.pushFailedIds = ['devB'];
    await engine.syncNow();
    expect(state.peers.single.lastError?.code, SyncIssueCode.pushFailed);

    // 第二轮：没有接触（无拉取、推送无失败 id）→ 失败状态保留。
    transport.pushFailures = 0;
    transport.pushFailedIds = const [];
    final quiet = await engine.syncNow();
    expect(quiet!.outcome, SyncOutcome.noPeers);
    expect(state.peers.single.lastError?.code, SyncIssueCode.pushFailed);

    // 第三轮：成功拉到该对端 → 接触成功，失败清除。
    transport.available.add(remoteTheme('dark'));
    await engine.syncNow();
    expect(state.peers.single.lastError, isNull);
  });

  test('传输异常不冒泡，报告里可见', () async {
    transport.peersSeenOverride = 1;
    transport.throwOnPull = true;
    final report = await engine.syncNow();

    // 拉取抛异常被传输边界吸收：本轮记为「部分失败」，原因进报告与日志，
    // 不冒泡给调用方（否则一次网络抖动就会打断调用链）。
    expect(report!.outcome, SyncOutcome.partial);
    expect(report.error?.code, SyncIssueCode.pullFailed);
    expect(report.error?.detail, contains('拉取失败'));
    expect(state.log.first.outcome, SyncOutcome.partial);
  });

  test('类别关闭：既不应用远端也不推送该类记录', () async {
    await control.setCategory(SyncCategory.settings, false);
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

  test('对端入站快照触发同步，且入站轮次不推送（防乒乓）', () async {
    await engine.onIncomingEnvelope(remoteTheme('light'));
    // 合流窗口结束后才跑入站轮。
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(prefs.getString('theme_mode'), 'light');
    expect(transport.pushed, isEmpty);
    expect(state.log.first.trigger, SyncTrigger.incoming);
    expect(state.log.first.outcome, SyncOutcome.ok);
  });

  test('入站合流：3 个对端先后推送只产生 1 轮', () async {
    // 三个对端在窗口内先后推送。
    await engine.onIncomingEnvelope(remoteTheme('light', deviceId: 'devB'));
    await engine.onIncomingEnvelope(remoteTheme('dark', deviceId: 'devC'));
    await engine.onIncomingEnvelope(remoteTheme('system', deviceId: 'devD'));
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(state.log, hasLength(1));
    expect(state.log.single.trigger, SyncTrigger.incoming);
    // 入站轮不拉取（不主动联系任何对端）。
    expect(transport.pullCount, 0);
    // 三次推送都消费了：最后一次（版本最大）生效。
    expect(prefs.getString('theme_mode'), 'system');
  });

  test('入站轮不推送、不拉取：只消费收到的快照', () async {
    transport.peersSeenOverride = 1;
    transport.available.add(remoteTheme('light'));
    await engine.onIncomingEnvelope(remoteTheme('dark'));
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(transport.pullCount, 0);
    expect(transport.pushed, isEmpty);
    expect(state.log, hasLength(1));
  });

  test('未设置口令：报告失败并写入日志', () async {
    await state.writePassphrase('');
    transport.available.add(remoteTheme('dark'));
    final report = await engine.syncNow();

    expect(report!.outcome, SyncOutcome.failed);
    expect(report.error?.code, SyncIssueCode.noPassphrase);
    expect(state.log.first.outcome, SyncOutcome.failed);
    expect(prefs.getString('theme_mode'), isNull);
  });

  test('首次使用新状态 key：engine.init 清空派生状态，不动用户数据与墓碑', () async {
    // 清掉 setUp 写下的新 key / 身份：模拟首次安装（旧 key 不参与判断）。
    await prefs.remove(SyncStateStore.stateKey);
    await prefs.remove(SyncStateStore.deviceIdKey);
    await prefs.remove('sync_device_id_backup_pending_v2');
    final db = openMemoryDatabase();
    addTearDown(db.close);
    final journal = SyncJournalRepository(
      databaseProvider: () => db,
      clock: () => 1000,
    );
    final known = SyncKnownRepository(databaseProvider: () => db);

    // 上一代命名空间留下的派生状态（旧 key 不读 → 这里按全新安装重建）。
    await journal.append(db, [
      (
        category: SyncCategory.settings,
        record: SyncRecord(
          key: 'theme_mode',
          version: const SyncVersion(physical: 1, deviceId: 'devA'),
          data: const {'v': 'dark'},
        ),
      ),
    ]);
    await journal.markSnapshotBuilt(1);
    await known.putKnownVersions({
      (category: SyncCategory.settings, key: 'theme_mode'):
          const SyncVersion(physical: 1, deviceId: 'devA'),
    });
    // 真实用户数据与墓碑不是派生状态：清理不能碰。
    await db.into(db.playHistory).insert(
          PlayHistoryCompanion.insert(
            sourceKey: 'kuwo',
            songId: 's1',
            title: 'Song',
            playedAt: 1,
          ),
        );
    await db.into(db.syncTombstones).insert(
          SyncTombstonesCompanion.insert(
            category: 'settings',
            key: 'theme_mode',
            versionPhysical: 1,
          ),
        );

    final freshState = SyncStateStore(
      preferences: prefs,
      secrets: MemorySyncSecretStore(),
      clock: () => 7000,
    );
    final freshEngine = SyncEngine(
      state: freshState,
      stamps: freshState.stampIssuer,
      adapters: const [],
      transports: const {},
      journal: journal,
      known: known,
    );
    addTearDown(freshEngine.dispose);
    await freshState.init();
    expect(freshState.freshInstall, isTrue);
    await freshEngine.init();

    expect(await journal.headSeq(), 0);
    expect(await journal.snapshotSeq(), -1);
    expect(await known.knownVersions(), isEmpty);
    expect(await db.select(db.playHistory).get(), hasLength(1));
    expect(await db.select(db.syncTombstones).get(), hasLength(1));

    // 新 key 已存在：再次初始化（重启）不清派生状态。
    await journal.append(db, [
      (
        category: SyncCategory.settings,
        record: SyncRecord(
          key: 'theme_mode',
          version: const SyncVersion(physical: 2, deviceId: 'devA'),
          data: const {'v': 'light'},
        ),
      ),
    ]);
    await known.putKnownVersions({
      (category: SyncCategory.settings, key: 'theme_mode'):
          const SyncVersion(physical: 2, deviceId: 'devA'),
    });
    final restartedState = SyncStateStore(
      preferences: prefs,
      secrets: MemorySyncSecretStore(),
      clock: () => 7000,
    );
    final restartedEngine = SyncEngine(
      state: restartedState,
      stamps: restartedState.stampIssuer,
      adapters: const [],
      transports: const {},
      journal: journal,
      known: known,
    );
    addTearDown(restartedEngine.dispose);
    await restartedState.init();
    expect(restartedState.freshInstall, isFalse);
    await restartedEngine.init();

    expect(await journal.headSeq(), 1);
    expect(await known.knownVersions(), hasLength(1));
  });

  test('装配不启动传输：首帧后的 startTransports 才起（权限门不挡首帧）', () async {
    final fresh = SyncEngine(
      state: state,
      stamps: state.stampIssuer,
      adapters: const [],
      transports: {'lan': transport},
      journal: FakeJournalStore(head: 0),
      clock: () => DateTime.fromMillisecondsSinceEpoch(7000),
    );
    final freshControl =
        SyncControlPlane(state: state, transports: {'lan': transport});
    addTearDown(freshControl.dispose);
    addTearDown(fresh.dispose);

    await fresh.init();
    expect(transport.isRunning, isFalse, reason: '装配不触发权限门 / 套接字绑定');

    await freshControl.startTransports();
    expect(transport.isRunning, isTrue);
    // 幂等：重复调用不重启。
    final started = transport.startCount;
    await freshControl.startTransports();
    expect(transport.startCount, started);
  });

  test('空窗口（只带回执）不算缺口；游标 -1 直接消费增量，不 bootstrap', () async {
    // 回执类载荷：增量 + 空窗口（windowEnd = 0）。
    transport.available.add(SyncEnvelope(
      deviceId: 'devB',
      deviceName: 'B',
      producedAt: 6000,
      journalHead: 1,
      acks: const {'devA': 0},
      journal: const [],
    ));
    final receiptPullCount = (await engine.syncNow())!;
    expect(transport.pullCount, 1, reason: '空窗口不触发第二轮全量拉取');
    expect(receiptPullCount.applied, 0);

    // 真正的增量窗口：游标 -1（全新对端）直接应用，不 bootstrap。
    transport.available.add(SyncEnvelope(
      deviceId: 'devB',
      deviceName: 'B',
      producedAt: 6000,
      journalHead: 1,
      windowStart: 1,
      windowEnd: 1,
      journal: [
        SyncJournalEntry(
          seq: 1,
          category: SyncCategory.settings,
          record: SyncRecord(
            key: 'theme_mode',
            version: const SyncVersion(physical: 9000, deviceId: 'devB'),
            data: const {'v': 'dark'},
          ),
        ),
      ],
    ));
    final report = await engine.syncNow();
    expect(report!.applied, 1);
    expect(transport.pullCount, 2, reason: '没有第二次 bootstrap 拉取');
    expect(prefs.getString('theme_mode'), 'dark');
  });

  test('窗口被截断（声明的 windowEnd 大于实到条目）仍触发 bootstrap', () async {
    transport.available.add(SyncEnvelope(
      deviceId: 'devB',
      deviceName: 'B',
      producedAt: 6000,
      journalHead: 3,
      windowStart: 1,
      // 声明到 3，实际只带 1 条：解析层丢条目 / 载荷被截断 → 必须回全量。
      windowEnd: 3,
      journal: [
        SyncJournalEntry(
          seq: 1,
          category: SyncCategory.settings,
          record: SyncRecord(
            key: 'theme_mode',
            version: const SyncVersion(physical: 9000, deviceId: 'devB'),
            data: const {'v': 'dark'},
          ),
        ),
      ],
    ));
    final report = await engine.syncNow();
    expect(report!.applied, 1);
    expect(transport.pullCount, 2, reason: '缺口 → 本轮内再拉一次全量兜底');
    expect(transport.lastRequest!.fullPeers, contains('devB'));
  });

  test('传输全关：同步完全停（不启动传输、不跑轮次）', () async {
    // 没有独立总开关：关掉唯一一路传输 = 同步已停。
    await control.setTransportEnabled('lan', true);
    await control.setTransportEnabled('lan', false);
    expect(transport.isRunning, isFalse);

    transport.available.add(remoteTheme('dark'));
    // 两路都关时轮次直接跳过：不启动传输、不拉取、连报告都不产生。
    expect(await engine.syncNow(), isNull);
    expect(prefs.getString('theme_mode'), isNull);

    await control.setTransportEnabled('lan', true);
    expect(transport.isRunning, isTrue);
    await engine.syncNow();
    expect(prefs.getString('theme_mode'), 'dark');
  });

  test('同步进行中的请求会排队补跑（点两次不会只生效一次）', () async {
    transport.available.add(remoteTheme('dark'));

    final first = engine.syncNow(trigger: SyncTrigger.timer);
    final second = engine.syncNow(trigger: SyncTrigger.manual);
    await Future.wait([first, second]);

    expect(state.log, hasLength(2));
    // 补跑的那轮用排队时记录的触发原因（手动）。
    expect(state.log.first.trigger, SyncTrigger.manual);
    // 内容未变：只有首轮真正推送（本机未变不推）。
    expect(transport.pushed, hasLength(1));
  });

  test('本机未变不推：内容指纹未变时第二轮跳过加密与上传', () async {
    transport.available.add(remoteTheme('dark'));
    await engine.syncNow();
    expect(transport.pushed, hasLength(1));
    final snapshotId = engine.lastEnvelope?.snapshotId ?? '';
    expect(snapshotId, isNotEmpty);
    expect(transport.pushed.single.snapshotId, snapshotId);

    // 对端仍在线但没有新内容：本地视图不变 → 不再推送。
    transport.peersSeenOverride = 1;
    final second = await engine.syncNow();

    expect(second!.outcome, SyncOutcome.noChanges);
    expect(transport.pushed, hasLength(1));
    expect(second.transports.single.bytesOut, 0);
    expect(second.transports.single.bytesIn, 0);
    expect(second.applied, 0);
  });

  test('传输未变跳过计数进入报告（skippedUnchanged）', () async {
    transport.peersSeenOverride = 1;
    transport.pullSkippedUnchanged = 2;
    final report = await engine.syncNow();

    expect(report!.transports.single.skippedUnchanged, 2);
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
    await failingState.setTransportEnabled('lan', true);
    final failingTransport = FakeSyncTransport();
    final adapter = _FlakyAdapter();
    final failingEngine = SyncEngine(
      state: failingState,
      stamps: failingState.stampIssuer,
      adapters: [adapter],
      transports: {'lan': failingTransport},
      inboundWindow: const Duration(milliseconds: 10),
    );
    addTearDown(failingEngine.dispose);
    await failingEngine.init();

    adapter.failNext = true;
    await failingEngine.onIncomingEnvelope(remoteTheme('light'));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(adapter.appliedKeys, isEmpty);
    // 收到数据但一条都没落地：本轮算失败（错误里带应用失败次数）。
    expect(failingState.log.first.outcome, SyncOutcome.failed);
    expect(failingState.log.first.failed, 1);
    expect(failingState.log.first.error?.code, SyncIssueCode.applyFailed);
    expect(failingState.log.first.error?.args['count'], 1);

    // 下一轮消费队列里的入站快照（否则对端推来的数据就永久丢了）。
    await failingEngine.syncNow();
    expect(adapter.appliedKeys, ['theme_mode']);
  });

  test('首次连通：真正交换过数据才通知一次（探测应答不算、重启不重发）', () async {
    final noticed = <String>[];
    final subscription = engine.peerConnectedNotices
        .listen((peer) => noticed.add(peer.deviceId));
    addTearDown(subscription.cancel);

    // 只有探测应答（接触但没有数据流转）：不算连通。
    transport.seenIdsOverride = const ['devB'];
    transport.peersSeenOverride = 1;
    await engine.syncNow();
    await pumpEventQueue();
    expect(noticed, isEmpty, reason: '只探测应答不算真正连通');

    // 真正拉到了载荷：通知一次。
    transport.seenIdsOverride = null;
    transport.peersSeenOverride = null;
    transport.available.add(remoteTheme('dark'));
    await engine.syncNow();
    await pumpEventQueue();
    expect(noticed, ['devB']);

    // 后续轮次不重复（登记已持久化）。
    await engine.syncNow();
    await pumpEventQueue();
    expect(noticed, ['devB']);
    expect(state.isPeerConnectNotified('devB'), isTrue);

    // 重启（同一份状态）：标记已落盘，不重发。
    final reloaded = SyncStateStore(preferences: prefs, secrets: secrets);
    await reloaded.init();
    expect(reloaded.isPeerConnectNotified('devB'), isTrue,
        reason: '一次性提示跨重启生效');
  });

  test('首次连通：对端主动推送（入站）同样算连通', () async {
    final noticed = <String>[];
    final subscription = engine.peerConnectedNotices
        .listen((peer) => noticed.add(peer.deviceId));
    addTearDown(subscription.cancel);

    await engine.onIncomingEnvelope(remoteTheme('light'));
    // 入站合流窗口（10ms）后跑一轮入站轮。
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await pumpEventQueue();
    expect(noticed, ['devB']);
    expect(state.isPeerConnectNotified('devB'), isTrue);
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
  Future<Map<SyncCategory, List<SyncRecord>>> collect(
          {bool fresh = false}) async =>
      const {};

  @override
  Future<SyncApplyOutcome> apply(
    Map<SyncCategory, List<SyncRecord>> records,
  ) async {
    if (failNext) {
      failNext = false;
      throw StateError('应用失败（测试注入）');
    }
    var applied = 0;
    for (final record
        in records[SyncCategory.settings] ?? const <SyncRecord>[]) {
      appliedKeys.add(record.key);
      applied++;
    }
    return SyncApplyOutcome(applied: applied);
  }
}
