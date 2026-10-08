import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

import 'lx_zlib_stub.dart' if (dart.library.io) 'lx_zlib_io.dart' as zlib_impl;

/// 绑定给 LX 脚本的同步工具函数实现。
///
/// 这些函数通过 flutter_js 的 JSInvokable 机制以同步 FFI 调用的形式暴露给 JS，
/// 因此必须保持同步执行。对应 `globalThis.lx.utils` 中：
/// - `crypto.md5 / aesEncrypt / rsaEncrypt / randomBytes`
/// - `zlib.inflate / deflate`
class LxNativeUtils {
  LxNativeUtils._();

  /// md5 十六进制摘要。
  static String md5(String str) {
    return crypto.md5.convert(utf8.encode(str)).toString();
  }

  /// AES 加密（默认 PKCS7 padding，支持 aes-128/192/256-cbc/ecb）。
  static Uint8List aesEncrypt(
    Uint8List buffer,
    String mode,
    dynamic key,
    dynamic iv,
  ) {
    final match = RegExp(r'aes-(\d+)-(cbc|ecb)', caseSensitive: false)
        .firstMatch(mode);
    if (match == null) {
      throw StateError('Unsupported AES mode: $mode');
    }
    final keyBits = int.parse(match.group(1)!);
    final modeName = match.group(2)!.toLowerCase();
    final keyBytes = _toBytes(key);
    final expectedKeyLen = keyBits ~/ 8;
    if (keyBytes.length != expectedKeyLen) {
      throw StateError(
          'Invalid AES key length: ${keyBytes.length}, expected $expectedKeyLen for $mode');
    }
    final ivBytes = modeName == 'ecb' ? Uint8List(0) : _toBytes(iv);
    if (modeName == 'cbc' && ivBytes.length != 16) {
      throw StateError('Invalid AES iv length: ${ivBytes.length}');
    }

    final engine = modeName == 'cbc'
        ? CBCBlockCipher(AESEngine())
        : ECBBlockCipher(AESEngine());
    final cipher = PaddedBlockCipherImpl(PKCS7Padding(), engine);
    final params = modeName == 'cbc'
        ? PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
            ParametersWithIV<KeyParameter>(KeyParameter(keyBytes), ivBytes),
            null,
          )
        : PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
            KeyParameter(keyBytes),
            null,
          );
    cipher.init(true, params);
    return cipher.process(buffer);
  }

  /// RSA 公钥加密（NO_PADDING，等价于 Node.js 的 RSA_NO_PADDING）。
  static Uint8List rsaEncrypt(Uint8List buffer, String publicKeyPem) {
    final key = _RsaPublicKey.parse(publicKeyPem);
    var message = _bytesToBigInt(buffer);
    final modulus = key.modulus;
    // 与 Node 行为接近：数据不能超过模数
    if (message >= modulus) {
      message = message % modulus;
    }
    final encrypted = message.modPow(key.exponent, modulus);
    return _bigIntToBytes(encrypted, key.modulusByteLength);
  }

  /// 加密安全的随机字节。
  static Uint8List randomBytes(int size) {
    if (size <= 0) return Uint8List(0);
    final random = Random.secure();
    final bytes = Uint8List(size);
    for (var i = 0; i < size; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes;
  }

  static Uint8List zlibInflate(Uint8List data) =>
      Uint8List.fromList(zlib_impl.zlibInflate(data));

  static Uint8List zlibDeflate(Uint8List data) =>
      Uint8List.fromList(zlib_impl.zlibDeflate(data));

  static Uint8List _toBytes(dynamic value) {
    if (value == null) return Uint8List(0);
    if (value is Uint8List) return value;
    if (value is List<int>) return Uint8List.fromList(value);
    if (value is String) return Uint8List.fromList(utf8.encode(value));
    if (value is List) {
      return Uint8List.fromList(value.map((e) => (e as num).toInt()).toList());
    }
    throw StateError('Cannot convert ${value.runtimeType} to bytes');
  }

  static BigInt _bytesToBigInt(Uint8List bytes) {
    var result = BigInt.zero;
    for (final byte in bytes) {
      result = (result << 8) | BigInt.from(byte);
    }
    return result;
  }

  static Uint8List _bigIntToBytes(BigInt value, int length) {
    final result = Uint8List(length);
    var v = value;
    final mask = BigInt.from(0xff);
    for (var i = length - 1; i >= 0; i--) {
      result[i] = (v & mask).toInt();
      v = v >> 8;
    }
    return result;
  }
}

/// 极简 DER 解析结果，仅覆盖 RSA 公钥需要的结构。
class _RsaPublicKey {
  final BigInt modulus;
  final BigInt exponent;

  const _RsaPublicKey(this.modulus, this.exponent);

  int get modulusByteLength => (modulus.bitLength + 7) ~/ 8;

  static _RsaPublicKey parse(String pem) {
    final body = pem
        .replaceAll(RegExp(r'-----(BEGIN|END)[^-]+-----'), '')
        .replaceAll(RegExp(r'\s'), '');
    if (body.isEmpty) throw const FormatException('Invalid RSA public key');
    final der = base64.decode(body);
    var node = _DerReader(der).readSequence();
    // SPKI: SEQUENCE { AlgorithmIdentifier, BIT STRING { RSAPublicKey } }
    if (node.peekTag() == 0x30) {
      node.readSequence(); // 跳过 AlgorithmIdentifier
      node = node.readBitString();
    }
    // PKCS#1 RSAPublicKey: SEQUENCE { INTEGER n, INTEGER e }
    if (node.peekTag() == 0x30) {
      node = node.readSequence();
    }
    final n = node.readInteger();
    final e = node.readInteger();
    return _RsaPublicKey(n, e);
  }
}

class _DerReader {
  final Uint8List bytes;
  int offset = 0;

  _DerReader(this.bytes);

  int peekTag() => offset < bytes.length ? bytes[offset] : -1;

  int _readLength() {
    var length = bytes[offset++];
    if (length & 0x80 != 0) {
      final count = length & 0x7f;
      length = 0;
      for (var i = 0; i < count; i++) {
        length = (length << 8) | bytes[offset++];
      }
    }
    return length;
  }

  /// 读取一个 TLV，校验 tag 并返回内容切片。
  Uint8List _readElement(int expectedTag) {
    if (offset >= bytes.length) {
      throw const FormatException('Unexpected end of DER data');
    }
    final tag = bytes[offset++];
    if (tag != expectedTag) {
      throw FormatException(
          'Unexpected DER tag 0x${tag.toRadixString(16)}, expected 0x${expectedTag.toRadixString(16)}');
    }
    final length = _readLength();
    final start = offset;
    offset += length;
    if (offset > bytes.length) {
      throw const FormatException('Invalid DER length');
    }
    return Uint8List.sublistView(bytes, start, offset);
  }

  _DerReader readSequence() => _DerReader(_readElement(0x30));

  BigInt readInteger() =>
      LxNativeUtils._bytesToBigInt(_readElement(0x02));

  _DerReader readBitString() {
    final content = _readElement(0x03);
    var c = content;
    // 跳过 unused bits 字节
    if (c.isNotEmpty && c[0] == 0) {
      c = Uint8List.sublistView(c, 1);
    }
    return _DerReader(c);
  }
}
