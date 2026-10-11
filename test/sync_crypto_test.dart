import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_crypto.dart';
import 'package:molia/data/sync/sync_passphrase.dart';
import 'package:molia/domain/models/device_sync.dart';

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
              updatedAt: 100,
              updatedBy: 'dev-a',
              data: {'v': 'dark'},
            ),
          ],
          SyncCategory.playlists: [
            const SyncRecord(
              key: '__favorites__',
              updatedAt: 200,
              updatedBy: 'dev-a',
              data: {'name': '__favorites__'},
            ),
            SyncRecord.tombstone(
              key: 'gone',
              updatedAt: 300,
              updatedBy: 'dev-a',
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
}
