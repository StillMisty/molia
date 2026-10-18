import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_crypto.dart';
import 'package:molia/data/sync/sync_passphrase.dart';
import 'package:molia/data/sync/sync_payload.dart';
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

  test('加密产出 v3 帧（magic 与版本在前 4 字节）', () {
    final bytes = codec.encrypt(envelope(), passphrase);
    expect(String.fromCharCodes(bytes.sublist(0, 3)), SyncCodec.magic);
    expect(bytes[3], SyncCodec.version);
    // 帧头只有 magic + 版本 + nonce：不再携带盐与迭代数（v3 首版即协议）。
    expect(bytes.length, greaterThan(SyncCodec.headerLength + SyncCodec.tagLength));
  });

  test('小载荷不压缩：帧长 = 帧头 + tag + 明文头 + 载荷（判定阈值见常量）', () {
    final small = envelope();
    final body = SyncPayload.encode(small);
    expect(body.length, lessThan(SyncCodec.compressThreshold));
    final frame = codec.encrypt(small, passphrase);
    expect(
      frame.length,
      SyncCodec.headerLength + SyncCodec.tagLength + SyncCodec.payloadHeaderLength + body.length,
      reason: '未压缩载荷逐字节进帧（AES-GCM 不改变长度）',
    );
    expect(codec.decrypt(frame, passphrase).deviceId, 'dev-a');
  });

  test('大载荷压缩：帧长明显小于明文载荷（压缩确实生效）', () {
    final big = SyncEnvelope(
      deviceId: 'dev-a',
      producedAt: 1728640000000,
      records: {
        SyncCategory.history: [
          for (var i = 0; i < 64; i++)
            SyncRecord(
              key: 'kw|song-$i',
              version: SyncVersion(physical: 1000 + i, deviceId: 'dev-a'),
              data: {'title': '标题' * 20, 'raw': '{"songmid":"${'a' * 32}"}'},
            ),
        ],
      },
    );
    final body = SyncPayload.encode(big);
    final frame = codec.encrypt(big, passphrase);
    expect(frame.length, lessThan(body.length ~/ 2));
    expect(codec.decrypt(frame, passphrase).recordsOf(SyncCategory.history),
        hasLength(64));
  });
}
