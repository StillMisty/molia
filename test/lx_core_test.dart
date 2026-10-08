import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/sources/builtin/crypto_utils.dart';
import 'package:molia/sources/lx/lx_native_utils.dart';
import 'package:molia/sources/lx/lx_script_info.dart';

/// 测试向量由 Node.js 的 crypto 模块生成（见提交说明），
/// 用于校验 LX utils 与内置平台加密实现的正确性。
void main() {
  group('LxNativeUtils.md5', () {
    test('matches known vector', () {
      expect(LxNativeUtils.md5('hello world'), '5eb63bbbe01eeed093cb22bb8f5acdc3');
    });
  });

  group('LxNativeUtils.aesEncrypt', () {
    test('aes-128-cbc with PKCS7 padding', () {
      final result = LxNativeUtils.aesEncrypt(
        Uint8List.fromList(utf8.encode('Hello, LX Music!')),
        'aes-128-cbc',
        '0123456789abcdef',
        'abcdef0123456789',
      );
      expect(
        hexEncode(result),
        '36a8ce69e59b07bb1ebd8d030232a07006902c46c33cb88a64da0b4e611e341d',
      );
    });

    test('aes-128-ecb no padding via crypto_utils', () {
      final cipher = aesEcbEncryptNoPadding(
        utf8.encode('0123456789abcdef'),
        utf8.encode('0123456789abcdef'),
      );
      expect(cipher.length, 16);
    });
  });

  group('eapiParams', () {
    test('matches Node.js crypto output', () {
      final params = eapiParams('/api/search/song/list/page', {
        'keyword': 'testxxxxx',
        'limit': 30,
      });
      expect(
        params,
        '74A595527B7A1647174ADDB4F261E92F180F42F921F98E9D338C60DB20AF499C'
        'EA90E95FB2FDA117A0B5D8175C2F21E5D125EEE69BC4A89E7B6A7FBE83F78CA'
        '61CAC3BD39A0A79BCDB3D913DF4E721B3343C1838ABF5665A342557E1DCB2988'
        '18238A3CB90019357C37B60C7D1035FDF04D8A5DF23EEBDB06B12627F05E11A73',
      );
    });
  });

  group('zzcSign', () {
    test('matches reference implementation', () {
      final sign = zzcSign('{"comm":{"cv":"2151","uin":"0"},"q":"test"}');
      expect(sign, 'zzcbc37db6vu73rwknhdliopiwcdfbxqohbssdc8267b4');
    });
  });

  group('LxNativeUtils.rsaEncrypt', () {
    test('RSA_NO_PADDING matches Node.js crypto output', () {
      const publicKey = '''-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDDFHhIqAqlkC4DXG9Z9y0W3ILJ
fb024dRZ7fhSbfno4YOAKN5rFo48lwhGjKHK4wVkJ0RzmgKWb2M5S6VFr7KYky/D
SPMZGCMrrRk+ZyB32oiatCOvpMe4pAI32B1A1zjv/aQ2B5HB/KayG3e8Sy11gwi/
fLgI/d5rt6cbIlUMywIDAQAB
-----END PUBLIC KEY-----''';
      final message = hexDecode(
        '0011223344556677889900112233445566778899001122334455667788990011'
        '0011223344556677889900112233445566778899001122334455667788990011',
      );
      final encrypted = LxNativeUtils.rsaEncrypt(message, publicKey);
      expect(encrypted.length, 128);
      expect(
        hexEncode(encrypted),
        '2afce264cc774d9f0308cf78e83aa0fd99add39356456708b0b6f951fa939922'
        'd65477c772b68cf2390a96d981d21ed25e0f8a6ef564c25e55424ea4c4170ba6'
        '414471f70d15c0a57713418991d1207e2c2ba995086ba5fa02dea0f53a6c1499'
        'e0d38f497858e53fd739063bff32f12f8cdaa5ca08b65009fd22452469e6d339',
      );
    });
  });

  group('LxNativeUtils.zlib', () {
    test('deflate/inflate roundtrip', () {
      final original = Uint8List.fromList(utf8.encode('LX Music zlib roundtrip 测试'));
      final deflated = LxNativeUtils.zlibDeflate(original);
      expect(deflated, isNot(equals(original)));
      final inflated = LxNativeUtils.zlibInflate(deflated);
      expect(utf8.decode(inflated), 'LX Music zlib roundtrip 测试');
    });
  });

  group('LxNativeUtils.randomBytes', () {
    test('returns requested size', () {
      expect(LxNativeUtils.randomBytes(16).length, 16);
      expect(LxNativeUtils.randomBytes(0), isEmpty);
    });
  });

  group('LxScriptInfo.parse', () {
    test('parses metadata from header comment', () {
      const script = '''
/**
 * @name 测试音乐源
 * @description 我只是一个测试音乐源哦
 * @version 1.0.0
 * @author xxx
 * @homepage http://xxx
 */
const { EVENT_NAMES, request, on, send } = globalThis.lx
''';
      final info = LxScriptInfo.parse(script);
      expect(info, isNotNull);
      expect(info!.name, '测试音乐源');
      expect(info.description, '我只是一个测试音乐源哦');
      expect(info.version, '1.0.0');
      expect(info.author, 'xxx');
      expect(info.homepage, 'http://xxx');
    });

    test('rejects script without @name', () {
      expect(LxScriptInfo.parse('console.log(1)'), isNull);
    });

    test('source declaration json roundtrip', () {
      final decl = LxSourceDecl.fromJson('mg', {
        'name': '咪咕音乐',
        'type': 'music',
        'actions': ['musicUrl', 'search'],
        'qualitys': ['128k', '320k'],
      });
      expect(decl.canSearch, isTrue);
      expect(decl.canResolveUrl, isTrue);
      expect(decl.supports('lyric'), isFalse);
    });
  });

  group('utility', () {
    test('formatPlayTime', () {
      expect(formatPlayTime(0), '--/--');
      expect(formatPlayTime(59), '00:59');
      expect(formatPlayTime(245), '04:05');
    });

    test('decodeName decodes html entities', () {
      expect(decodeName('A &amp; B'), 'A & B');
    });
  });
}

Uint8List hexDecode(String hex) {
  final bytes = <int>[];
  for (var i = 0; i + 1 < hex.length; i += 2) {
    bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return Uint8List.fromList(bytes);
}
