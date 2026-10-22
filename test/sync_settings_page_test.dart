import 'dart:async';

import 'package:flutter/services.dart';
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
import 'package:molia/data/sync/sync_passphrase.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/data/sync/transport/local_network_permission.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/models/sync_pairing.dart';
import 'package:molia/domain/ports/sync_transport.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/sync_content_page.dart';
import 'package:molia/pages/sync_log_page.dart';
import 'package:molia/pages/sync_settings_page.dart';
import 'package:molia/providers/sync_provider.dart';
import 'package:molia/services/language_service.dart';
import 'package:molia/services/notification_service.dart';
import 'package:molia/services/local_endpoints_service.dart';
import 'package:molia/theme/app_semantic_colors.dart';
import 'package:molia/widgets/settings/settings_tiles.dart';
import 'package:molia/widgets/sync_pairing_qr.dart';
import 'package:molia/widgets/sync_pairing_scanner.dart';

import 'support/notification_recorder.dart';
import 'support/sync_test_support.dart';

/// 同步设置页（配对工作台）：首屏 = 传输方式（局域网 / WebDAV，开关即总闸）/
/// 配对 / 设备 / 内容 · 日志 · 高级；设备名、口令、地址与端口在「高级设置」
/// 子页（`SyncAdvancedPage`）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const keys = [kThemeMode];

  late SyncStateStore state;
  late FakeSyncTransport transport;
  late SyncEngine engine;
  late SyncControlPlane control;
  late SyncBackup backup;
  late SyncProvider provider;
  late RecordingNotificationService notifications;
  var nowMs = 7000;

  /// 假接口数据：地址列表 / 配对码用例断言具体地址。
  LocalEndpointsService fakeEndpoints() => LocalEndpointsService(
        enumerate: () async => const [
          LocalEndpoint(interfaceName: 'wlan0', address: '192.168.1.10'),
          LocalEndpoint(interfaceName: 'wlan0', address: '2409:8a55::5'),
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
      // 与状态存储同一时钟源（观测面的窗口过滤依赖时间戳一致）。
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
    provider = SyncProvider(
      engine: engine,
      controlPlane: control,
      backup: backup,
      localEndpoints: fakeEndpoints(),
    );
    await provider.init();
    notifications = RecordingNotificationService();
  });

  tearDown(() async {
    provider.dispose();
    control.dispose();
    engine.dispose();
  });

  /// 扫码入口可用性：默认不可用（widget 测试不触达平台通道；探测的 2s
  /// 超时计时器会让「widget 树已销毁但定时器未走完」断言失败）。
  /// 具体用例（平台 × GMS 矩阵）在测试内按需覆盖。
  setUp(() {
    SyncPairingScanner.debugAvailabilityOverride = () async => false;
  });

  tearDown(() {
    SyncPairingScanner.debugAvailabilityOverride = null;
    SyncPairingScanner.debugPlatformOverride = null;
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
          // 底栏提示统一走 NotificationService（内部 = M3ESnackbar）；
          // 测试换成记录型，只断言「弹了什么」。
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

  /// 从首屏进入子页（内容 / 日志）。
  Future<void> openSubPage(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  /// 点首屏「粘贴配对码」（剪贴板内容先由 [mockClipboardRead] 备好）。
  Future<void> pastePairingCode(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('settingsSyncPasteCodeItem')));
    await tester.pumpAndSettle();
  }

  /// 剪贴板读取 mock：`Clipboard.getData` 返回给定文本。
  void mockClipboardRead(WidgetTester tester, String text) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          return <String, dynamic>{'text': text};
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
  }

  /// 进入「高级设置」子页（设备名 / 口令 / 地址与端口 / 地址簿）。
  Future<void> openAdvanced(WidgetTester tester) async {
    final entry = find.byKey(const Key('settingsSyncAdvancedItem'));
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();
  }

  /// 打开「手动连接」弹层（高级设置 ▸ 地址簿首行）。
  Future<void> openManualConnect(WidgetTester tester) async {
    await openAdvanced(tester);
    await tester.tap(find.byKey(const Key('settingsSyncManualConnectItem')));
    await tester.pumpAndSettle();
  }

  Future<void> openRenameDialog(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('settingsSyncDeviceNameItem')));
    await tester.pumpAndSettle();
  }

  Finder fieldAt(int index) => find.byType(EditableText).at(index);

  /// 传输卡片 footer 的状态结论（原总开关副文案搬到卡片脚注）。
  String transportFooter(WidgetTester tester) {
    final card = find.ancestor(
      of: find.byKey(const Key('settingsSyncLanSwitch')),
      matching: find.byType(SettingsSectionCard),
    );
    return tester
        .widget<SettingsSectionHint>(
          find.descendant(of: card, matching: find.byType(SettingsSectionHint)),
        )
        .text;
  }

  /// 剪贴板 mock：返回收集到的复制内容列表。
  List<String> mockClipboard(WidgetTester tester) {
    final clipboard = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    return clipboard;
  }

  /// 往名册注入一台设备（`lastSeenAt` 可控；失联阈值 = 180 天）。
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

  testWidgets('默认两路传输都关：页面完整可见，footer 提示同步不会运行', (tester) async {
    await pumpPage(tester);

    expect(find.text('Cross-device sync'), findsOneWidget);
    // 没有总开关：传输开关就是总闸，两路都在首屏。
    expect(find.byKey(const Key('settingsSyncSwitch')), findsNothing);
    expect(find.text('Transport'), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncLanSwitch')), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncWebdavSwitch')), findsOneWidget);
    expect(provider.enabled, isFalse);
    // 口令在初始化时就绪：配对码随时可分享，不等任何开关。
    expect(provider.passphrase, isNotNull);
    expect(find.text('turned off'), findsOneWidget, reason: '局域网默认关');
    expect(
      find.textContaining('both methods are off'),
      findsOneWidget,
      reason: 'footer 说明「同步不会运行」，免得把没同步误读成故障',
    );

    // 配对 / 设备 / 内容入口不依赖总开关：始终可见。
    expect(find.byKey(const Key('settingsSyncPasteCodeItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncScanCodeItem')), findsNothing,
        reason: '默认平台不支持扫码：只留粘贴');
    expect(find.byKey(const Key('settingsSyncPeersEmpty')), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncContentItem')), findsOneWidget);
    // 底层信息仍在高级子页，不暴露在首屏。
    expect(find.text('This device'), findsNothing);
    expect(find.byKey(const Key('settingsSyncDeviceNameItem')), findsNothing);
  });

  testWidgets('开局域网传输即启用同步：不弹口令窗，各分区齐全', (tester) async {
    await pumpPage(tester);
    expect(provider.enabled, isFalse);

    await tester.tap(find.byKey(const Key('settingsSyncLanSwitch')));
    await tester.pumpAndSettle();

    expect(provider.enabled, isTrue);
    expect(provider.enabledTransports, contains(SyncTransportKind.lan));
    // 口令在初始化时就绪：开启同步不打断（口令随配对码交给对端）。
    expect(find.text('Copy passphrase'), findsNothing);
    expect(provider.passphrase, isNotNull);

    // ② 配对：分享（复制 / 二维码）+ 加入（粘贴 / 扫码）。
    expect(find.text('Pair with a device'), findsOneWidget);
    expect(
        find.byKey(const Key('settingsSyncPairingShareItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncPairingQrItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncPasteCodeItem')), findsOneWidget);
    // ③ 设备：空名册给一句引导。
    expect(find.byKey(const Key('settingsSyncPeersEmpty')), findsOneWidget);
    // ④ 内容 / 日志 / 高级设置入口。
    expect(find.byKey(const Key('settingsSyncContentItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncLogItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncAdvancedItem')), findsOneWidget);
    // 底层信息不再暴露在首屏。
    expect(find.byKey(const Key('settingsSyncDeviceNameItem')), findsNothing);
    expect(find.byKey(const Key('settingsSyncPeerSelfItem')), findsNothing);
    expect(find.byKey(const Key('settingsSyncPassphraseItem')), findsNothing);
  });

  testWidgets('高级设置：设备名 / 设备 id / 口令 / 网络地址入口 / 端口齐全', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await pumpPage(tester);
    await openAdvanced(tester);

    // 本机：设备名 / 设备 id / 口令 / 网络地址（明细进弹窗）/ 端口。
    expect(find.text('This device'), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncDeviceNameItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncPeerSelfItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncPassphraseItem')), findsOneWidget);
    expect(
      find.byKey(const Key('settingsSyncLocalAddressesItem')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('settingsSyncProbePortItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncHttpPortItem')), findsOneWidget);
    // 传输方式在首屏，子页不再重复一份（开关只有一处）。
    expect(find.byKey(const Key('settingsSyncLanSwitch')), findsNothing);
    expect(find.byKey(const Key('settingsSyncWebdavSwitch')), findsNothing);
  });

  testWidgets('传输卡片 footer：未同步说「尚未同步」；跑完一轮给结论与相对时间', (tester) async {
    // 先以「两路都关」打开：页面不会自动跑轮次，footer 才能停在初始态。
    await pumpPage(tester);
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await tester.pumpAndSettle();
    expect(transportFooter(tester), 'Never synced');

    // 跑一轮（页面无手动主操作，这里直接驱动 provider）：无对端 →
    // 结论「No peer found」+ 相对时间「just now」。
    await provider.syncNow(manual: true);
    await tester.pumpAndSettle();
    final footer = transportFooter(tester);
    expect(footer, contains('No other device found'));
    expect(footer, contains('just now'));
    // 「跳过 N 项」这类全库计数不出现在任何文案里。
    expect(find.textContaining('skipped'), findsNothing);
  });

  testWidgets('本机网络地址：卡片只留一行入口，明细在弹窗里逐条复制', (tester) async {
    final clipboard = mockClipboard(tester);
    transport.discoveryPortsOverride = (v4: 47825, v6: 47825);
    await state.setLanHttpPort(40000);
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await pumpPage(tester);
    // 底层明细在「高级设置」子页。
    await openAdvanced(tester);

    // 入口行：条数而不是地址列表（双栈 + 多网卡不撑长卡片）。
    expect(
      find.byKey(const Key('settingsSyncLocalAddressesItem')),
      findsOneWidget,
    );
    expect(find.text('2 available'), findsOneWidget);
    expect(
      find.byKey(const Key('settingsSyncLocalAddress-192.168.1.10')),
      findsNothing,
      reason: '地址不该铺在卡片上',
    );

    await tester.tap(find.byKey(const Key('settingsSyncLocalAddressesItem')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('settingsSyncLocalAddress-192.168.1.10')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('settingsSyncLocalAddress-2409:8a55::5')),
      findsOneWidget,
    );
    // 行副标题：网卡 · 地址族 · 该族探测端口。
    expect(find.text('wlan0 · IPv4 · Discovery port 47825'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('settingsSyncLocalAddress-192.168.1.10')),
    );
    await tester.pumpAndSettle();
    expect(clipboard.last, '192.168.1.10');
    expect(find.text('Address copied'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    final probe = tester.widget<SettingsInfoTile>(
        find.byKey(const Key('settingsSyncProbePortItem')));
    expect(probe.subtitle, '47825', reason: '两族同值只显示一个端口');
    final http = tester.widget<SettingsInfoTile>(
        find.byKey(const Key('settingsSyncHttpPortItem')));
    expect(http.subtitle, '40000');
  });

  testWidgets('探测端口分族展示：v6 独立降级后按族列出', (tester) async {
    transport.discoveryPortsOverride = (v4: 47825, v6: 51234);
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await pumpPage(tester);
    // 底层明细在「高级设置」子页。
    await openAdvanced(tester);

    final probe = tester.widget<SettingsInfoTile>(
        find.byKey(const Key('settingsSyncProbePortItem')));
    expect(probe.subtitle, '47825 (IPv4) / 51234 (IPv6)');
  });

  testWidgets('配对码按地址族取探测端口：v6 候选带 v6 的端口', (tester) async {
    transport.discoveryPortsOverride = (v4: 47825, v6: 51234);
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await pumpPage(tester);

    final code = (await provider.pairingCode())!;
    final byHost = {
      for (final address in code.addresses) address.host: address.probePort,
    };
    expect(byHost['192.168.1.10'], 47825);
    expect(byHost['2409:8a55::5'], 51234,
        reason: 'v6 独立降级到 51234：不能拿 v4 的 47825');
    // 分享弹层里的码文本同样是分族端口。
    expect(code.encode(), contains('molia-pair:2:'));
  });

  testWidgets('本机设备 id：短号可读，点按复制完整 id', (tester) async {
    final clipboard = mockClipboard(tester);
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await pumpPage(tester);
    // 底层明细在「高级设置」子页。
    await openAdvanced(tester);

    final shortId = provider.deviceId.substring(provider.deviceId.length - 6);
    expect(find.textContaining(shortId), findsOneWidget);
    await tester.tap(find.byKey(const Key('settingsSyncPeerSelfItem')));
    await tester.pumpAndSettle();
    expect(clipboard.single, provider.deviceId);
    expect(find.text('Full device ID copied'), findsOneWidget);
  });

  testWidgets('口令行可查看完整口令；不再有「输入已有口令加入」入口', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await pumpPage(tester);
    // 底层明细在「高级设置」子页。
    await openAdvanced(tester);

    await tester.tap(find.byKey(const Key('settingsSyncPassphraseItem')));
    await tester.pumpAndSettle();
    expect(find.text(provider.passphrase!), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // 口令只随配对码传递：手感路径（手输口令）已删除。
    expect(
      find.byKey(const Key('settingsSyncPassphraseJoinItem')),
      findsNothing,
    );
  });

  testWidgets('设备名行：改名入口打开弹窗并保存', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await pumpPage(tester);
    // 底层明细在「高级设置」子页。
    await openAdvanced(tester);
    await openRenameDialog(tester);
    await tester.enterText(find.byType(EditableText).first, '书房');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(provider.deviceName, '书房');
  });

  testWidgets('分享配对信息：点行复制配对码，行尾二维码弹层展示二维码与警告', (tester) async {
    final clipboard = mockClipboard(tester);
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('settingsSyncPairingShareItem')));
    await tester.pumpAndSettle();
    expect(clipboard.single, startsWith('molia-pair:2:'));
    expect(find.text('Pairing info copied (contains the passphrase)'),
        findsOneWidget);
    final decoded = SyncPairingCode.tryParse(clipboard.single)!;
    expect(decoded.passphrase, provider.passphrase);
    expect(decoded.deviceId, provider.deviceId);
    expect(
      decoded.addresses.map((address) => address.host),
      containsAll(<String>['192.168.1.10', '2409:8a55::5']),
    );

    await tester.tap(find.byKey(const Key('settingsSyncPairingQrItem')));
    await tester.pumpAndSettle();
    expect(find.byType(SyncPairingQr), findsOneWidget);
    expect(
      find.textContaining('contains your sync passphrase'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('粘贴配对码：地址入簿并立即接触；连上时不弹提交提示', (tester) async {
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
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    final code = SyncPairingCode(
      deviceName: 'Device B',
      deviceId: 'devB',
      passphrase: provider.passphrase!,
      addresses: const [
        SyncPairingAddress(host: '192.168.1.23', probePort: 47825),
      ],
      httpPort: 40000,
    );
    await pumpPage(tester);
    mockClipboardRead(tester, code.encode());
    await pastePairingCode(tester);

    expect(provider.manualPeers.single.deviceId, 'devB');
    expect(provider.manualPeers.single.httpPort, 40000);
    expect(provider.manualPeers.single.name, 'Device B');
    // 首轮就连上：提交不弹提示——「已与『设备』连通」由连通通知负责，
    // 同一出口不叠两条。
    expect(notifications.isEmpty, isTrue, reason: '连上时提交不弹提示');
    expect(find.byKey(const Key('settingsSyncPeer-devB')), findsOneWidget);
  });

  testWidgets('粘贴配对码：剪贴板里没有码 → 提示先去复制，地址簿不变', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await pumpPage(tester);
    mockClipboardRead(tester, '午饭吃什么');
    await pastePairingCode(tester);

    expect(
      notifications.last,
      contains('No pairing code in the clipboard'),
    );
    expect(provider.manualPeers, isEmpty, reason: '不是码就不落成地址');
  });

  testWidgets('粘贴配对码：码损坏 / 没有可用地址 → 各自的错误提示', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await pumpPage(tester);

    // 前缀对但解析失败：报「配对码无效」，不当普通地址处理。
    mockClipboardRead(tester, 'molia-pair:2:not-base64!!');
    await pastePairingCode(tester);
    expect(notifications.last, contains('Invalid pairing code'));
    expect(provider.manualPeers, isEmpty);

    // 结构合法但没有地址候选。
    final empty = SyncPairingCode(
      deviceName: 'Device B',
      deviceId: 'devB',
      passphrase: provider.passphrase!,
      addresses: const [],
      httpPort: 40000,
    );
    mockClipboardRead(tester, empty.encode());
    await pastePairingCode(tester);
    expect(notifications.last, contains('no usable network address'));
    expect(provider.manualPeers, isEmpty);
  });

  testWidgets('粘贴配对码：没有路由时提示已添加并会重试', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    final code = SyncPairingCode(
      deviceName: 'Device B',
      deviceId: 'devB',
      passphrase: provider.passphrase!,
      addresses: const [
        SyncPairingAddress(host: '192.168.1.23', probePort: 47825),
      ],
      httpPort: 40000,
    );
    await pumpPage(tester);
    mockClipboardRead(tester, code.encode());
    await pastePairingCode(tester);

    // 对端不应答：地址仍入簿，提示「稍后自动重试」。
    expect(provider.manualPeers.single.host, '192.168.1.23');
    expect(notifications.last, contains('Device B added'));
    expect(notifications.last, contains('it will retry'));
  });

  testWidgets('粘贴配对码：同设备的旧地址被码里的地址替换（换 IP 场景）', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await provider.addManualPeer(
      '192.168.1.23',
      name: '书房',
      deviceId: 'devB',
      httpPort: 40000,
    );
    await pumpPage(tester);

    final code = SyncPairingCode(
      deviceName: 'Device B',
      deviceId: 'devB',
      passphrase: provider.passphrase!,
      addresses: const [
        SyncPairingAddress(host: '192.168.1.77', probePort: 47825),
        SyncPairingAddress(host: '2409:8a55::9', probePort: 51234),
      ],
      httpPort: 40000,
    );
    mockClipboardRead(tester, code.encode());
    await pastePairingCode(tester);

    final hosts = provider.manualPeers.map((entry) => entry.host).toList();
    expect(hosts, containsAll(<String>['192.168.1.77', '2409:8a55::9']));
    expect(hosts, isNot(contains('192.168.1.23')), reason: '旧 IP 退役');
    expect(provider.manualPeers, hasLength(2), reason: '双栈候选都保留');
    expect(provider.manualPeers.first.name, '书房', reason: '命名跟着设备迁移');
  });

  testWidgets('粘贴配对码：本机已有别的口令 → 替换 / 仅导入地址两分支', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    final original = provider.passphrase!;
    await pumpPage(tester);

    const incoming = 'ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ';
    final code = SyncPairingCode(
      deviceName: 'Device B',
      deviceId: 'devB',
      passphrase: incoming,
      addresses: const [SyncPairingAddress(host: '192.168.1.23')],
      httpPort: 40000,
    );

    // 仅导入地址：本机口令不变，地址照常入簿。
    mockClipboardRead(tester, code.encode());
    await pastePairingCode(tester);
    expect(find.text('Passphrase already set'), findsOneWidget);
    await tester.tap(find.text('Addresses only'));
    await tester.pumpAndSettle();
    expect(provider.passphrase, original);
    expect(provider.manualPeers.single.host, '192.168.1.23');

    // 替换本机口令：口令换成码里的（归一化后保存）。
    mockClipboardRead(tester, code.encode());
    await pastePairingCode(tester);
    await tester.tap(find.textContaining('Replace passphrase'));
    await tester.pumpAndSettle();
    expect(provider.passphrase, SyncPassphrase.normalize(incoming));
  });

  testWidgets('扫码入口 = 平台 × GMS（无 GMS / 桌面隐藏，只给粘贴）', (tester) async {
    addTearDown(() {
      SyncPairingScanner.debugPlatformOverride = null;
      SyncPairingScanner.debugAvailabilityOverride = null;
    });
    Future<void> pumpAndCheck({required bool expected}) async {
      // 先卸掉上一棵树：同型 widget 会复用 State，initState 里的可用性探测
      // 不会重跑，平台矩阵就测不出来。
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpPage(tester);
      expect(
        find.byKey(const Key('settingsSyncScanCodeItem')),
        expected ? findsOneWidget : findsNothing,
        reason: '平台=${SyncPairingScanner.debugPlatformOverride} '
            '可用=${SyncPairingScanner.debugAvailabilityOverride != null}',
      );
    }

    await provider.setTransportEnabled(SyncTransportKind.lan, true);

    // Android + GMS：显示。
    SyncPairingScanner.debugPlatformOverride = TargetPlatform.android;
    SyncPairingScanner.debugAvailabilityOverride = () async => true;
    await pumpAndCheck(expected: true);

    // Android 无 GMS（AOSP / 无 Play 服务）：隐藏入口，不给死胡同。
    SyncPairingScanner.debugAvailabilityOverride = () async => false;
    await pumpAndCheck(expected: false);

    // iOS：系统 Vision，不依赖 GMS，恒显示。
    SyncPairingScanner.debugPlatformOverride = TargetPlatform.iOS;
    SyncPairingScanner.debugAvailabilityOverride = null;
    await pumpAndCheck(expected: true);

    // Linux：平台不支持，隐藏。
    SyncPairingScanner.debugPlatformOverride = TargetPlatform.linux;
    await pumpAndCheck(expected: false);
  });

  testWidgets('手动连接：写入地址簿并立即接触；没连上留在弹层可改地址', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await pumpPage(tester);
    await openManualConnect(tester);

    await tester.enterText(fieldAt(0), '192.168.1.23');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // 地址已写入地址簿（用户不用重填），但弹层留在原地让用户改地址重试。
    expect(provider.manualPeers.single.host, '192.168.1.23');
    expect(
        find.textContaining('make sure the device is online'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);

    // 关掉弹层后：未连上的条目在地址簿里可见（点开可改 / 删）。
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('settingsSyncPeer-192.168.1.23')),
      findsOneWidget,
    );
  });

  testWidgets('手动连接：探测端口默认 47825，地址与端口校验在弹层内', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await pumpPage(tester);
    await openManualConnect(tester);

    // 端口字段预填默认值（UDP 探测端口）。
    expect(
      tester.widget<EditableText>(fieldAt(1)).controller.text,
      '${ManualPeer.defaultProbePort}',
    );

    // 地址为空：错误文案出现，弹层不关闭。
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Address cannot be empty'), findsOneWidget);
    expect(find.text('Connect manually'), findsWidgets);

    // 残缺 IPv4 不是合法地址；方括号 IPv6 归一后合法。
    await tester.enterText(fieldAt(0), '192.168.1');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Invalid address'), findsOneWidget);

    // 端口越界。
    await tester.enterText(fieldAt(0), '192.168.1.23');
    await tester.enterText(fieldAt(1), '70000');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Port must be 1–65535'), findsOneWidget);
    expect(provider.manualPeers, isEmpty);
  });

  testWidgets('手动连接：连上后关闭并提示已添加；重复地址提示已更新', (tester) async {
    transport.onPull = () async {
      // 只有地址已入簿后才回写身份：页面打开时的自动检查不应提前把测试
      // 地址学进地址簿（否则第一次「添加」会变成「已更新」）。
      if (!provider.manualPeers.any((entry) => entry.host == '192.168.1.23')) {
        return;
      }
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
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await pumpPage(tester);
    await openManualConnect(tester);

    await tester.enterText(fieldAt(0), '192.168.1.23');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(notifications.last, 'Device added');
    expect(find.text('Save'), findsNothing, reason: '连上即关弹层');

    // 再来一次同一地址：提示「已更新」而不是重复添加（已在本页，直接开弹层）。
    notifications.clear();
    await tester.tap(find.byKey(const Key('settingsSyncManualConnectItem')));
    await tester.pumpAndSettle();
    await tester.enterText(fieldAt(0), '192.168.1.23');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(notifications.last, 'Device updated');
    expect(provider.manualPeers, hasLength(1));
  });

  testWidgets('设备地址清单：逐条列出，可更新（保留身份）与删除', (tester) async {
    final clipboard = mockClipboard(tester);
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await provider.addManualPeer(
      '192.168.1.23',
      name: '书房',
      probePort: 47825,
      httpPort: 40000,
      deviceId: 'devB',
    );
    await provider.addManualPeer(
      '2409:8a55::9',
      probePort: 51234,
      deviceId: 'devB',
    );
    await pumpPage(tester);
    await openAdvanced(tester);

    // 已认领但未进名册的设备：一行入口（条数而不是地址串）→ 地址清单。
    expect(find.text('2 addresses · Not connected yet'), findsOneWidget);
    await tester.tap(find.byKey(const Key('settingsSyncPeer-devB')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('settingsSyncPeerAddress-192.168.1.23')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('settingsSyncPeerAddress-2409:8a55::9')),
      findsOneWidget,
    );
    expect(find.text('Discovery port 47825'), findsOneWidget);
    expect(find.text('Discovery port 51234'), findsOneWidget);

    // 更新第一条地址（换 IP）：身份与已学端点端口保留。
    await tester.tap(
      find.byKey(const Key('settingsSyncPeerAddress-192.168.1.23')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Update address'), findsWidgets);
    await tester.enterText(fieldAt(0), '192.168.1.99');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final moved = provider.manualPeers.singleWhere(
      (entry) => entry.host == '192.168.1.99',
    );
    expect(moved.deviceId, 'devB');
    expect(moved.httpPort, 40000, reason: '改的是「设备在哪」，端口与身份保留');
    expect(moved.name, '书房');
    expect(
      provider.manualPeers.any((entry) => entry.host == '192.168.1.23'),
      isFalse,
      reason: '旧地址条目被替换而不是并列',
    );

    // 删除第二条地址：二次确认后从地址簿移除。
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settingsSyncPeer-devB')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('settingsSyncPeerAddress-2409:8a55::9')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove address').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(notifications.last, 'Removed from the address list');
    expect(
      provider.manualPeers.any((entry) => entry.host == '2409:8a55::9'),
      isFalse,
    );
    expect(clipboard, isEmpty, reason: '本用例不涉及复制');
  });

  testWidgets('多地址导入后：未认领候选折叠为一行，点开可查看 / 删除', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await provider.addManualPeer('192.168.1.23');
    await provider.addManualPeer('192.168.1.24');
    await provider.addManualPeer('192.168.1.25');
    await pumpPage(tester);
    // 底层明细在「高级设置」子页。
    await openAdvanced(tester);

    expect(
      find.byKey(const Key('settingsSyncPeerCandidatesItem')),
      findsOneWidget,
    );
    expect(find.text('3 available addresses'), findsOneWidget);
    expect(
        find.byKey(const Key('settingsSyncPeer-192.168.1.24')), findsNothing);

    await tester.tap(find.byKey(const Key('settingsSyncPeerCandidatesItem')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const Key('settingsSyncPeer-192.168.1.24')), findsOneWidget);

    // 点开单项 → 详情弹层 → 移除地址。
    await tester.tap(find.byKey(const Key('settingsSyncPeer-192.168.1.24')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove address'));
    await tester.pumpAndSettle();
    expect(provider.manualPeers, hasLength(2));
  });

  testWidgets('名册行内联：对端行有名称与最后同步时间', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    transport.available.add(SyncEnvelope(
      deviceId: 'devB',
      deviceName: 'Device B',
      producedAt: 9000,
      records: {
        SyncCategory.settings: [
          SyncRecord(
            key: 'theme_mode',
            version: const SyncVersion(physical: 9000, deviceId: 'devB'),
            data: {'v': 'dark'},
          ),
        ],
      },
    ));
    await provider.syncNow(manual: true);
    await pumpPage(tester);

    expect(find.text('Device B'), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncPeer-devB')), findsOneWidget);
    expect(find.textContaining('Last synced'), findsOneWidget);
  });

  /// 设备卡片 footer（同步中 / 本轮已连接设备名）。
  String peersFooter(WidgetTester tester) {
    final card = find.ancestor(
      of: find.text('Devices'),
      matching: find.byType(SettingsSectionCard),
    );
    return tester
        .widget<SettingsSectionHint>(
          find.descendant(of: card, matching: find.byType(SettingsSectionHint)),
        )
        .text;
  }

  String peerSubtitle(WidgetTester tester, String deviceId) => tester
      .widget<SettingsNavTile>(
        find.byKey(Key('settingsSyncPeer-$deviceId')),
      )
      .subtitle;

  testWidgets('打开同步页自动跑一轮检查（任一路传输开启时）', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    final before = transport.pullCount;
    expect(provider.lastReport, isNull);

    await pumpPage(tester);

    expect(transport.pullCount, before + 1);
    expect(provider.lastReport, isNotNull);
  });

  testWidgets('设备区脚注：同步中显示「正在同步…」，完成后给本轮结论', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    final gate = Completer<void>();
    transport.onPull = () => gate.future;
    final inFlight = provider.syncNow(manual: true);

    await pumpPage(tester);
    expect(peersFooter(tester), 'Syncing…');

    gate.complete();
    await inFlight;
    await tester.pumpAndSettle();
    expect(peersFooter(tester), 'No devices connected this round');
  });

  testWidgets('设备行五态：已连接 / 未连接 / 上次同步 / 还没连上 / 已失联；WebDAV 不冒充已连接',
      (tester) async {
    // 失联阈值是 180 天：用真实纪元时钟，才能表达「成功在阈值之前」。
    nowMs = DateTime.now().millisecondsSinceEpoch;
    // 先跑一轮拿到「本轮起点」，再关掉传输阻止页面自动再跑一轮。
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await provider.syncNow(manual: true);
    final startedAt = provider.lastReport!.startedAt;
    await provider.setTransportEnabled(SyncTransportKind.lan, false);

    final now = provider.nowMs;
    state.recordRound(SyncRoundReport(
      trigger: SyncTrigger.manual,
      startedAt: startedAt,
      finishedAt: startedAt + 1,
      outcome: SyncOutcome.ok,
      peers: [
        SyncPeerState(
          deviceId: 'connectedA',
          name: 'Device A',
          transport: SyncTransportKind.lan,
          lastSeenAt: startedAt + 4,
          lastSuccessAt: startedAt + 4,
        ),
        SyncPeerState(
          deviceId: 'connectedB',
          name: 'Device B',
          transport: SyncTransportKind.lan,
          lastSeenAt: startedAt + 3,
          lastSuccessAt: startedAt + 3,
        ),
        SyncPeerState(
          deviceId: 'connectedC',
          name: 'Device C',
          transport: SyncTransportKind.lan,
          lastSeenAt: startedAt + 2,
          lastSuccessAt: startedAt + 2,
        ),
        SyncPeerState(
          deviceId: 'webdav',
          name: 'Cloud',
          transport: SyncTransportKind.webdav,
          lastSeenAt: startedAt + 1,
          lastSuccessAt: startedAt + 1,
        ),
        SyncPeerState(
          deviceId: 'unreachable',
          name: 'Offline',
          transport: SyncTransportKind.lan,
          lastSeenAt: startedAt + 5,
          lastSuccessAt: startedAt - 5000,
          lastError: const SyncIssue(code: SyncIssueCode.peerReadFailed),
        ),
        SyncPeerState(
          deviceId: 'idle',
          name: 'Idle',
          transport: SyncTransportKind.lan,
          lastSeenAt: startedAt - 5000,
          lastSuccessAt: startedAt - 5000,
        ),
        SyncPeerState(deviceId: 'never', name: 'Never'),
        SyncPeerState(
          deviceId: 'lost',
          name: 'Lost',
          transport: SyncTransportKind.lan,
          // 最近尝试是刚刚，但最近成功超过 180 天：失败尝试不续命。
          lastSeenAt: now,
          lastSuccessAt: now - SyncPeerState.lostThresholdMs - 1,
        ),
      ],
    ));
    provider.notifyListeners();
    await pumpPage(tester);

    expect(peerSubtitle(tester, 'connectedA'),
        allOf(contains('Connected'), contains('Last synced')));
    expect(peerSubtitle(tester, 'unreachable'),
        allOf(contains('Not connected'), contains('Last synced')));
    expect(peerSubtitle(tester, 'idle'), contains('Last synced'));
    expect(peerSubtitle(tester, 'idle'), isNot(contains('Connected')));
    expect(peerSubtitle(tester, 'never'), contains('Not connected yet'));
    expect(peerSubtitle(tester, 'lost'), allOf(contains('lost'), contains('180 days')));
    // WebDAV 设备只可能是「云端已同步」，不能说「已连接」。
    expect(peerSubtitle(tester, 'webdav'), contains('Synced to cloud'));
    expect(peerSubtitle(tester, 'webdav'), isNot(contains('Connected')));

    // 脚注：最多两个名字 + 等 N 台（本轮连上 4 台，含云端设备）。
    expect(
      peersFooter(tester),
      'Connected: Device A, Device B and 2 more',
    );
  });

  testWidgets('失联设备：名册标记 + 清理远端 / 从本机移除', (tester) async {
    // 注入时钟：失联阈值 = 180 天（与 lostPeers 判定同一时钟源）。
    nowMs = DateTime.now().millisecondsSinceEpoch;
    seedPeer('ghost', lastSeenAt: nowMs - SyncPeerState.lostThresholdMs - 1000);
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await pumpPage(tester);
    expect(find.textContaining('lost'), findsOneWidget);

    // 清理远端文件（二次确认后调用传输）。
    transport.deleteRemoteResult = true;
    await tester.tap(find.byKey(const Key('settingsSyncPeer-ghost')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('This device has not connected for over 180 days'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('settingsSyncPeerCleanup-ghost')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(transport.deletedRemotes, ['ghost']);
    expect(notifications.last, 'Cloud files cleaned up');

    // 再从本机移除：名册行消失（不写屏蔽，设备在线时仍可能重新出现）。
    await tester.tap(find.byKey(const Key('settingsSyncPeer-ghost')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove device'));
    await tester.pumpAndSettle();
    expect(provider.peers, isEmpty);
    expect(find.byKey(const Key('settingsSyncPeer-ghost')), findsNothing);
    expect(notifications.last, 'Removed from this device');
  });

  testWidgets('自动发现的设备也能从本机移除（不依赖地址簿条目）', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    transport.available.add(SyncEnvelope(
      deviceId: 'devB',
      deviceName: 'Device B',
      producedAt: 9000,
      records: const {},
    ));
    await provider.syncNow(manual: true);
    await pumpPage(tester);
    expect(find.byKey(const Key('settingsSyncPeer-devB')), findsOneWidget);
    expect(provider.manualPeers, isEmpty);

    await tester.tap(find.byKey(const Key('settingsSyncPeer-devB')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove device'));
    await tester.pumpAndSettle();

    expect(provider.peers, isEmpty);
    expect(find.byKey(const Key('settingsSyncPeer-devB')), findsNothing);
    expect(notifications.last, 'Removed from this device');
  });

  testWidgets('名册展示优先用户命名，对端自报名仅兜底', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await provider.addManualPeer('192.168.1.23', name: '书房');
    await state.learnManualPeer(const ManualPeer(
      host: '192.168.1.23',
      deviceId: 'devB',
      httpPort: 40000,
    ));
    transport.available.add(SyncEnvelope(
      deviceId: 'devB',
      deviceName: 'Device B',
      producedAt: 5000,
      records: const {},
    ));
    transport.available.add(SyncEnvelope(
      deviceId: 'devC',
      deviceName: 'Device C',
      producedAt: 5000,
      records: const {},
    ));
    await provider.syncNow(manual: true);

    await pumpPage(tester);
    // devB 在地址簿里有用户命名 → 用它；devC 无命名 → 用对端自报名。
    expect(find.text('书房'), findsOneWidget);
    expect(find.text('Device B'), findsNothing);
    expect(find.text('Device C'), findsOneWidget);

    // 详情弹层标题与名册行同一称谓。
    await tester.tap(find.byKey(const Key('settingsSyncPeer-devB')));
    await tester.pumpAndSettle();
    expect(find.text('书房'), findsWidgets);
    expect(find.text('Device B'), findsNothing);
  });

  testWidgets('同步在途时保存设备：不判未连上，提示稍后自动连接', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    // 先完成一轮，留下历史报告（排队路径拿到的正是这份旧报告）。
    await provider.syncNow(manual: true);

    final gate = Completer<void>();
    transport.onPull = () => gate.future;
    final inFlight = provider.syncNow(manual: true);
    await pumpPage(tester);
    await openManualConnect(tester);

    await tester.enterText(fieldAt(0), '192.168.1.23');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // 本轮被排队、结果未知：不判「没连上」，也不把弹层留在原地。
    expect(notifications.last, 'Device added — it will connect shortly');
    expect(find.textContaining('Not reachable'), findsNothing);
    expect(find.text('Save'), findsNothing);

    gate.complete();
    await inFlight;
    await tester.pumpAndSettle();
  });

  testWidgets('同步内容子页：类别开关可切、蜂窝暂停在页内，入口副文案跟随', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await pumpPage(tester);
    expect(find.text('All categories'), findsOneWidget);

    await openSubPage(tester, 'settingsSyncContentItem');
    expect(find.byType(SyncContentPage), findsOneWidget);

    await tester.tap(find.byKey(const Key('settingsSyncCategory-statistics')));
    await tester.pumpAndSettle();
    expect(provider.categories[SyncCategory.statistics], isFalse);

    expect(provider.cellularPolicy, SyncCellularPolicy.auto);
    await tester.tap(find.byKey(const Key('settingsSyncCellularPauseSwitch')));
    await tester.pumpAndSettle();
    expect(provider.cellularPolicy, SyncCellularPolicy.pause);

    // 返回：内容入口副文案给「已关闭 1 项」。
    await tester.tap(find.byType(BackButtonIcon));
    await tester.pumpAndSettle();
    expect(find.text('1 turned off'), findsOneWidget);
  });

  testWidgets('日志与诊断子页：24h 动态行与环境行', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    // 手动一轮 + 打开页面自动一轮：日志里出现 2 条无对端轮次。
    await provider.syncNow(manual: true);
    await pumpPage(tester);
    expect(find.byKey(const Key('settingsSyncActivityItem')), findsNothing);

    await openSubPage(tester, 'settingsSyncLogItem');
    expect(find.text('Last 24 hours'), findsOneWidget);
    expect(
      find.textContaining('2 runs, 0 with changes'),
      findsOneWidget,
    );
    // 环境行：未注入调度器 → 等级「未运行」；非移动数据；非省电。
    expect(
      find.textContaining('not running · Wi-Fi / other · power save off'),
      findsOneWidget,
    );
  });

  testWidgets('日志子页：完整日志（超过 6 条不截断），入口副文案跟随', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    for (var i = 0; i < 7; i++) {
      await provider.syncNow(manual: true);
    }
    await pumpPage(tester);

    // 首屏不渲染日志行；入口副文案给最近一轮结论 + 时间。
    expect(find.byType(SyncLogRow), findsNothing);
    expect(find.text('Sync log'), findsOneWidget);

    await openSubPage(tester, 'settingsSyncLogItem');
    // 7 次手动 + 打开页面自动 1 次。
    expect(find.byType(SyncLogRow), findsNWidgets(8));
  });

  testWidgets('日志入口副文案：无记录说「暂无记录」，有记录给最近结论', (tester) async {
    // 两路关闭时打开：页面不自动跑轮次，才能验证「暂无记录」。
    await pumpPage(tester);
    expect(find.text('No records yet'), findsOneWidget);

    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await provider.syncNow(manual: true);
    await tester.pumpAndSettle();
    expect(find.text('No records yet'), findsNothing);
    final logTile = tester
        .widget<SettingsNavTile>(find.byKey(const Key('settingsSyncLogItem')));
    expect(logTile.subtitle, contains('No other device found'));
    expect(logTile.subtitle, contains('just now'));
  });

  testWidgets('WebDAV 启用后才出现配置入口，副文案给地址 / 未配置', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await pumpPage(tester);
    expect(find.byKey(const Key('settingsSyncWebdavConfigItem')), findsNothing);

    await tester.tap(find.byKey(const Key('settingsSyncWebdavSwitch')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const Key('settingsSyncWebdavConfigItem')), findsOneWidget);
    expect(find.text('Not configured'), findsOneWidget);
  });

  testWidgets('日志子页不提供诊断导出入口', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await pumpPage(tester);
    expect(find.byKey(const Key('settingsSyncDiagnosticItem')), findsNothing);

    await openSubPage(tester, 'settingsSyncLogItem');
    expect(find.byKey(const Key('settingsSyncDiagnosticItem')), findsNothing);
    expect(find.text('Copy diagnostics'), findsNothing);
    expect(find.text('Diagnostics'), findsNothing);
  });

  testWidgets('局域网权限被永久拒绝：动作是「去系统设置」', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    transport.unavailableReason = SyncUnavailableReason.permissionDenied;
    var opened = 0;
    final permission = LocalNetworkPermission(
      needsPermission: true,
      request: () async => LocalNetworkPermissionStatus.permanentlyDenied,
      check: () async => LocalNetworkPermissionStatus.permanentlyDenied,
      openSettings: () async => opened++,
    );
    await permission.refresh();
    provider.dispose();
    provider = SyncProvider(
      engine: engine,
      controlPlane: control,
      backup: backup,
      lanPermission: permission,
      localEndpoints: fakeEndpoints(),
    );
    await provider.init();
    await pumpPage(tester);

    expect(
      find.byKey(const Key('settingsSyncLanPermissionItem')),
      findsOneWidget,
    );
    // 永久拒绝时系统不弹窗：UI 不给「授予权限」，直接指去系统设置。
    expect(find.text('Open settings'), findsOneWidget);
    expect(find.text('Grant LAN permission'), findsNothing);
    await tester.tap(find.byKey(const Key('settingsSyncLanPermissionItem')));
    await tester.pumpAndSettle();
    expect(opened, 1);
  });

  testWidgets('局域网权限可再申请：动作是「授予权限」', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    transport.unavailableReason = SyncUnavailableReason.permissionDenied;
    var requested = 0;
    final permission = LocalNetworkPermission(
      needsPermission: true,
      request: () async {
        requested++;
        return LocalNetworkPermissionStatus.granted;
      },
      check: () async => LocalNetworkPermissionStatus.denied,
    );
    provider.dispose();
    provider = SyncProvider(
      engine: engine,
      controlPlane: control,
      backup: backup,
      lanPermission: permission,
      localEndpoints: fakeEndpoints(),
    );
    await provider.init();
    await pumpPage(tester);

    expect(find.text('Grant LAN permission'), findsOneWidget);
    await tester.tap(find.byKey(const Key('settingsSyncLanPermissionItem')));
    await tester.pumpAndSettle();
    expect(requested, 1);
  });

  testWidgets('失败行按原因给可点动作：手动地址 / WebDAV / 重试', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    transport.pullError = const SyncIssue(code: SyncIssueCode.discoverySilent);
    await provider.syncNow(manual: true);
    await pumpPage(tester);

    await openSubPage(tester, 'settingsSyncLogItem');
    // 零应答（区别于从未发现）：日志行可点开下一步动作。打开页面自动跑的
    // 一轮会留下第二条同样的失败记录，点最新一条即可。
    expect(find.byType(SyncLogRow), findsWidgets);
    expect(find.textContaining('the network may be isolated'), findsWidgets);
    await tester.tap(find.byType(SyncLogRow).first);
    await tester.pumpAndSettle();

    expect(find.text('Add manual address'), findsOneWidget);
    expect(find.text('Use WebDAV'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    // 对话框约定：action 区只有「取消 + filled 确认」两颗，其余在内容区。
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is M3EButton && widget.style == M3EButtonStyle.filled,
      ),
      findsOneWidget,
    );
  });

  testWidgets('探测端口不可用：动作同样给手动地址出路', (tester) async {
    // 桌面不构建扫码入口（弹层里只有粘贴）。
    SyncPairingScanner.debugPlatformOverride = TargetPlatform.linux;
    addTearDown(() => SyncPairingScanner.debugPlatformOverride = null);
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    transport.pullError =
        const SyncIssue(code: SyncIssueCode.probePortUnavailable);
    await provider.syncNow(manual: true);
    await pumpPage(tester);

    await openSubPage(tester, 'settingsSyncLogItem');
    await tester.tap(find.byType(SyncLogRow).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('Auto-discovery unavailable'), findsWidgets);
    expect(find.text('Add manual address'), findsOneWidget);
    // 「添加手动地址」直接打开手动连接弹层（不跳页）。
    await tester.tap(find.text('Add manual address'));
    await tester.pumpAndSettle();
    expect(find.text('Connect manually'), findsWidgets);
    expect(find.text('Address'), findsWidgets);
  });

  testWidgets('传输副文案：启动失败只说状态词（原始细节不上界面）', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    transport.unavailableReason = SyncUnavailableReason.startFailed;
    transport.unavailableDetail = 'SocketException: 端口占用';
    await transport.stop();
    await pumpPage(tester);

    expect(find.textContaining('failed to start'), findsOneWidget);
    expect(find.textContaining('SocketException'), findsNothing);
    // 「最后成功」不进首屏（诊断导出里有）。
    expect(find.textContaining('Last success'), findsNothing);
  });

  testWidgets('传输关闭：副文案中性「已关闭」，不显示残留失败原因', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    transport.unavailableReason = SyncUnavailableReason.startFailed;
    transport.unavailableDetail = 'SocketException: 端口占用';
    await transport.stop();
    await provider.setTransportEnabled(SyncTransportKind.lan, false);
    await pumpPage(tester);

    expect(find.text('turned off'), findsOneWidget);
    expect(find.textContaining('failed to start'), findsNothing);
    // 中性色：关闭不是异常状态（不挂 warning）。
    final tile = tester.widget<SettingsSwitchTile>(
      find.ancestor(
        of: find.byKey(const Key('settingsSyncLanSwitch')),
        matching: find.byType(SettingsSwitchTile),
      ),
    );
    expect(tile.subtitleColor, isNull);
  });

  testWidgets('传输副文案：成功接触后状态词仍是「运行中」，颜色走成功色', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    transport.available.add(SyncEnvelope(
      deviceId: 'devB',
      deviceName: 'Device B',
      producedAt: 5000,
      records: const {},
    ));
    await provider.syncNow(manual: true);
    await pumpPage(tester);

    final finder = find.byKey(const Key('settingsSyncLanSwitch'));
    final tile = tester.widget<SettingsSwitchTile>(
      find.ancestor(of: finder, matching: find.byType(SettingsSwitchTile)),
    );
    expect(tile.subtitle, 'running');
    expect(
      tile.subtitleColor,
      AppSemanticColors.of(tester.element(finder)).success,
    );
  });
}
