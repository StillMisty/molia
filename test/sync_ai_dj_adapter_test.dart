import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/adapters/ai_dj_sync_adapter.dart';
import 'package:molia/data/sync/sync_journal.dart';
import 'package:molia/data/sync/sync_stamp_book.dart';
import 'package:molia/domain/models/ai_dj.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/services/ai/ai_recommendation_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// AI 推荐历史适配器：批次记录 / active 指针 / 本地删除墓碑 / 远端应用 /
/// 内容未变不追加日志。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late AiRecommendationStore store;
  late SyncStampBook stamps;
  late _RecordingJournal journal;
  late AiDjSyncAdapter adapter;
  var now = 1000;
  var reapplied = 0;
  var localChanges = 0;

  StoredAiBatch batch(String id, {String title = 'Song'}) => StoredAiBatch(
    id: id,
    items: [
      StoredAiBatchItem(
        sourceKey: 'wy',
        songId: id,
        title: title,
        artist: 'Artist',
        album: 'Album',
        reason: 'reason',
        raw: const {'songmid': 'x'},
      ),
    ],
    unresolved: const [],
    generatedAt: DateTime.fromMillisecondsSinceEpoch(now),
    origin: AiDjOrigin.refresh,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    now = 1000;
    reapplied = 0;
    localChanges = 0;
    store = AiRecommendationStore(
      preferences: prefs,
      clock: () => DateTime.fromMillisecondsSinceEpoch(now),
      // 强制走 prefs 后端：测试不注册 path_provider。
      directoryProvider: () async => null,
    );
    store.onLocalChange = () => localChanges++;
    stamps = SyncStampBook(
      clock: () => now,
      deviceId: () => 'devA',
      onChanged: () {},
    );
    journal = _RecordingJournal();
    adapter = AiDjSyncAdapter(
      store: store,
      state: stamps,
      journal: journal,
      onApplied: () async => reapplied++,
    );
  });

  test('首次收集：批次 + active 指针，变化追加日志；内容未变不重复追加', () async {
    await store.saveBatch(batch('b1'), makeActive: true);

    final first = (await adapter.collect())[SyncCategory.aiDj]!;
    expect(first, hasLength(2));
    final byKey = {for (final record in first) record.key: record};
    expect(byKey['b1']!.deleted, isFalse);
    expect(byKey['b1']!.data!['id'], 'b1');
    expect(byKey[SyncRecordKeys.activeAiBatchKey]!.data, {'id': 'b1'});
    expect(journal.changes, hasLength(2), reason: '本地新增批次与 active 都要外发');
    expect(stamps.aiBatchStamps['b1']!.hash, isNotEmpty);

    journal.changes.clear();
    final second = (await adapter.collect())[SyncCategory.aiDj]!;
    expect(second, hasLength(2));
    expect(journal.changes, isEmpty, reason: '哈希未变不应重复追加增量');
  });

  test('本地删除：生成墓碑并清空 active', () async {
    await store.saveBatch(batch('b1'), makeActive: true);
    await adapter.collect();
    journal.changes.clear();

    await store.deleteBatch('b1');
    expect(localChanges, 2, reason: '本地保存 / 删除都应触发同步触发钩子');

    final records = (await adapter.collect())[SyncCategory.aiDj]!;
    final byKey = {for (final record in records) record.key: record};
    expect(byKey['b1']!.deleted, isTrue);
    expect(byKey[SyncRecordKeys.activeAiBatchKey]!.data, {'id': null});
    expect(journal.changes, hasLength(2));
  });

  test('远端应用：写入批次与 active，登记远端版本，不触本地变更回调', () async {
    final remote = batch('remote');
    final record = SyncRecord(
      key: 'remote',
      version: const SyncVersion(physical: 2000, deviceId: 'devB'),
      data: remote.toJson(),
    );
    final active = SyncRecord(
      key: SyncRecordKeys.activeAiBatchKey,
      version: const SyncVersion(physical: 2001, deviceId: 'devB'),
      data: const {'id': 'remote'},
    );

    final outcome = await adapter.apply({
      SyncCategory.aiDj: [record, active],
    });
    expect(outcome.applied, 2);
    expect(outcome.skipped, 0);
    expect(reapplied, 1);
    expect(localChanges, 0, reason: '远端应用不能形成同步回环');

    final index = await store.loadIndex();
    expect(index.entries.single.id, 'remote');
    expect(index.activeBatchId, 'remote');
    expect(await store.loadBatch('remote'), isNotNull);
    expect(
      stamps.aiBatchStamps['remote']!.version,
      const SyncVersion(physical: 2000, deviceId: 'devB'),
    );
    expect(
      stamps.activeAiBatchStamp!.version,
      const SyncVersion(physical: 2001, deviceId: 'devB'),
    );

    journal.changes.clear();
    final collected = (await adapter.collect())[SyncCategory.aiDj]!;
    expect(
      {for (final item in collected) item.key: item.version}['remote'],
      const SyncVersion(physical: 2000, deviceId: 'devB'),
    );
    expect(journal.changes, isEmpty, reason: '远端落地的内容不应再当成本地变更');
  });

  test('远端墓碑：删除本地批次并登记墓碑，后续轮次继续外发', () async {
    await store.saveBatch(batch('b1'), makeActive: true);
    await adapter.collect();
    journal.changes.clear();

    final version = const SyncVersion(physical: 3000, deviceId: 'devB');
    final outcome = await adapter.apply({
      SyncCategory.aiDj: [SyncRecord.tombstone(key: 'b1', version: version)],
    });
    expect(outcome.applied, 1);
    expect((await store.loadIndex()).entries, isEmpty);
    expect(stamps.aiBatchTombstones['b1']!.version, version);
    expect(stamps.aiBatchStamps, isEmpty);

    final records = (await adapter.collect())[SyncCategory.aiDj]!;
    final gone = records.singleWhere((record) => record.key == 'b1');
    expect(gone.deleted, isTrue);
    expect(gone.version, version);
    expect(
      journal.changes,
      hasLength(1),
      reason: '墓碑本身已登记；只有 active 因批次消失回退 null 是新变化',
    );
    expect(journal.changes.single.record.key, SyncRecordKeys.activeAiBatchKey);
    expect(journal.changes.single.record.data, {'id': null});
  });

  test('类别未请求：立即返回空，不读历史', () async {
    await store.saveBatch(batch('b1'), makeActive: true);
    final records = await adapter.collectForCategories({SyncCategory.settings});
    expect(records, isEmpty);
    expect(journal.changes, isEmpty);
  });

  test('损坏记录：跳过且不写回；首次空 active 用零值戳', () async {
    final empty = (await adapter.collect())[SyncCategory.aiDj]!;
    final active = empty.single;
    expect(active.key, SyncRecordKeys.activeAiBatchKey);
    expect(active.version, SyncVersion.zero);
    expect(journal.changes, isEmpty);

    final outcome = await adapter.apply({
      SyncCategory.aiDj: [
        SyncRecord(
          key: 'bad',
          version: const SyncVersion(physical: 4000, deviceId: 'devB'),
          data: const {},
        ),
      ],
    });
    expect(outcome.applied, 0);
    expect(outcome.skipped, 1);
  });
}

class _RecordingJournal implements SyncJournalAppender {
  final List<SyncJournalChange> changes = [];

  @override
  Future<List<int>> appendAll(Iterable<SyncJournalChange> changes) async {
    final list = changes.toList();
    this.changes.addAll(list);
    return [for (var i = 0; i < list.length; i++) i];
  }
}
