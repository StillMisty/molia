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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final secrets = MemorySyncSecretStore();
    state = SyncStateStore(preferences: prefs, secrets: secrets);
    await state.init();
    transport = FakeSyncTransport();
    engine = SyncEngine(
      state: state,
      adapters: [
        PrefsSyncAdapter(
          state: state,
          settings: SettingsRegistry(
            keys: keys,
            preferences: prefs,
            secrets: secrets,
          ),
          deviceId: () => state.deviceId,
          now: () => 7000,
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
}
