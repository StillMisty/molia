import 'package:flutter_test/flutter_test.dart';
import 'package:molia/sources/builtin/crypto_utils.dart';

/// 网易云加密固定向量（由 `tool/gen_wy_crypto_vectors.mjs` 用 Node
/// 复刻 LX crypto.js + Android AES/RSA 原生模块语义生成）。
///
/// 生成脚本中的固定密钥 `0123456789012345` 通过 `secretKey` 注入，
/// 保证 weapi 的随机密钥不影响断言。
void main() {
  const secretKey = '0123456789012345';

  group('weapi 向量', () {
    test('歌曲详情参数（含 encSecKey）', () {
      final result = weapiParams(
        {'id': 33894312, 'n': 100000, 'p': 1},
        secretKey: secretKey,
      );
      expect(
        result.params,
        'FQRyBnNuUj2FOsy2/IspdBIcXiPkbBhOBJV3kWmZPRCT0H3NbLztizAokPYcZCq9'
        'U4yhCTOlvB185wxT8QIJEqaEukR0iroRh2JV+24lfeA=',
      );
      expect(
        result.encSecKey,
        'a96c3fc32a27d07873f0967b4fafd42beee8cdcc224519939dbd58a765d9b67b'
        'bd9c5deb528aabd492bfb088a39ba55fb42b605919498ab4dd60de23c2d7c8132'
        '65b1e344718f8d516e8c6d7de9235d91aa832b19ccd5a75a52a20f5675fb11286'
        '8afa3b69962837733afb8c2d3cb4d2d6e13e0e7565fcf0684031ae7ade73cb',
      );
    });

    test('空对象参数', () {
      final result = weapiParams(const {}, secretKey: secretKey);
      expect(result.params, 'HzoXVX52AK6zuF29+fczneY+ykxuY4S585gbSdMrV7g=');
      // encSecKey 只与 secretKey 有关，与明文无关
      expect(result.encSecKey, weapiParams(const {}, secretKey: secretKey).encSecKey);
    });

    test('weapiForm 返回 params / encSecKey 两个表单字段', () {
      final form = weapiForm({'a': 1}, secretKey: secretKey);
      expect(form.keys, containsAll(['params', 'encSecKey']));
      expect(form['params'], isNotEmpty);
      expect(form['encSecKey']!.length, 256); // 128 字节 RSA 密文
    });

    test('密钥必须为 16 字节', () {
      expect(
        () => weapiParams(const {}, secretKey: 'short'),
        throwsArgumentError,
      );
    });

    test('随机密钥：每次调用生成不同密文', () {
      final a = weapiParams(const {'x': 1});
      final b = weapiParams(const {'x': 1});
      expect(a.encSecKey, isNot(b.encSecKey));
      expect(a.params, isNot(b.params));
    });

    test('randomWeapiSecretKey 为 16 位数字（LX Math.random 语义）', () {
      for (var i = 0; i < 20; i++) {
        final key = randomWeapiSecretKey();
        expect(key.length, 16);
        expect(RegExp(r'^\d{16}$').hasMatch(key), isTrue);
      }
    });
  });

  group('linuxapi 向量', () {
    test('歌单详情转发参数', () {
      final eparams = linuxapiParams({
        'method': 'POST',
        'url': 'https://music.163.com/api/v3/playlist/detail',
        'params': {'id': '3778678', 'n': 100000, 's': 8},
      });
      expect(
        eparams,
        'A0D9583F4C5FF68DE851D2893A49DE98FAFB24399F27B4F7E74C64B6FC49A965'
        'CFA972FA5EA3D6247CD6247C8198CB87193DFC37756896DF3666AE409ED93B39'
        '34F099F173733DD2A2271FA1255205590F0C81A96ED498E731DBF7B8C9D4A817'
        '131922803C7411E66615626146979EF7FC5965DED0B85514DD5B3281C0C36ECB',
      );
      // 十六进制大写
      expect(eparams, matches(RegExp(r'^[0-9A-F]+$')));
    });
  });

  group('eapi 向量', () {
    test('搜索参数（与 wy_search 实际请求一致）', () {
      final params = eapiParams('/api/search/song/list/page', {
        'keyword': '晴天',
        'needCorrect': '1',
        'channel': 'typing',
        'offset': 0,
        'scene': 'normal',
        'total': true,
        'limit': 30,
      });
      expect(
        params,
        '74A595527B7A1647174ADDB4F261E92F180F42F921F98E9D338C60DB20AF499C'
        'EA90E95FB2FDA117A0B5D8175C2F21E5C1BD8D67F61C04584AFD482A98F5A426'
        '5ECCD6FB95592FA5280348236698BCBBAB8645D8F534488F2E7F9D639BF8146E'
        '070B45B5889004E0CC502E9F96CD56ED8E8FB700977800E5C616368B3C31571F'
        '7130F5BA92FF81EF767FE901A4783B3A87BCACA418296D0FF073E900D40B535AF'
        'F6EBDF07837FC2199D0D5B92265EBF3CAB368793ED567887FC8D96C60888F27A'
        '6073F78C543B0A89158359B0E15B6F6',
      );
    });
  });
}
