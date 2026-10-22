import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/pairing/pairing_crypto.dart';
import 'package:molia/domain/models/sync_nearby_pairing.dart';

/// 配对加密：ECDH + HKDF + AES-GCM、确认码、同组证明与坏公钥拒绝。
void main() {
  const passphrase = 'ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789';
  final nonceA = Uint8List.fromList(List<int>.generate(16, (i) => i));
  final nonceB = Uint8List.fromList(List<int>.generate(16, (i) => 100 + i));

  Uint8List aad({String requestId = 'req-12345678'}) => PairingCrypto.aad(
        requestId: requestId,
        intent: SyncPairingIntent.join,
        initiatorDeviceId: 'devA',
        receiverDeviceId: 'devB',
      );

  test('ECDH 双方派生同一会话密钥（salt = nonceA || nonceB）', () {
    final a = PairingCrypto.generateKeyPair();
    final b = PairingCrypto.generateKeyPair();
    addTearDown(() {
      a.destroy();
      b.destroy();
    });
    final keyA = PairingCrypto.deriveSessionKey(
      privateKey: a.privateKey,
      peerPublicKey: b.publicKey,
      initiatorNonce: nonceA,
      receiverNonce: nonceB,
    );
    final keyB = PairingCrypto.deriveSessionKey(
      privateKey: b.privateKey,
      peerPublicKey: a.publicKey,
      initiatorNonce: nonceA,
      receiverNonce: nonceB,
    );
    expect(keyA, hasLength(32));
    expect(keyA, equals(keyB));

    // salt 不同 → 密钥不同。
    final other = PairingCrypto.deriveSessionKey(
      privateKey: b.privateKey,
      peerPublicKey: a.publicKey,
      initiatorNonce: nonceB,
      receiverNonce: nonceA,
    );
    expect(other, isNot(equals(keyA)));
  });

  test('AES-GCM 密封往返；错误密钥 / 篡改 / 错误 AAD 一律失败', () {
    final a = PairingCrypto.generateKeyPair();
    final b = PairingCrypto.generateKeyPair();
    addTearDown(() {
      a.destroy();
      b.destroy();
    });
    final key = PairingCrypto.deriveSessionKey(
      privateKey: a.privateKey,
      peerPublicKey: b.publicKey,
      initiatorNonce: nonceA,
      receiverNonce: nonceB,
    );
    final sealed = PairingCrypto.seal(
      key: key,
      plaintext: utf8.encode(passphrase),
      aad: aad(),
    );
    expect(
      utf8.decode(
        PairingCrypto.open(key: key, sealed: sealed, aad: aad()),
      ),
      passphrase,
    );
    // 密文里不应出现口令明文。
    expect(
        utf8.decode(sealed, allowMalformed: true), isNot(contains(passphrase)));

    final tampered = Uint8List.fromList(sealed);
    tampered[tampered.length - 1] ^= 0x01;
    expect(
      () => PairingCrypto.open(key: key, sealed: tampered, aad: aad()),
      throwsA(isA<PairingCryptoException>()),
    );

    final wrongRequest = PairingCrypto.aad(
      requestId: 'req-87654321',
      intent: SyncPairingIntent.join,
      initiatorDeviceId: 'devA',
      receiverDeviceId: 'devB',
    );
    expect(
      () => PairingCrypto.open(key: key, sealed: sealed, aad: wrongRequest),
      throwsA(isA<PairingCryptoException>()),
    );

    final otherKey = Uint8List(32);
    expect(
      () => PairingCrypto.open(key: otherKey, sealed: sealed, aad: aad()),
      throwsA(isA<PairingCryptoException>()),
    );
  });

  test('确认码双方一致；公钥 / nonce / intent 变化都会改变确认码', () {
    final a = PairingCrypto.generateKeyPair();
    final b = PairingCrypto.generateKeyPair();
    addTearDown(() {
      a.destroy();
      b.destroy();
    });
    String code({
      SyncPairingIntent intent = SyncPairingIntent.join,
      Uint8List? nonceAOverride,
      Uint8List? publicB,
    }) =>
        PairingCrypto.confirmationCode(
          requestId: 'req-12345678',
          intent: intent,
          initiatorDeviceId: 'devA',
          receiverDeviceId: 'devB',
          initiatorNonce: nonceAOverride ?? nonceA,
          receiverNonce: nonceB,
          initiatorPublicKey: a.publicKey,
          receiverPublicKey: publicB ?? b.publicKey,
        );

    final initiatorCode = code();
    final receiverCode = code();
    expect(initiatorCode, hasLength(6));
    expect(initiatorCode, equals(receiverCode));
    expect(
        code(intent: SyncPairingIntent.invite), isNot(equals(initiatorCode)));
    expect(
      code(nonceAOverride: Uint8List(16)),
      isNot(equals(initiatorCode)),
    );
    // 对端公钥被替换 → 确认码变化（用户据此拒绝）。
    final c = PairingCrypto.generateKeyPair();
    addTearDown(c.destroy);
    expect(code(publicB: c.publicKey), isNot(equals(initiatorCode)));
  });

  test('坏公钥拒绝：长度 / 前缀 / 不在曲线上 / 无穷远', () {
    final a = PairingCrypto.generateKeyPair();
    addTearDown(a.destroy);

    expect(
      () => PairingCrypto.validatePublicKey(Uint8List(64)),
      throwsA(isA<PairingCryptoException>()),
    );
    final compressed = Uint8List.fromList(a.publicKey);
    compressed[0] = 0x02;
    expect(
      () => PairingCrypto.validatePublicKey(compressed),
      throwsA(isA<PairingCryptoException>()),
    );

    final notOnCurve = Uint8List(65)..[0] = 0x04;
    expect(
      () => PairingCrypto.validatePublicKey(notOnCurve),
      throwsA(isA<PairingCryptoException>()),
    );

    final infinity = Uint8List(1);
    expect(
      () => PairingCrypto.validatePublicKey(infinity),
      throwsA(isA<PairingCryptoException>()),
    );
  });

  test('同组证明：同一 discovery key + requestId 一致，口令不同则不一致', () {
    final key = Uint8List.fromList(List<int>.generate(32, (i) => i * 3));
    final other = Uint8List.fromList(List<int>.generate(32, (i) => i * 5));
    final proof = PairingCrypto.groupProof(
      discoveryKey: key,
      requestId: 'req-12345678',
    );
    expect(
      proof,
      equals(
        PairingCrypto.groupProof(
          discoveryKey: key,
          requestId: 'req-12345678',
        ),
      ),
    );
    expect(
      proof,
      isNot(
        equals(
          PairingCrypto.groupProof(
            discoveryKey: other,
            requestId: 'req-12345678',
          ),
        ),
      ),
    );
    expect(
      proof,
      isNot(
        equals(
          PairingCrypto.groupProof(
            discoveryKey: key,
            requestId: 'req-87654321',
          ),
        ),
      ),
    );
    expect(PairingCrypto.constantTimeEquals(proof, proof), isTrue);
    final tampered = Uint8List.fromList(proof)..[0] ^= 1;
    expect(PairingCrypto.constantTimeEquals(proof, tampered), isFalse);
  });

  test('临时密钥释放后不可再用，公钥字节清零；toString 不含口令', () {
    final keyPair = PairingCrypto.generateKeyPair();
    expect(keyPair.publicKey, hasLength(65));
    expect(keyPair.toString(), isNot(contains(passphrase)));
    keyPair.destroy();
    expect(keyPair.isDestroyed, isTrue);
    expect(keyPair.publicKey.every((byte) => byte == 0), isTrue);
    expect(() => keyPair.privateKey, throwsA(isA<PairingCryptoException>()));
  });
}
