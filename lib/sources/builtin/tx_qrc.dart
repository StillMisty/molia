import 'dart:convert';
import 'dart:typed_data';

import 'zlib_io.dart' as zlib_impl;

/// 腾讯 QRC 歌词解密（由 lx-music-mobile `tx/qrcDecode.js` 1:1 移植）。
///
/// 算法为标准 3DES（DES-EDE3，ECB、无填充）+ zlib inflate；
/// **注意**：QRC 使用的 DES S-box 是非标准变体（S2[23]=15、S4[53]=10，
/// 标准 DES 为 14、1），这两个值与原 native 插件二进制一致，不可“修正”，
/// 否则解密结果错误。
///
/// 数据流程：hex 字符串 → 字节 → 3DES 解密 → zlib inflate → UTF-8 文本。
class TxQrc {
  TxQrc._();

  static const int _desEncrypt = 1;
  static const int _desDecrypt = 0;

  /// QRC 固定密钥 ASCII：`!@#)(*$%123ZXC!@!@#)(NHL`。
  static final Uint8List _qrcKey = Uint8List.fromList(const [
    0x21, 0x40, 0x23, 0x29, 0x28, 0x2a, 0x24, 0x25, 0x31, 0x32, 0x33,
    0x5a, 0x58, 0x43, 0x21, 0x40, 0x21, 0x40, 0x23, 0x29, 0x28, 0x4e,
    0x48, 0x4c,
  ]);

  /// 非标准 DES S-box（与原 C++ 插件逐字节一致，见类注释）。
  static const List<List<int>> _sbox = [
    [
      14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4,
      14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8, 4, 1, 14, 8, 13, 6, 2, 11,
      15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14,
      10, 0, 6, 13,
    ],
    [
      15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7,
      15, 2, 8, 15, 12, 0, 1, 10, 6, 9, 11, 5, 0, 14, 7, 11, 10, 4, 13, 1,
      5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12,
      0, 5, 14, 9,
    ],
    [
      10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9,
      3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1, 13, 6, 4, 9, 8, 15, 3, 0,
      11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3,
      11, 5, 2, 12,
    ],
    [
      7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5,
      6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9, 10, 6, 9, 0, 12, 11, 7, 13,
      15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10, 10, 13, 8, 9, 4, 5, 11,
      12, 7, 2, 14,
    ],
    [
      2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12,
      4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6, 4, 2, 1, 11, 10, 13, 7, 8,
      15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9,
      10, 4, 5, 3,
    ],
    [
      12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2,
      7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8, 9, 14, 15, 5, 2, 8, 12, 3,
      7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7,
      6, 0, 8, 13,
    ],
    [
      4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7,
      4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6, 1, 4, 11, 13, 12, 3, 7, 14,
      10, 15, 6, 8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15,
      14, 2, 3, 12,
    ],
    [
      13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8,
      10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2, 7, 11, 4, 1, 9, 12, 14, 2,
      0, 6, 10, 13, 15, 3, 5, 8, 2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0,
      3, 5, 6, 11,
    ],
  ];

  static const List<int> _keyRndShift = [
    1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1,
  ];
  static const List<int> _keyPermC = [
    56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17, 9, 1, 58, 50,
    42, 34, 26, 18, 10, 2, 59, 51, 43, 35,
  ];
  static const List<int> _keyPermD = [
    62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 60, 52,
    44, 36, 28, 20, 12, 4, 27, 19, 11, 3,
  ];
  static const List<int> _keyCompression = [
    13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9, 22, 18, 11, 3, 25, 7, 15,
    6, 26, 19, 12, 1, 40, 51, 30, 36, 46, 54, 29, 39, 50, 44, 32, 47, 43,
    48, 38, 55, 33, 52, 45, 41, 49, 35, 28, 31,
  ];

  /// 全部以无符号 32 位处理，与 JS `>>> 0` / C++ `uint32_t` 一致。
  static int _u32(int value) => value & 0xFFFFFFFF;

  static int _bitnum(List<int> a, int b, int c) =>
      _u32((((a[(b ~/ 32) * 4 + 3 - ((b % 32) ~/ 8)] >>> (7 - (b % 8))) & 1)
              << c)
          .toUnsigned(32));

