import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/adapters/prefs_sync_adapter.dart';
import 'package:molia/data/sync/sync_engine.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/sync_test_support.dart';

/// 完整快照备份测试：导出内容与凭证排除、导入合并与幂等、坏文件拒绝。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const specs = [
    SyncSettingSpec(
      key: 'theme_mode',
      category: SyncCategory.settings,
      defaultValue: 'system',
    ),
    SyncSettingSpec(
      key: 'ai_dj_api_key',
      category: SyncCategory.credentials,
      store: SyncValueStore.secure,
      defaultValue: '',
    ),
  ];

  late SharedPreferences prefs;
  late MemorySyncSecretStore secrets;
  late SyncStateStore state;
  late SyncEngine engine;
  var now = 7000;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    secrets = MemorySyncSecretStore();
    now = 7000;
    state = SyncStateStore(
      preferences: prefs,
      secrets: secrets,
      clock: () => now,
    );
    await state.init();
    engine = SyncEngine(
      state: state,
      adapters: [
        PrefsSyncAdapter(
          state: state,
          specs: specs,
          deviceId: () => 'devA',
          now: () => now,
        ),
      ],
      transports: const {},
    );
    await engine.init();
  });

  tearDown(() => engine.dispose());

  test('导出：包含跟人走的设置，默认排除凭证', () async {
    await prefs.setString('theme_mode', 'dark');
    await secrets.write('ai_dj_api_key', 'sk-secret');

    final json = await engine.exportBackupJson();
    expect(json, contains('molia_backup'));
    expect(json, contains('theme_mode'));
    expect(json, contains('dark'));
    expect(json, isNot(contains('ai_dj_api_key')));
    expect(json, isNot(contains('sk-secret')));
  });

  test('导出：显式要求时凭证随快照进入（由调用方负责密文/保管）', () async {
    await secrets.write('ai_dj_api_key', 'sk-secret');
    final json =
        await engine.exportBackupJson(includeCredentials: true);
    expect(json, contains('ai_dj_api_key'));
    expect(json, contains('sk-secret'));
  });

  test('导入：与新备份逐键合并，凭证类别忽略；重复导入幂等', () async {
    final backup = jsonEncode({
      'kind': 'molia_backup',
      'v': 1,
      'producedAt': 1,
      'envelope': {
        'v': 1,
        'deviceId': 'devB',
        'producedAt': 1,
        'records': {
          'settings': [
            {
              'key': 'theme_mode',
              'updatedAt': 9000,
              'updatedBy': 'devB',
              'data': {'v': 'light'},
            },
          ],
          'credentials': [
            {
              'key': 'ai_dj_api_key',
              'updatedAt': 9000,
              'updatedBy': 'devB',
              'data': {'v': 'sk-from-backup'},
            },
          ],
        },
      },
    });

    final result = await engine.importBackupJson(backup);
    expect(result.applied, 1);
    expect(prefs.getString('theme_mode'), 'light');
    expect(secrets.values['ai_dj_api_key'], isNull);

    final again = await engine.importBackupJson(backup);
    expect(again.applied, 0);
    expect(again.skipped, greaterThanOrEqualTo(1));
  });

  test('导入：本地较新的改动不被旧备份覆盖', () async {
    now = 50000;
    await prefs.setString('theme_mode', 'dark');
    // 先登记本地现状（本次改动时间戳 = 50000）。
    await engine.exportBackupJson();

    final staleBackup = jsonEncode({
      'kind': 'molia_backup',
      'v': 1,
      'producedAt': 1,
      'envelope': {
        'deviceId': 'devB',
        'producedAt': 1,
        'records': {
          'settings': [
            {
              'key': 'theme_mode',
              'updatedAt': 10000,
              'updatedBy': 'devB',
              'data': {'v': 'light'},
            },
          ],
        },
      },
    });
    final result = await engine.importBackupJson(staleBackup);
    expect(result.applied, 0);
    expect(prefs.getString('theme_mode'), 'dark');
  });

  test('导入：非 JSON / 非 Molia 备份拒绝', () async {
    expect(
      () => engine.importBackupJson('not-json'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => engine.importBackupJson('{"kind":"other"}'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => engine.importBackupJson('{"kind":"molia_backup"}'),
      throwsA(isA<FormatException>()),
    );
  });
}
