/// 模块初始 / 默认值必须来自登记键的 [SettingsKey.defaultValue]。
///
/// 默认值此前在「键」与「模块字段」各写一份，改键默认值时模块不会跟；
/// 本测试把两份钉在一起（改任何一处都能红）。只覆盖当前由键派生初始值的
/// 模块字段，不检查持久化形态。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/play_statistics_repository.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/providers/nav_provider.dart';
import 'package:molia/providers/theme_provider.dart';
import 'package:molia/services/audio_focus_settings.dart';
import 'package:molia/services/library/library_add_settings.dart';
import 'package:molia/services/play_statistics_service.dart';
import 'package:molia/services/shortcut_settings.dart';
import 'package:molia/services/source_swap/source_swap_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';
import 'support/memory_database.dart';
import 'support/settings_test_support.dart';
import 'support/sync_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('ThemeProvider 初始值与加载后值都来自键默认值', () async {
    final provider = ThemeProvider(settings: testSettingsRegistry());
    addTearDown(provider.dispose);

    void expectDefaults() {
      expect(provider.themeMode.name, kThemeMode.defaultValue);
      expect(provider.baseColorSource.name, kColorBase.defaultValue);
      expect(provider.followArtworkEnabled, kFollowArtworkEnabled.defaultValue);
      expect(provider.pureBlackEnabled, kPureBlackEnabled.defaultValue);
      expect(provider.seedColor.toARGB32(), kSeedColor.defaultValue);
    }

    expectDefaults();
    await provider.preferencesReady;
    expectDefaults();
  });

  test('NavProvider 顺序 / 隐藏 / 首页都来自键默认值', () async {
    final provider = NavProvider(settings: testSettingsRegistry());
    addTearDown(provider.dispose);

    void expectDefaults() {
      expect(
        provider.order.map((destination) => destination.name).toList(),
        kShellNavOrder.defaultValue,
      );
      expect(
        provider.visibleDestinations.map((destination) => destination.name),
        kShellNavOrder.defaultValue,
        reason: '隐藏列表默认为空',
      );
      expect(provider.homeDestination.name, kShellHomeDestination.defaultValue);
    }

    expectDefaults();
    await provider.preferencesReady;
    expectDefaults();
    expect(NavProvider.defaultOrder.map((destination) => destination.name),
        kShellNavOrder.defaultValue);
  });

  test('ShortcutSettings 初始开关来自键默认值', () {
    // 独立测试文件内、attach 之前读取单例初始值。
    expect(
        ShortcutSettings.instance.inAppEnabled, kShortcutsEnabled.defaultValue);
    expect(
      ShortcutSettings.instance.globalEnabled,
      kGlobalShortcutsEnabled.defaultValue,
    );
  });

  test('PlayStatisticsService 初始开关来自键默认值', () async {
    final db = openMemoryDatabase();
    final repository = PlayStatisticsRepository(
      databaseProvider: () => db,
      statisticsSync: testStatisticsSyncStore(() => db),
    );
    final service = PlayStatisticsService(
      repository: repository,
      settings: testSettingsRegistry(),
    );
    addTearDown(() async {
      await repository.dispose();
      await db.close();
    });

    expect(service.enabled, kPlayStatisticsEnabled.defaultValue);
    expect(service.enabledNotifier.value, kPlayStatisticsEnabled.defaultValue);
    await service.init();
    expect(service.enabled, kPlayStatisticsEnabled.defaultValue);
  });

  test('PlaybackProvider 初始默认模式来自键默认值', () async {
    final provider = buildTestPlaybackProvider();
    addTearDown(provider.dispose);

    expect(provider.defaultPlayMode.name, kDefaultPlayMode.defaultValue);
    await provider.preferencesReady;
    expect(provider.defaultPlayMode.name, kDefaultPlayMode.defaultValue);
  });

  test('SourceSwapSettings 初始开关来自键默认值', () {
    final settings = SourceSwapSettings(settings: testSettingsRegistry());
    addTearDown(settings.dispose);
    expect(settings.autoEnabled, kSourceSwapAutoEnabled.defaultValue);
  });

  test('LibraryAddSettings 初始位置来自键默认值（默认放开头）', () async {
    final settings = LibraryAddSettings(settings: testSettingsRegistry());
    addTearDown(settings.dispose);

    expect(settings.position.name, kLibraryAddPosition.defaultValue);
    expect(settings.addToTop, isTrue, reason: '新曲目默认放列表开头');
    await settings.init();
    expect(settings.position.name, kLibraryAddPosition.defaultValue);
  });

  test('AudioFocusSettings 默认与其他应用同时播放，关闭后可持久化并重载', () async {
    final registry = testSettingsRegistry();
    final settings = AudioFocusSettings(settings: registry);
    addTearDown(settings.dispose);

    expect(settings.playWithOtherApps, kPlayWithOtherApps.defaultValue);
    expect(settings.playWithOtherApps, isTrue);
    await settings.init();
    expect(settings.playWithOtherApps, isTrue);

    await settings.setPlayWithOtherApps(false);
    expect(settings.playWithOtherApps, isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kPlayWithOtherApps.name), isFalse);

    final reloaded = AudioFocusSettings(settings: registry);
    addTearDown(reloaded.dispose);
    await reloaded.init();
    expect(reloaded.playWithOtherApps, isFalse);
  });
}