  static int _bitnumIntr(int a, int b, int c) =>
      _u32(((a >>> (31 - b)) & 1) << c);

  static int _bitnumIntl(int a, int b, int c) =>
      _u32((_u32(_u32(a << b) & 0x80000000) >>> c));

  static int _sboxBit(int a) => (a & 32) | ((a & 31) >>> 1) | ((a & 1) << 4);

  static List<int> _initialPermutation(List<int> input) {
    final s0 = _u32(
      _bitnum(input, 57, 31) |
          _bitnum(input, 49, 30) |
          _bitnum(input, 41, 29) |
          _bitnum(input, 33, 28) |
          _bitnum(input, 25, 27) |
          _bitnum(input, 17, 26) |
          _bitnum(input, 9, 25) |
          _bitnum(input, 1, 24) |
          _bitnum(input, 59, 23) |
          _bitnum(input, 51, 22) |
          _bitnum(input, 43, 21) |
          _bitnum(input, 35, 20) |
          _bitnum(input, 27, 19) |
          _bitnum(input, 19, 18) |
          _bitnum(input, 11, 17) |
          _bitnum(input, 3, 16) |
          _bitnum(input, 61, 15) |
          _bitnum(input, 53, 14) |
          _bitnum(input, 45, 13) |
          _bitnum(input, 37, 12) |
          _bitnum(input, 29, 11) |
          _bitnum(input, 21, 10) |
          _bitnum(input, 13, 9) |
          _bitnum(input, 5, 8) |
          _bitnum(input, 63, 7) |
          _bitnum(input, 55, 6) |
          _bitnum(input, 47, 5) |
          _bitnum(input, 39, 4) |
          _bitnum(input, 31, 3) |
          _bitnum(input, 23, 2) |
          _bitnum(input, 15, 1) |
          _bitnum(input, 7, 0),
    );
    final s1 = _u32(
      _bitnum(input, 56, 31) |
          _bitnum(input, 48, 30) |
          _bitnum(input, 40, 29) |
          _bitnum(input, 32, 28) |
          _bitnum(input, 24, 27) |
          _bitnum(input, 16, 26) |
          _bitnum(input, 8, 25) |
          _bitnum(input, 0, 24) |
          _bitnum(input, 58, 23) |
          _bitnum(input, 50, 22) |
          _bitnum(input, 42, 21) |
          _bitnum(input, 34, 20) |
          _bitnum(input, 26, 19) |
          _bitnum(input, 18, 18) |
          _bitnum(input, 10, 17) |
          _bitnum(input, 2, 16) |
          _bitnum(input, 60, 15) |
          _bitnum(input, 52, 14) |
          _bitnum(input, 44, 13) |
          _bitnum(input, 36, 12) |
          _bitnum(input, 28, 11) |
          _bitnum(input, 20, 10) |
          _bitnum(input, 12, 9) |
          _bitnum(input, 4, 8) |
          _bitnum(input, 62, 7) |
          _bitnum(input, 54, 6) |
          _bitnum(input, 46, 5) |
          _bitnum(input, 38, 4) |
          _bitnum(input, 30, 3) |
          _bitnum(input, 22, 2) |
          _bitnum(input, 14, 1) |
          _bitnum(input, 6, 0),
    );
    return [s0, s1];
  }

