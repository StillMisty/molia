import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/device_sync.dart';

/// 合并规则测试：逐键 LWW（版本三元组）、平局定序、墓碑、类别过滤、
/// 墓碑裁剪（按真实删除时间）、协议版本判定。
void main() {
  SyncRecord record(
    String key, {
    required int at,
    int counter = 0,
    String by = '',
    Object? value,
    bool deleted = false,
    int? deletedAt,
  }) =>
      SyncRecord(
        key: key,
        version: SyncVersion(physical: at, counter: counter, deviceId: by),
        deleted: deleted,
        data: deleted
            ? (deletedAt == null ? null : {'deletedAt': deletedAt})
            : {'v': value},
      );

  test('逐键取新：版本物理分量大者胜', () {
    final merged = mergeRecords([
      record('k', at: 100, value: 'local'),
      record('k', at: 200, value: 'remote'),
    ]);
    expect(merged['k']!.data, {'v': 'remote'});
  });

  test('同毫秒：counter 大者胜，不因同毫秒竞争丢后写', () {
    final merged = mergeRecords([
      record('k', at: 100, counter: 0, by: 'devA', value: 'first'),
      record('k', at: 100, counter: 1, by: 'devA', value: 'second'),
    ]);
    expect(merged['k']!.data, {'v': 'second'});
    // 顺序无关（确定性）。
    final reversed = mergeRecords([
      record('k', at: 100, counter: 1, by: 'devA', value: 'second'),
      record('k', at: 100, counter: 0, by: 'devA', value: 'first'),
    ]);
    expect(reversed['k']!.data, {'v': 'second'});
  });

  test('版本相等时按设备 id 字典序定序（确定性）', () {
    final merged = mergeRecords([
      record('k', at: 100, by: 'aaa', value: 'a'),
      record('k', at: 100, by: 'bbb', value: 'b'),
    ]);
    expect(merged['k']!.data, {'v': 'b'});
    // 交换输入顺序结果不变
    final reversed = mergeRecords([
      record('k', at: 100, by: 'bbb', value: 'b'),
      record('k', at: 100, by: 'aaa', value: 'a'),
    ]);
    expect(reversed['k']!.data, {'v': 'b'});
  });

  test('墓碑参与取新：更新的删除压过旧值，反之亦然', () {
    final deleted = mergeRecords([
      record('k', at: 100, value: 'old'),
      record('k', at: 200, deleted: true),
    ]);
    expect(deleted['k']!.deleted, isTrue);

    final kept = mergeRecords([
      record('k', at: 300, value: 'new'),
      record('k', at: 200, deleted: true),
    ]);
    expect(kept['k']!.deleted, isFalse);
    expect(kept['k']!.data, {'v': 'new'});
  });

  test('快照合并按类别过滤 + 同键取新', () {
    final local = SyncEnvelope(
      deviceId: 'a',
      producedAt: 1,
      records: {
        SyncCategory.settings: [record('theme', at: 100, value: 'light')],
        SyncCategory.statistics: [record('e1', at: 1, value: 1)],
      },
    );
    final remote = SyncEnvelope(
      deviceId: 'b',
      producedAt: 2,
      records: {
        SyncCategory.settings: [record('theme', at: 200, value: 'dark')],
        SyncCategory.statistics: [record('e2', at: 2, value: 2)],
      },
    );

    final all = mergeEnvelopesByCategory([local, remote]);
    expect(all[SyncCategory.settings]!['theme']!.data, {'v': 'dark'});
    expect(all[SyncCategory.statistics]!.length, 2);

    final onlySettings = mergeEnvelopesByCategory(
      [local, remote],
      categories: {SyncCategory.settings},
    );
    expect(onlySettings.keys, [SyncCategory.settings]);
    expect(onlySettings[SyncCategory.settings]!.length, 1);
  });

  test('墓碑裁剪：保留期内保留、超期丢弃（按真实删除时间）', () {
    const retention = 1000;
    final envelope = SyncEnvelope(
      deviceId: 'a',
      producedAt: 0,
      records: {
        SyncCategory.playlists: [
          record('fresh', at: 9500, deleted: true, deletedAt: 9500),
          record('stale', at: 100, deleted: true, deletedAt: 100),
          record('alive', at: 100),
        ],
      },
    );
    final pruned = envelope.pruneTombstones(
      now: 10000,
      tombstoneRetentionMs: retention,
    );
    final keys = pruned.recordsOf(SyncCategory.playlists).map((r) => r.key);
    expect(keys, containsAll(['fresh', 'alive']));
    expect(keys, isNot(contains('stale')));
  });

  test('墓碑裁剪用真实删除时间：版本物理分量被超前戳抬高也不影响淘汰', () {
    const retention = 1000;
    final envelope = SyncEnvelope(
      deviceId: 'a',
      producedAt: 0,
      records: {
        SyncCategory.history: [
          // 版本 = 未来（吸收超前戳的结果），真实删除时间已超保留期。
          record('old', at: 999999, deleted: true, deletedAt: 100),
        ],
      },
    );
    final pruned = envelope.pruneTombstones(
      now: 10000,
      tombstoneRetentionMs: retention,
    );
    expect(pruned.recordsOf(SyncCategory.history), isEmpty);
  });

  test('快照 JSON 往返 + 坏记录宽容解析', () {
    final envelope = SyncEnvelope(
      deviceId: 'dev',
      deviceName: '名称',
      producedAt: 123,
      records: {
        SyncCategory.sources: [
          record('lx_a', at: 5),
          SyncRecord.tombstone(
            key: 'lx_b',
            version: const SyncVersion(physical: 6, deviceId: 'dev'),
            deletedAt: 6,
          ),
        ],
      },
    );
    expect(envelope.toJson()['v'], SyncEnvelope.protocolVersion);
    final decoded = SyncEnvelope.fromJson(envelope.toJson())!;
    expect(decoded.deviceId, 'dev');
    expect(decoded.recordsOf(SyncCategory.sources).length, 2);
    final tombstone = decoded
        .recordsOf(SyncCategory.sources)
        .firstWhere((record) => record.key == 'lx_b');
    expect(tombstone.deletedAt, 6);
    expect(tombstone.version.deviceId, 'dev');

    final tolerant = SyncEnvelope.fromJson({
      'deviceId': 'dev',
      'producedAt': 1,
      'records': {
        'settings': [
          {'updatedAt': 1}, // 缺 key → 跳过
          {
            'key': 'ok',
            'version': {'physical': 2, 'counter': 3, 'deviceId': 'x'},
            'data': {'v': true},
          },
        ],
        'unknown_category': [
          {'key': 'x', 'version': {'physical': 1}},
        ],
      },
    })!;
    final parsed = tolerant.recordsOf(SyncCategory.settings).single;
    expect(parsed.key, 'ok');
    expect(parsed.version, const SyncVersion(physical: 2, counter: 3, deviceId: 'x'));
  });

  test('SyncVersion 排序：physical → counter → deviceId', () {
    const base = SyncVersion(physical: 100, counter: 1, deviceId: 'a');
    expect(base.isNewerThan(const SyncVersion(physical: 99, counter: 9, deviceId: 'z')), isTrue);
    expect(base.isNewerThan(const SyncVersion(physical: 100, counter: 0, deviceId: 'z')), isTrue);
    expect(base.isNewerThan(const SyncVersion(physical: 100, counter: 1, deviceId: 'b')), isFalse);
    expect(base.isNewerThan(base), isFalse);
  });

  test('列表曲目复合键编解码', () {
    final key = SyncRecordKeys.playlistTrack('pl-1', 'wy', 'song-9');
    final parsed = SyncRecordKeys.parsePlaylistTrack(key)!;
    expect(parsed.playlistSyncId, 'pl-1');
    expect(parsed.sourceKey, 'wy');
    expect(parsed.songId, 'song-9');
    expect(SyncRecordKeys.parsePlaylistTrack('plain'), isNull);
  });
}
