import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:html_unescape/html_unescape.dart';
import 'package:pointycastle/export.dart';

import '../lx/lx_native_utils.dart';

/// 内置平台搜索用到的加密 / 工具函数（自 lx-music-mobile 的 JS 实现移植，Apache-2.0）。

final _unescape = HtmlUnescape();

String decodeName(String? str) {
  if (str == null || str.isEmpty) return '';
  return _unescape.convert(str);
}

String formatPlayTime(num seconds) {
  final m = seconds ~/ 60;
  final s = (seconds % 60).floor();
  if (m == 0 && s == 0) return '--/--';
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

String sizeFormat(num size) {
  if (size <= 0) return '0 B';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  final value = size.toDouble();
  final index =
      (math.log(value) / math.ln2 / 10).floor().clamp(0, units.length - 1);
  return '${(value / math.pow(1024, index)).toStringAsFixed(2)} ${units[index]}';
}

String md5Hex(String input) =>
    crypto.md5.convert(utf8.encode(input)).toString();

String sha1Hex(String input) =>
    crypto.sha1.convert(utf8.encode(input)).toString();

Uint8List aesEcbEncryptNoPadding(List<int> data, List<int> key) {
  final cipher = ECBBlockCipher(AESEngine())
    ..init(true, KeyParameter(Uint8List.fromList(key)));
  final input = Uint8List.fromList(data);
  if (input.length % 16 != 0) {
    throw ArgumentError('AES-ECB no padding requires 16-byte aligned data');
  }
  final output = Uint8List(input.length);
  for (var offset = 0; offset < input.length; offset += 16) {
    cipher.processBlock(input, offset, output, offset);
  }
  return output;
}

/// AES-ECB + PKCS7 解密（同步；酷我 wbd 接口响应解密用）。
Uint8List aesEcbDecryptPkcs7(List<int> data, List<int> key) {
  final cipher = PaddedBlockCipherImpl(PKCS7Padding(), ECBBlockCipher(AESEngine()))
    ..init(
      false,
      PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
        KeyParameter(Uint8List.fromList(key)),
        null,
      ),
    );
  return cipher.process(Uint8List.fromList(data));
}

String hexEncode(List<int> data) =>
    data.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

// QQ 音乐 zzcSign

const _txPart1Indexes = [23, 14, 6, 36, 16, 40, 7, 19];
const _txPart2Indexes = [16, 1, 32, 12, 19, 27, 8, 5];
const _txScrambleValues = [
  89, 39, 179, 150, 218, 82, 58, 252, 177, 52,
  186, 123, 120, 64, 242, 133, 143, 161, 121, 179,
];

String zzcSign(String text) {
  final hash = sha1Hex(text);
  // 注意：原 JS 实现中越界索引会得到 undefined，join('') 时按空串处理
  String pick(List<int> indexes) =>
      indexes.map((i) => i < hash.length ? hash[i] : '').join();
  final part1 = pick(_txPart1Indexes);
  final part2 = pick(_txPart2Indexes);
  final part3 = Uint8List(20);
  for (var i = 0; i < _txScrambleValues.length; i++) {
    part3[i] = _txScrambleValues[i] ^
        int.parse(hash.substring(i * 2, i * 2 + 2), radix: 16);
  }
  final b64Part = base64.encode(part3).replaceAll(RegExp(r'[\\/+=]'), '');
  return 'zzc$part1$b64Part$part2'.toLowerCase();
}

// 酷我 wbd 接口（bang_info 等）

/// 酷我 wbd AES 密钥（base64，LX `kw/util.js` wbdCrypto 原样）。
const kwWbdKeyBase64 = 'cFcnPcf6Kb85RC1y3V6M5A==';

/// 酷我 wbd appId（参与 sign）。
const kwWbdAppId = 'y67sprxhhpws';

/// 生成酷我 wbd 请求参数（AES-128-ECB/PKCS7 + 大写 md5 sign）。
///
/// [time] 仅测试注入（毫秒时间戳），生产不传取当前时间。
String kwWbdBuildParam(Map<String, dynamic> jsonData, {int? time}) {
  final key = base64.decode(kwWbdKeyBase64);
  final ts = time ?? DateTime.now().millisecondsSinceEpoch;
  final encrypted = base64.encode(LxNativeUtils.aesEncrypt(
    Uint8List.fromList(utf8.encode(jsonEncode(jsonData))),
    'aes-128-ecb',
    key,
    null,
  ));
  final sign = md5Hex('$kwWbdAppId$encrypted$ts').toUpperCase();
  return 'data=${Uri.encodeComponent(encrypted)}&time=$ts'
      '&appId=$kwWbdAppId&sign=$sign';
}

/// 解码酷我 wbd 响应（base64 → AES-128-ECB/PKCS7 → JSON）。
dynamic kwWbdDecodeData(String raw) {
  final data = base64.decode(Uri.decodeComponent(raw.trim()));
  final plain = aesEcbDecryptPkcs7(data, base64.decode(kwWbdKeyBase64));
  return jsonDecode(utf8.decode(plain));
}

// 网易云 weapi / linuxapi

