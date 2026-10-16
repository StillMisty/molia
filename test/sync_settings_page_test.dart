import 'dart:convert';

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
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/data/sync/transport/local_network_permission.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/ports/sync_transport.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/sync_log_page.dart';
import 'package:molia/pages/sync_settings_page.dart';
import 'package:molia/providers/sync_provider.dart';
import 'package:molia/services/language_service.dart';

import 'support/sync_test_support.dart';

/// 同步设置页冒烟：开关生成口令、类别分区、传输开关与日志区。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const keys = [kThemeMode];

  late SyncStateStore state;
  late FakeSyncTransport transport;
  late SyncEngine engine;
  late SyncProvider provider;
  var nowMs = 7000;

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
    );
    provider = SyncProvider(engine: engine);
    await provider.init();
  });

  tearDown(() async {
    provider.dispose();
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

  testWidgets('默认关闭：显示总开关，隐藏类别与传输分区', (tester) async {
    await pumpPage(tester);
    expect(find.text('Cross-device sync'), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncSwitch')), findsOneWidget);
    expect(find.text('What to sync'), findsNothing);
    expect(find.text('Transport'), findsNothing);
  });

  testWidgets('开启同步：生成口令弹窗，确认后显示类别与传输分区', (tester) async {
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
    expect(find.text('What to sync'), findsOneWidget);
    expect(find.text('Transport'), findsOneWidget);
    expect(
      find.byKey(const Key('settingsSyncCategory-playlists')),
      findsOneWidget,
    );
  });

  testWidgets('关闭单个类别写入状态；立即同步记录日志', (tester) async {
    await provider.setEnabled(true);
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('settingsSyncCategory-statistics')));
    await tester.pumpAndSettle();
    expect(provider.categories[SyncCategory.statistics], isFalse);

    await tester.tap(find.byKey(const Key('settingsSyncLanSwitch')));
    await tester.pumpAndSettle();
    expect(provider.enabledTransports.contains('lan'), isFalse);

    await tester.tap(find.byKey(const Key('settingsSyncNowItem')));
    await tester.pumpAndSettle();
    expect(provider.lastSyncAt, greaterThan(0));
    expect(find.text('Sync log'), findsOneWidget);
  });

  testWidgets('结论行给五态：没有对端显示「未发现对端」而不是「同步完成」', (tester) async {
    await provider.setEnabled(true);
    await pumpPage(tester);

    // 传输开着但没有任何对端 → noPeers。
    expect(find.byKey(const Key('settingsSyncStatusItem')), findsOneWidget);
    await tester.tap(find.byKey(const Key('settingsSyncNowItem')));
    await tester.pumpAndSettle();

    expect(provider.lastOutcome, SyncOutcome.noPeers);
    expect(find.text('No peer found'), findsWidgets);
    // 「跳过 N 项」这类全库计数不出现在任何文案里。
    expect(find.textContaining('skipped'), findsNothing);
  });

  testWidgets('名册子页：对端行有名称与最后同步时间', (tester) async {
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

    await tester.tap(find.byKey(const Key('settingsSyncPeersItem')));
    await tester.pumpAndSettle();

    expect(find.text('Paired devices'), findsWidgets);
    expect(find.byKey(const Key('settingsSyncPeer-devB')), findsOneWidget);
    expect(find.text('Device B'), findsOneWidget);
    expect(find.textContaining('Last synced'), findsOneWidget);
  });

  testWidgets('诊断行存在且可复制（不含密钥）', (tester) async {
    await provider.setEnabled(true);
    await pumpPage(tester);

    expect(find.byKey(const Key('settingsSyncDiagnosticItem')), findsOneWidget);
    expect(find.text('Copy diagnostics'), findsOneWidget);
  });

  testWidgets('诊断导出：含原因码与原始细节（detail），不含口令', (tester) async {
    await provider.setEnabled(true);
    // 拉取抛异常 → 日志与最近一轮都带 pull_failed + 原始 `$e`。
    transport.throwOnPull = true;
    await provider.syncNow(manual: true);

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

    await pumpPage(tester);
    await tester.tap(find.byKey(const Key('settingsSyncDiagnosticItem')));
    await tester.pumpAndSettle();

    final payload = jsonDecode(clipboard.single) as Map<String, dynamic>;
    final lastRound = payload['lastRound'] as Map<String, dynamic>;
    final error = lastRound['error'] as Map<String, dynamic>;
    expect(error['code'], SyncIssueCode.pullFailed);
    // 原始细节只进诊断导出，不上界面（界面断言见「传输异常」用例）。
    expect(error['detail'], contains('拉取失败'));
    expect(clipboard.single, isNot(contains(provider.passphrase!)));
  });

  testWidgets('添加设备：写入地址簿并立即跑一轮', (tester) async {
    await provider.setEnabled(true);
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('settingsSyncPeersItem')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settingsSyncAddPeerItem')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(EditableText).first, '192.168.1.23');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(provider.manualPeers.single.host, '192.168.1.23');
    // 尚未接触的对端在名册页可见（点开可删除）。
    expect(
      find.byKey(const Key('settingsSyncPeer-192.168.1.23')),
      findsOneWidget,
    );
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
    provider = SyncProvider(engine: engine, lanPermission: permission);
    await provider.init();
    await pumpPage(tester);

    expect(
      find.byKey(const Key('settingsSyncLanPermissionItem')),
      findsOneWidget,
    );
    // 系统不再弹窗：不给「授予权限」，直接指去系统设置。
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
    provider = SyncProvider(engine: engine, lanPermission: permission);
    await provider.init();
    await pumpPage(tester);

    expect(find.text('Grant LAN permission'), findsOneWidget);
    await tester.tap(find.byKey(const Key('settingsSyncLanPermissionItem')));
    await tester.pumpAndSettle();
    expect(requested, 1);
  });

  testWidgets('日志超过 6 行：首屏留 6 行 + 入口进完整日志子页', (tester) async {
    await provider.setEnabled(true);
    for (var i = 0; i < 7; i++) {
      await provider.syncNow(manual: true);
    }
    await pumpPage(tester);

    expect(find.byKey(const Key('settingsSyncLogMoreItem')), findsOneWidget);
    expect(find.text('View all logs (7)'), findsOneWidget);
    // 首屏只渲染 6 行（第 7 行在子页）。
    expect(find.byType(SyncLogRow), findsNWidgets(6));

    await tester.tap(find.byKey(const Key('settingsSyncLogMoreItem')));
    await tester.pumpAndSettle();
    expect(find.byType(SyncLogRow), findsNWidgets(7));
  });
}
