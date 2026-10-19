import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/data/settings/settings_registry.dart';
import 'package:molia/data/sync/adapters/prefs_sync_adapter.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/sync_test_support.dart';

/// 设置 / 音源 / 凭证适配器测试：首次登记、变化检测、远端应用与 LWW。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const keys = [
    kThemeMode,
    kLxDefaultQuality,
    kPlayStatisticsEnabled,
    kAiDjBaseUrl,
    kAiDjApiKey,
  ];

  late SharedPreferences prefs;
  late MemorySyncSecretStore secrets;
  late SyncStateStore state;
  late SettingsRegistry registry;
  late PrefsSyncAdapter adapter;
  var now = 1000;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    secrets = MemorySyncSecretStore();
    now = 1000;
    state = SyncStateStore(
      preferences: prefs,
      secrets: secrets,
      clock: () => now,
      deviceId: 'devA',
    );
    await state.init();
    registry = SettingsRegistry(
      keys: keys,
      preferences: prefs,
      secrets: secrets,
    );
    adapter = PrefsSyncAdapter(state: state, settings: registry);
  });

  test('首次登记：默认值零值戳、已改过的键用当前发号', () async {
    await prefs.setString('theme_mode', 'dark');
    final collected = await adapter.collect();
    final settings = collected[SyncCategory.settings]!;
    final theme = settings.firstWhere((r) => r.key == 'theme_mode');
    expect(theme.version.physical, 1000);
    expect(theme.version.deviceId, 'devA');
    expect(theme.data, {'v': 'dark'});
    // 未改过、取默认值的键：零值戳、无修改者。
    final untouched =
        settings.firstWhere((r) => r.key == 'play_statistics_enabled');
    expect(untouched.version, SyncVersion.zero);
    expect(untouched.data, {'v': true});

    expect(collected[SyncCategory.sources]!.single.key, 'lx_default_quality');
    expect(
      collected[SyncCategory.credentials]!.map((r) => r.key),
      containsAll(['ai_dj_base_url', 'ai_dj_api_key']),
    );
  });

  test('快捷键四键进入设置类别收集结果（跟人走）', () async {
    final fullAdapter = PrefsSyncAdapter(
      state: state,
      settings: SettingsRegistry(
        keys: kAllSettingsKeys,
        preferences: prefs,
        secrets: secrets,
      ),
    );

    final collected = await fullAdapter.collect();
    final settings = collected[SyncCategory.settings]!;
    final byKey = {for (final record in settings) record.key: record};
    for (final key in const [
      kShortcutsEnabled,
      kGlobalShortcutsEnabled,
      kShortcutBindings,
      kGlobalShortcutBindings,
    ]) {
      expect(byKey, contains(key.name));
      expect(
        byKey[key.name]!.data,
        {'v': key.defaultValue},
        reason: '${key.name} 首次登记应按默认值参与同步',
      );
    }
  });

  test('本地修改检测：值变化后重新取戳', () async {
    final first = await adapter.collect();
    final before =
        first[SyncCategory.settings]!.firstWhere((r) => r.key == 'theme_mode');
    expect(before.version, SyncVersion.zero);

    now = 5000;
    await prefs.setString('theme_mode', 'light');
    final second = await adapter.collect();
    final after =
        second[SyncCategory.settings]!.firstWhere((r) => r.key == 'theme_mode');
    expect(after.version.physical, 5000);
    expect(after.version.deviceId, 'devA');
    expect(after.data, {'v': 'light'});
  });

  test('同版本但值不同：修回远端值（全量快照的强制交付）', () async {
    await adapter.collect(); // 登记默认值
    final stamp = state.settingStamps['theme_mode']!;
    final version = SyncVersion(physical: 9000, deviceId: 'devB');
    // 先应用一次远端值（登记版本 = 远端版本）。
    await adapter.apply({
      SyncCategory.settings: [
        SyncRecord(key: 'theme_mode', version: version, data: {'v': 'dark'}),
      ],
    });
    expect(prefs.getString('theme_mode'), 'dark');
    expect(state.settingStamps['theme_mode']!.version, version);

    // 值被直接改写（版本与登记都没变）→ 同版本重放要能修回去。
    await prefs.setString('theme_mode', 'tampered');
    final repaired = await adapter.apply({
      SyncCategory.settings: [
        SyncRecord(key: 'theme_mode', version: version, data: {'v': 'dark'}),
      ],
    });
    expect(repaired.applied, 1);
    expect(prefs.getString('theme_mode'), 'dark');

    // 内容一致时重复应用仍然幂等（不产生写入）。
    final again = await adapter.apply({
      SyncCategory.settings: [
        SyncRecord(key: 'theme_mode', version: version, data: {'v': 'dark'}),
      ],
    });
    expect(again.applied, 0);
    expect(again.skipped, 1);
    expect(stamp.version, isNot(version));
  });

  test('应用远端更新：写回 Prefs 并更新登记（重复应用幂等）', () async {
    await adapter.collect(); // 登记默认值
    final remote = SyncRecord(
      key: 'theme_mode',
      version: const SyncVersion(physical: 9000, deviceId: 'devB'),
      data: {'v': 'dark'},
    );
    final applied = await adapter.apply({
      SyncCategory.settings: [remote],
    });
    expect(applied.applied, 1);
    expect(prefs.getString('theme_mode'), 'dark');

    final again = await adapter.apply({
      SyncCategory.settings: [remote],
    });
    expect(again.applied, 0);
    expect(again.skipped, 1);

    // 再次 collect 时该键保持远端戳（不产生新的本地变更）。
    final collected = await adapter.collect();
    final record = collected[SyncCategory.settings]!
        .firstWhere((r) => r.key == 'theme_mode');
    expect(record.version.physical, 9000);
    expect(record.version.deviceId, 'devB');
  });

  test('旧记录被跳过：本地更新者胜出', () async {
    await prefs.setString('theme_mode', 'dark');
    await adapter.collect(); // 1000/devA
    final stale = SyncRecord(
      key: 'theme_mode',
      version: const SyncVersion(physical: 500, deviceId: 'devB'),
      data: {'v': 'light'},
    );
    final result = await adapter.apply({
      SyncCategory.settings: [stale],
    });
    expect(result.applied, 0);
    expect(prefs.getString('theme_mode'), 'dark');
  });

  test('同毫秒竞争：counter 大的远端写胜出', () async {
    await prefs.setString('theme_mode', 'dark');
    await adapter.collect(); // 1000/0@devA
    final sameMs = SyncRecord(
      key: 'theme_mode',
      version: const SyncVersion(
        physical: 1000,
        counter: 1,
        deviceId: 'devB',
      ),
      data: {'v': 'light'},
    );
    final result = await adapter.apply({
      SyncCategory.settings: [sameMs],
    });
    expect(result.applied, 1);
    expect(prefs.getString('theme_mode'), 'light');
  });

  test('安全存储键：远端写入与读取（ai key 组）', () async {
    await adapter.collect();
    final result = await adapter.apply({
      SyncCategory.credentials: [
        SyncRecord(
          key: 'ai_dj_base_url',
          version: const SyncVersion(physical: 100, deviceId: 'devB'),
          data: {'v': 'https://api.example.com'},
        ),
        SyncRecord(
          key: 'ai_dj_api_key',
          version: const SyncVersion(physical: 100, deviceId: 'devB'),
          data: {'v': 'sk-test'},
        ),
      ],
    });
    expect(result.applied, 2);
    expect(secrets.values['ai_dj_base_url'], 'https://api.example.com');
    expect(secrets.values['ai_dj_api_key'], 'sk-test');

    final collected = await adapter.collect();
    final credentials = collected[SyncCategory.credentials]!;
    expect(
      credentials.firstWhere((r) => r.key == 'ai_dj_api_key').data,
      {'v': 'sk-test'},
    );
    expect(
      credentials.firstWhere((r) => r.key == 'ai_dj_base_url').data,
      {'v': 'https://api.example.com'},
    );
  });

  test('onApplied 回调只报告实际变化的键', () async {
    final changedKeys = <String>{};
    final notifying = PrefsSyncAdapter(
      state: state,
      settings: registry,
      onApplied: (keys) async => changedKeys.addAll(keys),
    );
    await notifying.collect();
    await notifying.apply({
      SyncCategory.settings: [
        SyncRecord(
          key: 'theme_mode',
          version: const SyncVersion(physical: 100, deviceId: 'devB'),
          data: {'v': 'dark'},
        ),
        SyncRecord(
          key: 'play_statistics_enabled',
          version: SyncVersion.zero,
          data: {'v': true},
        ),
      ],
    });
    expect(changedKeys, {'theme_mode'});
  });

  test('StringList 类型往返（shell_nav_order 风格）', () async {
    final listAdapter = PrefsSyncAdapter(
      state: state,
      settings: SettingsRegistry(
        keys: const [kShellNavOrder],
        preferences: prefs,
        secrets: secrets,
      ),
    );
    await listAdapter.collect();
    await listAdapter.apply({
      SyncCategory.settings: [
        const SyncRecord(
          key: 'shell_nav_order',
          version: SyncVersion(physical: 100, deviceId: 'devB'),
          data: {
            'v': ['c', 'a', 'b'],
          },
        ),
      ],
    });
    expect(prefs.getStringList('shell_nav_order'), ['c', 'a', 'b']);
  });
}
