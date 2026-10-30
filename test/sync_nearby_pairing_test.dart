import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/data/settings/settings_registry.dart';
import 'package:molia/data/sync/adapters/prefs_sync_adapter.dart';
import 'package:molia/data/sync/sync_backup.dart';
import 'package:molia/data/sync/sync_control_plane.dart';
import 'package:molia/data/sync/sync_engine.dart';
import 'package:molia/data/sync/sync_scheduler.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/models/sync_nearby_pairing.dart';
import 'package:molia/domain/ports/sync_transport.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/sync_log_page.dart';
import 'package:molia/pages/sync_nearby_pairing_dialogs.dart';
import 'package:molia/pages/sync_settings_page.dart';
import 'package:molia/providers/sync_provider.dart';
import 'package:molia/services/battery_probe.dart';
import 'package:molia/services/language_service.dart';
import 'package:molia/services/local_endpoints_service.dart';
import 'package:molia/services/notification_service.dart';
import 'package:molia/widgets/settings/settings_tiles.dart';

import 'support/notification_recorder.dart';
import 'support/sync_test_support.dart';

/// 附近设备一键配对：附近卡片 / 发起方确认码 / 接收方确认窗 / 手动地址兜底。
/// 旧配对码（复制 / 粘贴 / 扫码）路径已删除，这里只覆盖现行入口。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const keys = [kThemeMode];

  late SyncStateStore state;
  late FakeSyncTransport transport;
  late SyncEngine engine;
  late SyncControlPlane control;
  late SyncBackup backup;
  late FakeSyncPairingPort pairing;
  late SyncProvider provider;
  late RecordingNotificationService notifications;
  var nowMs = 7000;

  LocalEndpointsService fakeEndpoints() => LocalEndpointsService(
        enumerate: () async => const [
          LocalEndpoint(interfaceName: 'wlan0', address: '192.168.1.10'),
        ],
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final secrets = MemorySyncSecretStore();
    state = SyncStateStore(
      preferences: prefs,
      secrets: secrets,
      clock: () => nowMs++,
    );
    await state.init();
    transport = FakeSyncTransport();
    // 附近设备扫描要求发现端口可用：默认给一个 v4 端口，个别不可用空态
    // 用例再显式改成 (0, 0)。
    transport.discoveryPortsOverride = (v4: 47825, v6: 0);
    final adapter = PrefsSyncAdapter(
      state: state,
      settings: SettingsRegistry(
        keys: keys,
        preferences: prefs,
        secrets: secrets,
      ),
    );
    engine = SyncEngine(
      state: state,
      stamps: state.stampIssuer,
      adapters: [adapter],
      transports: {'lan': transport},
      clock: () => DateTime.fromMillisecondsSinceEpoch(state.nowMs()),
    );
    control = SyncControlPlane(state: state, transports: {'lan': transport});
    backup = SyncBackup(
      state: state,
      adapters: [adapter],
      stamps: state.stampIssuer,
      collect: engine.collectRecords,
      clock: () => DateTime.fromMillisecondsSinceEpoch(state.nowMs()),
    );
    pairing = FakeSyncPairingPort();
    provider = SyncProvider(
      engine: engine,
      controlPlane: control,
      backup: backup,
      localEndpoints: fakeEndpoints(),
      pairing: pairing,
    );
    await provider.init();
    notifications = RecordingNotificationService();
  });

  tearDown(() async {
    provider.dispose();
    control.dispose();
    engine.dispose();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SyncProvider>.value(value: provider),
          Provider<NotificationService>.value(value: notifications),
        ],
        child: M3EMaterialApp(
          data: M3EThemeData.fromMaterial(ThemeData.light()),
          theme: ThemeData.light(),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: LanguageService.supportedLocales,
          home: const SyncSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 列表懒构建：先滚到目标控件（找不到时持续向下拖）。
  Future<void> reveal(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        finder,
        300,
        scrollable: find.byType(Scrollable).first,
      );
    } else {
      await tester.ensureVisible(finder);
    }
    await tester.pumpAndSettle();
  }

  Future<void> openAdvanced(WidgetTester tester) async {
    final entry = find.byKey(const Key('settingsSyncAdvancedItem'));
    await reveal(tester, entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
  }

  Future<void> openManualConnect(WidgetTester tester) async {
    await openAdvanced(tester);
    await tester.tap(find.byKey(const Key('settingsSyncManualConnectItem')));
    await tester.pumpAndSettle();
  }

  Finder fieldAt(int index) => find.byType(EditableText).at(index);

  SyncNearbyDevice nearbyDevice(
    String id, {
    String name = '',
    bool hasGroup = false,
  }) =>
      SyncNearbyDevice(
        deviceId: id,
        name: name,
        host: '192.168.1.23',
        httpPort: 40000,
        probePort: ManualPeer.defaultProbePort,
        hasGroup: hasGroup,
        lastSeenAt: 1000,
      );

  SyncPairingAttempt attempt(
    SyncPairingStatus status, {
    String requestId = 'r1',
    String code = '482193',
  }) =>
      SyncPairingAttempt(
        requestId: requestId,
        peerDeviceId: 'devC',
        peerName: 'Device C',
        intent: SyncPairingIntent.join,
        code: code,
        status: status,
        expiresAt: 1 << 50,
      );

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
    provider.notifyListeners();
  }

  Future<void> emitCandidate(WidgetTester tester) async {
    pairing.emitNearby([
      nearbyDevice('devC', name: 'Pixel 9', hasGroup: true),
    ]);
    await tester.pumpAndSettle();
  }

  Future<void> openCandidateDialog(WidgetTester tester) async {
    final row = find.byKey(const Key('settingsSyncNearby-devC'));
    await reveal(tester, row);
    await tester.tap(row);
    // 等待期间有环形进度动画：不能 pumpAndSettle（永远不收敛）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() done, {
    int attempts = 40,
  }) async {
    for (var i = 0; i < attempts && !done(); i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets('附近设备：局域网关闭时只说明下一步，不再放第二个开关', (tester) async {
    await pumpPage(tester);
    final hint = find.byKey(const Key('settingsSyncNearbyLanOff'));
    await reveal(tester, hint);

    expect(find.text('LAN sync is off'), findsOneWidget);
    expect(
      find.textContaining('nearby devices will appear here'),
      findsOneWidget,
    );
    expect(pairing.startScanCalls, 0);
    expect(find.byKey(const Key('settingsSyncLanSwitch')), findsOneWidget);
  });

  testWidgets('附近设备：权限缺失时说明先完成上方授权，不扫描', (tester) async {
    await state.setTransportEnabled(SyncTransportKind.lan, true);
    transport.unavailableReason = SyncUnavailableReason.permissionDenied;
    await pumpPage(tester);

    final stateTile = find.byKey(
      const Key('settingsSyncNearby-permissionDenied'),
    );
    await reveal(tester, stateTile);
    expect(find.text('Nearby search needs LAN access'), findsOneWidget);
    expect(
      find.textContaining('Grant LAN access above first'),
      findsOneWidget,
    );
    expect(pairing.startScanCalls, 0);
  });

  testWidgets('附近设备：传输未启动时说明原因并给同步日志入口', (tester) async {
    await state.setTransportEnabled(SyncTransportKind.lan, true);
    transport.unavailableReason = SyncUnavailableReason.startFailed;
    await pumpPage(tester);

    final stateTile = find.byKey(
      const Key('settingsSyncNearby-transportUnavailable'),
    );
    await reveal(tester, stateTile);
    expect(find.text("LAN sync isn't running"), findsOneWidget);
    expect(find.textContaining('Check the sync log'), findsOneWidget);
    expect(pairing.startScanCalls, 0);

    final logEntry = find.byKey(const Key('settingsSyncNearbyOpenLog'));
    await reveal(tester, logEntry);
    await tester.tap(logEntry);
    await tester.pumpAndSettle();
    expect(find.byType(SyncLogPage), findsOneWidget);
  });

  testWidgets('附近设备：UDP 不可用时明确自动发现不可用，给手动地址入口', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    transport.discoveryPortsOverride = (v4: 0, v6: 0);
    await pumpPage(tester);

    final stateTile = find.byKey(
      const Key('settingsSyncNearby-discoveryUnavailable'),
    );
    await reveal(tester, stateTile);
    expect(find.text('Auto-discovery unavailable'), findsOneWidget);
    expect(
      find.textContaining('manual address or WebDAV'),
      findsOneWidget,
    );
    expect(pairing.startScanCalls, 0);

    final manual = find.byKey(const Key('settingsSyncNearbyManualConnect'));
    await reveal(tester, manual);
    await tester.tap(manual);
    await tester.pumpAndSettle();
    expect(find.text('Connect manually'), findsWidgets);
  });

  testWidgets('附近设备：移动数据 / 省电模式分别说明搜索暂停原因', (tester) async {
    var cellular = true;
    var battery = BatterySnapshot.unknown;
    final scheduler = SyncScheduler(
      host: engine,
      state: state,
      cellularProbe: () async => cellular,
      batteryProbe: () async => battery,
    );
    provider.dispose();
    provider = SyncProvider(
      engine: engine,
      controlPlane: control,
      backup: backup,
      scheduler: scheduler,
      localEndpoints: fakeEndpoints(),
      pairing: pairing,
    );
    await provider.init();
    await scheduler.refreshEnvironment();
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await pumpPage(tester);

    await reveal(
      tester,
      find.byKey(const Key('settingsSyncNearby-cellular')),
    );
    expect(find.text('On mobile data'), findsOneWidget);
    expect(
      find.textContaining('Switch to Wi-Fi'),
      findsOneWidget,
    );
    expect(pairing.startScanCalls, 0);

    cellular = false;
    battery = const BatterySnapshot(
      level: 80,
      charging: false,
      powerSave: true,
    );
    await scheduler.refreshEnvironment();
    provider.notifyListeners();
    await tester.pumpAndSettle();
    await reveal(
      tester,
      find.byKey(const Key('settingsSyncNearby-powerSave')),
    );
    expect(find.text('Power saver is on'), findsOneWidget);
    expect(
      find.textContaining('Turn off power saver'),
      findsOneWidget,
    );
    expect(pairing.startScanCalls, 0);
  });

  testWidgets('附近设备：页面内开启局域网即扫描，离开页面停止', (tester) async {
    await pumpPage(tester);
    expect(pairing.startScanCalls, 0);

    await tester.tap(find.byKey(const Key('settingsSyncLanSwitch')));
    await tester.pumpAndSettle();
    expect(pairing.startScanCalls, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(pairing.stopScanCalls, greaterThan(0));
  });

  testWidgets('附近设备：权限缺失时不扫描，传输恢复运行后补扫', (tester) async {
    // 直接写状态不启动传输：模拟启动时权限缺失（开关已开、传输不可用）。
    await state.setTransportEnabled(SyncTransportKind.lan, true);
    transport.unavailableReason = SyncUnavailableReason.permissionDenied;
    await pumpPage(tester);
    expect(pairing.startScanCalls, 0, reason: '缺权限时不在不可用状态反复扫描');
    expect(
      find.byKey(const Key('settingsSyncNearby-permissionDenied')),
      findsOneWidget,
    );

    // 授权后传输恢复运行：即使开关没有 false → true，也要重新扫描候选。
    transport.unavailableReason = null;
    await transport.start();
    await control.setDeviceName('授权后的设备');
    await tester.pumpAndSettle();

    expect(pairing.startScanCalls, greaterThan(0));
    expect(pairing.scanning, isTrue);
  });

  testWidgets('附近设备：开局域网即扫描；空态可重新查找并落到「没有发现设备」', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await pumpPage(tester);
    expect(pairing.startScanCalls, 1);
    expect(pairing.scanning, isTrue);

    final rescan = find.byKey(const Key('settingsSyncNearbyRescan'));
    await reveal(tester, rescan);
    await tester.tap(rescan);
    await tester.pump();

    expect(pairing.startScanCalls, 2);
    expect(find.text('Looking for nearby devices…'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('No devices found'), findsOneWidget);
    expect(
      find.textContaining(
        'Ask the other device to open Molia and turn on LAN sync',
      ),
      findsOneWidget,
    );
  });

  testWidgets('附近设备：过滤本机与已配对设备；候选行显示组提示', (tester) async {
    seedPeer('devPaired', lastSeenAt: 1);
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await pumpPage(tester);
    pairing.emitNearby([
      nearbyDevice(provider.deviceId),
      nearbyDevice('devPaired'),
      nearbyDevice('devC', name: 'Pixel 9', hasGroup: true),
    ]);
    await tester.pumpAndSettle();

    final row = find.byKey(const Key('settingsSyncNearby-devC'));
    await reveal(tester, row);
    expect(
      find.byKey(Key('settingsSyncNearby-${provider.deviceId}')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('settingsSyncNearby-devPaired')),
      findsNothing,
    );
    final tile = tester.widget<SettingsNavTile>(row);
    expect(tile.title, 'Pixel 9');
    expect(
      tile.subtitle,
      'Tap to pair · The other device is already in a sync group',
    );
  });

  testWidgets('发起方：点候选即开确认码弹窗；接受后关闭、提示并跑一轮', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await pumpPage(tester);
    await emitCandidate(tester);
    await openCandidateDialog(tester);

    expect(find.text('Pair with “Pixel 9”'), findsOneWidget);
    expect(find.text('Contacting the other device…'), findsOneWidget);
    expect(pairing.requestedDevices.single.deviceId, 'devC');

    pairing.emitAttempt(attempt(SyncPairingStatus.pending));
    await tester.pump();
    expect(find.text('482 193'), findsOneWidget);
    expect(
      find.text('Waiting for the other device to accept…'),
      findsOneWidget,
    );
    expect(
      find.text('Check that the other device shows the same numbers'),
      findsOneWidget,
    );

    final pulls = transport.pullCount;
    pairing.completeRequest(
      SyncPairingResult(
        outcome: SyncPairingOutcome.accepted,
        attempt: attempt(SyncPairingStatus.accepted),
      ),
    );
    await pumpUntil(
      tester,
      () =>
          transport.pullCount > pulls &&
          find.text('482 193').evaluate().isEmpty,
    );

    expect(find.text('482 193'), findsNothing);
    expect(notifications.last, 'Joined the sync group');
    expect(transport.pullCount, pulls + 1);
  });

  testWidgets('发起方：冲突 / 不可达 / 拒绝各自给一句原因与下一步', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await pumpPage(tester);
    await emitCandidate(tester);

    final cases = <(SyncPairingOutcome, String)>[
      (
        SyncPairingOutcome.conflict,
        'The devices are in different sync groups. Reset one device’s passphrase and try again.',
      ),
      (
        SyncPairingOutcome.unreachable,
        'Couldn’t reach the device. Make sure both devices are on the same network; keep Molia open in the foreground on the other device and confirm LAN access is granted.',
      ),
      (
        SyncPairingOutcome.rejected,
        'The other device rejected the request. You can try again later.',
      ),
    ];
    for (final (outcome, copy) in cases) {
      pairing.requestResult = SyncPairingResult(outcome: outcome);
      await openCandidateDialog(tester);
      await tester.pumpAndSettle();
      expect(notifications.last, copy);
      notifications.clear();
    }
  });

  testWidgets('发起方：取消会通知服务并关闭弹窗', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await pumpPage(tester);
    await emitCandidate(tester);
    await openCandidateDialog(tester);
    pairing.emitAttempt(attempt(SyncPairingStatus.pending));
    await tester.pump();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(pairing.cancelledRequests, contains('r1'));
    expect(find.text('482 193'), findsNothing);
    expect(
      notifications.last,
      'Pairing cancelled. Tap the device to try again.',
    );
  });

  testWidgets('发起方：确认码到达前取消，拿到请求 id 后仍会通知服务', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await pumpPage(tester);
    await emitCandidate(tester);
    await openCandidateDialog(tester);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(pairing.cancelledRequests, isEmpty);

    pairing.emitAttempt(attempt(SyncPairingStatus.pending));
    await tester.pump();
    expect(pairing.cancelledRequests, contains('r1'));
  });

  testWidgets('发起方：等待期间返回键不会静默关窗，取消仍是唯一出口', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await pumpPage(tester);
    await emitCandidate(tester);
    await openCandidateDialog(tester);
    pairing.emitAttempt(attempt(SyncPairingStatus.pending));
    await tester.pump();

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('482 193'), findsOneWidget, reason: '返回键必须被否决');
    expect(pairing.cancelledRequests, isEmpty);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(pairing.cancelledRequests, contains('r1'));
    expect(find.text('482 193'), findsNothing);
  });

  testWidgets('发起方：请求抛异常也收口弹层并给不可用提示', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    pairing.requestError = StateError('boom');
    await pumpPage(tester);
    await emitCandidate(tester);
    await openCandidateDialog(tester);
    await tester.pumpAndSettle();

    expect(
      notifications.last,
      'Pairing is unavailable. Keep Molia open in the foreground on the other device and confirm LAN access is granted, then try again.',
    );
    expect(find.text('Pair with “Pixel 9”'), findsNothing);
  });

  testWidgets('接收方（加入组）：标题 / 确认码 / 警告；接受后提示并跑一轮', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await openReceiverDialog(
      tester,
      notifications: notifications,
      provider: provider,
      request: SyncPairingRequest(
        requestId: 'in1',
        peerDeviceId: 'devA',
        peerName: 'Pixel 9',
        intent: SyncPairingIntent.join,
        code: '482193',
        expiresAt: provider.nowMs + 60000,
      ),
    );

    expect(
        find.text('“Pixel 9” wants to join your sync group'), findsOneWidget);
    expect(find.text('482 193'), findsOneWidget);
    expect(
      find.textContaining('the other device can read all synced data'),
      findsOneWidget,
    );

    final pulls = transport.pullCount;
    pairing.respondResult = SyncPairingOutcome.accepted;
    await tester.tap(find.text('Accept'));
    await pumpUntil(
      tester,
      () =>
          transport.pullCount > pulls &&
          find.text('482 193').evaluate().isEmpty,
    );

    expect(pairing.responses.single.requestId, 'in1');
    expect(pairing.responses.single.accept, isTrue);
    expect(notifications.last, 'Joined the sync group');
    expect(find.text('482 193'), findsNothing);
    expect(transport.pullCount, pulls + 1);
  });

  testWidgets('接收方：拒绝会回传拒绝并给短提示', (tester) async {
    await openReceiverDialog(
      tester,
      notifications: notifications,
      provider: provider,
      request: SyncPairingRequest(
        requestId: 'in2',
        peerDeviceId: 'devA',
        peerName: 'Pixel 9',
        intent: SyncPairingIntent.join,
        code: '111222',
        expiresAt: provider.nowMs + 60000,
      ),
    );

    pairing.respondResult = SyncPairingOutcome.rejected;
    await tester.tap(find.text('Reject'));
    await tester.pumpAndSettle();

    expect(pairing.responses.single.accept, isFalse);
    expect(notifications.last, 'Pairing request rejected');
  });

  testWidgets('接收方：返回键不会静默关窗，必须明确接受或拒绝', (tester) async {
    await openReceiverDialog(
      tester,
      notifications: notifications,
      provider: provider,
      request: SyncPairingRequest(
        requestId: 'in-back',
        peerDeviceId: 'devA',
        peerName: 'Pixel 9',
        intent: SyncPairingIntent.join,
        code: '999888',
        expiresAt: provider.nowMs + 60000,
      ),
    );

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('999 888'), findsOneWidget, reason: '返回键必须被否决');
    expect(pairing.responses, isEmpty);

    pairing.respondResult = SyncPairingOutcome.rejected;
    await tester.tap(find.text('Reject'));
    await tester.pumpAndSettle();
    expect(pairing.responses.single.requestId, 'in-back');
    expect(find.text('999 888'), findsNothing);
  });

  testWidgets('接收方：确认窗到期主动拒绝，释放服务里的待确认槽位', (tester) async {
    final expiresAt = provider.nowMs + 80;
    await openReceiverDialog(
      tester,
      notifications: notifications,
      provider: provider,
      request: SyncPairingRequest(
        requestId: 'in-expired',
        peerDeviceId: 'devA',
        peerName: 'Pixel 9',
        intent: SyncPairingIntent.join,
        code: '777666',
        expiresAt: expiresAt,
      ),
    );

    pairing.respondResult = SyncPairingOutcome.expired;
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();

    expect(pairing.responses.single.requestId, 'in-expired');
    expect(pairing.responses.single.accept, isFalse,
        reason: '本地计时器先到也要主动拒绝，不能等 service sweep');
    expect(notifications.last, 'The pairing request expired');
    expect(find.text('777 666'), findsNothing);
  });

  testWidgets('接收方（邀请）：文案说明改口令；接受等待时按钮禁用并显示进度', (tester) async {
    pairing.respondCompleter = Completer<SyncPairingOutcome>();
    await openReceiverDialog(
      tester,
      notifications: notifications,
      provider: provider,
      request: SyncPairingRequest(
        requestId: 'in3',
        peerDeviceId: 'devA',
        peerName: 'Pixel 9',
        intent: SyncPairingIntent.invite,
        code: '333444',
        expiresAt: provider.nowMs + 60000,
      ),
    );

    expect(
      find.text('“Pixel 9” invited you to join their sync group'),
      findsOneWidget,
    );
    expect(
      find.textContaining('switches this device to their passphrase'),
      findsOneWidget,
    );

    await tester.tap(find.text('Accept'));
    await tester.pump();

    expect(find.byType(M3EProgressIndicator), findsOneWidget);
    expect(
      tester
          .widget<M3EButton>(find.widgetWithText(M3EButton, 'Accept'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<M3EButton>(find.widgetWithText(M3EButton, 'Reject'))
          .onPressed,
      isNull,
    );

    pairing.completeRespond(SyncPairingOutcome.accepted);
    await tester.pumpAndSettle();
    expect(notifications.last, 'Joined the sync group');
  });

  testWidgets('接收方（邀请）：接受后对方未完成时给可行动的提示', (tester) async {
    pairing.respondResult = SyncPairingOutcome.unavailable;
    await openReceiverDialog(
      tester,
      notifications: notifications,
      provider: provider,
      request: SyncPairingRequest(
        requestId: 'in4',
        peerDeviceId: 'devA',
        peerName: 'Pixel 9',
        intent: SyncPairingIntent.invite,
        code: '555666',
        expiresAt: provider.nowMs + 60000,
      ),
    );

    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();

    expect(
      notifications.last,
      'Accepted, but the other device hasn’t finished pairing. If it doesn’t join, ask it to try again.',
    );
  });

  testWidgets('手动地址：未配对设备发附近探测，出现后在附近设备里点击配对', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    pairing.probeResult = true;
    await pumpPage(tester);
    await openManualConnect(tester);

    await tester.enterText(fieldAt(0), '192.168.1.23');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(pairing.probes.single.host, '192.168.1.23');
    expect(pairing.probes.single.probePort, ManualPeer.defaultProbePort);
    expect(
      notifications.last,
      'Looking for this device; tap it under Nearby devices to pair',
    );
    expect(provider.manualPeers.single.host, '192.168.1.23');
    expect(find.text('Save'), findsNothing);
  });

  testWidgets('手动地址：已配对设备仍走立即接触（更新地址不断开）', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await provider.addManualPeer(
      '192.168.1.23',
      probePort: ManualPeer.defaultProbePort,
      httpPort: 40000,
      deviceId: 'devB',
    );
    transport.onPull = () async {
      await state.learnManualPeer(const ManualPeer(
        host: '192.168.1.23',
        deviceId: 'devB',
        httpPort: 40000,
      ));
    };
    transport.available.add(SyncEnvelope(
      deviceId: 'devB',
      deviceName: 'Device B',
      producedAt: 5000,
      records: const {},
    ));
    pairing.probeResult = true;
    await pumpPage(tester);
    await openManualConnect(tester);

    await tester.enterText(fieldAt(0), '192.168.1.23');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(pairing.probes.single.host, '192.168.1.23');
    expect(notifications.last, 'Device updated');
    expect(provider.manualPeers.single.deviceId, 'devB');
  });
}

/// 直接用按钮承载「应用壳收到请求」的时刻：测试只关心弹层文案与回传。
class _ReceiverHost extends StatefulWidget {
  const _ReceiverHost({required this.provider, required this.request});

  final SyncProvider provider;
  final SyncPairingRequest request;

  @override
  State<_ReceiverHost> createState() => _ReceiverHostState();
}

class _ReceiverHostState extends State<_ReceiverHost> {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: M3EButton.filled(
        onPressed: () => unawaited(
          showSyncIncomingPairingDialog(
            context,
            provider: widget.provider,
            request: widget.request,
          ),
        ),
        child: const Text('open'),
      ),
    );
  }
}

Future<void> openReceiverDialog(
  WidgetTester tester, {
  required RecordingNotificationService notifications,
  required SyncProvider provider,
  required SyncPairingRequest request,
}) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SyncProvider>.value(value: provider),
        Provider<NotificationService>.value(value: notifications),
      ],
      child: M3EMaterialApp(
        data: M3EThemeData.fromMaterial(ThemeData.light()),
        theme: ThemeData.light(),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: LanguageService.supportedLocales,
        home: _ReceiverHost(provider: provider, request: request),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}
