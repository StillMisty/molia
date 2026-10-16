import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:pointycastle/export.dart';

import '../../domain/models/device_sync.dart';
import 'sync_passphrase.dart';

/// 快照解密失败（口令不符 / 数据损坏 / 非本协议数据）。
class SyncCryptoException implements Exception {
  final String message;

  const SyncCryptoException(this.message);

  @override
  String toString() => 'SyncCryptoException($message)';
}

/// 快照编解码：gzip(JSON) → 口令派生密钥 → AES-256-GCM。
///
/// 帧结构（解密所需参数全部随帧携带，口令是唯一秘密）：
/// `magic(9) | version(1) | salt(16) | iterations(4, BE) | nonce(12) | 密文+GCM tag`
/// 头部作为 AAD 参与认证。
///
/// 密钥派生分两级，消除「每份快照一次 PBKDF2(120k)」的开销：
/// - 根密钥 = PBKDF2(口令, 应用级固定盐, 迭代数)，**会话内按（口令, 迭代数）
///   缓存一次**；
/// - 帧密钥 = HKDF(根密钥, 帧盐)（RFC 5869，info 固定）。
///
/// 帧盐仍是随机值（每帧唯一），迭代数照常随帧携带并校验；PBKDF2 用固定盐
/// 不降低离线猜口令成本（帧盐本来就随密文公开），而接收方一轮内 N 份快照
/// 只做一次 PBKDF2。
///
/// 帧版本 1 = 旧式 `PBKDF2(口令, 帧盐)` 直接派生，仍可解密（与既有快照 /
/// 未升级对端互通）；版本 2 = 上述两级派生。加密只产出版本 2。
class SyncCodec {
  SyncCodec({this.iterations = 120000});

  static const String _magic = 'MOLIASYNC';

  /// 帧版本 1：PBKDF2 直接派生（解密兼容）。
  static const int _versionPbkdf2 = 1;

  /// 帧版本 2：根密钥（PBKDF2 缓存）+ HKDF 帧密钥。
  static const int _versionHkdf = 2;

  static const int _saltLength = 16;
  static const int _iterationsLength = 4;
  static const int _nonceLength = 12;
  static const int _keyLength = 32;
  static const int _headerLength =
      _magic.length + 1 + _saltLength + _iterationsLength + _nonceLength;

  /// 根密钥的 PBKDF2 固定盐与帧密钥的 HKDF info（同属协议常量，随帧版本 2）。
  static final Uint8List _rootSalt = Uint8List.fromList(
    utf8.encode('molia-sync-root-v2'),
  );
  static final Uint8List _frameInfo = Uint8List.fromList(
    utf8.encode('molia-sync-frame-v2'),
  );

  /// PBKDF2 迭代次数（加密时写入帧头；解密按帧头值执行）。
  final int iterations;

  /// 根密钥缓存：口令 → (迭代数, 密钥)。口令通常只有一组，缓存上限兜底
  /// 异常输入（对端口令不同的帧）不会让缓存无界增长。
  static const int _maxCachedRoots = 4;
  final Map<String, ({int iterations, Uint8List key})> _rootKeys = {};
  int _pbkdf2Derivations = 0;

  /// 本实例执行的 PBKDF2 派生次数（断言会话内缓存生效用）。
  @visibleForTesting
  int get pbkdf2Derivations => _pbkdf2Derivations;

