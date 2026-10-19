import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/adapters/statistics_sync_adapter.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/ports/statistics_sync_store.dart';

/// 听歌统计适配器测试：只验证「类型化记录 ↔ SyncRecord」的薄映射与
/// 指纹缓存；导出 / 合并语义由 test/statistics_sync_store_test.dart 覆盖。
void main() {
  late _FakeStatisticsSyncStore store;
  late StatisticsSyncAdapter adapter;

  setUp(() {
    store = _FakeStatisticsSyncStore();
    adapter = StatisticsSyncAdapter(store: store);
  });

  test('collect：类型化事件 → 同步记录（键 / 版本 / 线上载荷）', () async {
    store.events = [
      _event(syncKey: 'k1', songId: 's1', raw: '{"id":1}'),
      _event(syncKey: 'k2', songId: 's2'),
    ];

    final collected = await adapter.collect();
    final records = collected[SyncCategory.statistics]!;
    expect(records, hasLength(2));
    expect(records.first.key, 'k1');
    expect(records.first.version,
        const SyncVersion(physical: 900, deviceId: 'devA'));
    expect(records.first.data!['songId'], 's1');
    expect(records.first.data!['raw'], '{"id":1}');
    expect(records.first.data!.containsKey('id'), isFalse,
        reason: '本机行 id 不进线上记录');
    expect(records.first.data!.containsKey('trackId'), isFalse);
  });

  test('collect：指纹未变复用缓存，fresh 强制重读', () async {
    store.events = [_event(syncKey: 'k1')];
    await adapter.collect();
    expect(store.exportCalls, 1);

    await adapter.collect();
    expect(store.exportCalls, 1, reason: '指纹未变不读行');

    await adapter.collect(fresh: true);
    expect(store.exportCalls, 2);

    store.fingerprint = 'r1';
    await adapter.collect();
    expect(store.exportCalls, 3, reason: '指纹变化重新导出');
  });

  test('collect → apply 往返：类型化事件字段不丢失', () async {
    store.events = [_event(syncKey: 'k1', songId: 's1', raw: '{"a":1}')];
    final collected = await adapter.collect();

    final target = _FakeStatisticsSyncStore();
    final targetAdapter = StatisticsSyncAdapter(store: target);
    final outcome = await targetAdapter.apply(collected);

    expect(outcome.applied, target.applyResult.applied);
    final event = target.applied.single;
    expect(event.syncKey, 'k1');
    expect(event.version, const SyncVersion(physical: 900, deviceId: 'devA'));
    expect(event.sourceKey, 'wy');
    expect(event.songId, 's1');
    expect(event.raw, '{"a":1}');
    expect(event.endedAt, 61000);
    expect(event.endReason, 'completed');
  });

  test('apply：信封版本覆盖 data 版本，坏记录计入 skipped', () async {
    final records = <SyncRecord>[
      SyncRecord(
        key: 'remote-1',
        version:
            const SyncVersion(physical: 9000, counter: 2, deviceId: 'devB'),
        data: const {
          // data 里的版本列只用于自包含备份，不是胜负判据。
          'versionPhysical': 1,
          'originDeviceId': 'stale',
          'sourceKey': 'wy',
          'songId': 's1',
          'startedAt': 100,
          'endedAt': 200,
          'listenedMs': 50,
        },
      ),
      SyncRecord(
        key: 'bad-no-end',
        version: const SyncVersion(physical: 9000),
        data: const {'sourceKey': 'wy', 'songId': 's2'},
      ),
      SyncRecord(
        key: 'deleted',
        version: const SyncVersion(physical: 9000),
        deleted: true,
      ),
      SyncRecord(
        key: 'null-data',
        version: const SyncVersion(physical: 9000),
      ),
    ];

    store.applyResult = (applied: 1, skipped: 0);
    final outcome = await adapter.apply({SyncCategory.statistics: records});
    expect(store.applied, hasLength(1));
    final event = store.applied.single;
    expect(event.syncKey, 'remote-1');
    expect(event.version,
        const SyncVersion(physical: 9000, counter: 2, deviceId: 'devB'));
    expect(event.sourceKey, 'wy');
    expect(event.endedAt, 200);
    expect(outcome.applied, 1);
    expect(outcome.skipped, 3, reason: '缺结束时间 / 墓碑 / 空载荷都跳过');
  });

  test('apply：落地后让 collect 缓存失效', () async {
    store.events = [_event(syncKey: 'k1')];
    await adapter.collect();
    expect(store.exportCalls, 1);

    store.applyResult = (applied: 1, skipped: 0);
    await adapter.apply({
      SyncCategory.statistics: [
        SyncRecord(
          key: 'remote-1',
          version: const SyncVersion(physical: 1),
          data: const {
            'sourceKey': 'wy',
            'songId': 's1',
            'startedAt': 100,
            'endedAt': 200,
          },
        ),
      ],
    });
    await adapter.collect();
    expect(store.exportCalls, 2, reason: '远端落地后下一轮必须重新导出');
  });

  test('未启用类别 / 无统计数据时不变更 store', () async {
    final outcome = await adapter.apply(const {});
    expect(outcome.applied, 0);
    expect(outcome.skipped, 0);
    expect(store.applyCalls, 1);
  });
}

StatisticsSyncEvent _event({
  required String syncKey,
  String songId = 's1',
  String raw = '',
}) =>
    StatisticsSyncEvent(
      syncKey: syncKey,
      version: const SyncVersion(physical: 900, deviceId: 'devA'),
      sourceKey: 'wy',
      songId: songId,
      title: 'Song $songId',
      raw: raw,
      startedAt: 1000,
      endedAt: 61000,
      listenedMs: 60000,
      maxPositionMs: 60000,
      endReason: 'completed',
    );

class _FakeStatisticsSyncStore implements StatisticsSyncStore {
  List<StatisticsSyncEvent> events = const [];
  String fingerprint = 'r0';
  int exportCalls = 0;
  int applyCalls = 0;
  List<StatisticsSyncEvent> applied = const [];
  ({int applied, int skipped}) applyResult = (applied: 0, skipped: 0);

  @override
  Future<String> syncFingerprint() async => fingerprint;

  @override
  Future<List<StatisticsSyncEvent>> syncExportEvents() async {
    exportCalls++;
    return events;
  }

  @override
  Future<({int applied, int skipped})> syncApplyEvents(
    List<StatisticsSyncEvent> incoming,
  ) async {
    applyCalls++;
    applied = incoming;
    return applyResult;
  }
}
