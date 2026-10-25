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
import 'package:molia/data/sync/sync_scheduler.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/data/sync/transport/local_network_permission.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/ports/sync_transport.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/sync_content_page.dart';
import 'package:molia/pages/sync_log_page.dart';
import 'package:molia/pages/sync_settings_page.dart';
import 'package:molia/providers/sync_provider.dart';
import 'package:molia/services/battery_probe.dart';
import 'package:molia/services/language_service.dart';
import 'package:molia/services/notification_service.dart';
import 'package:molia/services/local_endpoints_service.dart';
import 'package:molia/theme/app_semantic_colors.dart';
import 'package:molia/widgets/settings/settings_tiles.dart';

import 'support/notification_recorder.dart';
import 'support/sync_test_support.dart';

/// 同步设置页：首屏 = 传输方式（局域网 / WebDAV，开关即总闸）/ 已配对设备 /
/// 附近设备 / 内容 · 日志 · 高级；设备名、口令、地址与端口在「高级设置」子页
/// （`SyncAdvancedPage`）。旧配对码（复制 / 粘贴 / 扫码）入口已删除。
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

  /// 假接口数据：地址列表用例断言具体地址。
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
          lastSuccessAt: lastSeenAt,
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
    // 口令在初始化时就绪：附近设备配对随时可用，不等任何开关。
    expect(provider.passphrase, isNotNull);
    expect(find.text('turned off'), findsOneWidget, reason: '局域网默认关');
    expect(
      find.textContaining('both methods are off'),
      findsOneWidget,
      reason: 'footer 说明「同步不会运行」，免得把没同步误读成故障',
    );

    // 设备 / 附近设备 / 内容入口不依赖总开关：始终可见。
    expect(find.byKey(const Key('settingsSyncPeersEmpty')), findsOneWidget);
    expect(find.text('Nearby devices'), findsOneWidget);
    // 旧配对码入口（复制 / 粘贴 / 扫码）已删除。
    expect(find.byKey(const Key('settingsSyncPasteCodeItem')), findsNothing);
    expect(find.byKey(const Key('settingsSyncScanCodeItem')), findsNothing);
    expect(find.byKey(const Key('settingsSyncContentItem')), findsOneWidget);
    // 底层信息仍在高级子页，不暴露在首屏。
    expect(find.text('This device'), findsNothing);
    expect(find.byKey(const Key('settingsSyncDeviceNameItem')), findsNothing);
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
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await pumpPage(tester);
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
    expect(notifications.last, 'Address copied');

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
    expect(notifications.last, 'Full device ID copied');
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

    // 口令由附近设备配对自动传递：手输口令 / 粘贴配对码路径已删除。
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

  test('contactManualPeer：没有一轮真正跑（同步关闭）时返回 null', () async {
    expect(provider.enabled, isFalse);
    expect(await provider.contactManualPeer('192.168.1.23'), isNull);
    expect(provider.lastReport, isNull, reason: 'null 不冒充任何一轮结论');
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

  testWidgets('多个未认领地址：折叠为一行，点开可查看 / 删除', (tester) async {
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
    expect(find.textContaining('last synced'), findsOneWidget);
  });

  /// 设备卡片 footer（同步中 / 本轮已同步设备名）。
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

  testWidgets('打开同步页自动检查：经调度器跑 check 轮，不是 manual', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    final scheduler = SyncScheduler(
      host: engine,
      state: state,
      cellularProbe: () async => false,
      batteryProbe: () async => BatterySnapshot.unknown,
    );
    provider.dispose();
    provider = SyncProvider(
      engine: engine,
      controlPlane: control,
      backup: backup,
      scheduler: scheduler,
      localEndpoints: fakeEndpoints(),
    );
    await provider.init();
    final before = transport.pullCount;
    expect(provider.lastReport, isNull);

    await pumpPage(tester);

    expect(transport.pullCount, before + 1);
    expect(provider.lastReport, isNotNull);
    expect(provider.lastReport!.trigger, SyncTrigger.check);
  });

  testWidgets('未注入调度器：打开同步页不直接跑引擎（不绕过策略）', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    final before = transport.pullCount;

    await pumpPage(tester);

    expect(transport.pullCount, before);
    expect(provider.lastReport, isNull);
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
    // 先跑一轮拿到「本轮起点」（页面本身不注入调度器，不会自动再跑）。
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await provider.syncNow(manual: true);
    final startedAt = provider.lastReport!.startedAt;

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
        // 只有失败尝试、从未成功过：不能说「未连接 · 上次同步」。
        SyncPeerState(
          deviceId: 'failedOnly',
          name: 'Failed only',
          transport: SyncTransportKind.lan,
          lastSeenAt: startedAt + 6,
          lastError: const SyncIssue(code: SyncIssueCode.peerReadFailed),
        ),
        // WebDAV 从未同步成功：也不能说「云端未同步」（那暗示同步过）。
        SyncPeerState(
          deviceId: 'webdavNever',
          name: 'Cloud never',
          transport: SyncTransportKind.webdav,
          lastSeenAt: startedAt + 7,
          lastError: const SyncIssue(code: SyncIssueCode.webdavReadFailed),
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
        allOf(contains('Connected'), contains('last synced')));
    expect(peerSubtitle(tester, 'unreachable'),
        allOf(contains('Not connected'), contains('last synced')));
    expect(peerSubtitle(tester, 'idle'), contains('Last synced'));
    expect(peerSubtitle(tester, 'idle'), isNot(contains('Connected')));
    expect(peerSubtitle(tester, 'never'), contains('Not connected yet'));
    // 失败过但从未成功：也是「还没连上」，不是带上次同步时间的「未连接」。
    expect(peerSubtitle(tester, 'failedOnly'), contains('Not connected yet'));
    expect(peerSubtitle(tester, 'failedOnly'), isNot(contains('last synced')));
    // WebDAV 从未同步成功：不能显示「云端未同步」（暗示曾经同步过）。
    expect(peerSubtitle(tester, 'webdavNever'), contains('Not connected yet'));
    expect(
      peerSubtitle(tester, 'webdavNever'),
      isNot(contains('Not synced to cloud')),
    );
    // 失联行只给结论 + 上次成功；180 天解释在详情弹层。
    expect(
      peerSubtitle(tester, 'lost'),
      allOf(contains('Lost'), contains('last synced')),
    );
    expect(peerSubtitle(tester, 'lost'), isNot(contains('180 days')));
    // WebDAV 设备只可能是「云端已同步」，不能说「已连接」。
    expect(peerSubtitle(tester, 'webdav'), contains('Synced to cloud'));
    expect(peerSubtitle(tester, 'webdav'), isNot(contains('Connected')));

    // 脚注用传输中性的「本轮已同步」：云端设备也同步过，但不算「已连接」。
    expect(
      peersFooter(tester),
      'Synced this round: Device A, Device B and 2 more',
    );
    expect(peersFooter(tester), isNot(contains('Connected')));
  });

  testWidgets('设备区脚注：有名册但还没有本轮报告 → 还没有连接记录', (tester) async {
    // 只有持久化名册、本次进程还没跑过轮次：不能说「本轮没有连上设备」。
    seedPeer('devB', lastSeenAt: provider.nowMs - 60 * 1000);
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    expect(provider.lastReport, isNull);

    await pumpPage(tester);

    expect(peersFooter(tester), 'No connection records yet');
  });

  testWidgets('设备区脚注：只有云端设备时不说「已连接」', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await provider.syncNow(manual: true);
    final startedAt = provider.lastReport!.startedAt;
    state.recordRound(SyncRoundReport(
      trigger: SyncTrigger.manual,
      startedAt: startedAt,
      finishedAt: startedAt + 1,
      outcome: SyncOutcome.ok,
      peers: [
        SyncPeerState(
          deviceId: 'cloud',
          name: 'Cloud',
          transport: SyncTransportKind.webdav,
          lastSeenAt: startedAt + 1,
          lastSuccessAt: startedAt + 1,
        ),
      ],
    ));
    provider.notifyListeners();

    await pumpPage(tester);

    expect(peersFooter(tester), 'Synced this round: Cloud');
    expect(peersFooter(tester), isNot(contains('Connected')));
    expect(peerSubtitle(tester, 'cloud'), contains('Synced to cloud'));
  });

  testWidgets('设备区脚注：局域网 + 云端混合只按「已同步」汇总', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await provider.syncNow(manual: true);
    final startedAt = provider.lastReport!.startedAt;
    state.recordRound(SyncRoundReport(
      trigger: SyncTrigger.manual,
      startedAt: startedAt,
      finishedAt: startedAt + 1,
      outcome: SyncOutcome.ok,
      peers: [
        SyncPeerState(
          deviceId: 'lanA',
          name: 'Device A',
          transport: SyncTransportKind.lan,
          lastSeenAt: startedAt + 3,
          lastSuccessAt: startedAt + 3,
        ),
        SyncPeerState(
          deviceId: 'lanB',
          name: 'Device B',
          transport: SyncTransportKind.lan,
          lastSeenAt: startedAt + 2,
          lastSuccessAt: startedAt + 2,
        ),
        SyncPeerState(
          deviceId: 'cloud',
          name: 'Cloud',
          transport: SyncTransportKind.webdav,
          lastSeenAt: startedAt + 1,
          lastSuccessAt: startedAt + 1,
        ),
      ],
    ));
    provider.notifyListeners();

    await pumpPage(tester);

    expect(
      peersFooter(tester),
      'Synced this round: Device A, Device B and 1 more',
    );
    expect(peersFooter(tester), isNot(contains('Connected')));
  });

  testWidgets('失联设备：名册标记 + 清理远端 / 从本机移除', (tester) async {
    // 注入时钟：失联阈值 = 180 天（与 lostPeers 判定同一时钟源）。
    nowMs = DateTime.now().millisecondsSinceEpoch;
    seedPeer('ghost', lastSeenAt: nowMs - SyncPeerState.lostThresholdMs - 1000);
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await pumpPage(tester);
    expect(find.textContaining('Lost'), findsOneWidget);

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

  testWidgets('同步在途时保存设备：等补跑轮给出结论，不拿上一轮报告冒充', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    // 先完成一轮，留下历史报告（旧实现会把这份旧报告当成本轮结果）。
    await provider.syncNow(manual: true);

    var pulls = 0;
    final gate = Completer<void>();
    transport.onPull = () async {
      pulls++;
      if (pulls == 1) {
        // 在途轮：卡住，模拟一轮还没跑完。
        await gate.future;
        return;
      }
      // 补跑轮：对端应答，地址簿学到身份，本轮算接触成功。
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
    };
    final inFlight = provider.syncNow(manual: true);
    await pumpPage(tester);
    await openManualConnect(tester);

    await tester.enterText(fieldAt(0), '192.168.1.23');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // 请求已排队、补跑轮还没跑：等待本轮结论，不判「没连上」也不关弹层。
    expect(notifications.isEmpty, isTrue);
    expect(find.text('Connecting…'), findsOneWidget);
    expect(find.textContaining('Not reachable'), findsNothing);
    expect(find.text('Save'), findsNothing);

    gate.complete();
    await inFlight;
    await tester.pumpAndSettle();

    // 补跑轮真正接触成功：按该轮报告关闭弹层并提示已添加。
    expect(notifications.last, 'Device added');
    expect(find.text('Save'), findsNothing);
    expect(find.textContaining('Not reachable'), findsNothing);
  });

  testWidgets('同步内容子页：类别开关可切、蜂窝暂停在页内，入口副文案跟随', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await pumpPage(tester);
    expect(find.text('1 turned off'), findsOneWidget, reason: '自定义封面默认关闭');

    await openSubPage(tester, 'settingsSyncContentItem');
    expect(find.byType(SyncContentPage), findsOneWidget);
    expect(provider.categories[SyncCategory.covers], isFalse);

    // 自定义封面默认关闭；在内容页打开后与同步设置同源。
    await tester.tap(find.byKey(const Key('settingsSyncCategory-covers')));
    await tester.pumpAndSettle();
    expect(provider.categories[SyncCategory.covers], isTrue);

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
    // 手动一轮：日志里出现一条无对端轮次（0 字节、0 落地）。
    await provider.syncNow(manual: true);
    await pumpPage(tester);
    expect(find.byKey(const Key('settingsSyncActivityItem')), findsNothing);

    await openSubPage(tester, 'settingsSyncLogItem');
    expect(find.text('Last 24 hours'), findsOneWidget);
    expect(
      find.textContaining('1 runs, 0 with changes'),
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
    expect(find.byType(SyncLogRow), findsNWidgets(7));
  });

  testWidgets('日志入口副文案：无记录说「暂无记录」，有记录给最近结论', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    await pumpPage(tester);
    expect(find.text('No records yet'), findsOneWidget);

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

  testWidgets('局域网权限被永久拒绝：警告行动作是「去系统设置」', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    transport.unavailableReason = SyncUnavailableReason.permissionDenied;
    var opened = 0;
    var requested = 0;
    final permission = LocalNetworkPermission(
      needsPermission: true,
      request: () async {
        requested++;
        return LocalNetworkPermissionStatus.permanentlyDenied;
      },
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
    // 与桌面歌词未授权提示同款：常驻警告行 + 去授权动作。
    expect(find.text('LAN permission required'), findsOneWidget);
    // 永久拒绝时系统不弹窗：动作改为去系统设置。
    expect(find.text('Open settings'), findsOneWidget);
    expect(find.text('Grant'), findsNothing);
    expect(requested, 0, reason: '永久拒绝不应再向系统请求');
    await tester.tap(
      find.byKey(const Key('settingsSyncLanPermissionGrant')),
    );
    await tester.pumpAndSettle();
    expect(opened, 1);
  });

  testWidgets('局域网权限可再申请：警告行动作是「去授权」', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    var requested = 0;
    final permission = LocalNetworkPermission(
      needsPermission: true,
      request: () async {
        requested++;
        return LocalNetworkPermissionStatus.granted;
      },
      check: () async => LocalNetworkPermissionStatus.denied,
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

    expect(find.text('LAN permission required'), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('settingsSyncLanPermissionGrant')),
    );
    await tester.pumpAndSettle();
    expect(requested, 1);
    expect(
      find.byKey(const Key('settingsSyncLanPermissionItem')),
      findsNothing,
    );
  });

  testWidgets('开启局域网开关：先申请权限，授权后启用', (tester) async {
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

    await tester.tap(find.byKey(const Key('settingsSyncLanSwitch')));
    await tester.pumpAndSettle();

    expect(requested, 1, reason: '开关即申请，不等传输启动时才问');
    expect(provider.enabledTransports, contains(SyncTransportKind.lan));
    expect(
      find.byKey(const Key('settingsSyncLanPermissionItem')),
      findsNothing,
    );
    expect(notifications.isEmpty, isTrue, reason: '授权成功不弹错误提示');
  });

  testWidgets('开启局域网被拒：开关回到关闭，底栏提示并可重试', (tester) async {
    var requested = 0;
    var granted = false;
    final permission = LocalNetworkPermission(
      needsPermission: true,
      request: () async {
        requested++;
        return granted
            ? LocalNetworkPermissionStatus.granted
            : LocalNetworkPermissionStatus.denied;
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

    await tester.tap(find.byKey(const Key('settingsSyncLanSwitch')));
    await tester.pumpAndSettle();

    expect(requested, 1);
    expect(provider.enabledTransports, isNot(contains(SyncTransportKind.lan)));
    expect(notifications.last, 'LAN permission required');
    expect(notifications.lastActionLabel, 'Grant');
    // 底栏提示之外，开关下保留与桌面歌词同款的常驻警告行。
    expect(
      find.byKey(const Key('settingsSyncLanPermissionItem')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('settingsSyncLanPermissionGrant')),
      findsOneWidget,
    );

    // 底栏「去授权」重试：这次授予，开关打开、警告行消失。
    granted = true;
    notifications.lastAction!.call();
    await tester.pumpAndSettle();
    expect(requested, 2);
    expect(provider.enabledTransports, contains(SyncTransportKind.lan));
    expect(
      find.byKey(const Key('settingsSyncLanPermissionItem')),
      findsNothing,
    );
  });

  testWidgets('开启局域网永久拒绝：开关关闭，提示动作去系统设置', (tester) async {
    var requested = 0;
    var opened = 0;
    final permission = LocalNetworkPermission(
      needsPermission: true,
      request: () async {
        requested++;
        return LocalNetworkPermissionStatus.denied;
      },
      check: () async => LocalNetworkPermissionStatus.permanentlyDenied,
      openSettings: () async => opened++,
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

    await tester.tap(find.byKey(const Key('settingsSyncLanSwitch')));
    await tester.pumpAndSettle();

    expect(requested, 0, reason: '永久拒绝时系统不再弹窗，不应请求');
    expect(provider.enabledTransports, isNot(contains(SyncTransportKind.lan)));
    expect(notifications.last, 'LAN permission required');
    expect(notifications.lastActionLabel, 'Open settings');
    expect(
      find.byKey(const Key('settingsSyncLanPermissionItem')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const Key('settingsSyncLanPermissionGrant')),
    );
    await tester.pumpAndSettle();
    expect(opened, 1);
  });

  testWidgets('失败行按原因给可点动作：手动地址 / WebDAV / 重试', (tester) async {
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    transport.pullError = const SyncIssue(code: SyncIssueCode.discoverySilent);
    await provider.syncNow(manual: true);
    await pumpPage(tester);

    await openSubPage(tester, 'settingsSyncLogItem');
    // 零应答（区别于从未发现）：日志行可点开下一步动作。
    expect(find.byType(SyncLogRow), findsOneWidget);
    expect(find.textContaining('the network may be isolated'), findsWidgets);
    await tester.tap(find.byType(SyncLogRow));
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
    await provider.setTransportEnabled(SyncTransportKind.lan, true);
    transport.pullError =
        const SyncIssue(code: SyncIssueCode.probePortUnavailable);
    await provider.syncNow(manual: true);
    await pumpPage(tester);

    await openSubPage(tester, 'settingsSyncLogItem');
    await tester.tap(find.byType(SyncLogRow));
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