// 与 LX crypto.js 一致：这些常量在 JS 侧先 btoa（base64 编码），
// 原生 AES 模块再对 data/key/iv 做 base64 解码后使用，
// 因此 Dart 侧直接使用解码后的原始字节（与现有 eapi 实现同一约定）。
const _wyWeapiPresetKey = '0CoJUm6Qyw8W8jud';
const _wyWeapiIv = '0102030405060708';
const _wyLinuxapiKey = 'rFgB&h#%2?^eDg:Q';

/// weapi RSA 公钥（lx-music-mobile `wy/utils/crypto.js` 原样）。
const wyWeapiPublicKey = '''-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDgtQn2JZ34ZC28NWYpAUd98iZ37BUrX/aKzmFbt7clFSs6sXqHauqKWqdtLkF2KexO40H1YTX8z2lSgBBOAxLsvaklV8k4cBFK9snQXE9/DDaFt6Rr7iVZMldczhC0JNgTz+SHXT6CBHuX3e9SdB1Ua44oncaTWz7OBGLbCiK45wIDAQAB
-----END PUBLIC KEY-----''';

/// weapi 加密结果（form 字段 params / encSecKey）。
typedef WeapiParams = ({String params, String encSecKey});

/// 生成 LX `String(Math.random()).substring(2, 18)` 等价的 16 位数字密钥。
///
/// 与 LX 行为一致（16 位数字）；随机源改用 [math.Random.secure]，
/// 避免可预测的客户端密钥（服务端只做一次 RSA 还原，不依赖弱随机）。
String randomWeapiSecretKey() {
  final random = math.Random.secure();
  return List.generate(16, (_) => random.nextInt(10).toString()).join();
}

/// weapi 加密（移植自 LX crypto.js `weapi`，对应网易云 NeteaseCloudMusicApi）：
/// 1. AES-128-CBC/PKCS7（presetKey + iv）加密 JSON 文本的 base64 串；
/// 2. 结果整体再做一次 base64 后，用随机 secretKey 二次 AES 加密；
/// 3. secretKey 反转左补零至 128 字节后 RSA(NO_PADDING) 加密为 encSecKey。
///
/// [secretKey] 仅测试注入（需 16 字节 ASCII），生产不传即随机生成。
WeapiParams weapiParams(Object object, {String? secretKey}) {
  final sk = secretKey ?? randomWeapiSecretKey();
  final skBytes = utf8.encode(sk);
  if (skBytes.length != 16) {
    throw ArgumentError.value(sk, 'secretKey', 'weapi 密钥必须为 16 字节');
  }
  final text = jsonEncode(object);
  final first = LxNativeUtils.aesEncrypt(
    Uint8List.fromList(utf8.encode(text)),
    'aes-128-cbc',
    Uint8List.fromList(utf8.encode(_wyWeapiPresetKey)),
    Uint8List.fromList(utf8.encode(_wyWeapiIv)),
  );
  final second = LxNativeUtils.aesEncrypt(
    Uint8List.fromList(utf8.encode(base64.encode(first))),
    'aes-128-cbc',
    Uint8List.fromList(skBytes),
    Uint8List.fromList(utf8.encode(_wyWeapiIv)),
  );

  // Buffer.from(secretKey).reverse() 后左补零到 128 字节
  final reversed = Uint8List.fromList(skBytes.reversed.toList());
  final padded = Uint8List(128)..setRange(128 - reversed.length, 128, reversed);
  final encSecKey = hexEncode(LxNativeUtils.rsaEncrypt(padded, wyWeapiPublicKey));

  return (params: base64.encode(second), encSecKey: encSecKey);
}

/// 供 form 提交使用的 weapi 字段（params / encSecKey）。
Map<String, String> weapiForm(Object object, {String? secretKey}) {
  final result = weapiParams(object, secretKey: secretKey);
  return {'params': result.params, 'encSecKey': result.encSecKey};
}

/// linuxapi 加密（移植自 LX crypto.js `linuxapi`）：
/// AES-128-ECB/PKCS7 加密 JSON 文本，密文转十六进制大写。
String linuxapiParams(Object object) {
  final text = jsonEncode(object);
  final cipher = LxNativeUtils.aesEncrypt(
    Uint8List.fromList(utf8.encode(text)),
    'aes-128-ecb',
    Uint8List.fromList(utf8.encode(_wyLinuxapiKey)),
    null,
  );
  return hexEncode(cipher).toUpperCase();
}

// 网易云 eapi

const _wyEapiKey = 'e82ckenh8dichen8';

/// 标准 eapi：AES-128-ECB/PKCS7 加密原始 data 串（与 lx-music-desktop 一致）。
String eapiParams(String url, Object object) {
  final text = jsonEncode(object);
  final message = 'nobody${url}use${text}md5forencrypt';
  final digest = md5Hex(message);
  final data = '$url-36cd479b6b5-$text-36cd479b6b5-$digest';
  final cipher = LxNativeUtils.aesEncrypt(
    Uint8List.fromList(utf8.encode(data)),
    'aes-128-ecb',
    _wyEapiKey,
    null,
  );
  return hexEncode(cipher).toUpperCase();
}
