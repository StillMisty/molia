import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/sources/builtin/builtin_pic_dispatch.dart';
import 'package:molia/sources/builtin/builtin_search.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';
import 'package:molia/sources/source_track.dart';

import 'support/mock_dio.dart';

/// 内置平台原生取图派发（BuiltinPicDispatch）契约：五平台分派、空 raw
/// 降级、缓存。只经 [BuiltinPicDispatch.fetch] 接口验证。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BuiltinTransport originalTransport;
  setUpAll(() => originalTransport = BuiltinSearch.transport);
  tearDown(() => BuiltinSearch.transport = originalTransport);

  SourceTrack track(String sourceKey, Map<String, dynamic> raw) => SourceTrack(
        sourceKey: sourceKey,
        origin: 'builtin',
        title: '测试',
        artist: '歌手',
        album: '',
        raw: raw,
      );

  /// 网易云歌曲详情夹具（真实响应）：首曲封面在 `al.picUrl`。
  String wyDetailFixture() =>
      File('test/fixtures/lyric_search/wy_song_detail.json').readAsStringSync();

  test('五平台分派：请求落到各自平台端点，命中取图结果', () async {
    final requests = <Uri>[];
    BuiltinSearch.transport = BuiltinTransport(
      dio: mockDio((request) async {
        requests.add(request.uri);
        switch (request.uri.host) {
          case 'artistpicserver.kuwo.cn':
            return textResponse('https://img.example/kw-228908.jpg',
                statusCode: 200);
          case 'media.store.kugou.com':
            return textResponse(
              jsonEncode({
                'error_code': 0,
                'data': [
                  {
                    'info': {
                      'image': 'https://img.example/kg-{size}.jpg',
                      'imgsize': ['500'],
                    },
                  },
                ],
              }),
              statusCode: 200,
            );
          case 'c.musicapp.migu.cn':
            return textResponse(
              jsonEncode({
                'resource': [
                  {
                    'albumImgs': [
                      {'img': '/img/mg-cover.jpg'},
                    ],
                  },
                ],
              }),
              statusCode: 200,
            );
          case 'music.163.com':
            return textResponse(wyDetailFixture(), statusCode: 200);
          default:
            return textResponse('意外请求：${request.uri}', statusCode: 500);
        }
      }),
    );

    final dispatch = BuiltinPicDispatch();
    expect(
      await dispatch.fetch(track('kw', {'songmid': '228908'})),
      'https://img.example/kw-228908.jpg',
    );
    expect(
      await dispatch.fetch(track('kg', {'songmid': 'hash', 'hash': 'HASH'})),
      'https://img.example/kg-500.jpg',
      reason: 'kg 的 {size} 占位需按 imgsize 替换',
    );
    expect(
      await dispatch.fetch(
        track('tx', {'albumMid': 'ALB01', 'songmid': 'x'}),
      ),
      'https://y.gtimg.cn/music/photo_new/T002R500x500M000ALB01.jpg',
      reason: 'tx 按专辑 mid 拼 URL，不发请求',
    );
    expect(
      await dispatch.fetch(track('mg', {'img': 'https://img.example/mg.jpg'})),
      'https://img.example/mg.jpg',
    );
    expect(
      await dispatch.fetch(track('mg', {'songmid': '1'})),
      'http://d.musicapp.migu.cn/img/mg-cover.jpg',
      reason: 'mg 无 img 时走资源信息封面',
    );
    expect(
      await dispatch.fetch(track('wy', {'songmid': 1399112638})),
      'https://p2.music.126.net/pE_xbRjFKTza8i7CKfmDuQ==/109951164447654929.jpg',
      reason: 'wy 走歌曲详情 al.picUrl',
    );
    expect(
      await dispatch.fetch(track('bili', {
        'bvid': 'BV1xx411c7mD',
        'pic': '//i1.hdslb.com/bfs/archive/cover.jpg',
      })),
      'https://i1.hdslb.com/bfs/archive/cover.jpg',
      reason: 'bili 直接用搜索响应封面，只补协议头',
    );

    expect(
      requests.map((uri) => uri.host).toSet(),
      containsAll([
        'artistpicserver.kuwo.cn',
        'media.store.kugou.com',
        'c.musicapp.migu.cn',
        'music.163.com',
      ]),
    );
    expect(
      requests.any((uri) => uri.host == 'y.gtimg.cn'),
      isFalse,
      reason: 'tx 封面无需网络请求',
    );
  });

  test('空 raw / 非内置平台：降级返回 null 且不发请求', () async {
    final requests = <RequestOptions>[];
    BuiltinSearch.transport = BuiltinTransport(
      dio: mockDio((request) async {
        requests.add(request);
        return textResponse('{}', statusCode: 200);
      }),
    );

    final dispatch = BuiltinPicDispatch();
    expect(await dispatch.fetch(track('wy', const {})), isNull);
    expect(await dispatch.fetch(track('tx', const {})), isNull);
    expect(await dispatch.fetch(track('kw', const {})), isNull);
    expect(await dispatch.fetch(track('mg', const {})), isNull);
    expect(await dispatch.fetch(track('bili', const {})), isNull);
    expect(
      await dispatch.fetch(track('custom-source', {'songmid': '1'})),
      isNull,
    );
    expect(requests, isEmpty);
  });

  test('响应自带封面：直接复用，不再请求取图接口', () async {
    final requests = <RequestOptions>[];
    BuiltinSearch.transport = BuiltinTransport(
      dio: mockDio((request) async {
        requests.add(request);
        return textResponse('unexpected', statusCode: 500);
      }),
    );

    final dispatch = BuiltinPicDispatch();
    expect(
      await dispatch.fetch(
        track('kg', {
          'songmid': '1',
          'img': 'http://imge.kugou.com/stdmusic/{size}/kg.jpg',
        }),
      ),
      'http://imge.kugou.com/stdmusic/480/kg.jpg',
    );
    expect(
      await dispatch.fetch(
        track('kw', {
          'songmid': '2',
          'web_albumpic_short': '120/s3s94/93/211513640.jpg',
        }),
      ),
      'https://img1.kuwo.cn/star/albumcover/500/s3s94/93/211513640.jpg',
    );
    expect(requests, isEmpty);
  });

  test('缓存：失败不进缓存、成功命中缓存', () async {
    // 取 wy 链路：平台拒绝时 `getList` 抛错（异常路径不缓存）；
    // kw/mg/kg 内部把失败吞成 null，那是「成功返回无结果」，与本用例无关。
    final song = track('wy', {'songmid': 1399112638});
    var calls = 0;
    var healthy = false;
    BuiltinSearch.transport = BuiltinTransport(
      dio: mockDio((request) async {
        calls++;
        if (!healthy) return textResponse('{}', statusCode: 200);
        return textResponse(wyDetailFixture(), statusCode: 200);
      }),
    );

    final dispatch = BuiltinPicDispatch();
    expect(await dispatch.fetch(song), isNull);
    expect(calls, 1);

    healthy = true;
    const cover =
        'https://p2.music.126.net/pE_xbRjFKTza8i7CKfmDuQ==/109951164447654929.jpg';
    expect(await dispatch.fetch(song), cover);
    expect(calls, 2, reason: '失败不进缓存：下一次调用重新请求');

    expect(await dispatch.fetch(song), cover);
    expect(calls, 2, reason: '成功后命中缓存：同曲目不再请求');
  });
}
