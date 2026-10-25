import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/data/sync/adapters/cover_sync_adapter.dart';
import 'package:molia/data/sync/sync_journal.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/services/covers/custom_cover_store.dart';

import 'support/sync_test_support.dart';

/// 自定义封面同步适配器：首次登记 / 变化 / 删除墓碑 / 远端 LWW /
/// 默认封面 / 损坏与超限跳过 / 类别未请求时跳过 / 开启切换轮的日志门控。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late CustomCoverStore store;
  late SyncStateStore state;
  late _RecordingJournal journal;
  late CoverSyncAdapter adapter;
  var enabled = true;
  var now = 1000;

  const trackId = TrackId('wy', '1');

  Uint8List jpeg(int seed) => Uint8List.fromList(
        [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, seed, seed, seed],
      );

  SyncRecord imageRecord(
    String key,
    Uint8List bytes, {
    required SyncVersion version,
  }) =>
      SyncRecord(
        key: key,
        version: version,
        data: {
          'image': base64Encode(bytes),
          'mime': 'image/jpeg',
          'hash': sha256.convert(bytes).toString(),
          'updatedAt': version.physical,
        },
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('molia_cover_sync_');
    now = 1000;
    store = CustomCoverStore(
      supportDirectory: () async => tempDir,
      clock: () => DateTime.fromMillisecondsSinceEpoch(now),
    );
    await store.load();
    state = SyncStateStore(
      preferences: await SharedPreferences.getInstance(),
      secrets: MemorySyncSecretStore(),
      clock: () => now,
      deviceId: 'devA',
    );
    await state.init();
    journal = _RecordingJournal();
    enabled = true;
    adapter = CoverSyncAdapter(
      store: store,
      state: state,
      journal: journal,
      enabled: () => enabled,
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('首次登记：类别开启时也追加日志；哈希未变复用版本与缓存', () async {
    await store.setTrackCover(trackId, jpeg(1));

    final first = (await adapter.collect())[SyncCategory.covers]!;
    expect(first, hasLength(1));
    final record = first.single;
    expect(record.key, 'wy:1');
    expect(record.deleted, isFalse);
    expect(record.version.physical, greaterThan(0));
    expect(
      base64Decode(record.data!['image'] as String),
      jpeg(1),
    );
    expect(record.data!['mime'], 'image/jpeg');
    expect(record.data!['hash'], sha256.convert(jpeg(1)).toString());
    expect(journal.changes, hasLength(1), reason: '开启类别时首次登记要进增量');
    expect(journal.changes.single.record.key, 'wy:1');

    // 同一内容再收集：版本不变、不重复追加；base64 从按哈希缓存读取
    //（删掉文件也不会重新读盘，证明缓存生效）。
    File(store.trackCoverPath(trackId)!).deleteSync();
    final again = (await adapter.collect())[SyncCategory.covers]!;
    expect(again.single.version, record.version);
    expect(journal.changes, hasLength(1));
  });

  test('内容变化：取新版本并追加日志，旧版本不会继续外发', () async {
    await store.setTrackCover(trackId, jpeg(1));
    final before = (await adapter.collect())[SyncCategory.covers]!.single;
    journal.changes.clear();

    now = 2000;
    await store.setTrackCover(trackId, jpeg(2));
    final after = (await adapter.collect())[SyncCategory.covers]!.single;

    expect(after.version.isNewerThan(before.version), isTrue);
    expect(after.data!['hash'], sha256.convert(jpeg(2)).toString());
    expect(journal.changes, hasLength(1));
    expect(journal.changes.single.category, SyncCategory.covers);
    expect(journal.changes.single.record.key, 'wy:1');
    expect(journal.changes.single.record.data!['hash'], after.data!['hash']);
    expect(state.coverStamps['wy:1']!.hash, after.data!['hash']);
  });

  test('墓碑后重设：即使内容与删除前相同也取新版本并追加日志', () async {
    await store.setTrackCover(trackId, jpeg(1));
    final before = (await adapter.collect())[SyncCategory.covers]!.single;

    now = 2000;
    await store.resetTrackCover(trackId);
    final deleted = (await adapter.collect())[SyncCategory.covers]!
        .singleWhere((record) => record.deleted);
    expect(state.coverTombstones['wy:1']!.version, deleted.version);

    journal.changes.clear();
    // 重设成与删除前完全相同的内容：不能复用旧戳（会输给墓碑）。
    await store.setTrackCover(trackId, jpeg(1));
    final restored = (await adapter.collect())[SyncCategory.covers]!.single;

    expect(restored.deleted, isFalse);
    expect(restored.version.isNewerThan(deleted.version), isTrue);
    expect(restored.version, isNot(before.version));
    expect(state.coverTombstones.containsKey('wy:1'), isFalse);
    expect(journal.changes, hasLength(1));
    expect(journal.changes.single.record.deleted, isFalse);
    expect(journal.changes.single.record.version, restored.version);
  });

  test('本地删除：发新墓碑、清登记并追加日志', () async {
    await store.setTrackCover(trackId, jpeg(1));
    final image = (await adapter.collect())[SyncCategory.covers]!.single;
    journal.changes.clear();

    now = 2000;
    await store.resetTrackCover(trackId);
    final after = (await adapter.collect())[SyncCategory.covers]!;

    final tombstone =
        after.singleWhere((record) => record.deleted && record.key == 'wy:1');
    expect(tombstone.version.isNewerThan(image.version), isTrue);
    expect(state.coverStamps.containsKey('wy:1'), isFalse);
    expect(state.coverTombstones['wy:1']!.version, tombstone.version);
    expect(journal.changes, hasLength(1));
    expect(journal.changes.single.record.deleted, isTrue);
    expect(journal.changes.single.record.deletedAt, tombstone.version.physical);
  });

  test('远端图片：较新落地、较旧跳过、同版本幂等', () async {
    await store.setTrackCover(trackId, jpeg(1));
    final local = (await adapter.collect())[SyncCategory.covers]!.single;

    final newer = SyncVersion(
      physical: local.version.physical + 1000,
      deviceId: 'devB',
    );
    final remote = imageRecord('wy:1', jpeg(2), version: newer);
    var outcome = await adapter.apply({
      SyncCategory.covers: [remote],
    });
    expect(outcome.applied, 1);
    expect(await store.readTrackCover(trackId), jpeg(2));
    expect(state.coverStamps['wy:1']!.version, newer);

    // 同版本同内容重放：幂等跳过。
    outcome = await adapter.apply({
      SyncCategory.covers: [remote],
    });
    expect(outcome.applied, 0);
    expect(outcome.skipped, 1);

    // 同版本不同内容（全量快照强制交付）：修回远端视图。
    outcome = await adapter.apply({
      SyncCategory.covers: [
        imageRecord('wy:1', jpeg(3), version: newer),
      ],
    });
    expect(outcome.applied, 1);
    expect(await store.readTrackCover(trackId), jpeg(3));

    // 更旧的图片不覆盖本地较新版本。
    outcome = await adapter.apply({
      SyncCategory.covers: [
        imageRecord(
          'wy:1',
          jpeg(4),
          version: SyncVersion(physical: newer.physical - 500),
        ),
      ],
    });
    expect(outcome.applied, 0);
    expect(await store.readTrackCover(trackId), jpeg(3));
  });

  test('远端墓碑：较旧的删除不生效，较新的删除清封面并保留墓碑', () async {
    await store.setTrackCover(trackId, jpeg(1));
    final local = (await adapter.collect())[SyncCategory.covers]!.single;

    var outcome = await adapter.apply({
      SyncCategory.covers: [
        SyncRecord.tombstone(
          key: 'wy:1',
          version: SyncVersion(physical: local.version.physical - 1),
        ),
      ],
    });
    expect(outcome.applied, 0);
    expect(await store.readTrackCover(trackId), jpeg(1));

    final newer = SyncVersion(
      physical: local.version.physical + 1000,
      deviceId: 'devB',
    );
    outcome = await adapter.apply({
      SyncCategory.covers: [
        SyncRecord.tombstone(
          key: 'wy:1',
          version: newer,
          deletedAt: newer.physical,
        ),
      ],
    });
    expect(outcome.applied, 1);
    expect(await store.readTrackCover(trackId), isNull);
    expect(state.coverStamps.containsKey('wy:1'), isFalse);
    expect(state.coverTombstones['wy:1']!.version, newer);
  });

  test('默认封面：记录键固定，远端替换与删除都落到同一 store', () async {
    await store.setDefaultCover(jpeg(4));
    final local = (await adapter.collect())[SyncCategory.covers]!.single;
    expect(local.key, SyncRecordKeys.defaultCoverKey);

    final newer = SyncVersion(
      physical: local.version.physical + 1000,
      deviceId: 'devB',
    );
    var outcome = await adapter.apply({
      SyncCategory.covers: [
        imageRecord(SyncRecordKeys.defaultCoverKey, jpeg(5), version: newer),
      ],
    });
    expect(outcome.applied, 1);
    expect(await store.readDefaultCover(), jpeg(5));

    outcome = await adapter.apply({
      SyncCategory.covers: [
        SyncRecord.tombstone(
          key: SyncRecordKeys.defaultCoverKey,
          version: SyncVersion(physical: newer.physical + 1000),
        ),
      ],
    });
    expect(outcome.applied, 1);
    expect(await store.readDefaultCover(), isNull);
    expect(state.coverTombstones[SyncRecordKeys.defaultCoverKey], isNotNull);
  });

  test('损坏 / 超限：接收跳过且不抛，本地大图仍可用但不同步', () async {
    // 远端损坏（非图片）与超限图片都被跳过。
    var outcome = await adapter.apply({
      SyncCategory.covers: [
        SyncRecord(
          key: 'wy:bad',
          version: const SyncVersion(physical: 5000, deviceId: 'devB'),
          data: {
            'image': base64Encode([1, 2, 3])
          },
        ),
        SyncRecord(
          key: 'wy:huge',
          version: const SyncVersion(physical: 5001, deviceId: 'devB'),
          data: {
            'image': base64Encode(
              Uint8List.fromList([
                0xFF,
                0xD8,
                0xFF,
                ...List<int>.filled(CustomCoverStore.maxSyncBytes, 0),
              ]),
            ),
          },
        ),
        // 记录固定声明 JPEG / .jpg：合法 PNG 也不能落地。
        SyncRecord(
          key: 'wy:png',
          version: const SyncVersion(physical: 5002, deviceId: 'devB'),
          data: {
            'image': base64Encode(
              Uint8List.fromList([
                0x89,
                0x50,
                0x4E,
                0x47,
                0x0D,
                0x0A,
                0x1A,
                0x0A,
              ]),
            ),
            'mime': 'image/jpeg',
          },
        ),
      ],
    });
    expect(outcome.applied, 0);
    expect(outcome.skipped, 3);
    expect(await store.readTrackCover(const TrackId('wy', 'bad')), isNull);
    expect(await store.readTrackCover(const TrackId('wy', 'huge')), isNull);
    expect(await store.readTrackCover(const TrackId('wy', 'png')), isNull);

    // 本地超限：本地封面照常保存 / 查询，同步记录直接跳过（不抛）。
    await store.setTrackCover(
      const TrackId('wy', 'local-huge'),
      Uint8List.fromList([
        0xFF,
        0xD8,
        0xFF,
        ...List<int>.filled(CustomCoverStore.maxSyncBytes, 0),
      ]),
    );
    final records = (await adapter.collect())[SyncCategory.covers]!;
    expect(
      records.where((record) => record.key == 'wy:local-huge'),
      isEmpty,
    );
    expect(store.trackCoverPath(const TrackId('wy', 'local-huge')), isNotNull);
    expect(journal.changes, isEmpty);
  });

  test('类别未请求：立即返回空，不读封面文件', () async {
    final counting = _CountingCoverStore(
      supportDirectory: () async => tempDir,
      clock: () => DateTime.fromMillisecondsSinceEpoch(now),
    );
    await counting.load();
    await counting.setTrackCover(trackId, jpeg(1));
    final scoped = CoverSyncAdapter(
      store: counting,
      state: state,
      journal: journal,
      enabled: () => false,
    );

    final empty = await scoped.collectForCategories({SyncCategory.settings});
    expect(empty, isEmpty);
    expect(counting.reads, 0, reason: '非封面轮不能读盘 / 算哈希 / base64');

    // 手动完整备份请求全部类别（即使开关关闭）仍能看到封面记录。
    final covers = (await scoped.collectForCategories(
        SyncCategory.values.toSet()))[SyncCategory.covers]!;
    expect(covers, hasLength(1));
    expect(counting.reads, 1);
  });

  test('默认关闭：不写封面日志；开启后变化照常追加', () async {
    expect(state.isCategoryEnabled(SyncCategory.covers), isFalse,
        reason: '状态层默认关闭');
    enabled = false;
    await store.setTrackCover(trackId, jpeg(1));

    final off = (await adapter.collect())[SyncCategory.covers]!;
    expect(off, hasLength(1), reason: '手动备份仍需看到封面记录');
    expect(journal.changes, isEmpty, reason: '关闭期间封面字节不进增量窗口');
    expect(state.coverStamps['wy:1'], isNotNull, reason: '关闭期间仍登记本地变化');

    // 开启后出现的真实变化追加日志，增量对端可收。
    enabled = true;
    now = 2000;
    await store.setTrackCover(trackId, jpeg(2));
    await adapter.collect();
    expect(journal.changes, hasLength(1));
    expect(journal.changes.single.record.deleted, isFalse);
  });

  test('开启时已有封面：首轮只登记不追加；之后新封面才追加', () async {
    enabled = false;
    // 关闭期间的普通轮次仍会调用 scoped collect（只是不请求封面）。
    await adapter.collectForCategories({SyncCategory.settings});
    await store.setTrackCover(trackId, jpeg(1));

    enabled = true;
    // 开启后先跑一轮小类别（不请求封面）：切换轮规则仍应留给第一次封面轮。
    await adapter.collectForCategories({SyncCategory.settings});
    final first = (await adapter.collect())[SyncCategory.covers]!;
    expect(first, hasLength(1), reason: '快照 / 手动备份仍能看到已有封面');
    expect(journal.changes, isEmpty, reason: '开启后的首轮由全量快照携带已有封面，不逐张塞进增量');
    expect(state.coverStamps['wy:1'], isNotNull, reason: '只登记，供后续变化检测');

    // 开启状态下首次登记的新封面仍追加日志。
    now = 2000;
    await store.setTrackCover(const TrackId('wy', '2'), jpeg(2));
    final second = (await adapter.collect())[SyncCategory.covers]!;
    expect(second, hasLength(2));
    expect(journal.changes, hasLength(1));
    expect(journal.changes.single.record.key, 'wy:2');
  });

  test('store 未加载时 ready=false，collect 为空', () async {
    final unloaded = CustomCoverStore(
      supportDirectory: () async => tempDir,
      clock: () => DateTime.fromMillisecondsSinceEpoch(now),
    );
    final unloadedAdapter = CoverSyncAdapter(
      store: unloaded,
      state: state,
      journal: journal,
      enabled: () => enabled,
    );
    expect(unloadedAdapter.ready, isFalse);
    expect(await unloadedAdapter.collect(), isEmpty);
    await unloaded.load();
    expect(unloadedAdapter.ready, isTrue);
  });
}

/// 记录读盘次数的封面存储：验证非封面轮不触碰封面文件。
class _CountingCoverStore extends CustomCoverStore {
  _CountingCoverStore({
    required super.supportDirectory,
    required super.clock,
  });

  int reads = 0;

  @override
  Future<Uint8List?> readTrackCoverByKey(String key) {
    reads++;
    return super.readTrackCoverByKey(key);
  }

  @override
  Future<Uint8List?> readDefaultCover() {
    reads++;
    return super.readDefaultCover();
  }
}

class _RecordingJournal implements SyncJournalAppender {
  final List<SyncJournalChange> changes = [];

  @override
  Future<List<int>> appendAll(Iterable<SyncJournalChange> changes) async {
    final list = changes.toList();
    this.changes.addAll(list);
    return [for (var i = 0; i < list.length; i++) i + 1];
  }
}
