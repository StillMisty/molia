/// 局域网配对的一次性密钥协商与口令密封。
///
/// 设计约束：
/// - 只支持 P-256（`prime256v1`），公钥必须是未压缩点且**在曲线上**；
/// - ECDH 共享秘密 → HKDF-SHA256（salt = 发起方 nonce || 接收方 nonce，
///   info = `molia-sync-pair-v1`）→ 32B 会话密钥；
/// - AES-256-GCM（12B nonce），AAD 绑定 requestId / intent / 双方 deviceId；
/// - 6 位确认码由双方公钥与 nonce / requestId 的 SHA-256 派生，**不经过口令**；
/// - 任何失败只抛 [PairingCryptoException]（消息不含口令 / 密钥 / 明文）。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../../../domain/models/sync_nearby_pairing.dart';

/// 配对加密失败（公钥非法 / 认证失败 / 格式错误）。
class PairingCryptoException implements Exception {
  final String message;

  const PairingCryptoException(this.message);

  @override
  String toString() => 'PairingCryptoException($message)';
}

/// 一次性的 P-256 密钥对。
///
/// 私钥在 [destroy] 后不可再用；已生成的公钥字节会被清零，避免 pending
/// 状态结束后还长期留在内存里。
class PairingKeyPair {
  PairingKeyPair._(this._privateKey, this.publicKey);

  ECPrivateKey? _privateKey;
  final Uint8List publicKey;

  bool get isDestroyed => _privateKey == null;

  ECPrivateKey get privateKey {
    final key = _privateKey;
    if (key == null) {
      throw const PairingCryptoException('临时密钥已释放');
    }
    return key;
  }

  void destroy() {
    _privateKey = null;
    publicKey.fillRange(0, publicKey.length, 0);
  }
}

/// 配对加密原语（无状态；密钥材料由调用方持有并及时释放）。
abstract final class PairingCrypto {
  /// 协议版本 / HKDF info 的固定前缀。
  static const String protocol = 'molia-sync-pair-v1';

  static const int nonceLength = 16;
  static const int gcmNonceLength = 12;
  static const int _compressedPointLength = 65;
  static const int _sealedVersion = 1;

  static final ECDomainParameters _p256 = ECDomainParameters('prime256v1');

  /// P-256 素数域（协议常量；只用于显式验证公钥在曲线上）。
  static final BigInt _p = BigInt.parse(
    'ffffffff00000001000000000000000000000000ffffffffffffffffffffffff',
    radix: 16,
  );
  static final BigInt _a = BigInt.parse(
    'ffffffff00000001000000000000000000000000fffffffffffffffffffffffc',
    radix: 16,
  );
  static final BigInt _b = BigInt.parse(
    '5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b',
    radix: 16,
  );

  /// 生成一次性 P-256 密钥对。
  static PairingKeyPair generateKeyPair() {
    final random = FortunaRandom();
    random.seed(KeyParameter(_randomBytes(32)));
    final generator = ECKeyGenerator()
      ..init(ParametersWithRandom(
        ECKeyGeneratorParameters(_p256),
        random,
      ));
    final pair = generator.generateKeyPair();
    final publicKey = pair.publicKey;
    final point = publicKey.Q;
    if (point == null || point.isInfinity) {
      throw const PairingCryptoException('临时公钥生成失败');
    }
    return PairingKeyPair._(
      pair.privateKey,
      Uint8List.fromList(point.getEncoded(false)),
    );
  }

  /// 派生会话密钥：ECDH → HKDF-SHA256（salt = nonceA || nonceB）。
  static Uint8List deriveSessionKey({
    required ECPrivateKey privateKey,
    required Uint8List peerPublicKey,
    required Uint8List initiatorNonce,
    required Uint8List receiverNonce,
  }) {
    final point = _decodePublicKey(peerPublicKey);
    final agreement = ECDHBasicAgreement()..init(privateKey);
    final shared = agreement.calculateAgreement(ECPublicKey(point, _p256));
    final secret = _unsignedBigEndian(shared, 32);
    final salt = Uint8List.fromList([...initiatorNonce, ...receiverNonce]);
    final derivator = HKDFKeyDerivator(SHA256Digest())
      ..init(HkdfParameters(
        secret,
        32,
        salt,
        Uint8List.fromList(utf8.encode(protocol)),
      ));
    return derivator.process(Uint8List(0));
  }

