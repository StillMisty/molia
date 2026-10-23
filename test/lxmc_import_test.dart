import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/lxmc_decoder.dart';
import 'package:molia/data/lxmc_decoder_io.dart'
    show lxmcDecodeIsolateThreshold, shouldDecodeLxmcBytesOffThread;

/// `.lxmc` 解码测试：真实 LX Music 导出夹具（1018 首）+ 合成异常夹具。
void main() {
  Uint8List lxmc(Map<String, dynamic> payload) => Uint8List.fromList(
        gzip.encode(utf8.encode(jsonEncode(payload))),
      );

  Map<String, dynamic> wrap(List<dynamic> list, {String name = 'list__name_x'}) => {
        'type': 'playListPart_v2',
        'data': {'id': 'x', 'name': name, 'list': list},
      };

  /// 超过 isolate 阈值的合成列表（压缩后 > 64KB）。
  List<Map<String, dynamic>> largeTracks([int count = 4000]) => [
        for (var i = 0; i < count; i++)
          {
            'id': 'wy_$i',
            'name': 'Song $i',
            'singer': 'Artist $i',
            'source': 'wy',
            'interval': '03:00',
            'meta': {
              'songId': i,
              'albumName': 'Album $i',
              'picUrl': 'https://img.example/$i.jpg',
              'qualitys': [
                {'type': '128k', 'size': '1 MiB'},
              ],
              '_qualitys': {
                '320k': {'size': '2 MiB'},
              },
            },
          },
      ];

  /// 可发送模型 → 纯数据描述，便于比较同步 / isolate 两条路径的结果。
  Map<String, Object?> describe(LxmcDecodedPlaylist playlist) => {
        'name': playlist.name,
        'skipped': playlist.skipped,
        'tracks': [
          for (final track in playlist.tracks)
            {
              'sourceKey': track.sourceKey,
              'songId': track.songId,
              'title': track.title,
              'artist': track.artist,
              'album': track.album,
              'coverUrl': track.coverUrl,
              'durationMs': track.durationMs,
              'raw': track.raw,
            },
        ],
      };

  group('真实夹具（test/fixtures/lx_list_love.lxmc）', () {
    late LxmcDecodedPlaylist decoded;

    setUpAll(() {
      final bytes = File('test/fixtures/lx_list_love.lxmc').readAsBytesSync();
      decoded = decodeLxmcBytes(Uint8List.fromList(bytes));
    });

    test('解析 1018 首，名称清洗 list__name_love → love', () {
      expect(decoded.tracks, hasLength(1018));
      expect(decoded.name, 'love');
      expect(decoded.skipped, 0);
    });

    test('字段映射：wy 平台 id / 标题 / 歌手 / 专辑 / 封面 / 时长', () {
      final first = decoded.tracks.first;
      expect(first.sourceKey, 'wy');
      expect(first.songId, '1888818113');
      expect(first.title, 'If You Lie Down With Me');
      expect(first.artist, 'Lana Del Rey');
      expect(first.album, 'Blue Banisters');
      expect(first.coverUrl, contains('p2.music.126.net'));
      expect(first.durationMs, (4 * 60 + 25) * 1000);

      // 全部条目都必须有 sourceKey / songId / title
      for (final track in decoded.tracks) {
        expect(track.sourceKey, isNotEmpty);
        expect(track.songId, isNotEmpty);
        expect(track.title, isNotEmpty);
      }
    });

    test('raw 保真：等于 meta 原样（含 qualitys/_qualitys）', () {
      final first = decoded.tracks.first;
      expect(first.raw['songId'], 1888818113);
      expect(first.raw['albumId'], 135099927);
      expect(first.raw['qualitys'], isA<List>());
      expect(first.raw['_qualitys'], isA<Map>());
      expect((first.raw['qualitys'] as List), hasLength(3));
      expect(first.raw['_qualitys']['flac']['size'], '23.83 MiB');
    });
  });

  group('平台 id 映射', () {
    test('各平台字段优先级 + item.id 前缀兜底', () {
      final decoded = decodeLxmcBytes(lxmc(wrap([
        {
          'id': 'tx_0039MnYb0qxYhV',
          'name': 'TX Song',
          'singer': 'A',
          'source': 'tx',
          'interval': '03:05',
          'meta': {'songmid': '0039MnYb0qxYhV', 'songId': 999, 'albumName': 'TA'},
        },
        {
          'id': 'kg_HASH1',
          'name': 'KG Song',
          'singer': 'B',
          'source': 'kg',
          'meta': {'hash': 'HASH1', 'songmid': '123', 'albumName': 'KA'},
        },
        {
          'id': 'kw_456',
          'name': 'KW Song',
          'singer': 'C',
          'source': 'kw',
          'meta': {'musicId': '456', 'albumName': 'WA'},
        },
        {
          'id': 'mg_789',
          'name': 'MG Song',
          'singer': 'D',
          'source': 'mg',
          'meta': {'copyrightId': '789', 'albumName': 'MA'},
        },
        {
          // meta 缺平台字段：解析 item.id 前缀
          'id': 'wy_112233',
          'name': 'WY Fallback',
          'singer': 'E',
          'source': 'wy',
          'meta': {'albumName': 'Fallback'},
        },
      ])));

      expect(decoded.skipped, 0);
      expect(decoded.tracks.map((t) => t.songId).toList(),
          ['0039MnYb0qxYhV', 'HASH1', '456', '789', '112233']);
      expect(decoded.tracks[0].album, 'TA');
      expect(decoded.tracks[2].songId, '456');
    });

    test('未知平台走默认字段顺序', () {
      final decoded = decodeLxmcBytes(lxmc(wrap([
        {
          'id': 'custom_1',
          'name': 'Custom',
          'source': 'custom',
          'meta': {'songId': 's1', 'hash': 'h1'},
        },
      ])));
      expect(decoded.tracks.single.songId, 's1');
    });

    test('缺 source / 标题 / 平台 id 的条目被跳过', () {
      final decoded = decodeLxmcBytes(lxmc(wrap([
        {'id': 'wy_1', 'name': 'ok', 'source': 'wy', 'meta': {'songId': 1}},
        {'id': 'wy_2', 'name': 'no source', 'meta': {'songId': 2}},
        {'id': 'wy_3', 'name': '', 'source': 'wy', 'meta': {'songId': 3}},
        {'name': 'no id', 'source': 'wy', 'meta': {}},
        'not a map',
      ])));
      expect(decoded.tracks, hasLength(1));
      expect(decoded.skipped, 4);
    });
  });

  group('时长与名称', () {
    test('interval 支持 mm:ss / h:mm:ss / 秒数', () {
      final decoded = decodeLxmcBytes(lxmc(wrap([
        {'id': 'wy_1', 'name': 'a', 'source': 'wy', 'interval': '04:25', 'meta': {'songId': 1}},
        {'id': 'wy_2', 'name': 'b', 'source': 'wy', 'interval': '1:02:03', 'meta': {'songId': 2}},
        {'id': 'wy_3', 'name': 'c', 'source': 'wy', 'interval': 125, 'meta': {'songId': 3}},
        {'id': 'wy_4', 'name': 'd', 'source': 'wy', 'interval': 'oops', 'meta': {'songId': 4}},
      ])));
      expect(decoded.tracks[0].durationMs, 265000);
      expect(decoded.tracks[1].durationMs, 3723000);
      expect(decoded.tracks[2].durationMs, 125000);
      expect(decoded.tracks[3].durationMs, isNull);
    });

    test('名称为空时退回文件名（去 lx_list_part_ 前缀与扩展名）', () {
      final decoded = decodeLxmcBytes(
        lxmc(wrap(const [], name: '')),
        fileName: 'lx_list_part_list__name_love.lxmc',
      );
      expect(decoded.name, 'list__name_love');
    });
  });

  group('异步解码（>64KB 走 isolate，小文件保持同步）', () {
    test('阈值判定：低于 64KB 同步，达到阈值走 isolate', () {
      expect(
        shouldDecodeLxmcBytesOffThread(
          Uint8List(lxmcDecodeIsolateThreshold - 1),
        ),
        isFalse,
      );
      expect(
        shouldDecodeLxmcBytesOffThread(Uint8List(lxmcDecodeIsolateThreshold)),
        isTrue,
      );
    });

    test('大文件异步解码与同步结果一致（含 fileName 与 raw 保真）', () async {
      const fileName = 'lx_list_part_list__name_big.lxmc';
      final bytes = lxmc(wrap(largeTracks(), name: ''));
      expect(bytes.length, greaterThan(lxmcDecodeIsolateThreshold));

      final sync = decodeLxmcBytes(bytes, fileName: fileName);
      final offThread = await decodeLxmcBytesOffThread(
        bytes,
        fileName: fileName,
      );
      expect(offThread.name, 'list__name_big');
      expect(describe(offThread), describe(sync));
    });

    test('小文件仍走同步快路径：结果与同步入口一致', () async {
      final bytes = lxmc(wrap([
        {
          'id': 'wy_1',
          'name': 'Small',
          'singer': 'A',
          'source': 'wy',
          'meta': {'songId': 1},
        },
      ]));
      expect(shouldDecodeLxmcBytesOffThread(bytes), isFalse);

      final sync = decodeLxmcBytes(bytes);
      final offThread = await decodeLxmcBytesOffThread(bytes);
      expect(describe(offThread), describe(sync));
    });

    test('大文件非 gzip 字节 → not_gzip', () async {
      final bytes = Uint8List(lxmcDecodeIsolateThreshold);
      await expectLater(
        decodeLxmcBytesOffThread(bytes),
        throwsA(isA<LxmcDecodeException>()
            .having((e) => e.reason, 'reason', 'not_gzip')),
      );
    });

    test('大文件 gzip 内非法 JSON → invalid_json', () async {
      final random = Random(7);
      final noise = List<int>.generate(
        lxmcDecodeIsolateThreshold + 1024,
        (_) => random.nextInt(256),
      );
      final bytes = Uint8List.fromList(gzip.encode(noise));
      expect(bytes.length, greaterThan(lxmcDecodeIsolateThreshold));

      await expectLater(
        decodeLxmcBytesOffThread(bytes),
        throwsA(isA<LxmcDecodeException>()
            .having((e) => e.reason, 'reason', 'invalid_json')),
      );
    });

    test('大文件根节点错误 → not_play_list', () async {
      final bytes = lxmc({
        'type': 'playList_v2',
        'data': {'name': 'x', 'list': largeTracks()},
      });
      expect(bytes.length, greaterThan(lxmcDecodeIsolateThreshold));

      await expectLater(
        decodeLxmcBytesOffThread(bytes),
        throwsA(isA<LxmcDecodeException>()
            .having((e) => e.reason, 'reason', 'not_play_list')),
      );
    });
  });

  group('错误路径', () {
    test('非 gzip 字节 → not_gzip', () {
      expect(
        () => decodeLxmcBytes(Uint8List.fromList(utf8.encode('{"type":"x"}'))),
        throwsA(isA<LxmcDecodeException>()
            .having((e) => e.reason, 'reason', 'not_gzip')),
      );
    });

    test('gzip 内非法 JSON → invalid_json', () {
      final bytes =
          Uint8List.fromList(gzip.encode(utf8.encode('not json at all')));
      expect(
        () => decodeLxmcBytes(bytes),
        throwsA(isA<LxmcDecodeException>()
            .having((e) => e.reason, 'reason', 'invalid_json')),
      );
    });

    test('type 非 playListPart_v2 → not_play_list', () {
      final bytes = lxmc({
        'type': 'playList_v2',
        'data': {'name': 'x', 'list': const []},
      });
      expect(
        () => decodeLxmcBytes(bytes),
        throwsA(isA<LxmcDecodeException>()
            .having((e) => e.reason, 'reason', 'not_play_list')),
      );
    });

    test('缺少 data.list → not_play_list', () {
      final bytes = lxmc({
        'type': 'playListPart_v2',
        'data': {'name': 'x'},
      });
      expect(
        () => decodeLxmcBytes(bytes),
        throwsA(isA<LxmcDecodeException>()
            .having((e) => e.reason, 'reason', 'not_play_list')),
      );
    });
  });
}