  static void _inversePermutation(int s0, int s1, Uint8List out) {
    out[3] = (_bitnumIntr(s1, 7, 7) |
        _bitnumIntr(s0, 7, 6) |
        _bitnumIntr(s1, 15, 5) |
        _bitnumIntr(s0, 15, 4) |
        _bitnumIntr(s1, 23, 3) |
        _bitnumIntr(s0, 23, 2) |
        _bitnumIntr(s1, 31, 1) |
        _bitnumIntr(s0, 31, 0)) &
        0xff;
    out[2] = (_bitnumIntr(s1, 6, 7) |
        _bitnumIntr(s0, 6, 6) |
        _bitnumIntr(s1, 14, 5) |
        _bitnumIntr(s0, 14, 4) |
        _bitnumIntr(s1, 22, 3) |
        _bitnumIntr(s0, 22, 2) |
        _bitnumIntr(s1, 30, 1) |
        _bitnumIntr(s0, 30, 0)) &
        0xff;
    out[1] = (_bitnumIntr(s1, 5, 7) |
        _bitnumIntr(s0, 5, 6) |
        _bitnumIntr(s1, 13, 5) |
        _bitnumIntr(s0, 13, 4) |
        _bitnumIntr(s1, 21, 3) |
        _bitnumIntr(s0, 21, 2) |
        _bitnumIntr(s1, 29, 1) |
        _bitnumIntr(s0, 29, 0)) &
        0xff;
    out[0] = (_bitnumIntr(s1, 4, 7) |
        _bitnumIntr(s0, 4, 6) |
        _bitnumIntr(s1, 12, 5) |
        _bitnumIntr(s0, 12, 4) |
        _bitnumIntr(s1, 20, 3) |
        _bitnumIntr(s0, 20, 2) |
        _bitnumIntr(s1, 28, 1) |
        _bitnumIntr(s0, 28, 0)) &
        0xff;
    out[7] = (_bitnumIntr(s1, 3, 7) |
        _bitnumIntr(s0, 3, 6) |
        _bitnumIntr(s1, 11, 5) |
        _bitnumIntr(s0, 11, 4) |
        _bitnumIntr(s1, 19, 3) |
        _bitnumIntr(s0, 19, 2) |
        _bitnumIntr(s1, 27, 1) |
        _bitnumIntr(s0, 27, 0)) &
        0xff;
    out[6] = (_bitnumIntr(s1, 2, 7) |
        _bitnumIntr(s0, 2, 6) |
        _bitnumIntr(s1, 10, 5) |
        _bitnumIntr(s0, 10, 4) |
        _bitnumIntr(s1, 18, 3) |
        _bitnumIntr(s0, 18, 2) |
        _bitnumIntr(s1, 26, 1) |
        _bitnumIntr(s0, 26, 0)) &
        0xff;
    out[5] = (_bitnumIntr(s1, 1, 7) |
        _bitnumIntr(s0, 1, 6) |
        _bitnumIntr(s1, 9, 5) |
        _bitnumIntr(s0, 9, 4) |
        _bitnumIntr(s1, 17, 3) |
        _bitnumIntr(s0, 17, 2) |
        _bitnumIntr(s1, 25, 1) |
        _bitnumIntr(s0, 25, 0)) &
        0xff;
    out[4] = (_bitnumIntr(s1, 0, 7) |
        _bitnumIntr(s0, 0, 6) |
        _bitnumIntr(s1, 8, 5) |
        _bitnumIntr(s0, 8, 4) |
        _bitnumIntr(s1, 16, 3) |
        _bitnumIntr(s0, 16, 2) |
        _bitnumIntr(s1, 24, 1) |
        _bitnumIntr(s0, 24, 0)) &
        0xff;
  }

