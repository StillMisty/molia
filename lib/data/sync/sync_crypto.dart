import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:pointycastle/export.dart';

import '../../domain/models/device_sync.dart';
import 'sync_passphrase.dart';
import 'sync_payload.dart';

/// 快照解密失败（口令不符 / 数据损坏 / 非本协议数据）。
class SyncCryptoException implements Exception {
  final String message;

  const SyncCryptoException(this.message);

  @override
  String toString() => 'SyncCryptoException($message)';
}

/// 同步帧编解码（协议 v3）：载荷编码 → 可选压缩 → AES-256-GCM。
///
/// 帧布局：`magic(3, 'MSY') | version(1, =3) | nonce(12) | 密文 + GCM tag`，
/// 头部作为 AAD 参与认证。明文载荷由 [SyncPayload] 编解码：
/// `marker(1, =3) | codec(1) | flags(1) | body`（flags bit0 = body 为
/// raw deflate）。
///
/// 密钥派生两级，消除「每份快照一次 PBKDF2」：
/// - 根密钥 = PBKDF2(口令, 应用级固定盐, [iterations])，**会话内按口令缓存一次**；
/// - 帧密钥 = HKDF(根密钥, 帧 nonce, 固定 info)。
///
/// 帧不携带盐与迭代数：帧 nonce 已保证 (key, nonce) 唯一，宏与密码学参数都是
/// 协议常量。版本字节不匹配 / 截断 / 认证失败 / 载荷结构非法一律明确失败
/// （协议只有 v3，没有版本分支与降级，见 ADR-0003 §1）。
///
/// 小载荷（< [compressThreshold]）不压缩：压缩头与无效匹配会让几百字节的
/// 载荷反而变大（实测单条变更 239B → 250B），压缩开销也白付。
class SyncCodec {
  SyncCodec({this.iterations = 120000});

  /// 帧标识与版本（`protocolVersion` 的线上表达）。
  static const String magic = 'MSY';
  static const int version = 3;

  static const int nonceLength = 12;
  static const int tagLength = 16;
  static const int headerLength = 3 + 1 + nonceLength;

  /// 明文头：marker | payloadCodec | flags。
  static const int payloadMarker = 3;
  static const int payloadHeaderLength = 3;
  static const int _flagDeflated = 0x01;

  /// 低于该长度不压缩。
  static const int compressThreshold = 256;

  /// PBKDF2 迭代数（协议常量：v3 只有一种帧，不再随帧携带）。
  final int iterations;

  /// 根密钥盐与帧密钥 info（协议常量，随帧版本固定）。
  static final Uint8List _rootSalt = Uint8List.fromList(
    utf8.encode('molia-sync-root-v3'),
  );
  static final Uint8List _frameInfo = Uint8List.fromList(
    utf8.encode('molia-sync-frame-v3'),
  );

  /// 根密钥缓存：口令 → (迭代数, 密钥)。上限兜底异常输入（对端口令不同的帧）。
  static const int _maxCachedRoots = 4;
  final Map<String, ({int iterations, Uint8List key})> _rootKeys = {};
  int _pbkdf2Derivations = 0;
  int _decryptions = 0;

  /// 本实例执行的 PBKDF2 派生次数（断言会话内缓存生效用）。
  @visibleForTesting
  int get pbkdf2Derivations => _pbkdf2Derivations;

  /// 本实例执行的解密次数（断言「未变不拉」时没有解密用）。
  @visibleForTesting
  int get decryptions => _decryptions;