  /// 用会话密钥密封明文（口令）；输出 `[版本 1][GCM nonce 12][密文+tag]`。
  static Uint8List seal({
    required Uint8List key,
    required List<int> plaintext,
    required List<int> aad,
  }) {
    final nonce = _randomBytes(gcmNonceLength);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(
          KeyParameter(key),
          128,
          nonce,
          Uint8List.fromList(aad),
        ),
      );
    final encrypted = cipher.process(Uint8List.fromList(plaintext));
    return Uint8List.fromList([_sealedVersion, ...nonce, ...encrypted]);
  }

  /// 打开 [seal] 的输出；认证失败 / 结构非法抛 [PairingCryptoException]。
  static Uint8List open({
    required Uint8List key,
    required Uint8List sealed,
    required List<int> aad,
  }) {
    if (sealed.length <= 1 + gcmNonceLength + 16 ||
        sealed[0] != _sealedVersion) {
      throw const PairingCryptoException('密封载荷结构无效');
    }
    final nonce = Uint8List.sublistView(sealed, 1, 1 + gcmNonceLength);
    final cipherText = Uint8List.sublistView(sealed, 1 + gcmNonceLength);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(
          KeyParameter(key),
          128,
          nonce,
          Uint8List.fromList(aad),
        ),
      );
    try {
      return cipher.process(cipherText);
    } catch (_) {
      throw const PairingCryptoException('密封载荷认证失败');
    }
  }

  /// 6 位确认码：双方用同一份握手材料派生，用户肉眼核对。
  ///
  /// 输入包含双方公钥 / nonce / requestId / intent / deviceId；不包含口令。
  static String confirmationCode({
    required String requestId,
    required SyncPairingIntent intent,
    required String initiatorDeviceId,
    required String receiverDeviceId,
    required Uint8List initiatorNonce,
    required Uint8List receiverNonce,
    required Uint8List initiatorPublicKey,
    required Uint8List receiverPublicKey,
  }) {
    final transcript = _canonical([
      ('tag', utf8.encode('$protocol/sas')),
      ('requestId', utf8.encode(requestId)),
      ('intent', utf8.encode(intent.name)),
      ('initiator', utf8.encode(initiatorDeviceId)),
      ('receiver', utf8.encode(receiverDeviceId)),
      ('initiatorNonce', initiatorNonce),
      ('receiverNonce', receiverNonce),
      ('initiatorKey', initiatorPublicKey),
      ('receiverKey', receiverPublicKey),
    ]);
    final digest = SHA256Digest().process(transcript);
    var value = 0;
    for (var i = 0; i < 4; i++) {
      value = (value << 8) | digest[i];
    }
    return (value % 1000000).toString().padLeft(6, '0');
  }

  /// AAD：绑定 requestId / intent / 双方 deviceId（防替换 / 防跨请求重放）。
  static Uint8List aad({
    required String requestId,
    required SyncPairingIntent intent,
    required String initiatorDeviceId,
    required String receiverDeviceId,
  }) =>
      _canonical([
        ('tag', utf8.encode('$protocol/aad')),
        ('requestId', utf8.encode(requestId)),
        ('intent', utf8.encode(intent.name)),
        ('initiator', utf8.encode(initiatorDeviceId)),
        ('receiver', utf8.encode(receiverDeviceId)),
      ]);

  /// 同组证明：HMAC-SHA256(discoveryKey(passphrase), requestId)。
  ///
  /// proof 只证明「双方口令相同」，不泄露口令；它只用于跳过接受弹窗。
  static Uint8List groupProof({
    required Uint8List discoveryKey,
    required String requestId,
  }) {
    final hmac = HMac(SHA256Digest(), 64)..init(KeyParameter(discoveryKey));
    return hmac.process(Uint8List.fromList(utf8.encode(requestId)));
  }

  /// 常量时间比较（proof / 认证标签不泄露前缀匹配长度）。
  static bool constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// 公开的曲线校验入口（接收方在入队前拒绝坏公钥）。
  static ECPoint validatePublicKey(Uint8List bytes) => _decodePublicKey(bytes);

  static ECPoint _decodePublicKey(Uint8List bytes) {
    if (bytes.length != _compressedPointLength || bytes.first != 0x04) {
      throw const PairingCryptoException('对端公钥格式无效');
    }
    final ECPoint? point;
    try {
      point = _p256.curve.decodePoint(bytes);
    } catch (_) {
      throw const PairingCryptoException('对端公钥无法解析');
    }
    if (point == null || point.isInfinity) {
      throw const PairingCryptoException('对端公钥无效');
    }
    final x = point.x?.toBigInteger();
    final y = point.y?.toBigInteger();
    if (x == null ||
        y == null ||
        x < BigInt.zero ||
        x >= _p ||
        y < BigInt.zero ||
        y >= _p) {
      throw const PairingCryptoException('对端公钥超出曲线域');
    }
    // 显式曲线方程：decodePoint / createPoint 本身不校验 y² = x³ + ax + b。
    final lhs = (y * y) % _p;
    final rhs = ((x * x % _p) * x + _a * x + _b) % _p;
    if (lhs != rhs) {
      throw const PairingCryptoException('对端公钥不在曲线上');
    }
    // 子群校验（P-256 cofactor = 1，nQ 必须是无穷远点）。
    ECPoint? order;
    try {
      order = point * _p256.n;
    } catch (_) {
      throw const PairingCryptoException('对端公钥子群无效');
    }
    if (order == null || !order.isInfinity) {
      throw const PairingCryptoException('对端公钥子群无效');
    }
    return point;
  }

  static Uint8List _canonical(List<(String, List<int>)> fields) {
    final builder = BytesBuilder(copy: false);
    for (final (tag, value) in fields) {
      final tagBytes = utf8.encode(tag);
      builder.addByte(tagBytes.length & 0xff);
      builder.add(tagBytes);
      builder.addByte((value.length >> 8) & 0xff);
      builder.addByte(value.length & 0xff);
      builder.add(value);
    }
    return builder.toBytes();
  }

  static Uint8List _unsignedBigEndian(BigInt value, int length) {
    final bytes = Uint8List(length);
    var remaining = value;
    for (var i = length - 1; i >= 0; i--) {
      bytes[i] = (remaining & BigInt.from(0xff)).toInt();
      remaining = remaining >> 8;
    }
    if (remaining != BigInt.zero) {
      throw const PairingCryptoException('共享秘密长度异常');
    }
    return bytes;
  }

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }
}