  static int _desF(int state, Uint8List key) {
    final t1 = _u32(
      _bitnumIntl(state, 31, 0) |
          _u32((_u32(state & 0xF0000000)) >>> 1) |
          _bitnumIntl(state, 4, 5) |
          _bitnumIntl(state, 3, 6) |
          _u32((_u32(state & 0x0F000000)) >>> 3) |
          _bitnumIntl(state, 8, 11) |
          _bitnumIntl(state, 7, 12) |
          _u32((_u32(state & 0x00F00000)) >>> 5) |
          _bitnumIntl(state, 12, 17) |
          _bitnumIntl(state, 11, 18) |
          _u32((_u32(state & 0x000F0000)) >>> 7) |
          _bitnumIntl(state, 16, 23),
    );
    final t2 = _u32(
      _bitnumIntl(state, 15, 0) |
          _u32((_u32(state & 0x0000F000)) << 15) |
          _bitnumIntl(state, 20, 5) |
          _bitnumIntl(state, 19, 6) |
          _u32((_u32(state & 0x00000F00)) << 13) |
          _bitnumIntl(state, 24, 11) |
          _bitnumIntl(state, 23, 12) |
          _u32((_u32(state & 0x000000F0)) << 11) |
          _bitnumIntl(state, 28, 17) |
          _bitnumIntl(state, 27, 18) |
          _u32((_u32(state & 0x0000000F)) << 9) |
          _bitnumIntl(state, 0, 23),
    );

    final lrgstate = <int>[
      (t1 >>> 24) & 0xFF,
      (t1 >>> 16) & 0xFF,
      (t1 >>> 8) & 0xFF,
      (t2 >>> 24) & 0xFF,
      (t2 >>> 16) & 0xFF,
      (t2 >>> 8) & 0xFF,
    ];
    for (var i = 0; i < 6; i++) {
      lrgstate[i] ^= key[i];
    }

    final s = _u32(
      (_sbox[0][_sboxBit(lrgstate[0] >>> 2)] << 28) |
          (_sbox[1][_sboxBit(((lrgstate[0] & 0x03) << 4) |
                  (lrgstate[1] >>> 4))] <<
              24) |
          (_sbox[2][_sboxBit(((lrgstate[1] & 0x0F) << 2) |
                  (lrgstate[2] >>> 6))] <<
              20) |
          (_sbox[3][_sboxBit(lrgstate[2] & 0x3F)] << 16) |
          (_sbox[4][_sboxBit(lrgstate[3] >>> 2)] << 12) |
          (_sbox[5][_sboxBit(((lrgstate[3] & 0x03) << 4) |
                  (lrgstate[4] >>> 4))] <<
              8) |
          (_sbox[6][_sboxBit(((lrgstate[4] & 0x0F) << 2) |
                  (lrgstate[5] >>> 6))] <<
              4) |
          _sbox[7][_sboxBit(lrgstate[5] & 0x3F)],
    );

    return _u32(
      _bitnumIntl(s, 15, 0) |
          _bitnumIntl(s, 6, 1) |
          _bitnumIntl(s, 19, 2) |
          _bitnumIntl(s, 20, 3) |
          _bitnumIntl(s, 28, 4) |
          _bitnumIntl(s, 11, 5) |
          _bitnumIntl(s, 27, 6) |
          _bitnumIntl(s, 16, 7) |
          _bitnumIntl(s, 0, 8) |
          _bitnumIntl(s, 14, 9) |
          _bitnumIntl(s, 22, 10) |
          _bitnumIntl(s, 25, 11) |
          _bitnumIntl(s, 4, 12) |
          _bitnumIntl(s, 17, 13) |
          _bitnumIntl(s, 30, 14) |
          _bitnumIntl(s, 9, 15) |
          _bitnumIntl(s, 1, 16) |
          _bitnumIntl(s, 7, 17) |
          _bitnumIntl(s, 23, 18) |
          _bitnumIntl(s, 13, 19) |
          _bitnumIntl(s, 31, 20) |
          _bitnumIntl(s, 26, 21) |
          _bitnumIntl(s, 2, 22) |
          _bitnumIntl(s, 8, 23) |
          _bitnumIntl(s, 18, 24) |
          _bitnumIntl(s, 12, 25) |
          _bitnumIntl(s, 29, 26) |
          _bitnumIntl(s, 5, 27) |
          _bitnumIntl(s, 21, 28) |
          _bitnumIntl(s, 10, 29) |
          _bitnumIntl(s, 3, 30) |
          _bitnumIntl(s, 24, 31),
    );
  }

  static void _desCrypt(List<int> input, List<Uint8List> schedule, Uint8List output) {
    var perm = _initialPermutation(input);
    var s0 = perm[0];
    var s1 = perm[1];
    for (var i = 0; i < 15; i++) {
      final prev = s1;
      s1 = _u32(_desF(s1, schedule[i]) ^ s0);
      s0 = prev;
    }
    s0 = _u32(_desF(s1, schedule[15]) ^ s0);
    _inversePermutation(s0, s1, output);
  }

