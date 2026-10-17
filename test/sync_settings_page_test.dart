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
import 'package:molia/services/local_endpoints_service.dart';
import 'package:molia/theme/app_semantic_colors.dart';
import 'package:molia/widgets/settings/settings_tiles.dart';
import 'package:molia/widgets/sync_pairing_qr.dart';
import 'package:molia/widgets/sync_pairing_scanner.dart';

import 'support/sync_test_support.dart';

/// 同步设置页（配对工作台）：一页闭环 = 开关 / 本机 / 设备 / 传输 / 内容 / 日志。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const keys = [kThemeMode];

  late SyncStateStore state;
  late FakeSyncTransport transport;
  late SyncEngine engine;
  late SyncProvider provider;
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
      // 与状态存储同一时钟源（观测面的窗口过滤依赖时间戳一致）。
      clock: () => DateTime.fromMillisecondsSinceEpoch(state.nowMs()),
    );
    provider = SyncProvider(engine: engine, localEndpoints: fakeEndpoints());
    await provider.init();
  });

  tearDown(() async {
    provider.dispose();
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
      ChangeNotifierProvider<SyncProvider>.value(
        value: provider,
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

  Future<void> openAddDialog(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('settingsSyncAddPeerItem')));
    await tester.pumpAndSettle();
  }

  Future<void> openRenameDialog(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('settingsSyncDeviceNameItem')));
    await tester.pumpAndSettle();
  }

  Finder fieldAt(int index) => find.byType(EditableText).at(index);

  /// 首屏总开关行（副文案 = 一句话状态）。
  SettingsSwitchTile syncSwitchTile(WidgetTester tester) =>
      tester.widget<SettingsSwitchTile>(
        find.ancestor(
          of: find.byKey(const Key('settingsSyncSwitch')),
          matching: find.byType(SettingsSwitchTile),
        ),
      );

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

  testWidgets('默认关闭：只留总开关与一句说明，隐藏其余分区', (tester) async {
    await pumpPage(tester);
    expect(find.text('Cross-device sync'), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncSwitch')), findsOneWidget);
    expect(find.text('This device'), findsNothing);
    expect(find.text('What to sync'), findsNothing);
    expect(find.text('Transport'), findsNothing);
  });

  testWidgets('开启同步：生成口令弹窗，确认后一页出现本机 / 设备 / 传输 / 内容 / 日志', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const Key('settingsSyncSwitch')));
    await tester.pumpAndSettle();

    // 首次开启自动生成口令并弹出展示弹窗（含复制与重置动作）。
    expect(find.text('Copy passphrase'), findsOneWidget);
    expect(find.text('Reset passphrase'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(provider.enabled, isTrue);
    expect(provider.passphrase, isNotNull);
    // ② 本机：设备名 / 设备 id / 口令 / 加入口令 / 配对信息 / 地址 / 端口。
    expect(find.text('This device'), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncDeviceNameItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncPeerSelfItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncPassphraseItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncJoinItem')), findsOneWidget);
    expect(
        find.byKey(const Key('settingsSyncPairingShareItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncProbePortItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncHttpPortItem')), findsOneWidget);
    // ③ 设备 / ④ 传输 / ⑤⑥ 内容与日志入口。
    expect(find.byKey(const Key('settingsSyncAddPeerItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncLanSwitch')), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncWebdavSwitch')), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncContentItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncLogItem')), findsOneWidget);
  });

  testWidgets('状态副文案：未同步说「尚未同步」；跑完一轮给结论与相对时间', (tester) async {
    await provider.setEnabled(true);
    await pumpPage(tester);
    expect(syncSwitchTile(tester).subtitle, 'Never synced');

    // 跑一轮（页面无手动主操作，这里直接驱动 provider）：无对端 →
    // 结论「No peer found」+ 相对时间「just now」。
    await provider.syncNow(manual: true);
    await tester.pumpAndSettle();
    final subtitle = syncSwitchTile(tester).subtitle;
    expect(subtitle, contains('No peer found'));
    expect(subtitle, contains('just now'));
    // 「跳过 N 项」这类全库计数不出现在任何文案里。
    expect(find.textContaining('skipped'), findsNothing);
  });

  testWidgets('本机地址列表：可路由地址逐条展示，点按复制；端口行展示实际值', (tester) async {
    final clipboard = mockClipboard(tester);
    transport.discoveryPortsOverride = (v4: 47825, v6: 47825);
    await state.setLanHttpPort(40000);
    await provider.setEnabled(true);
    await pumpPage(tester);

    expect(
      find.byKey(const Key('settingsSyncLocalAddress-192.168.1.10')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('settingsSyncLocalAddress-2409:8a55::5')),
      findsOneWidget,
    );
    expect(find.text('wlan0'), findsWidgets);

    await tester.tap(
      find.byKey(const Key('settingsSyncLocalAddress-192.168.1.10')),
    );
    await tester.pumpAndSettle();
    expect(clipboard.last, '192.168.1.10');
    expect(find.text('Address copied'), findsOneWidget);

    final probe = tester.widget<SettingsInfoTile>(
        find.byKey(const Key('settingsSyncProbePortItem')));
    expect(probe.subtitle, '47825', reason: '两族同值只显示一个端口');
    final http = tester.widget<SettingsInfoTile>(
        find.byKey(const Key('settingsSyncHttpPortItem')));
    expect(http.subtitle, '40000');
  });

  testWidgets('探测端口分族展示：v6 独立降级后按族列出', (tester) async {
    transport.discoveryPortsOverride = (v4: 47825, v6: 51234);
    await provider.setEnabled(true);
    await pumpPage(tester);

    final probe = tester.widget<SettingsInfoTile>(
        find.byKey(const Key('settingsSyncProbePortItem')));
    expect(probe.subtitle, '47825 (IPv4) / 51234 (IPv6)');
  });

  testWidgets('配对码按地址族取探测端口：v6 候选带 v6 的端口', (tester) async {
    transport.discoveryPortsOverride = (v4: 47825, v6: 51234);
    await provider.setEnabled(true);
    await pumpPage(tester);

    final code = (await provider.pairingCode())!;
    final byHost = {
      for (final address in code.addresses) address.host: address.probePort,
    };
    expect(byHost['192.168.1.10'], 47825);
    expect(byHost['2409:8a55::5'], 51234,
        reason: 'v6 独立降级到 51234：不能拿 v4 的 47825');
    // 分享弹层里的码文本同样是分族端口。
    expect(code.encode(), contains('molia-pair:1:'));
  });

  testWidgets('本机设备 id：短号可读，点按复制完整 id', (tester) async {
    final clipboard = mockClipboard(tester);
    await provider.setEnabled(true);
    await pumpPage(tester);

    final shortId = provider.deviceId.substring(provider.deviceId.length - 6);
    expect(find.textContaining(shortId), findsOneWidget);
    await tester.tap(find.byKey(const Key('settingsSyncPeerSelfItem')));
    await tester.pumpAndSettle();
    expect(clipboard.single, provider.deviceId);
    expect(find.text('Full device ID copied'), findsOneWidget);
  });

  testWidgets('口令行可查看完整口令；加入口令入口打开输入弹层', (tester) async {
    await provider.setEnabled(true);
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('settingsSyncPassphraseItem')));
    await tester.pumpAndSettle();
    expect(find.text(provider.passphrase!), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('settingsSyncJoinItem')));
    await tester.pumpAndSettle();
    expect(find.text('Enter sync passphrase'), findsWidgets);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('设备名行：改名入口打开弹窗并保存', (tester) async {
    await provider.setEnabled(true);
    await pumpPage(tester);
    await openRenameDialog(tester);
    await tester.enterText(find.byType(EditableText).first, '书房');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(provider.deviceName, '书房');
  });

  testWidgets('分享配对信息：点行复制配对码，行尾二维码弹层展示二维码与警告', (tester) async {
    final clipboard = mockClipboard(tester);
    await provider.setEnabled(true);
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('settingsSyncPairingShareItem')));
    await tester.pumpAndSettle();
    expect(clipboard.single, startsWith('molia-pair:1:'));
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

  testWidgets('添加设备：写入地址簿并立即跑一轮', (tester) async {
    await provider.setEnabled(true);
    await pumpPage(tester);
    await openAddDialog(tester);

    await tester.enterText(fieldAt(0), '192.168.1.23');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(provider.manualPeers.single.host, '192.168.1.23');
    // 尚未接触的对端在名册区可见（点开可删除）。
    expect(
      find.byKey(const Key('settingsSyncPeer-192.168.1.23')),
      findsOneWidget,
    );
  });

  testWidgets('添加设备：探测端口默认 47825，地址与端口校验在弹层内', (tester) async {
    await provider.setEnabled(true);
    await pumpPage(tester);
    await openAddDialog(tester);

    // 端口字段预填默认值（UDP 探测端口）。
    expect(
      tester.widget<EditableText>(fieldAt(1)).controller.text,
      '${ManualPeer.defaultProbePort}',
    );

    // 地址为空：错误文案出现，弹层不关闭。
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Address cannot be empty'), findsOneWidget);
    expect(find.text('Add device'), findsWidgets);

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

  testWidgets('接触失败：弹层不关闭，层内给出未接触成功提示', (tester) async {
    await provider.setEnabled(true);
    await pumpPage(tester);
    await openAddDialog(tester);

    await tester.enterText(fieldAt(0), '192.168.1.23');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // 地址已写入地址簿（用户不用重填），但弹层留在原地让用户改地址重试。
    expect(provider.manualPeers.single.host, '192.168.1.23');
    expect(find.textContaining('Not reached yet'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
  });

  testWidgets('重复地址：提示已更新而不是重复添加', (tester) async {
    await provider.setEnabled(true);
    await provider.addManualPeer('192.168.1.23', name: '书房');
    await pumpPage(tester);
    await openAddDialog(tester);

    await tester.enterText(fieldAt(0), '192.168.1.23');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(
      find.text('Already in the list — name and port updated'),
      findsOneWidget,
    );
    expect(provider.manualPeers, hasLength(1));
  });

  testWidgets('重复地址且接触成功：提示已更新而不是已添加', (tester) async {
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
    await provider.setEnabled(true);
    await provider.addManualPeer('192.168.1.23', name: '书房');
    await pumpPage(tester);
    await openAddDialog(tester);

    await tester.enterText(fieldAt(0), '192.168.1.23');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Device updated'), findsOneWidget);
    expect(find.text('Device added'), findsNothing);
    expect(provider.manualPeers, hasLength(1));
  });

  testWidgets('接触成功：关闭弹层并提示已添加', (tester) async {
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
    await provider.setEnabled(true);
    await pumpPage(tester);
    await openAddDialog(tester);

    await tester.enterText(fieldAt(0), '192.168.1.23');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Device added'), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncPeer-devB')), findsOneWidget);
  });

  testWidgets('添加设备弹层：扫码入口 = 平台 × GMS（无 GMS / 桌面隐藏，只给粘贴）', (tester) async {
    addTearDown(() {
      SyncPairingScanner.debugPlatformOverride = null;
      SyncPairingScanner.debugAvailabilityOverride = null;
    });
    Future<void> openAndCheck({required bool expected}) async {
      await openAddDialog(tester);
      expect(
        find.byKey(const Key('settingsSyncPairingScanButton')),
        expected ? findsOneWidget : findsNothing,
        reason: '平台=${SyncPairingScanner.debugPlatformOverride} '
            '可用=${SyncPairingScanner.debugAvailabilityOverride != null}',
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    }

    await provider.setEnabled(true);
    await pumpPage(tester);

    // Android + GMS：显示。
    SyncPairingScanner.debugPlatformOverride = TargetPlatform.android;
    SyncPairingScanner.debugAvailabilityOverride = () async => true;
    await openAndCheck(expected: true);

    // Android 无 GMS（AOSP / 无 Play 服务）：隐藏入口，不给死胡同。
    SyncPairingScanner.debugAvailabilityOverride = () async => false;
    await openAndCheck(expected: false);

    // iOS：系统 Vision，不依赖 GMS，恒显示。
    SyncPairingScanner.debugPlatformOverride = TargetPlatform.iOS;
    SyncPairingScanner.debugAvailabilityOverride = null;
    await openAndCheck(expected: true);

    // Linux：平台不支持，隐藏。
    SyncPairingScanner.debugPlatformOverride = TargetPlatform.linux;
    await openAndCheck(expected: false);
  });

  testWidgets('配对码前缀但内容损坏：报「配对码无效」并按码处理（不落成地址）', (tester) async {
    await provider.setEnabled(true);
    await pumpPage(tester);
    await openAddDialog(tester);

    await tester.enterText(fieldAt(0), 'molia-pair:1:not-base64!!');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Invalid pairing code'), findsOneWidget);
    expect(provider.manualPeers, isEmpty);
  });

  testWidgets('配对码导入：地址逐个入簿并立即接触（无需手填端口）', (tester) async {
    await provider.setEnabled(true);
    await pumpPage(tester);

    final code = SyncPairingCode(
      deviceName: 'Device B',
      deviceId: 'devB',
      passphrase: provider.passphrase!,
      addresses: const [
        SyncPairingAddress(host: '192.168.1.23', probePort: 47825),
        SyncPairingAddress(host: '2409:8a55::9', probePort: 47825),
      ],
      httpPort: 40000,
    );
    await openAddDialog(tester);
    await tester.enterText(fieldAt(0), code.encode());
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(provider.manualPeers, hasLength(2));
    expect(provider.manualPeers.first.deviceId, 'devB');
    expect(provider.manualPeers.first.httpPort, 40000);
    expect(provider.manualPeers.first.name, 'Device B');
    // 未接触成功：弹层留在原地，条目已在地址簿（按设备合并成一行）。
    expect(find.byKey(const Key('settingsSyncPeer-devB')), findsOneWidget);
    expect(find.text('Device B'), findsWidgets);
    // 弹层关闭后点开该行：两个地址都在（逐个可删）。
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settingsSyncPeer-devB')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const Key('settingsSyncPeer-192.168.1.23')), findsOneWidget);
    expect(
        find.byKey(const Key('settingsSyncPeer-2409:8a55::9')), findsOneWidget);
  });

  testWidgets('配对码口令冲突：确认后替换本机口令；选「仅导入地址」则保留', (tester) async {
    await provider.setEnabled(true);
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
    await openAddDialog(tester);
    await tester.enterText(fieldAt(0), code.encode());
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Passphrase already set'), findsOneWidget);
    await tester.tap(find.text('Addresses only'));
    await tester.pumpAndSettle();
    expect(provider.passphrase, original);
    expect(provider.manualPeers.single.host, '192.168.1.23');

    // 替换本机口令：口令换成码里的（归一化后保存）。
    await tester.enterText(fieldAt(0), code.encode());
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Replace passphrase'));
    await tester.pumpAndSettle();
    expect(provider.passphrase, SyncPassphrase.normalize(incoming));
  });

  testWidgets('多地址导入后：未认领候选折叠为一行，点开可查看 / 删除', (tester) async {
    await provider.setEnabled(true);
    await provider.addManualPeer('192.168.1.23');
    await provider.addManualPeer('192.168.1.24');
    await provider.addManualPeer('192.168.1.25');
    await pumpPage(tester);

    expect(
      find.byKey(const Key('settingsSyncPeerCandidatesItem')),
      findsOneWidget,
    );
    expect(find.text('3 candidate addresses'), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncPeer-192.168.1.24')), findsNothing);

    await tester.tap(find.byKey(const Key('settingsSyncPeerCandidatesItem')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settingsSyncPeer-192.168.1.24')), findsOneWidget);

    // 点开单项 → 详情弹层 → 删除。
    await tester.tap(find.byKey(const Key('settingsSyncPeer-192.168.1.24')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove device'));
    await tester.pumpAndSettle();
    expect(provider.manualPeers, hasLength(2));
  });

  testWidgets('名册行内联：对端行有名称与最后同步时间', (tester) async {
    await provider.setEnabled(true);
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

  testWidgets('失联设备：名册标记 + 忽略 / 清理远端文件动作', (tester) async {
    // 注入时钟：失联阈值 = 180 天（与 lostPeers 判定同一时钟源）。
    nowMs = DateTime.now().millisecondsSinceEpoch;
    seedPeer('ghost', lastSeenAt: nowMs - SyncPeerState.lostThresholdMs - 1000);
    await provider.setEnabled(true);
    await pumpPage(tester);
    expect(find.textContaining('lost'), findsOneWidget);

    // 打开详情：忽略该设备（只影响本机）。
    await tester.tap(find.byKey(const Key('settingsSyncPeer-ghost')));
    await tester.pumpAndSettle();
    expect(find.textContaining('180 days'), findsOneWidget);
    await tester.tap(find.byKey(const Key('settingsSyncPeerIgnore-ghost')));
    await tester.pumpAndSettle();
    expect(provider.isPeerIgnored('ghost'), isTrue);

    // 再打开详情：清理远端文件（二次确认后调用传输）。
    transport.deleteRemoteResult = true;
    await tester.tap(find.byKey(const Key('settingsSyncPeer-ghost')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settingsSyncPeerCleanup-ghost')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(transport.deletedRemotes, ['ghost']);
    expect(find.text('Remote files cleaned up'), findsOneWidget);
  });

  testWidgets('名册展示优先用户命名，对端自报名仅兜底', (tester) async {
    await provider.setEnabled(true);
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

  testWidgets('同步在途时保存设备：不误报未接触，提示稍后接触', (tester) async {
    await provider.setEnabled(true);
    // 先完成一轮，留下历史报告（排队路径拿到的正是这份旧报告）。
    await provider.syncNow(manual: true);

    final gate = Completer<void>();
    transport.onPull = () => gate.future;
    final inFlight = provider.syncNow(manual: true);
    await pumpPage(tester);
    await openAddDialog(tester);

    await tester.enterText(fieldAt(0), '192.168.1.23');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // 本轮被排队、结果未知：不判「未接触成功」，也不把弹层留在原地。
    expect(find.text('Device saved — contact will follow'), findsOneWidget);
    expect(find.textContaining('Not reached yet — check'), findsNothing);
    expect(find.text('Save'), findsNothing);

    gate.complete();
    await inFlight;
    await tester.pumpAndSettle();
  });

  testWidgets('同步内容子页：类别开关可切、蜂窝暂停在页内，入口副文案跟随', (tester) async {
    await provider.setEnabled(true);
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
    await provider.setEnabled(true);
    // 手动一轮：日志里出现一条无对端轮次（0 字节、0 落地）。
    await provider.syncNow(manual: true);
    await pumpPage(tester);
    expect(find.byKey(const Key('settingsSyncActivityItem')), findsNothing);

    await openSubPage(tester, 'settingsSyncLogItem');
    expect(find.text('Last 24 hours'), findsOneWidget);
    expect(
      find.textContaining('1 rounds, 0 with transfer'),
      findsOneWidget,
    );
    // 环境行：未注入调度器 → 等级「未运行」；非移动数据；非省电。
    expect(
      find.textContaining('not running · Wi-Fi / other · power save off'),
      findsOneWidget,
    );
  });

  testWidgets('日志子页：完整日志（超过 6 条不截断），入口副文案跟随', (tester) async {
    await provider.setEnabled(true);
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
    await provider.setEnabled(true);
    await pumpPage(tester);
    expect(find.text('No records yet'), findsOneWidget);

    await provider.syncNow(manual: true);
    await tester.pumpAndSettle();
    expect(find.text('No records yet'), findsNothing);
    final logTile = tester
        .widget<SettingsNavTile>(find.byKey(const Key('settingsSyncLogItem')));
    expect(logTile.subtitle, contains('No peer found'));
    expect(logTile.subtitle, contains('just now'));
  });

  testWidgets('WebDAV 启用后才出现配置入口，副文案给地址 / 未配置', (tester) async {
    await provider.setEnabled(true);
    await pumpPage(tester);
    expect(find.byKey(const Key('settingsSyncWebdavConfigItem')), findsNothing);

    await tester.tap(find.byKey(const Key('settingsSyncWebdavSwitch')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const Key('settingsSyncWebdavConfigItem')), findsOneWidget);
    expect(find.text('Not configured'), findsOneWidget);
  });

  testWidgets('日志子页不提供诊断导出入口', (tester) async {
    await provider.setEnabled(true);
    await pumpPage(tester);
    expect(find.byKey(const Key('settingsSyncDiagnosticItem')), findsNothing);

    await openSubPage(tester, 'settingsSyncLogItem');
    expect(find.byKey(const Key('settingsSyncDiagnosticItem')), findsNothing);
    expect(find.text('Copy diagnostics'), findsNothing);
    expect(find.text('Diagnostics'), findsNothing);
  });

  testWidgets('局域网权限被永久拒绝：动作是「去系统设置」', (tester) async {
    await provider.setEnabled(true);
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
    await provider.setEnabled(true);
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
    await provider.setEnabled(true);
    transport.pullError = const SyncIssue(code: SyncIssueCode.discoverySilent);
    await provider.syncNow(manual: true);
    await pumpPage(tester);

    await openSubPage(tester, 'settingsSyncLogItem');
    // 零应答（区别于从未发现）：日志行可点开下一步动作。
    expect(find.byType(SyncLogRow), findsOneWidget);
    expect(find.textContaining('No device answered'), findsWidgets);
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
    // 桌面不构建扫码入口（弹层里只有粘贴）。
    SyncPairingScanner.debugPlatformOverride = TargetPlatform.linux;
    addTearDown(() => SyncPairingScanner.debugPlatformOverride = null);
    await provider.setEnabled(true);
    transport.pullError =
        const SyncIssue(code: SyncIssueCode.probePortUnavailable);
    await provider.syncNow(manual: true);
    await pumpPage(tester);

    await openSubPage(tester, 'settingsSyncLogItem');
    await tester.tap(find.byType(SyncLogRow));
    await tester.pumpAndSettle();
    expect(find.textContaining('Probe port unavailable'), findsWidgets);
    expect(find.text('Add manual address'), findsOneWidget);
    // 「添加手动地址」直接打开添加设备弹层（不跳页）。
    await tester.tap(find.text('Add manual address'));
    await tester.pumpAndSettle();
    expect(find.text('Add device'), findsWidgets);
    expect(
        find.byKey(const Key('settingsSyncPairingScanButton')), findsNothing);
  });

  testWidgets('传输副文案：启动失败只说状态词（原始细节不上界面）', (tester) async {
    await provider.setEnabled(true);
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
    await provider.setEnabled(true);
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
    await provider.setEnabled(true);
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
