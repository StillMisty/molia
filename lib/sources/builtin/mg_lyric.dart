import 'dart:typed_data';

import 'builtin_search.dart';
import 'builtin_transport.dart';
import 'lyric_result.dart';

/// 咪咕歌词获取（移植自 lx-music-mobile `mg/lyric.js` + `mg/musicInfo.js`
/// + `mg/utils/mrc.js`）。
///
/// - 搜索响应自带 `mrcUrl` / `lrcUrl` / `trcUrl`；缺失时按 `songId` 走
///   `resourceinfo.do`（对应 LX `getMusicInfo`）；
/// - MRC 正文为 TEA（XXTEA 变体）加密的十六进制串，解密后是
///   `[start,dur](偏移,dur)词...` 格式；`trcUrl` 为纯文本翻译。
class MgLyric {
  MgLyric._();

  static const Map<String, String> _headers = {
    'Referer': 'https://app.c.nf.migu.cn/',
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 5.1.1; Nexus 6 Build/LYZ28E) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/59.0.3071.115 '
        'Mobile Safari/537.36',
    'channel': '0146921',
  };

  static final RegExp _lineTime = RegExp(r'^\s*\[(\d+),\d+\]');
  static final RegExp _wordAll = RegExp(r'\((\d+),(\d+)\)');
  static final RegExp _word = RegExp(r'\(\d+,\d+\)');

  /// 获取歌词；失败返回 null（由调用方回退其它来源）。
  static Future<BuiltinLyricResult?> fetch({
    String? songId,
    String? mrcUrl,
    String? lrcUrl,
    String? trcUrl,
  }) async {
    var mrc = mrcUrl;
    var lrc = lrcUrl;
    var trc = trcUrl;
    if ((mrc == null || mrc.isEmpty) && (songId ?? '').isNotEmpty) {
      final info = await resourceInfo(songId!);
      mrc ??= info?['mrcUrl']?.toString();
      lrc ??= info?['lrcUrl']?.toString();
      trc ??= info?['trcUrl']?.toString();
    }

    BuiltinLyricResult? result;
    if ((mrc ?? '').isNotEmpty) {
      final text = await getText(mrc!);
      final decrypted = decrypt(text);
      if (decrypted != null && decrypted.trim().isNotEmpty) {
        result = _parseMrcText(decrypted);
      }
    } else if ((lrc ?? '').isNotEmpty) {
      final text = await getText(lrc!);
      if (text != null && text.trim().isNotEmpty) {
        result = BuiltinLyricResult(lyric: text);
      }
    }
    if (result == null || result.isEmpty) return null;

    String? tlyric = result.tlyric;
    if ((trc ?? '').isNotEmpty) {
      final text = await getText(trc!);
      if (text != null && text.trim().isNotEmpty) tlyric = text;
    }
    return BuiltinLyricResult(
      lyric: result.lyric,
      tlyric: tlyric,
      rlyric: result.rlyric,
      lxlyric: result.lxlyric,
    );
  }

  /// 按 songId 取资源信息（mrc/lrc/trc URL、专辑封面）。
  static Future<Map<String, dynamic>?> resourceInfo(String songId) async {
    try {
      final json = await lxHttpPost(
        'https://c.musicapp.migu.cn/MIGUM2.0/v1.0/content/'
        'resourceinfo.do?resourceType=2',
        form: true,
        body: {'resourceId': songId},
        retries: BuiltinTransport.defaultRetries,
        retryIf: (value) => value is! Map,
      );
      final resource = json is Map ? json['resource'] : null;
      if (resource is List && resource.isNotEmpty && resource.first is Map) {
        return (resource.first as Map).cast<String, dynamic>();
      }
    } catch (_) {
      // 资源信息失败按无资源处理。
    }
    return null;
  }

  /// 取资源封面（`albumImgs[0].img`），供封面回退使用。
  static Future<String?> coverOf(String songId) async {
    final info = await resourceInfo(songId);
    final imgs = info?['albumImgs'];
    if (imgs is List && imgs.isNotEmpty && imgs.first is Map) {
      final img = (imgs.first as Map)['img']?.toString();
      if (img != null && img.isNotEmpty) {
        return img.startsWith('http') ? img : 'http://d.musicapp.migu.cn$img';
      }
    }
    return null;
  }

  /// 下载歌词文本（多媒体资源 URL，统一走咪咕请求头）。
  static Future<String?> getText(String url) async {
    try {
      return await lxHttpGetText(url, headers: _headers);
    } catch (_) {
      return null;
    }
  }

  /// MRC 正文解析（对照 LX `mrcTools.parseLyric`）：
  /// `[绝对开始ms,行时长]` → `[mm:ss.mmm]`；词时间 `(词开始ms,词时长)` →
  /// LX `<相对开始ms,时长>`。
  static BuiltinLyricResult _parseMrcText(String raw) {
    final text = raw.replaceAll('\r', '');
    final lxLines = <String>[];
    final lrcLines = <String>[];
    for (final line in text.split('\n')) {
      if (line.length < 6) continue;
      final match = _lineTime.firstMatch(line);
      if (match == null) continue;
      final startTime = int.tryParse(match.group(1)!);
      if (startTime == null) continue;
      final timeTag = msFormat(startTime);
      final words = line.substring(match.end);

      lrcLines.add('$timeTag${words.replaceAll(_word, '')}');

      final times =
          _wordAll.allMatches(words).map((m) => m.group(0)!).toList();
      if (times.isEmpty) continue;
      final converted = <String>[];
      for (final time in times) {
        final pair = _wordAll.firstMatch(time)!;
        final start = int.parse(pair.group(1)!);
        converted.add('<${(start - startTime).truncate()},${pair.group(2)}>');
      }
      final wordArr = words.split(_word);
      final newWords = [
        for (var i = 0; i < converted.length; i++)
          '${converted[i]}${i < wordArr.length ? wordArr[i] : ''}',
      ].join();
      lxLines.add('$timeTag$newWords');
    }
    return BuiltinLyricResult(
      lyric: lrcLines.join('\n'),
      lxlyric: lxLines.join('\n'),
    );
  }

  // ---------------------------------------------------------------------------
  // MRC 解密（LX `mg/utils/mrc.js` 1:1 移植：TTEA + 64 位回绕）
  // ---------------------------------------------------------------------------

  static final BigInt _delta = BigInt.parse('2654435769');
  static final BigInt _max = BigInt.parse('9223372036854775807');
  static final BigInt _min = BigInt.parse('-9223372036854775808');
  static final BigInt _two64 = BigInt.one << 64;

  static final List<BigInt> _keyArr = [
    BigInt.parse('27303562373562475'),
    BigInt.parse('18014862372307051'),
    BigInt.parse('22799692160172081'),
    BigInt.parse('34058940340699235'),
    BigInt.parse('30962724186095721'),
    BigInt.parse('27303523720101991'),
    BigInt.parse('27303523720101998'),
    BigInt.parse('31244139033526382'),
    BigInt.parse('28992395054481524'),
  ];

  /// 解密 MRC：长度不足 32 时原样返回（与 LX 一致）。
  static String? decrypt(String? data) {
    if (data == null || data.length < 32) return data;
    try {
      return _longArrToString(_teaDecrypt(_toBigIntArray(data), _keyArr));
    } catch (_) {
      return null;
    }
  }

  static BigInt _toLong(BigInt value) {
    var result = value;
    while (result > _max) {
      result -= _two64;
    }
    while (result < _min) {
      result += _two64;
    }
    return result;
  }

  static List<BigInt> _toBigIntArray(String data) {
    final length = data.length ~/ 16;
    final arr = List<BigInt>.filled(length, BigInt.zero);
    for (var i = 0; i < length; i++) {
      arr[i] = _toLong(
        BigInt.parse(data.substring(i * 16, i * 16 + 16), radix: 16),
      );
    }
    return arr;
  }

  static List<BigInt> _teaDecrypt(List<BigInt> data, List<BigInt> key) {
    final length = data.length;
    if (length < 1) return data;
    final lengthBig = BigInt.from(length);
    var j2 = data[0];
    var j3 = _toLong(
      (BigInt.from(6) + BigInt.from(52) ~/ lengthBig) * _delta,
    );
    while (true) {
      final j4 = j3;
      if (j4 == BigInt.zero) break;
      final j5 = _toLong(BigInt.from(3) & _toLong(j4 >> 2));
      var j6 = lengthBig;
      while (true) {
        j6 -= BigInt.one;
        if (j6 > BigInt.zero) {
          final prevIndex = (j6 - BigInt.one).toInt();
          final index = j6.toInt();
          final j7 = data[prevIndex];
          final a = _toLong(j2 ^ j4);
          final b = _toLong(
            j7 ^ key[(_toLong(BigInt.from(3) & j6) ^ j5).toInt()],
          );
          final c = _toLong(_toLong(j7 >> 5) ^ _toLong(j2 << 2));
          final d = _toLong(_toLong(j2 >> 3) ^ _toLong(j7 << 4));
          j2 = _toLong(data[index] - (_toLong(a + b) ^ _toLong(c + d)));
          data[index] = j2;
        } else {
          break;
        }
      }
      final j8 = data[length - 1];
      final a = _toLong(
        key[(_toLong(j6 & BigInt.from(3)) ^ j5).toInt()] ^ j8,
      );
      final b = _toLong(j2 ^ j4);
      final c = _toLong(_toLong(j8 >> 5) ^ _toLong(j2 << 2));
      final d = _toLong(_toLong(j2 >> 3) ^ _toLong(j8 << 4));
      j2 = _toLong(data[0] - (_toLong(a + b) ^ _toLong(c + d)));
      data[0] = j2;
      j3 = _toLong(j4 - _delta);
    }
    return data;
  }

  static String _longArrToString(List<BigInt> data) {
    final codeUnits = <int>[];
    for (final value in data) {
      final bytes = _longToBytes(value);
      for (var i = 0; i < 8; i += 2) {
        codeUnits.add(bytes[i] | (bytes[i + 1] << 8));
      }
    }
    return String.fromCharCodes(codeUnits);
  }

  static Uint8List _longToBytes(BigInt value) {
    final result = Uint8List(8);
    var v = value;
    final mask = BigInt.from(0xFF);
    for (var i = 0; i < 8; i++) {
      result[i] = (v & mask).toInt();
      v >>= 8;
    }
    return result;
  }

  /// 供单测使用：MRC 加密（TEA 逆运算 + UTF-16LE 分组长）。
  static String encrypt(String text) {
    final codeUnits = text.codeUnits;
    final longCount = (codeUnits.length + 3) ~/ 4;
    final data = List<BigInt>.filled(longCount, BigInt.zero);
    for (var i = 0; i < longCount; i++) {
      var value = BigInt.zero;
      for (var j = 3; j >= 0; j--) {
        final unit =
            i * 4 + j < codeUnits.length ? codeUnits[i * 4 + j] : 0;
        value = (value << 16) | BigInt.from(unit);
      }
      data[i] = _toLong(value);
    }
    final encrypted = _teaEncrypt(
      List<BigInt>.from(data),
      _keyArr,
    );
    final buffer = StringBuffer();
    for (final value in encrypted) {
      buffer.write(
        value.toUnsigned(64).toRadixString(16).padLeft(16, '0'),
      );
    }
    return buffer.toString();
  }

  static List<BigInt> _teaEncrypt(List<BigInt> data, List<BigInt> key) {
    // 与 _teaDecrypt 严格互逆（逐操作推导）：
    // 每轮先还原 data[0]（decrypt 的收尾操作），再按 i = 1..n-1 递增还原
    // data[i]（decrypt 内层 i = n-1..1 的逆序），sum 以 delta 递增。
    final length = data.length;
    if (length < 1) return data;
    final rounds =
        (BigInt.from(6) + BigInt.from(52) ~/ BigInt.from(length)).toInt();
    var sum = BigInt.zero;
    for (var round = 0; round < rounds; round++) {
      sum = _toLong(sum + _delta);
      final j5 = _toLong(BigInt.from(3) & _toLong(sum >> 2));
      if (length == 1) {
        data[0] = _toLong(
          data[0] + _mix(y: data[0], z: data[0], sum: sum, key: key[j5.toInt()]),
        );
        continue;
      }
      final b1 = data[1];
      final bn = data[length - 1];
      data[0] = _toLong(
        data[0] + _mix(y: b1, z: bn, sum: sum, key: key[j5.toInt()]),
      );
      for (var i = 1; i < length; i++) {
        final y = (i == length - 1) ? data[0] : data[i + 1];
        final z = data[i - 1];
        final k = key[(_toLong(BigInt.from(3) & BigInt.from(i)) ^ j5).toInt()];
        data[i] = _toLong(data[i] + _mix(y: y, z: z, sum: sum, key: k));
      }
    }
    return data;
  }

  /// `mix(y, z, sum, key)`（与 `_teaDecrypt` 内层表达式同构）。
  static BigInt _mix({
    required BigInt y,
    required BigInt z,
    required BigInt sum,
    required BigInt key,
  }) {
    final left = _toLong(_toLong(y ^ sum) + _toLong(z ^ key));
    final right = _toLong(
      _toLong(_toLong(z >> 5) ^ _toLong(y << 2)) +
          _toLong(_toLong(y >> 3) ^ _toLong(z << 4)),
    );
    return _toLong(left ^ right);
  }
}
