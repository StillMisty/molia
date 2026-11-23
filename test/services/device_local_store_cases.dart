import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/app/bootstrap/runtime_providers.dart';
import 'package:molia/domain/models/app_release.dart';
import 'package:molia/providers/collection_mode.dart';
import 'package:molia/providers/theme_provider.dart';
import 'package:molia/services/haptics.dart';
import 'package:molia/services/update/update_preferences.dart';
import 'package:molia/services/window/tray_settings.dart';
import 'package:molia/services/window/window_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/settings_test_support.dart';

/// 迁移到 DeviceSettings 的零散设备本地 store：默认值 / 键名 / 重载行为。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    HapticsService.enabledNotifier.value = HapticsService.defaultEnabled;
    WindowSettings.rememberBoundsNotifier.value =
        WindowSettings.defaultRememberBounds;
  });

  test('触感：默认开，写入落到 haptics_enabled，重载后保持', () async {
    await HapticsService.load();
    expect(HapticsService.enabled, isTrue);

    await HapticsService.setEnabled(false);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(HapticsService.keyEnabled), isFalse);

    HapticsService.enabledNotifier.value = true;
    await HapticsService.load();
    expect(HapticsService.enabled, isFalse);
  });

  test('窗口记忆：默认开，写入落到 window_remember_bounds', () async {
    await WindowSettings.load();
    expect(WindowSettings.rememberBounds, isTrue);

    await WindowSettings.setRememberBounds(false);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(WindowSettings.keyRememberBounds), isFalse);
  });

  test('托盘：默认关闭即最小化，写入后新实例读回', () async {
    final tray = TraySettings();
    addTearDown(tray.dispose);
    await tray.init();
    expect(tray.closeToTray, isTrue);

    await tray.setCloseToTray(false);
    final reloaded = TraySettings();
    addTearDown(reloaded.dispose);
    await reloaded.init();
    expect(reloaded.closeToTray, isFalse);
  });

  test('更新偏好：渠道 / 镜像 / 待确认回执往返，缺 build 不算待确认', () async {
    final update = UpdatePreferences();
    await update.load();
    expect(update.checkOnStartup, isFalse);
    expect(update.checkDaily, isFalse);
    expect(update.channel, UpdateChannel.stable);

    await update.setCheckOnStartup(true);
    await update.setCheckDaily(true);
    await update.setChannel(UpdateChannel.beta);
    await update.setManifestUrlOverride(' https://example.com ');
    await update.setDownloadPrefix(' https://cdn.example.com ');
    await update.markChecked(DateTime(2026, 1, 2, 3, 4, 5));
    await update.markPendingUpdate(version: '1.2.3', build: 45);

    final reloaded = UpdatePreferences();
    await reloaded.load();
    expect(reloaded.checkOnStartup, isTrue);
    expect(reloaded.checkDaily, isTrue);
    expect(reloaded.anyAutoCheckEnabled, isTrue);
    expect(reloaded.channel, UpdateChannel.beta);
    expect(reloaded.manifestUrlOverride, 'https://example.com');
    expect(reloaded.downloadPrefix, 'https://cdn.example.com');
    expect(reloaded.lastCheckedAt, DateTime(2026, 1, 2, 3, 4, 5));
    expect(reloaded.pendingUpdate?.version, '1.2.3');
    expect(reloaded.pendingUpdate?.build, 45);

    await reloaded.clearPendingUpdate();
    final cleared = UpdatePreferences();
    await cleared.load();
    expect(cleared.pendingUpdate, isNull);

    // 只有 version 没有 build：按「没有待确认更新」处理，避免误报安装失败。
    SharedPreferences.setMockInitialValues({
      UpdatePreferences.keyPendingVersion: '9.9.9',
    });
    final partial = UpdatePreferences();
    await partial.load();
    expect(partial.pendingUpdate, isNull);
  });

  test('更新偏好：旧版单开关迁移成启动 + 每日，写新键后不再回填旧值', () async {
    SharedPreferences.setMockInitialValues({
      UpdatePreferences.keyAutoCheck: true,
    });
    final migrated = UpdatePreferences();
    await migrated.load();
    expect(migrated.checkOnStartup, isTrue);
    expect(migrated.checkDaily, isTrue);

    await migrated.setCheckDaily(false);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(UpdatePreferences.keyCheckOnStartup), isTrue);
    expect(prefs.getBool(UpdatePreferences.keyCheckDaily), isFalse);

    // 即使用户把两个开关都关掉、旧键仍是 true，也以新键为准。
    SharedPreferences.setMockInitialValues({
      UpdatePreferences.keyAutoCheck: true,
      UpdatePreferences.keyCheckOnStartup: false,
      UpdatePreferences.keyCheckDaily: false,
    });
    final disabled = UpdatePreferences();
    await disabled.load();
    expect(disabled.checkOnStartup, isFalse);
    expect(disabled.checkDaily, isFalse);
  });

  test('曲库浏览模式：默认专辑，未知值回退专辑', () async {
    final store = CollectionModeStore();
    addTearDown(store.dispose);
    await store.load();
    expect(store.mode, CollectionMode.albums);

    await store.setMode(CollectionMode.artists);
    final reloaded = CollectionModeStore();
    addTearDown(reloaded.dispose);
    await reloaded.load();
    expect(reloaded.mode, CollectionMode.artists);

    SharedPreferences.setMockInitialValues({
      CollectionModeStore.prefsKey: 'future-layout',
    });
    final unknown = CollectionModeStore();
    addTearDown(unknown.dispose);
    await unknown.load();
    expect(unknown.mode, CollectionMode.albums);
  });

  test('全局字体：写 app_font_family，null 回到系统默认并删除键', () async {
    ProviderContainer createContainer() {
      final container = ProviderContainer(
        overrides: [
          settingsRegistryProvider.overrideWithValue(testSettingsRegistry()),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    final container = createContainer();
    final theme = container.read(themeProvider.notifier);
    await theme.preferencesReady;
    expect(container.read(themeProvider).appFontFamily, isNull);

    await theme.setAppFontFamily('Inter');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('app_font_family'), 'Inter');

    final reloadedContainer = createContainer();
    final reloaded = reloadedContainer.read(themeProvider.notifier);
    await reloaded.preferencesReady;
    expect(reloadedContainer.read(themeProvider).appFontFamily, 'Inter');

    await reloaded.setAppFontFamily(null);
    expect(prefs.containsKey('app_font_family'), isFalse);
  });
}
