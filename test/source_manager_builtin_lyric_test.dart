import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:molia/sources/builtin/builtin_search.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';
import 'package:molia/sources/builtin/zlib_io.dart' as zlib_impl;
import 'package:molia/sources/source_manager.dart';
import 'package:molia/sources/source_track.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SourceManager 内置平台原生取词/取图路由（脚本不可用时的 Dart 实现）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  late BuiltinTransport originalTransport;
  setUpAll(() {
    originalTransport = BuiltinSearch.transport;
  });
  tearDown(() {
    BuiltinSearch.transport = originalTransport;
  });

  List<int> encodeLrcx(String text) {
    final inner = utf8.encode(text);
    const key = 'yeelion';
    final xored = Uint8List(inner.length);
    for (var i = 0; i < inner.length; i++) {
      xored[i] = inner[i] ^ key.codeUnitAt(i % key.length);
    }
    final compressed =
        zlib_impl.zlibDeflate(utf8.encode(base64.encode(xored)));
    return [
      ...utf8.encode('TP=content\r\nlrcx=1\r\n\r\n'),
      ...compressed,
    ];
  }

  SourceTrack kwTrack({String? coverUrl}) => SourceTrack(
        sourceKey: 'kw',
        origin: 'builtin',
        title: '晴天',
        artist: '周杰伦',
        album: '叶惠美',
        coverUrl: coverUrl,
        raw: {'songmid': '228908', 'source': 'kw'},
      );

  test('能力位：内置五平台歌词/封面为真（无需脚本声明）', () {
    final manager = SourceManager();
    for (final key in ['kw', 'kg', 'tx', 'wy', 'mg']) {
      final capabilities = manager.capabilitiesFor(key);
      expect(capabilities.lyrics, isTrue, reason: key);
      expect(capabilities.artwork, isTrue, reason: key);
    }
    manager.dispose();
  });

  test('fetchLyric：kw 曲目走内置 LRCX 解码（脚本缺失时）', () async {
    BuiltinSearch.transport = BuiltinTransport(
      client: MockClient((request) async {
        return http.Response.bytes(
          encodeLrcx('[kuwo:127]\n[00:00.000]<1120,-1120>你<2400,160>好\n'),
          200,
        );
      }),
    );

    final manager = SourceManager();
    final lyric = await manager.fetchLyric(kwTrack());
    expect(lyric, isNotNull);
    expect(lyric!.lyric, contains('你好'));
    expect(lyric.lxlyric, contains('<0,160>'));
    manager.dispose();
  });

  test('fetchPic：已有封面直接复用，不发请求', () async {
    var called = false;
    BuiltinSearch.transport = BuiltinTransport(
      client: MockClient((request) async {
        called = true;
        return http.Response('unexpected', 500);
      }),
    );

    final manager = SourceManager();
    final pic = await manager.fetchPic(
      kwTrack(coverUrl: 'http://img.example/cover.jpg'),
    );
    expect(pic, 'http://img.example/cover.jpg');
    expect(called, isFalse);
    manager.dispose();
  });

  test('fetchPic：kw 无封面时走 pic.web 接口', () async {
    BuiltinSearch.transport = BuiltinTransport(
      client: MockClient((request) async {
        expect(request.url.host, 'artistpicserver.kuwo.cn');
        return http.Response('http://img.example/228908.jpg', 200);
      }),
    );

    final manager = SourceManager();
    final pic = await manager.fetchPic(kwTrack());
    expect(pic, 'http://img.example/228908.jpg');
    manager.dispose();
  });
}
