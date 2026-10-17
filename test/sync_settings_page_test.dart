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
import 'package:molia/pages/sync_content_page.dart';
import 'package:molia/pages/sync_device_page.dart';
import 'package:molia/pages/sync_log_page.dart';
import 'package:molia/pages/sync_settings_page.dart';
import 'package:molia/providers/sync_provider.dart';
import 'package:molia/services/language_service.dart';
import 'package:molia/theme/app_semantic_colors.dart';
import 'package:molia/widgets/settings/settings_tiles.dart';

import 'support/sync_test_support.dart';

/// 同步设置页信息架构：首屏只留结论与配置入口（≤ 9 行），明细下沉子页。
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
      // 与状态存储同一时钟源（观测面的窗口过滤依赖时间戳一致）。
      clock: () => DateTime.fromMillisecondsSinceEpoch(state.nowMs()),
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

  /// 从首屏进入子页。
  Future<void> openSubPage(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  /// 首屏总开关行（副文案 = 一句话状态）。
  SettingsSwitchTile syncSwitchTile(WidgetTester tester) =>
      tester.widget<SettingsSwitchTile>(
        find.ancestor(
          of: find.byKey(const Key('settingsSyncSwitch')),
          matching: find.byType(SettingsSwitchTile),
        ),
      );

  testWidgets('默认关闭：只留总开关与一句说明，隐藏其余分区', (tester) async {
    await pumpPage(tester);
    expect(find.text('Cross-device sync'), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncSwitch')), findsOneWidget);
    expect(find.text('What to sync'), findsNothing);
    expect(find.text('Transport'), findsNothing);
    // 设备与口令入口也在启用后才出现（口令未生成时没有可做的事）。
    expect(find.byKey(const Key('settingsSyncAdvancedItem')), findsNothing);
  });

  testWidgets('开启同步：生成口令弹窗，确认后首屏出现内容 / 传输 / 设备入口', (tester) async {
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
    expect(find.byKey(const Key('settingsSyncContentItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncAdvancedItem')), findsOneWidget);
  });

  testWidgets('首屏行数预算：启用后设置行 ≤ 9，明细全部下沉子页', (tester) async {
    await provider.setEnabled(true);
    await pumpPage(tester);

    final rows = find.byWidgetPredicate((widget) =>
        widget is SettingsSwitchTile ||
        widget is SettingsNavTile ||
        widget is SettingsInfoTile);
    expect(rows, findsAtLeastNWidgets(1));
    expect(rows.evaluate().length, lessThanOrEqualTo(9));

    // 首屏不再有手动同步主操作。
    expect(find.byKey(const Key('settingsSyncNowItem')), findsNothing);

    // 被下沉的键在首屏不可见：类别 / 蜂窝策略 / 动态 / 设备与口令 / 日志行。
    expect(
        find.byKey(const Key('settingsSyncCategory-playlists')), findsNothing);
    expect(
        find.byKey(const Key('settingsSyncCellularPauseSwitch')), findsNothing);
    expect(find.byKey(const Key('settingsSyncActivityItem')), findsNothing);
    expect(find.byKey(const Key('settingsSyncDeviceNameItem')), findsNothing);
    expect(find.byKey(const Key('settingsSyncPassphraseItem')), findsNothing);
    expect(find.byKey(const Key('settingsSyncJoinItem')), findsNothing);
    expect(find.byType(SyncLogRow), findsNothing);
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

  testWidgets('同步内容子页：类别开关可切、蜂窝暂停在页内，首屏副文案跟随', (tester) async {
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

    // 返回首屏：内容入口副文案给「已关闭 1 项」。
    await tester.tap(find.byType(BackButtonIcon));
    await tester.pumpAndSettle();
    expect(find.text('1 turned off'), findsOneWidget);
  });

  testWidgets('设备与口令子页：改名 / 口令 / 加入口令入口，口令行可查看完整口令', (tester) async {
    await provider.setEnabled(true);
    await pumpPage(tester);
    // 首屏结论：设备名 · 口令已设置。
    final advanced = tester.widget<SettingsNavTile>(
        find.byKey(const Key('settingsSyncAdvancedItem')));
    expect(advanced.subtitle, '${provider.deviceName} · Passphrase set');

    await openSubPage(tester, 'settingsSyncAdvancedItem');
    expect(find.byType(SyncDevicePage), findsOneWidget);
    expect(find.text('Trust model'), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncDeviceNameItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncPassphraseItem')), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncJoinItem')), findsOneWidget);

    // 口令行点开显示完整口令（可复制）。
    await tester.tap(find.byKey(const Key('settingsSyncPassphraseItem')));
    await tester.pumpAndSettle();
    expect(find.text(provider.passphrase!), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // 改名入口打开弹窗并保存。
    await tester.tap(find.byKey(const Key('settingsSyncDeviceNameItem')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, '书房');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(provider.deviceName, '书房');
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

  testWidgets('日志子页：完整日志（超过 6 条不截断），首屏只给结论入口', (tester) async {
    await provider.setEnabled(true);
    for (var i = 0; i < 7; i++) {
      await provider.syncNow(manual: true);
    }
    await pumpPage(tester);

    // 首屏不再渲染日志行（入口副文案给最近一轮结论 + 时间）。
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

    // 首屏结论：对端数 + 最后同步时间。
    expect(find.textContaining('1 peers · '), findsOneWidget);

    await openSubPage(tester, 'settingsSyncPeersItem');
    expect(find.text('Paired devices'), findsWidgets);
    expect(find.byKey(const Key('settingsSyncPeer-devB')), findsOneWidget);
    expect(find.text('Device B'), findsOneWidget);
    expect(find.textContaining('Last synced'), findsOneWidget);
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

  testWidgets('日志子页不再提供诊断导出入口', (tester) async {
    await provider.setEnabled(true);
    await pumpPage(tester);
    expect(find.byKey(const Key('settingsSyncDiagnosticItem')), findsNothing);

    await openSubPage(tester, 'settingsSyncLogItem');
    expect(find.byKey(const Key('settingsSyncDiagnosticItem')), findsNothing);
    expect(find.text('Copy diagnostics'), findsNothing);
    expect(find.text('Diagnostics'), findsNothing);
  });

  testWidgets('添加设备：写入地址簿并立即跑一轮', (tester) async {
    await provider.setEnabled(true);
    await pumpPage(tester);

    await openSubPage(tester, 'settingsSyncPeersItem');
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

  testWidgets('失败行按原因给可点动作：手动地址 / WebDAV / 重试', (tester) async {
    await provider.setEnabled(true);
    transport.pullError = const SyncIssue(code: SyncIssueCode.discoverySilent);
    await provider.syncNow(manual: true);
    await pumpPage(tester);

    await openSubPage(tester, 'settingsSyncLogItem');
    // 零应答但此前成功过：日志行可点开下一步动作。
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

    // 「添加手动地址」直达名册页（不是死胡同）。
    await tester.tap(find.text('Add manual address'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settingsSyncAddPeerItem')), findsOneWidget);
  });

  testWidgets('传输副文案：启动失败只说状态词（原始细节不上界面）', (tester) async {
    await provider.setEnabled(true);
    transport.unavailableReason = SyncUnavailableReason.startFailed;
    transport.unavailableDetail = 'SocketException: 端口占用';
    await transport.stop();
    await pumpPage(tester);

    expect(find.textContaining('failed to start'), findsOneWidget);
    expect(find.textContaining('SocketException'), findsNothing);
    // 「最后成功」不再进首屏（诊断导出里有）。
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
