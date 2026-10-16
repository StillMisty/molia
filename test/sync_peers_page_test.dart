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
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/sync_peers_page.dart';
import 'package:molia/providers/sync_provider.dart';
import 'package:molia/services/language_service.dart';

import 'support/sync_test_support.dart';

/// 名册页：本机行复制、添加设备表单（校验 / 失败不关弹层 / 重复地址提示）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const keys = [kThemeMode];

  late SyncStateStore state;
  late FakeSyncTransport transport;
  late SyncEngine engine;
  late SyncProvider provider;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final secrets = MemorySyncSecretStore();
    state = SyncStateStore(
      preferences: prefs,
      secrets: secrets,
      clock: () => 7000,
    );
    await state.init();
    await state.setEnabled(true);
    await state.writePassphrase('ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789');
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
          home: const SyncPeersPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openAddDialog(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('settingsSyncAddPeerItem')));
    await tester.pumpAndSettle();
  }

  Finder fieldAt(int index) => find.byType(EditableText).at(index);

  String fieldText(WidgetTester tester, int index) =>
      tester.widget<EditableText>(fieldAt(index)).controller.text;

  testWidgets('本机行展示短号，点按复制完整设备 id', (tester) async {
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
    final shortId = provider.deviceId.substring(provider.deviceId.length - 6);
    expect(find.textContaining(shortId), findsOneWidget);

    await tester.tap(find.byKey(const Key('settingsSyncPeerSelfItem')));
    await tester.pumpAndSettle();
    expect(clipboard.single, provider.deviceId);
    expect(find.text('Full device ID copied'), findsOneWidget);
  });

  testWidgets('添加设备：探测端口默认 47825，地址与端口校验在弹层内', (tester) async {
    await pumpPage(tester);
    await openAddDialog(tester);

    // 端口字段预填默认值（UDP 探测端口）。
    expect(fieldText(tester, 1), '${ManualPeer.defaultProbePort}');

    // 地址为空：错误文案出现，弹层不关闭。
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Address cannot be empty'), findsOneWidget);
    expect(find.text('Add device'), findsWidgets);

    // 残缺 IPv4 / 带端口输入都不是合法地址。
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
    await pumpPage(tester);
    await openAddDialog(tester);

    await tester.enterText(fieldAt(0), '192.168.1.23');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Device added'), findsOneWidget);
    expect(find.byKey(const Key('settingsSyncPeer-devB')), findsOneWidget);
  });

  testWidgets('重复地址：提示已更新而不是重复添加', (tester) async {
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
}
