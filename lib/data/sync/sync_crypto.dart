import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

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

/// 快照编解码：gzip(JSON) → PBKDF2(口令) → AES-256-GCM。
///
/// 帧结构（解密所需参数全部随帧携带，口令是唯一秘密）：
/// `magic(9) | version(1) | salt(16) | iterations(4, BE) | nonce(12) | 密文+GCM tag`
/// 头部作为 AAD 参与认证；同一口令 + 不同 salt 派生不同密钥，故不缓存密钥。
class SyncCodec {
  const SyncCodec({this.iterations = 120000});

  static const String _magic = 'MOLIASYNC';
  static const int _version = 1;
  static const int _saltLength = 16;
  static const int _iterationsLength = 4;
  static const int _nonceLength = 12;
  static const int _keyLength = 32;
  static const int _headerLength =
      _magic.length + 1 + _saltLength + _iterationsLength + _nonceLength;

  /// PBKDF2 迭代次数（帧头携带；解密按帧头值执行）。
  final int iterations;

  /// 加密快照。
  Uint8List encrypt(SyncEnvelope envelope, String passphrase) {
    final key = SyncPassphrase.normalize(passphrase);
    if (key.isEmpty) throw const SyncCryptoException('同步口令为空');
    final json = utf8.encode(jsonEncode(envelope.toJson()));
    final compressed = Uint8List.fromList(gzip.encode(json));
    final random = Random.secure();
    final salt = _randomBytes(random, _saltLength);
    final nonce = _randomBytes(random, _nonceLength);
    final header = _buildHeader(salt, iterations, nonce);
    final derived = _deriveKey(key, salt, iterations);
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
    if (header[_magic.length] != _version) {
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
    final derived = _deriveKey(key, salt, iterations);
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

  /// 生成同步口令（见 [SyncPassphrase.generate]，保留入口兼容旧调用）。
  static String generatePassphrase() => SyncPassphrase.generate();

  static Uint8List _randomBytes(Random random, int length) {
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes;
  }

  static Uint8List _buildHeader(
      Uint8List salt, int iterations, Uint8List nonce) {
    final header = BytesBuilder();
    header.add(utf8.encode(_magic));
    header.addByte(_version);
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

  static Uint8List _deriveKey(String passphrase, Uint8List salt, int iterations) {
    final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, iterations, _keyLength));
    return derivator.process(Uint8List.fromList(utf8.encode(passphrase)));
  }
}
