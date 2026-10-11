import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/device_sync.dart';

/// 合并规则测试：逐键 LWW、平局定序、墓碑、类别过滤、墓碑裁剪。
void main() {
  SyncRecord record(
    String key, {
    required int at,
    String by = '',
    Object? value,
    bool deleted = false,
  }) =>
      SyncRecord(
        key: key,
        updatedAt: at,
        updatedBy: by,
        deleted: deleted,
        data: deleted ? null : {'v': value},
      );

  test('逐键取新：updatedAt 大者胜', () {
    final merged = mergeRecords([
      record('k', at: 100, value: 'local'),
      record('k', at: 200, value: 'remote'),
    ]);
    expect(merged['k']!.data, {'v': 'remote'});
  });

  test('时间相同时按设备 id 字典序定序（确定性）', () {
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

  test('墓碑裁剪：保留期内保留、超期丢弃（仅推送侧）', () {
    const retention = 1000;
    final envelope = SyncEnvelope(
      deviceId: 'a',
      producedAt: 0,
      records: {
        SyncCategory.playlists: [
          record('fresh', at: 9500, deleted: true),
          record('stale', at: 100, deleted: true),
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

  test('快照 JSON 往返 + 坏记录宽容解析', () {
    final envelope = SyncEnvelope(
      deviceId: 'dev',
      deviceName: '名称',
      producedAt: 123,
      records: {
        SyncCategory.sources: [
          record('lx_a', at: 5),
          SyncRecord.tombstone(key: 'lx_b', updatedAt: 6, updatedBy: 'dev'),
        ],
      },
    );
    final decoded = SyncEnvelope.fromJson(envelope.toJson())!;
    expect(decoded.deviceId, 'dev');
    expect(decoded.recordsOf(SyncCategory.sources).length, 2);

    final tolerant = SyncEnvelope.fromJson({
      'deviceId': 'dev',
      'producedAt': 1,
      'records': {
        'settings': [
          {'updatedAt': 1}, // 缺 key → 跳过
          {'key': 'ok', 'updatedAt': 2, 'data': {'v': true}},
        ],
        'unknown_category': [
          {'key': 'x', 'updatedAt': 1},
        ],
      },
    })!;
    expect(tolerant.recordsOf(SyncCategory.settings).single.key, 'ok');
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