  /// 加密快照（帧版本 2）。
  Uint8List encrypt(SyncEnvelope envelope, String passphrase) {
    final key = SyncPassphrase.normalize(passphrase);
    if (key.isEmpty) throw const SyncCryptoException('同步口令为空');
    final json = utf8.encode(jsonEncode(envelope.toJson()));
    final compressed = Uint8List.fromList(gzip.encode(json));
    final random = Random.secure();
    final salt = _randomBytes(random, _saltLength);
    final nonce = _randomBytes(random, _nonceLength);
    final header = _buildHeader(_versionHkdf, salt, iterations, nonce);
    final derived = _deriveFrameKey(key, salt, iterations);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(KeyParameter(derived), 128, nonce, header),
      );
    final cipherText = cipher.process(compressed);
    return Uint8List.fromList([...header, ...cipherText]);
  }

  /// 解密快照；任何帧/口令/认证失败统一抛 [SyncCryptoException]。
  SyncEnvelope decrypt(Uint8List bytes, String passphrase) {
    final key = SyncPassphrase.normalize(passphrase);
    if (key.isEmpty) throw const SyncCryptoException('同步口令为空');
    if (bytes.length <= _headerLength) {
      throw const SyncCryptoException('快照数据不完整');
    }
    final header = Uint8List.sublistView(bytes, 0, _headerLength);
    final magic = utf8.decode(header.sublist(0, _magic.length), allowMalformed: true);
    if (magic != _magic) throw const SyncCryptoException('不是 Molia 同步数据');
    final version = header[_magic.length];
    if (version != _versionPbkdf2 && version != _versionHkdf) {
      throw const SyncCryptoException('同步协议版本不支持');
    }
    final salt = Uint8List.sublistView(
        bytes, _magic.length + 1, _magic.length + 1 + _saltLength);
    final iterations = _readUint32(
        bytes, _magic.length + 1 + _saltLength, _iterationsLength);
    if (iterations < 1000 || iterations > 5000000) {
      throw const SyncCryptoException('快照迭代参数异常');
    }
    final nonce = Uint8List.sublistView(
      bytes,
      _magic.length + 1 + _saltLength + _iterationsLength,
      _headerLength,
    );
    final cipherText = Uint8List.sublistView(bytes, _headerLength);
    final derived = version == _versionHkdf
        ? _deriveFrameKey(key, salt, iterations)
        : _deriveRootKey(key, salt, iterations);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(KeyParameter(derived), 128, nonce, header),
      );
    late final Uint8List compressed;
    try {
      compressed = cipher.process(cipherText);
    } catch (_) {
      throw const SyncCryptoException('口令不正确或数据已损坏');
    }
    try {
      final json = jsonDecode(utf8.decode(gzip.decode(compressed)));
      final envelope = SyncEnvelope.fromJson(json);
      if (envelope == null) throw const SyncCryptoException('快照格式无效');
      return envelope;
    } catch (e) {
      if (e is SyncCryptoException) rethrow;
      throw const SyncCryptoException('快照内容无法解析');
    }
  }

  /// 生成同步口令（见 [SyncPassphrase.generate]）。
  static String generatePassphrase() => SyncPassphrase.generate();

  /// 帧密钥 = HKDF(根密钥, 帧盐)。
  Uint8List _deriveFrameKey(String passphrase, Uint8List salt, int iterations) {
    final root = _cachedRootKey(passphrase, iterations);
    final derivator = HKDFKeyDerivator(SHA256Digest())
      ..init(HkdfParameters(root, _keyLength, salt, _frameInfo));
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

  static Uint8List _buildHeader(
      int version, Uint8List salt, int iterations, Uint8List nonce) {
    final header = BytesBuilder();
    header.add(utf8.encode(_magic));
    header.addByte(version);
    header.add(salt);
    final iterationBytes = Uint8List(_iterationsLength);
    iterationBytes.buffer.asByteData().setUint32(0, iterations);
    header.add(iterationBytes);
    header.add(nonce);
    return header.toBytes();
  }

  static int _readUint32(Uint8List bytes, int offset, int length) {
    final view = ByteData.sublistView(bytes, offset, offset + length);
    return view.getUint32(0);
  }

  Uint8List _deriveRootKey(String passphrase, Uint8List salt, int iterations) {
    _pbkdf2Derivations++;
    final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, iterations, _keyLength));
    return derivator.process(Uint8List.fromList(utf8.encode(passphrase)));
  }
}
