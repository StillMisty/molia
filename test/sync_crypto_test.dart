import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_crypto.dart';
import 'package:molia/data/sync/sync_passphrase.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:pointycastle/export.dart';

/// 快照编解码测试：往返、错误口令、篡改、帧格式。
void main() {
  const passphrase = 'ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789';
  final codec = SyncCodec(iterations: 2000);

  SyncEnvelope envelope() => SyncEnvelope(
        deviceId: 'dev-a',
        deviceName: '测试设备',
        producedAt: 1728640000000,
        records: {
          SyncCategory.settings: [
            const SyncRecord(
              key: 'theme_mode',
              version: SyncVersion(physical: 100, deviceId: 'dev-a'),
              data: {'v': 'dark'},
            ),
          ],
          SyncCategory.playlists: [
            const SyncRecord(
              key: '__favorites__',
              version: SyncVersion(physical: 200, deviceId: 'dev-a'),
              data: {'name': '__favorites__'},
            ),
            SyncRecord.tombstone(
              key: 'gone',
              version: const SyncVersion(physical: 300, deviceId: 'dev-a'),
              deletedAt: 300,
            ),
          ],
        },
      );

  test('加密 → 解密往返保持内容（含中文与墓碑）', () {
    final bytes = codec.encrypt(envelope(), passphrase);
    final decoded = codec.decrypt(bytes, passphrase);
    expect(decoded.deviceId, 'dev-a');
    expect(decoded.deviceName, '测试设备');
    expect(decoded.recordsOf(SyncCategory.settings).single.data, {'v': 'dark'});
    expect(decoded.recordsOf(SyncCategory.playlists).length, 2);
    expect(
      decoded.recordsOf(SyncCategory.playlists).last.deleted,
      isTrue,
    );
  });

  test('口令归一化：带分隔符 / 小写输入均可解密', () {
    final bytes = codec.encrypt(envelope(), passphrase);
    final lowercase = passphrase.toLowerCase().replaceAll('-', ' ');
    expect(codec.decrypt(bytes, lowercase).deviceId, 'dev-a');
  });

  test('错误口令解密失败', () {
    final bytes = codec.encrypt(envelope(), passphrase);
    expect(
      () => codec.decrypt(bytes, 'ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ'),
      throwsA(isA<SyncCryptoException>()),
    );
  });

  test('篡改密文认证失败', () {
    final bytes = codec.encrypt(envelope(), passphrase);
    bytes[bytes.length - 1] ^= 0xFF;
    expect(
      () => codec.decrypt(bytes, passphrase),
      throwsA(isA<SyncCryptoException>()),
    );
  });

  test('非本协议数据 / 截断数据拒绝', () {
    expect(
      () => codec.decrypt(Uint8List.fromList([1, 2, 3]), passphrase),
      throwsA(isA<SyncCryptoException>()),
    );
    final bytes = codec.encrypt(envelope(), passphrase);
    expect(
      () => codec.decrypt(Uint8List.sublistView(bytes, 0, 20), passphrase),
      throwsA(isA<SyncCryptoException>()),
    );
  });

  test('生成口令格式与归一化匹配', () {
    final generated = SyncPassphrase.generate();
    expect(generated, matches(RegExp(r'^([A-Z2-9]{4}-){7}[A-Z2-9]{4}$')));
    expect(SyncPassphrase.matches(generated.toLowerCase(), generated), isTrue);
    expect(SyncPassphrase.matches('wrong', generated), isFalse);
  });

  test('空口令加解密抛异常', () {
    expect(
      () => codec.encrypt(envelope(), ''),
      throwsA(isA<SyncCryptoException>()),
    );
  });

  test('一轮内多份快照解密只做一次 PBKDF2（根密钥会话内缓存）', () {
    final fresh = SyncCodec(iterations: 2000);
    final frames = [
      for (var i = 0; i < 5; i++) fresh.encrypt(envelope(), passphrase),
    ];
    for (final frame in frames) {
      expect(fresh.decrypt(frame, passphrase).deviceId, 'dev-a');
    }
    // 5 份快照（各自随机帧盐）→ 只派生一次根密钥。
    expect(fresh.pbkdf2Derivations, 1);
  });

  test('加密产出版本 2 帧（HKDF 派生）', () {
    final bytes = codec.encrypt(envelope(), passphrase);
    // magic(9) 之后是帧版本字节。
    expect(bytes[9], 2);
  });

  test('版本 1 帧（PBKDF2 直接派生）仍可解密', () {
    final legacy = _legacyFrame(codec.iterations, passphrase, envelope());
    expect(codec.decrypt(legacy, passphrase).deviceId, 'dev-a');
  });
}

/// 版本 1 帧（`PBKDF2(口令, 帧盐)` 直接作为 AES 密钥）：已发布版本的帧格式。
///
/// 帧头布局与当前实现一致，只有版本字节与派生方式不同；用于钉住解密兼容。
Uint8List _legacyFrame(
  int iterations,
  String passphrase,
  SyncEnvelope envelope,
) {
  final salt = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
  final nonce = Uint8List.fromList(List<int>.generate(12, (i) => i + 20));
  final header = BytesBuilder()
    ..add(utf8.encode('MOLIASYNC'))
    ..addByte(1)
    ..add(salt)
    ..add(
      Uint8List(4)..buffer.asByteData().setUint32(0, iterations),
    )
    ..add(nonce);
  final headerBytes = header.toBytes();
  final key = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(salt, iterations, 32));
  final derived = key.process(
    Uint8List.fromList(utf8.encode(SyncPassphrase.normalize(passphrase))),
  );
  final compressed = Uint8List.fromList(
    gzip.encode(utf8.encode(jsonEncode(envelope.toJson()))),
  );
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      true,
      AEADParameters(KeyParameter(derived), 128, nonce, headerBytes),
    );
  return Uint8List.fromList([...headerBytes, ...cipher.process(compressed)]);
}
