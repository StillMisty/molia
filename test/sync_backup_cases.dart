import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/settings_key.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/data/settings/settings_registry.dart';
import 'package:molia/data/sync/adapters/prefs_sync_adapter.dart';
import 'package:molia/data/sync/sync_backup.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/sync_test_support.dart';

/// 完整快照备份测试：导出内容与凭证排除、导入合并与幂等、坏文件与结构校验拒绝。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const keys = [kThemeMode, kAiDjApiKey, kBiliAccountCookie];

  late SharedPreferences prefs;
  late MemorySyncSecretStore secrets;
  late SyncStateStore state;
  late SettingsRegistry registry;
  late PrefsSyncAdapter adapter;
  late SyncBackup backup;
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
      deviceId: 'devA',
    );
    await state.init();
    registry = SettingsRegistry(
      keys: keys,
      preferences: prefs,
      secrets: secrets,
    );
    adapter = PrefsSyncAdapter(state: state, settings: registry);
    // 备份只依赖「按类别收集」这一个读动作：测试不构造引擎、传输或轮次，
    // 收集语义仍与生产一致（同一适配器 + 同一类别过滤）。
    backup = SyncBackup(
      state: state,
      adapters: [adapter],
      stamps: state.stampIssuer,
      clock: () => DateTime.fromMillisecondsSinceEpoch(now),
      collect: (categories) async {
        final collected = await adapter.collect();
        return {
          for (final entry in collected.entries)
            if (categories.contains(entry.key)) entry.key: entry.value,
        };
      },
    );
  });

  /// 一份备份文件（外层 v 是备份文件格式版本，内层 envelope 是协议快照）。
  String backupJson({required Map<String, Object?> records}) => jsonEncode({
    'kind': 'molia_backup',
    'v': 1,
    'producedAt': 1,
    'envelope': {
      'v': SyncEnvelope.protocolVersion,
      'deviceId': 'devB',
      'producedAt': 1,
      'records': records,
    },
  });

  test('B 站登录凭据：凭证类别 + secure 盒', () {
    expect(kBiliAccountCookie.category, SyncCategory.credentials);
    expect(kBiliAccountCookie.store, SettingsValueStore.secure);
  });

  test('导出：默认导出完整状态（设置 + 全部凭证）', () async {
    await prefs.setString('theme_mode', 'dark');
    await secrets.write('ai_dj_api_key', 'sk-secret');
    await secrets.write(kBiliAccountCookie.name, 'SESSDATA=bili-login');

    final json = await backup.exportBackupJson();
    expect(json, contains('molia_backup'));
    expect(json, contains('theme_mode'));
    expect(json, contains('dark'));
    expect(json, contains('ai_dj_api_key'));
    expect(json, contains('sk-secret'));
    expect(json, contains('bili_account_cookie_v1'));
    expect(json, contains('SESSDATA=bili-login'));
    // 内层 envelope 是协议 v3（记录带版本对象；协议自始为 v3）。
    expect(jsonDecode(json)['envelope']['v'], SyncEnvelope.protocolVersion);
  });

  test('导出：includeCredentials=false 时显式排除全部凭证', () async {
    await secrets.write('ai_dj_api_key', 'sk-secret');
    await secrets.write(kBiliAccountCookie.name, 'SESSDATA=bili-login');
    final json = await backup.exportBackupJson(includeCredentials: false);
    expect(json, isNot(contains('ai_dj_api_key')));
    expect(json, isNot(contains('bili_account_cookie_v1')));
  });

  test('导入：默认恢复全部凭证，换机状态一致', () async {
    final backupText = backupJson(
      records: {
        'credentials': [
          {
            'key': kBiliAccountCookie.name,
            'version': {'physical': 9000, 'counter': 0, 'deviceId': 'devB'},
            'data': {'v': 'SESSDATA=from-backup; DedeUserID=7'},
          },
          {
            'key': 'ai_dj_api_key',
            'version': {'physical': 9000, 'counter': 0, 'deviceId': 'devB'},
            'data': {'v': 'sk-from-backup'},
          },
        ],
      },
    );

    final result = await backup.importBackupJson(backupText);
    expect(result.applied, 2);
    expect(
      secrets.values[kBiliAccountCookie.name],
      contains('SESSDATA=from-backup'),
    );
    expect(secrets.values['ai_dj_api_key'], 'sk-from-backup');
  });

  test('导入：includeCredentials=false 时忽略全部凭证', () async {
    final backupText = backupJson(
      records: {
        'credentials': [
          {
            'key': 'ai_dj_api_key',
            'version': {'physical': 9000, 'counter': 0, 'deviceId': 'devB'},
            'data': {'v': 'sk-from-backup'},
          },
        ],
      },
    );
    final result = await backup.importBackupJson(
      backupText,
      includeCredentials: false,
    );
    expect(result.applied, 0);
    expect(secrets.values['ai_dj_api_key'], isNull);
  });

  test('导入：显式排除凭证时只合并普通设置；重复导入幂等', () async {
    final backupText = backupJson(
      records: {
        'settings': [
          {
            'key': 'theme_mode',
            'version': {'physical': 9000, 'counter': 0, 'deviceId': 'devB'},
            'data': {'v': 'light'},
          },
        ],
        'credentials': [
          {
            'key': 'ai_dj_api_key',
            'version': {'physical': 9000, 'counter': 0, 'deviceId': 'devB'},
            'data': {'v': 'sk-from-backup'},
          },
        ],
      },
    );

    final result = await backup.importBackupJson(
      backupText,
      includeCredentials: false,
    );
    expect(result.applied, 1);
    expect(prefs.getString('theme_mode'), 'light');
    expect(secrets.values['ai_dj_api_key'], isNull);

    final again = await backup.importBackupJson(
      backupText,
      includeCredentials: false,
    );
    expect(again.applied, 0);
    expect(again.skipped, greaterThanOrEqualTo(1));
  });

  test('导入：本地较新的改动不被旧备份覆盖', () async {
    now = 50000;
    await prefs.setString('theme_mode', 'dark');
    // 先登记本地现状（本次改动版本 = 50000）。
    await backup.exportBackupJson();

    final staleBackup = backupJson(
      records: {
        'settings': [
          {
            'key': 'theme_mode',
            'version': {'physical': 10000, 'counter': 0, 'deviceId': 'devB'},
            'data': {'v': 'light'},
          },
        ],
      },
    );
    final result = await backup.importBackupJson(staleBackup);
    expect(result.applied, 0);
    expect(prefs.getString('theme_mode'), 'dark');
  });

  test('导入：结构不对的备份拒绝，不静默合并', () async {
    // 内层 envelope 缺 deviceId：不是有效的 Molia 快照。
    final malformed = jsonEncode({
      'kind': 'molia_backup',
      'v': 1,
      'producedAt': 1,
      'envelope': {'producedAt': 1, 'records': const {}},
    });
    await expectLater(
      () => backup.importBackupJson(malformed),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('无效'),
        ),
      ),
    );
    expect(prefs.getString('theme_mode'), isNull);
  });

  test('导入：非 JSON / 非 Molia 备份拒绝', () async {
    expect(
      () => backup.importBackupJson('not-json'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => backup.importBackupJson('{"kind":"other"}'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => backup.importBackupJson('{"kind":"molia_backup"}'),
      throwsA(isA<FormatException>()),
    );
  });
}
