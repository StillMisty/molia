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
    kCopyLyricsSingleLine,
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
    );
    await state.init();
    registry = SettingsRegistry(
      keys: keys,
      preferences: prefs,
      secrets: secrets,
    );
    adapter = PrefsSyncAdapter(
      state: state,
      settings: registry,
      deviceId: () => 'devA',
      now: () => now,
    );
  });

  test('首次登记：默认值时间戳 0、已改过的键用当前时间', () async {
    await prefs.setString('theme_mode', 'dark');
    final collected = await adapter.collect();
    final settings = collected[SyncCategory.settings]!;
    final theme = settings.firstWhere((r) => r.key == 'theme_mode');
    expect(theme.updatedAt, 1000);
    expect(theme.updatedBy, 'devA');
    expect(theme.data, {'v': 'dark'});
    final secure = settings.firstWhere((r) => r.key == 'copy_lyrics_single_line');
    expect(secure.updatedAt, 0);
    expect(secure.updatedBy, '');
    expect(secure.data, {'v': null});

    expect(collected[SyncCategory.sources]!.single.key, 'lx_default_quality');
    expect(collected[SyncCategory.credentials]!.single.key, 'ai_dj_api_key');
  });

  test('本地修改检测：值变化后重新打戳', () async {
    final first = await adapter.collect();
    final before = first[SyncCategory.settings]!
        .firstWhere((r) => r.key == 'theme_mode');
    expect(before.updatedAt, 0);

    now = 5000;
    await prefs.setString('theme_mode', 'light');
    final second = await adapter.collect();
    final after = second[SyncCategory.settings]!
        .firstWhere((r) => r.key == 'theme_mode');
    expect(after.updatedAt, 5000);
    expect(after.updatedBy, 'devA');
    expect(after.data, {'v': 'light'});
  });

  test('应用远端更新：写回 Prefs 并更新登记（重复应用幂等）', () async {
    await adapter.collect(); // 登记默认值
    final remote = SyncRecord(
      key: 'theme_mode',
      updatedAt: 9000,
      updatedBy: 'devB',
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
    expect(record.updatedAt, 9000);
    expect(record.updatedBy, 'devB');
  });

  test('旧记录被跳过：本地更新者胜出', () async {
    await prefs.setString('theme_mode', 'dark');
    await adapter.collect(); // t=1000 devA
    final stale = SyncRecord(
      key: 'theme_mode',
      updatedAt: 500,
      updatedBy: 'devB',
      data: {'v': 'light'},
    );
    final result = await adapter.apply({
      SyncCategory.settings: [stale],
    });
    expect(result.applied, 0);
    expect(prefs.getString('theme_mode'), 'dark');
  });

  test('安全存储键：远端写入与读取（copy_lyrics_single_line / ai key）', () async {
    await adapter.collect();
    final result = await adapter.apply({
      SyncCategory.settings: [
        SyncRecord(
          key: 'copy_lyrics_single_line',
          updatedAt: 100,
          updatedBy: 'devB',
          data: {'v': 'true'},
        ),
      ],
      SyncCategory.credentials: [
        SyncRecord(
          key: 'ai_dj_api_key',
          updatedAt: 100,
          updatedBy: 'devB',
          data: {'v': 'sk-test'},
        ),
      ],
    });
    expect(result.applied, 2);
    expect(secrets.values['copy_lyrics_single_line'], 'true');
    expect(secrets.values['ai_dj_api_key'], 'sk-test');

    final collected = await adapter.collect();
    expect(
      collected[SyncCategory.credentials]!.single.data,
      {'v': 'sk-test'},
    );
  });

  test('onApplied 回调只报告实际变化的键', () async {
    final changedKeys = <String>{};
    final notifying = PrefsSyncAdapter(
      state: state,
      settings: registry,
      deviceId: () => 'devA',
      now: () => now,
      onApplied: (keys) async => changedKeys.addAll(keys),
    );
    await notifying.collect();
    await notifying.apply({
      SyncCategory.settings: [
        SyncRecord(
          key: 'theme_mode',
          updatedAt: 100,
          updatedBy: 'devB',
          data: {'v': 'dark'},
        ),
        SyncRecord(
          key: 'copy_lyrics_single_line',
          updatedAt: 0,
          updatedBy: '',
          data: {'v': null},
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
      deviceId: () => 'devA',
      now: () => now,
    );
    await listAdapter.collect();
    await listAdapter.apply({
      SyncCategory.settings: [
        const SyncRecord(
          key: 'shell_nav_order',
          updatedAt: 100,
          updatedBy: 'devB',
          data: {
            'v': ['c', 'a', 'b'],
          },
        ),
      ],
    });
    expect(prefs.getStringList('shell_nav_order'), ['c', 'a', 'b']);
  });
}