  static List<Uint8List> _keySchedule(Uint8List key, int mode) {
    final schedule = List.generate(16, (_) => Uint8List(6));
    var c = 0;
    var d = 0;
    for (var i = 0; i < 28; i++) {
      c = _u32(c | _bitnum(key, _keyPermC[i], 31 - i));
      d = _u32(d | _bitnum(key, _keyPermD[i], 31 - i));
    }
    for (var i = 0; i < 16; i++) {
      c = _u32((_u32(c << _keyRndShift[i]) | (c >>> (28 - _keyRndShift[i]))) &
          0xFFFFFFF0);
      d = _u32((_u32(d << _keyRndShift[i]) | (d >>> (28 - _keyRndShift[i]))) &
          0xFFFFFFF0);
      final togen = mode == _desDecrypt ? 15 - i : i;
      for (var j = 0; j < 24; j++) {
        schedule[togen][j ~/ 8] |= _bitnumIntr(c, _keyCompression[j], 7 - (j % 8));
      }
      for (var j = 24; j < 48; j++) {
        schedule[togen][j ~/ 8] |=
            _bitnumIntr(d, _keyCompression[j] - 27, 7 - (j % 8));
      }
    }
    return schedule;
  }

  static List<List<Uint8List>> _tripleDesKeySetup(Uint8List key, int mode) {
    if (mode == _desEncrypt) {
      return [
        _keySchedule(Uint8List.sublistView(key, 0, 8), _desEncrypt),
        _keySchedule(Uint8List.sublistView(key, 8, 16), _desDecrypt),
        _keySchedule(Uint8List.sublistView(key, 16, 24), _desEncrypt),
      ];
    }
    return [
      _keySchedule(Uint8List.sublistView(key, 16, 24), _desDecrypt),
      _keySchedule(Uint8List.sublistView(key, 8, 16), _desEncrypt),
      _keySchedule(Uint8List.sublistView(key, 0, 8), _desDecrypt),
    ];
  }

  static void _tripleDesCrypt(
    List<int> input,
    List<List<Uint8List>> schedule,
    Uint8List output,
  ) {
    final buf = Uint8List(8);
    _desCrypt(input, schedule[0], buf);
    _desCrypt(buf, schedule[1], output);
    _desCrypt(output, schedule[2], buf);
    output.setAll(0, buf);
  }

  static Uint8List _cryptBlocks(
    Uint8List data,
    List<List<Uint8List>> schedule,
  ) {
    final block = Uint8List(8);
    for (var i = 0; i + 8 <= data.length; i += 8) {
      _tripleDesCrypt(
        Uint8List.sublistView(data, i, i + 8),
        schedule,
        block,
      );
      data.setAll(i, block);
    }
    return data;
  }

  /// 解密 QRC 歌词；输入非 hex / 解密失败时返回 null。
  static String? decode(String? hexData) {
    if (hexData == null || hexData.isEmpty || hexData.length.isOdd) {
      return null;
    }
    final Uint8List encrypted;
    try {
      encrypted = Uint8List.fromList(_hexDecode(hexData));
    } catch (_) {
      return null;
    }
    if (encrypted.isEmpty) return null;
    final schedule = _tripleDesKeySetup(_qrcKey, _desDecrypt);
    _cryptBlocks(encrypted, schedule);
    try {
      final inflated = zlib_impl.zlibInflateTolerant(encrypted);
      if (inflated.isEmpty) return null;
      return utf8.decode(inflated, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  /// 加密 QRC（供单测做往返校验，格式与解密互逆）。
  ///
  /// [compress] 默认使用 zlib 压缩；测试可注入原字节。
  static String encode(String text, {List<int> Function(List<int>)? compress}) {
    final data = Uint8List.fromList(
      utf8.encode(text),
    );
    final compressed = compress == null
        ? zlib_impl.zlibDeflate(data)
        : compress(data);
    final padded = Uint8List((compressed.length + 7) & ~7);
    padded.setAll(0, compressed);
    final schedule = _tripleDesKeySetup(_qrcKey, _desEncrypt);
    _cryptBlocks(padded, schedule);
    return _hexEncode(padded);
  }

  static List<int> _hexDecode(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }

  static String _hexEncode(List<int> data) =>
      data.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