  /// 编码一份载荷（帧）：
  /// `magic + 版本 + nonce | AES-256-GCM(明文头 + 载荷)`。
  Uint8List encrypt(
    SyncEnvelope envelope,
    String passphrase, {
    int payloadCodec = SyncPayload.wireCodec,
  }) {
    final key = SyncPassphrase.normalize(passphrase);
    if (key.isEmpty) throw const SyncCryptoException('同步口令为空');
    final body = SyncPayload.encode(envelope, codec: payloadCodec);
    var flags = 0;
    var payloadBody = body;
    if (body.length >= compressThreshold) {
      final deflated = Uint8List.fromList(
        ZLibCodec(raw: true, level: 6).encode(body),
      );
      if (deflated.length < body.length) {
        payloadBody = deflated;
        flags = _flagDeflated;
      }
    }
    final plaintext = Uint8List.fromList([
      payloadMarker,
      payloadCodec,
      flags,
      ...payloadBody,
    ]);
    final nonce = _randomBytes(Random.secure(), nonceLength);
    final header = _buildHeader(nonce);
    final derived = _deriveFrameKey(key, nonce);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(derived), 128, nonce, header));
    return Uint8List.fromList([...header, ...cipher.process(plaintext)]);
  }

  /// 解码一份帧；任何帧 / 口令 / 认证 / 载荷结构失败统一抛
  /// [SyncCryptoException]。
  SyncEnvelope decrypt(Uint8List bytes, String passphrase) {
    _decryptions++;
    final key = SyncPassphrase.normalize(passphrase);
    if (key.isEmpty) throw const SyncCryptoException('同步口令为空');
    if (bytes.length <= headerLength + tagLength) {
      throw const SyncCryptoException('快照数据不完整');
    }
    final header = Uint8List.sublistView(bytes, 0, headerLength);
    for (var i = 0; i < magic.length; i++) {
      if (header[i] != magic.codeUnitAt(i)) {
        throw const SyncCryptoException('不是 Molia 同步数据');
      }
    }
    if (header[magic.length] != version) {
      throw const SyncCryptoException('同步协议版本不支持');
    }
    final nonce = Uint8List.sublistView(bytes, magic.length + 1, headerLength);
    final cipherText = Uint8List.sublistView(bytes, headerLength);
    final derived = _deriveFrameKey(key, nonce);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(derived), 128, nonce, header));
    late final Uint8List plaintext;
    try {
      plaintext = cipher.process(cipherText);
    } catch (_) {
      throw const SyncCryptoException('口令不正确或数据已损坏');
    }
    try {
      if (plaintext.length < payloadHeaderLength ||
          plaintext[0] != payloadMarker) {
        throw const SyncCryptoException('载荷结构无效');
      }
      final payloadCodec = plaintext[1];
      final flags = plaintext[2];
      var body = Uint8List.sublistView(plaintext, payloadHeaderLength);
      if (flags & _flagDeflated != 0) {
        body = Uint8List.fromList(ZLibCodec(raw: true).decode(body));
      }
      return SyncPayload.decode(body, codec: payloadCodec);
    } on SyncCryptoException {
      rethrow;
    } on SyncPayloadFormatException catch (e) {
      throw SyncCryptoException(e.message);
    } catch (_) {
      throw const SyncCryptoException('快照内容无法解析');
    }
  }

  /// 帧密钥 = HKDF(根密钥, 帧 nonce)。
  Uint8List _deriveFrameKey(String passphrase, Uint8List nonce) {
    final root = _cachedRootKey(passphrase, iterations);
    final derivator = HKDFKeyDerivator(SHA256Digest())
      ..init(HkdfParameters(root, 32, nonce, _frameInfo));
    return derivator.process(Uint8List(0));
  }

  /// 根密钥（PBKDF2）：同一（口令, 迭代数）在本实例内只派生一次。
  Uint8List _cachedRootKey(String passphrase, int iterations) {
    final cached = _rootKeys[passphrase];
    if (cached != null && cached.iterations == iterations) return cached.key;
    final derived = _deriveRootKey(passphrase, _rootSalt, iterations);
    if (_rootKeys.length >= _maxCachedRoots) {
      _rootKeys.remove(_rootKeys.keys.first);
    }
    _rootKeys[passphrase] = (iterations: iterations, key: derived);
    return derived;
  }

  static Uint8List _randomBytes(Random random, int length) {
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes;
  }

  static Uint8List _buildHeader(Uint8List nonce) {
    final header = BytesBuilder()
      ..add(utf8.encode(magic))
      ..addByte(version)
      ..add(nonce);
    return header.toBytes();
  }

  Uint8List _deriveRootKey(String passphrase, Uint8List salt, int iterations) {
    _pbkdf2Derivations++;
    final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, iterations, 32));
    return derivator.process(Uint8List.fromList(utf8.encode(passphrase)));
  }
}
