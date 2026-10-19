import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/settings/settings_keys.dart';
import 'package:molia/data/settings/settings_registry.dart';
import 'package:molia/data/sync/adapters/prefs_sync_adapter.dart';
import 'package:molia/data/sync/adapters/script_sync_adapter.dart';
import 'package:molia/data/sync/adapters/session_sync_adapter.dart';
import 'package:molia/data/sync/sync_journal.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/ports/playback_session_sync.dart';
import 'package:molia/services/playback_session_store.dart';
import 'package:molia/sources/lx/lx_script_info.dart';
import 'package:molia/sources/lx/lx_script_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_database.dart';
import 'support/sync_test_support.dart';

/// 写入点即时追加：设置 / 脚本 / 会话在**写入点**就登记并追加日志
/// （不等下一轮的哈希检测），且下一轮不会重复追加。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MoliaDatabase db;
  late SyncJournalRepository journal;
  late SyncStateStore state;
  var now = 1000;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    now = 1000;
    db = openMemoryDatabase();
    journal = SyncJournalRepository(
      databaseProvider: () => db,
      clock: () => now,
    );
    state = SyncStateStore(
      preferences: prefs,
      secrets: MemorySyncSecretStore(),
      clock: () => now,
      deviceId: 'devA',
    );
    await state.init();
  });

  tearDown(() => db.close());

  test('设置：写入点即时追加日志，下一轮 collect 不重复', () async {
    final prefs = await SharedPreferences.getInstance();
    final registry = SettingsRegistry(
      keys: const [kThemeMode],
      preferences: prefs,
      secrets: MemorySyncSecretStore(),
    );
    final adapter = PrefsSyncAdapter(
      state: state,
      settings: registry,
      journal: journal,
    );

    // 首次登记（初始视图）不追加。
    await adapter.collect();
    expect(await journal.headSeq(), 0);

    // 用户切换主题：写入钩子立即登记 + 追加（不等下一轮）。
    now = 5000;
    await registry.write(kThemeMode, 'dark');
    await adapter.noteKeyWritten(kThemeMode);
    final window = await journal.window();
    expect(window, hasLength(1));
    expect(window.single.category, SyncCategory.settings);
    expect(window.single.record.key, 'theme_mode');
    expect(window.single.record.data, {'v': 'dark'});

    // 下一轮 collect：登记已更新 → 不重复追加，记录版本一致。
    final collected = await adapter.collect();
    expect(await journal.headSeq(), 1);
    expect(
      collected[SyncCategory.settings]!.single.version,
      window.single.record.version,
    );
  });

  test('设置：远端应用不触发写入钩子（不追加日志、不标记待发）', () async {
    final prefs = await SharedPreferences.getInstance();
    final written = <String>[];
    final registry = SettingsRegistry(
      keys: const [kThemeMode],
      preferences: prefs,
      secrets: MemorySyncSecretStore(),
    )..onWrite = (key) => written.add(key.name);
    final adapter = PrefsSyncAdapter(
      state: state,
      settings: registry,
      journal: journal,
    );
    await adapter.collect();

    await adapter.apply({
      SyncCategory.settings: [
        SyncRecord(
          key: 'theme_mode',
          version: const SyncVersion(physical: 9000, deviceId: 'devB'),
          data: const {'v': 'dark'},
        ),
      ],
    });

    expect(prefs.getString('theme_mode'), 'dark');
    expect(written, isEmpty, reason: '远端值不算本机写入');
    expect(await journal.headSeq(), 0);
  });

  test('脚本：新导入即时追加日志（不依赖下一轮哈希检测）', () async {
    final repository = LxScriptRepository();
    final adapter = ScriptSyncAdapter(
      repository: repository,
      state: state,
      journal: journal,
    );
    await adapter.collect();

    // 导入一个**新**脚本（没有历史登记，只靠下一轮检测会被当首次登记）。
    final info = LxScriptInfo(
      id: 'script-1',
      name: '源一',
      description: '',
      version: '1.0.0',
      author: '',
      homepage: '',
      script: '/* @name 源一 */',
      importedAt: 500,
    );
    await repository.add(info);
    await adapter.noteScriptWritten('script-1');

    final window = await journal.window();
    expect(window, hasLength(1));
    expect(window.single.category, SyncCategory.sources);
    expect(window.single.record.key, 'script-1');
    expect(window.single.record.data?['name'], '源一');

    // 下一轮 collect 不重复。
    await adapter.collect();
    expect(await journal.headSeq(), 1);

    // 本机删除：即时写墓碑。
    await repository.remove('script-1');
    await adapter.noteScriptRemoved('script-1');
    final afterRemove = await journal.window(since: 1);
    expect(afterRemove, hasLength(1));
    expect(afterRemove.single.record.deleted, isTrue);
    expect(afterRemove.single.record.key, 'script-1');
    await adapter.collect();
    expect(await journal.headSeq(), 2);
  });

  test('会话：保存后即时追加；窗口内高频保存合并，窗口外再追加', () async {
    final store = PlaybackSessionStore(
        clock: () => DateTime.fromMillisecondsSinceEpoch(now));
    final adapter = SessionSyncAdapter(
      port: _StoreSessionPort(store),
      state: state,
      journal: journal,
    );
    await adapter.collect();

    Future<void> save() => store.saveRaw({
          PlaybackSessionStore.savedAtKey: now,
          'index': 0,
          'tracks': [
            {'sourceKey': 'kuwo', 'songId': 'song-1', 'title': '歌曲'},
          ],
        });

    // 第一次保存：立即追加。
    await save();
    await adapter.noteLocalSave();
    expect(await journal.headSeq(), 1);
    final entry = (await journal.window()).single;
    expect(entry.category, SyncCategory.session);
    expect(entry.record.key, SyncRecordKeys.sessionKey);

    // 窗口内第二次保存：合并（不追加）。
    now += 10 * 1000;
    await save();
    await adapter.noteLocalSave();
    expect(await journal.headSeq(), 1);

    // 窗口外：再追加（内容已变化）。
    now += SessionSyncAdapter.immediateWindowMs + 1;
    await save();
    await adapter.noteLocalSave();
    expect(await journal.headSeq(), 2);

    // 下一轮 collect 不重复追加。
    await adapter.collect();
    expect(await journal.headSeq(), 2);
  });
}

/// store → 同步端口的测试适配器。
///
/// 生产由 `PlaybackSessionCoordinator` 实现端口（唯一写者）；本测试只关心
/// 写入点钩子，用一个最小的本地适配器把 store 接到 [SessionSyncAdapter]。
class _StoreSessionPort implements PlaybackSessionSyncPort {
  _StoreSessionPort(this._store);

  final PlaybackSessionStore _store;

  @override
  Future<Map<String, dynamic>?> loadRaw() => _store.loadRaw();

  @override
  Future<void> applyRemote(Map<String, dynamic> raw) => _store.saveRaw(raw);

  @override
  Future<void> clearRemote() => _store.clear();
}
