import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_crypto.dart';
import 'package:molia/data/sync/sync_payload.dart';
import 'package:molia/data/sync/sync_payload_binary.dart';
import 'package:molia/domain/models/device_sync.dart';

/// 列式二进制载荷测试：往返等价（与 JSON 编码对照）、边界形态、损坏拒绝。
void main() {
  SyncEnvelope encodeBinary(SyncEnvelope envelope) => SyncPayload.decode(
        SyncPayloadBinary.encode(envelope),
        codec: SyncPayloadCodec.binary,
      );

  /// 规范化 JSON：映射按键排序，屏蔽键序差异（内容等价即可）。
  String canonical(Object? value) => jsonEncode(_sorted(value));

  void expectEquivalent(SyncEnvelope a, SyncEnvelope b) {
    expect(canonical(b.toJson()), canonical(a.toJson()));
  }

  test('全量快照往返：多类别 / 墓碑 / 中文字段', () {
    final envelope = SyncEnvelope(
      deviceId: 'dev-a',
      deviceName: '客厅的电脑',
      producedAt: 1728640000000,
      snapshotId: 'a' * 64,
      journalHead: 42,
      baseSeq: 7,
      acks: {'dev-b': 11},
      categories: ['settings', 'playlistTracks', 'covers'],
      records: {
        SyncCategory.covers: [
          const SyncRecord(
            key: '__default_cover__',
            version: SyncVersion(physical: 100, counter: 4, deviceId: 'dev-a'),
            data: {
              'image': '/9j/4AAQ',
              'mime': 'image/jpeg',
              'hash': 'cover-hash',
              'updatedAt': 100,
            },
          ),
        ],
        SyncCategory.settings: [
          const SyncRecord(
            key: 'theme_mode',
            version: SyncVersion(physical: 100, counter: 3, deviceId: 'dev-a'),
            data: {'v': 'dark'},
          ),
        ],
        SyncCategory.playlistTracks: [
          SyncRecord(
            key: '__favorites__|kw|song-1',
            version: const SyncVersion(physical: 1728640000001, deviceId: 'dev-a'),
            data: {
              'playlistSyncId': '__favorites__',
              'sourceKey': 'kw',
              'songId': 'song-1',
              'title': '夜曲 · 测试',
              'artist': '歌手',
              'album': null,
              'coverUrl': 'https://img.example.com/cover/abcdef123456?s=300',
              'durationMs': 254000,
              'raw': '{"songmid":"0123456789abcdef","quality":320}',
              'addedAt': 1728640000002,
              'sortOrder': 0,
              'explicit': true,
              'nested': {'a': [1, 2, 3], 'b': 'x'},
              'ratio': 0.5,
            },
          ),
          SyncRecord.tombstone(
            key: '__favorites__|kw|song-2',
            version: const SyncVersion(physical: 1728640000003, deviceId: 'dev-b'),
            deletedAt: 1728640000003,
          ),
        ],
      },
    );

    expectEquivalent(envelope, encodeBinary(envelope));
  });

  test('增量窗口往返：journal 条目保序保 seq', () {
    final envelope = SyncEnvelope(
      deviceId: 'dev-a',
      producedAt: 1728640000000,
      snapshotId: 'b' * 64,
      journalHead: 9,
      baseSeq: 4,
      windowStart: 5,
      windowEnd: 9,
      categories: ['history'],
      journal: [
        for (var seq = 5; seq <= 9; seq++)
          SyncJournalEntry(
            seq: seq,
            category: SyncCategory.history,
            record: SyncRecord(
              key: 'kw|song-$seq',
              version: SyncVersion(physical: 1728640000000 + seq, deviceId: 'dev-a'),
              data: {'title': '曲目 $seq', 'playedAt': 1728640000000 + seq},
            ),
          ),
      ],
    );

    final decoded = encodeBinary(envelope);
    expectEquivalent(envelope, decoded);
    expect(decoded.isDelta, isTrue);
    expect(decoded.journal!.map((entry) => entry.seq), [5, 6, 7, 8, 9]);
  });

  test('二进制与 JSON 两种编码往返等价（对照）', () {
    final envelope = SyncEnvelope(
      deviceId: 'dev-a',
      deviceName: '测试',
      producedAt: 1728640000000,
      records: {
        SyncCategory.playlists: [
          for (var i = 0; i < 8; i++)
            SyncRecord(
              key: 'list-$i',
              version: SyncVersion(physical: 1000 + i, deviceId: 'dev-a'),
              data: {
                'name': '列表 $i',
                'createdAt': 1728640000000 + i,
                'pinned': i.isEven,
                'missing': null,
              },
            ),
        ],
      },
    );
    final viaJson = SyncPayload.decode(
      SyncPayload.encode(envelope, codec: SyncPayloadCodec.json),
      codec: SyncPayloadCodec.json,
    );
    final viaBinary = encodeBinary(envelope);
    expectEquivalent(envelope, viaBinary);
    expectEquivalent(viaJson, viaBinary);
  });

  test('重复内容走字典列：统计型载荷显著小于 JSON + gzip', () {
    // 同一首歌重复播放：payload 逐字节相同（raw 原样回传），只有事件字段不同。
    final records = [
      for (var i = 0; i < 200; i++)
        SyncRecord(
          key: 'sync-key-$i',
          version: SyncVersion(physical: 1728640000000 + i, deviceId: 'dev-a'),
          data: {
            'sourceKey': 'kw',
            'songId': 'song-1',
            'title': '夜曲',
            'artist': '歌手',
            'album': '专辑',
            'coverUrl': 'https://img.example.com/cover/abcdef123456?s=300',
            'durationMs': 254000,
            'raw': '{"songmid":"0123456789abcdef","hash":"${'f' * 32}","quality":320}',
            'startedAt': 1728640000000 + i * 1000,
            'listenedMs': 240000,
            'endReason': 'completed',
          },
        ),
    ];
    final envelope = SyncEnvelope(
      deviceId: 'dev-a',
      producedAt: 1728640000000,
      records: {SyncCategory.statistics: records},
    );
    final binary = SyncPayloadBinary.encode(envelope);
    final jsonBytes = SyncPayload.encode(envelope, codec: SyncPayloadCodec.json);
    expect(binary.length, lessThan(jsonBytes.length ~/ 2));
    expectEquivalent(envelope, encodeBinary(envelope));
  });

  test('帧尺寸基线：统计型 1k 事件整帧 < gzip(JSON) 的三分之一', () {
    // 形状对齐真实统计记录（同一首歌重复携带完整 payload + 事件字段）。
    // 钉住「列式 + 字典」的实际收益，防止将来往 data 里塞大字段悄悄回归。
    final envelope = SyncEnvelope(
      deviceId: 'dev-a',
      producedAt: 1728640000000,
      records: {
        SyncCategory.statistics: [
          for (var i = 0; i < 1000; i++)
            SyncRecord(
              key: i.toRadixString(16).padLeft(32, '0'),
              version: SyncVersion(physical: 1728640000000 + i, deviceId: 'dev-a'),
              data: {
                'sourceKey': 'kw',
                'songId': 'song-1',
                'title': '夜曲',
                'artist': '歌手',
                'album': '专辑',
                'coverUrl': 'https://img.example.com/cover/abcdef123456?s=300',
                'durationMs': 254000,
                'raw': '{"songmid":"0123456789abcdef","hash":"${'f' * 32}",'
                    '"quality":320,"name":"夜曲"}',
                'startedAt': 1728640000000 + i * 1000,
                'listenedMs': 240000,
                'endReason': 'completed',
              },
            ),
        ],
      },
    );
    final frame = SyncCodec(iterations: 2000)
        .encrypt(envelope, 'ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789');
    final compressedJson = gzip.encode(
      SyncPayload.encode(envelope, codec: SyncPayloadCodec.json),
    );
    expect(frame.length, lessThan(compressedJson.length ~/ 3));
  });

  test('空载荷 / 无 data / 空 map / 越界拒绝', () {    final empty = SyncEnvelope(deviceId: 'dev-a', producedAt: 1);
    expectEquivalent(empty, encodeBinary(empty));

    final edge = SyncEnvelope(
      deviceId: 'dev-a',
      producedAt: 1,
      records: {
        SyncCategory.settings: [
          const SyncRecord(
            key: 'k1',
            version: SyncVersion(physical: 1, deviceId: 'dev-a'),
            data: <String, Object?>{},
          ),
          const SyncRecord(
            key: 'k2',
            version: SyncVersion(physical: 2, deviceId: 'dev-a'),
            data: {'v': null},
          ),
        ],
      },
    );
    expectEquivalent(edge, encodeBinary(edge));

    final bytes = SyncPayloadBinary.encode(edge);
    expect(
      () => SyncPayloadBinary.decode(Uint8List.sublistView(bytes, 0, bytes.length - 1)),
      throwsA(isA<SyncPayloadFormatException>()),
    );
    expect(
      () => SyncPayloadBinary.decode(Uint8List.fromList([99, ...bytes])),
      throwsA(isA<SyncPayloadFormatException>()),
    );
  });
}

/// 递归按键排序（映射）；列表保持顺序。
Object? _sorted(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return {for (final key in keys) key: _sorted(value[key])};
  }
  if (value is List) return [for (final item in value) _sorted(item)];
  return value;
}
