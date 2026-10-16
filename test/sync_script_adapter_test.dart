import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/adapters/script_sync_adapter.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/sources/lx/lx_script_info.dart';
import 'package:molia/sources/lx/lx_script_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/sync_test_support.dart';

/// LX 脚本适配器的墓碑版本判定：本地删除一律取新戳（删除能外传）、
/// 陈旧远端墓碑/脚本不覆盖本地较新的删除，也不复活已删除脚本。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SyncStateStore state;
  late LxScriptRepository repository;
  late ScriptSyncAdapter adapter;
  var now = 1000;

  LxScriptInfo script(String id) => LxScriptInfo(
        id: id,
        name: '源 $id',
        description: '',
        version: '1.0.0',
        author: '',
        homepage: '',
        script: '/* @name 源 $id */',
        importedAt: 500,
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    now = 1000;
    state = SyncStateStore(
      preferences: prefs,
      secrets: MemorySyncSecretStore(),
      clock: () => now,
      deviceId: 'devA',
    );
    await state.init();
    // 不 init：测试里不落盘（add/remove 的持久化在无文件时是空操作）。
    repository = LxScriptRepository();
    adapter = ScriptSyncAdapter(repository: repository, state: state);
  });

  test('同版本但内容不同：修回远端脚本（全量快照的强制交付）', () async {
    await repository.add(script('a'));
    final version = SyncVersion(physical: 9000, deviceId: 'devB');
    final remote = SyncRecord(
      key: 'a',
      version: version,
      data: script('a').toJson(),
    );

    // 首次应用：登记版本 = 远端版本。
    await adapter.apply({
      SyncCategory.sources: [remote],
    });
    expect(state.scriptStamps['a']!.version, version);

    // 脚本被直接改写（登记哈希与版本都没变）→ 同版本重放要修回去。
    await repository.add(LxScriptInfo(
      id: 'a',
      name: '被改写',
      description: '',
      version: '9.9.9',
      author: '',
      homepage: '',
      script: '/* @name 被改写 */',
      importedAt: 500,
    ));
    final repaired = await adapter.apply({
      SyncCategory.sources: [remote],
    });
    expect(repaired.applied, 1);
    expect(repository.scripts.single.name, '源 a');

    // 内容一致时重复应用仍然幂等。
    final again = await adapter.apply({
      SyncCategory.sources: [remote],
    });
    expect(again.applied, 0);
    expect(again.skipped, 1);
  });

  test('本地删除一律取新戳：删除能外传，且不被陈旧远端脚本复活', () async {
    await repository.add(script('lx-a'));
    final collected = await adapter.collect();
    final scriptRecord = collected[SyncCategory.sources]!
        .firstWhere((record) => record.key == 'lx-a' && !record.deleted);
    final scriptVersion = scriptRecord.version;
    expect(state.knownScriptIds, ['lx-a']);

    // 先收一条陈旧的远端删除（版本低于脚本版本）：不动脚本，但会种下墓碑。
    final staleDelete = SyncRecord.tombstone(
      key: 'lx-a',
      version: const SyncVersion(physical: 500, deviceId: 'devB'),
      deletedAt: 500,
    );
    var result = await adapter.apply({
      SyncCategory.sources: [staleDelete],
    });
    expect(result.applied, 0);
    expect(repository.scripts, hasLength(1), reason: '陈旧删除不动脚本');
    expect(state.scriptTombstones['lx-a']!.version.physical, 500);

    // 本地删除：必须取新戳（覆盖陈旧墓碑），否则这次删除会输给对端旧脚本。
    now = 2000;
    await repository.remove('lx-a');
    final afterDelete = await adapter.collect();
    final tombstone = afterDelete[SyncCategory.sources]!
        .firstWhere((record) => record.deleted && record.key == 'lx-a');
    expect(tombstone.version.isNewerThan(scriptVersion), isTrue);
    expect(
      tombstone.version
          .isNewerThan(const SyncVersion(physical: 500, deviceId: 'devB')),
      isTrue,
    );
    expect(state.scriptTombstones['lx-a']!.version.physical, 2000);

    // 对端仍持有旧脚本（版本小于墓碑）回推：不落地、不复活。
    result = await adapter.apply({
      SyncCategory.sources: [
        SyncRecord(
          key: 'lx-a',
          version: scriptVersion,
          data: script('lx-a').toJson(),
        ),
      ],
    });
    expect(result.applied, 0);
    expect(repository.scripts, isEmpty, reason: '旧脚本不复活');
    expect(state.scriptTombstones['lx-a']!.version.physical, 2000);
  });

  test('远端陈旧删除不覆盖本地较新的墓碑；更新的删除才覆盖', () async {
    state.putScriptTombstone(
      'lx-a',
      const SyncStamp(version: SyncVersion(physical: 9000, deviceId: 'devA')),
    );

    final stale = await adapter.apply({
      SyncCategory.sources: [
        SyncRecord.tombstone(
          key: 'lx-a',
          version: const SyncVersion(physical: 1000, deviceId: 'devB'),
          deletedAt: 1000,
        ),
      ],
    });
    expect(stale.applied, 0);
    expect(
      state.scriptTombstones['lx-a']!.version.physical,
      9000,
      reason: '保留本地较新的删除',
    );

    await adapter.apply({
      SyncCategory.sources: [
        SyncRecord.tombstone(
          key: 'lx-a',
          version: const SyncVersion(physical: 10000, deviceId: 'devB'),
          deletedAt: 10000,
        ),
      ],
    });
    expect(state.scriptTombstones['lx-a']!.version.physical, 10000);
  });

  test('删除被采纳时移除脚本且保留墓碑供继续传播', () async {
    await repository.add(script('lx-a'));
    await adapter.collect();

    final result = await adapter.apply({
      SyncCategory.sources: [
        SyncRecord.tombstone(
          key: 'lx-a',
          version: const SyncVersion(physical: 5000, deviceId: 'devB'),
          deletedAt: 5000,
        ),
      ],
    });
    expect(result.applied, 1);
    expect(repository.scripts, isEmpty);
    expect(state.scriptTombstones['lx-a']!.version.physical, 5000);
    expect(state.scriptStamps.containsKey('lx-a'), isFalse);
  });
}
