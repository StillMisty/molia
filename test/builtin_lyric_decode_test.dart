import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/sources/builtin/builtin_search.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';
import 'package:molia/sources/builtin/kg_lyric.dart';
import 'package:molia/sources/builtin/kw_lyric.dart';
import 'package:molia/sources/builtin/mg_lyric.dart';
import 'package:molia/sources/builtin/tx_lyric.dart';
import 'package:molia/sources/builtin/tx_qrc.dart';
import 'support/mock_dio.dart';
import 'package:molia/sources/builtin/zlib_io.dart' as zlib_impl;

/// builtin 平台歌词解码/解析单测：用合成数据做「编码 → 平台接口（MockClient）
/// → 解码」的闭环，锁定 KRC / LRCX / QRC / MRC 四条移植链路。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BuiltinTransport originalTransport;
  setUpAll(() {
    originalTransport = BuiltinSearch.transport;
  });
  tearDown(() {
    BuiltinSearch.transport = originalTransport;
  });

  group('kg KRC', () {
    const encKey = [
      0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47,
      0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69,
    ];

    String encodeKrc(String text) {
      final compressed = Uint8List.fromList(
        zlib_impl.zlibDeflate(utf8.encode(text)),
      );
      final buf = Uint8List(4 + compressed.length);
      for (var i = 0; i < compressed.length; i++) {
        buf[4 + i] = compressed[i] ^ encKey[i % 16];
      }
      return base64.encode(buf);
    }

    test('search + download + KRC 解码：逐字 / 翻译 / 罗马音', () async {
      final language = base64.encode(utf8.encode(jsonEncode({
        'content': [
          {
            'type': 0,
            'lyricContent': [
              ['roma line 1'],
              ['roma line 2'],
            ],
          },
          {
            'type': 1,
            'lyricContent': [
              ['译一'],
              ['译二'],
            ],
          },
        ],
      })));
      final krcText = '[id:\$abc123]\n'
          '[ti:测试]\n'
          '[language:$language]\n'
          '[0,1000]<0,500,0>你<500,500,0>好\n'
          '[2000,1000]<0,500,0>再<500,500,0>见\n';
      final download = jsonEncode({
        'fmt': 'krc',
        'content': encodeKrc(krcText),
      });
      final search = jsonEncode({
        'candidates': [
          {'id': 'c1', 'accesskey': 'k1', 'krctype': 1, 'contenttype': 0},
        ],
      });

      BuiltinSearch.transport = BuiltinTransport(
        dio: mockDio((request) async {
          if (request.uri.path.contains('/search')) {
            return bytesResponse(utf8.encode(search), statusCode: 200);
          }
          return bytesResponse(utf8.encode(download), statusCode: 200);
        }),
      );

      final result = await KgLyric.fetch(
        name: '测试',
        hash: 'HASH',
        timelengthSeconds: 200,
      );
      expect(result, isNotNull);
      expect(result!.lyric, contains('[00:00.000]你好'));
      expect(result.lyric, contains('[00:02.000]再见'));
      expect(result.lyric.contains('<'), isFalse);
      expect(result.lxlyric, contains('[00:00.000]<0,500>你<500,500>好'));
      expect(result.tlyric, contains('译一'));
      expect(result.rlyric, contains('roma line 1'));
    });
  });

  group('kw LRCX', () {
    List<int> encodeLrcx(String text) {
      final inner = utf8.encode(text);
      const key = 'yeelion';
      final xored = Uint8List(inner.length);
      for (var i = 0; i < inner.length; i++) {
        xored[i] = inner[i] ^ key.codeUnitAt(i % key.length);
      }
      final compressed = zlib_impl.zlibDeflate(
        utf8.encode(base64.encode(xored)),
      );
      return [
        ...utf8.encode('TP=content\r\nlrcx=1\r\n\r\n'),
        ...compressed,
      ];
    }

    test('TP=content + zlib + XOR：逐字换算与重复时间翻译拆分', () async {
      const lrcx = '[kuwo:127]\n'
          '[ti:测试]\n'
          '[00:00.000]<1120,-1120>你<2400,160>好\n'
          '[00:02.250]<3150,-3150>译<6750,450>文\n'
          '[00:02.250]<3150,-3150>原<6750,450>文\n';
      BuiltinSearch.transport = BuiltinTransport(
        dio: mockDio((request) async {
          return bytesResponse(encodeLrcx(lrcx), statusCode: 200);
        }),
      );

      final result = await KwLyric.fetch('228908');
      expect(result, isNotNull);
      // `<1120,-1120>` 在 [kuwo:127]（offset 8 / offset2 7）下换算为 <0,160>。
      expect(result!.lyric, contains('[00:00.000]你好'));
      expect(result.lxlyric, contains('[00:00.000]<0,160>你<160,160>好'));
      expect(result.lyric.contains('<'), isFalse);
      // 重复时间行的后一次出现 = 翻译行（时间回退到前一行）。
      expect(result.tlyric, isNotNull);
      expect(result.tlyric, contains('译文'));
    });
  });

  group('tx QRC', () {
    test('3DES + zlib 往返，且 QRC 包装 / 逐字解析正确', () {
      const raw = '[ti:测试]\n[0,1000]你(0,200)好(200,300)\n';
      final encoded = TxQrc.encode(raw);
      final decoded = TxQrc.decode(encoded);
      expect(decoded, raw);

      final wrapped =
          '<?xml version="1.0"?><LyricInfo LyricContent="$raw"/>';
      final info = TxLyric.parse(wrapped, null, null);
      expect(info.lyric, contains('[00:00.000]你好'));
      expect(info.lxlyric, contains('[00:00.000]<0,200>你<200,300>好'));
    });

    test('非 hex / 空输入返回 null', () {
      expect(TxQrc.decode(null), isNull);
      expect(TxQrc.decode(''), isNull);
      expect(TxQrc.decode('xyz'), isNull);
    });
  });

  group('mg MRC', () {
    test('TEA 往返 + 行时间/词时间解析', () {
      const raw = '[ti:测试]\n[1000,500]你(1000,200)好(1200,300)\n';
      final encrypted = MgLyric.encrypt(raw);
      final decrypted = MgLyric.decrypt(encrypted);
      expect(decrypted, isNotNull);
      // 明文按 4 个 UTF-16 码元一组分组长，尾部以 \x00 补齐。
      expect(decrypted!.replaceAll(RegExp(r'\x00+$'), ''), raw);

      BuiltinSearch.transport = BuiltinTransport(
        dio: mockDio((request) async {
          return textResponse(encrypted, statusCode: 200);
        }),
      );
      // ignore: unawaited_futures
      return MgLyric.fetch(mrcUrl: 'https://x/mrc').then((result) {
        expect(result, isNotNull);
        expect(result!.lyric, contains('[00:01.000]你好'));
        expect(result.lxlyric, contains('[00:01.000]<0,200>你<200,300>好'));
      });
    });
  });
}
