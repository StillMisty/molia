import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_codec_isolate.dart';
import 'package:molia/data/sync/sync_crypto.dart';
import 'package:molia/domain/models/device_sync.dart';

/// worker isolate 编解码端口测试：往返、错误传播、释放、不占主 isolate。
void main() {
  const passphrase = 'ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789';

  SyncEnvelope envelope({int records = 1}) => SyncEnvelope(
        deviceId: 'dev-a',
        deviceName: '测试设备',
        producedAt: 1728640000000,
        records: {
          SyncCategory.playlistTracks: [
            for (var i = 0; i < records; i++)
              SyncRecord(
                key: '__favorites__|kw|song-$i',
                version: SyncVersion(physical: 1728640000000 + i, deviceId: 'dev-a'),
                data: {
                  'sourceKey': 'kw',
                  'songId': 'song-$i',
                  'title': '夜曲 $i',
                  'raw': '{"songmid":"0123456789abcdef${'0' * 8}",'
                      '"hash":"${'f' * 32}"}',
                },
              ),
          ],
        },
      );

  test('往返：编码与解码在 worker 内完成，结果与进程内实现一致', () async {
    final port = IsolateSyncCodecPort(iterations: 2000);
    addTearDown(port.dispose);

    final bytes = await port.encrypt(envelope(records: 4), passphrase);
    final decoded = await port.decrypt(bytes, passphrase);

    expect(port.workerReady, isTrue);
    expect(decoded.deviceId, 'dev-a');
    expect(decoded.recordsOf(SyncCategory.playlistTracks), hasLength(4));
    expect(
      decoded.recordsOf(SyncCategory.playlistTracks).first.data!['title'],
      '夜曲 0',
    );
  });

  test('口令不符经 worker 回传为 SyncCryptoException', () async {
    final port = IsolateSyncCodecPort(iterations: 2000);
    addTearDown(port.dispose);

    final bytes = await port.encrypt(envelope(), passphrase);
    await expectLater(
      port.decrypt(bytes, 'ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ'),
      throwsA(isA<SyncCryptoException>()),
    );
  });

  test('释放后调用立即失败且幂等', () async {
    final port = IsolateSyncCodecPort(iterations: 2000);
    await port.encrypt(envelope(), passphrase);
    await port.dispose();
    await port.dispose();
    await expectLater(
      port.encrypt(envelope(), passphrase),
      throwsA(isA<StateError>()),
    );
  });

  test('重载荷编码期间主 isolate 事件循环不被占（定时器照常触发）', () async {
    final port = IsolateSyncCodecPort(iterations: 2000);
    addTearDown(port.dispose);

    // 先热身：启动 worker（首次调用含 isolate 启动开销）。
    await port.encrypt(envelope(), passphrase);

    final order = <String>[];
    final pending = port.encrypt(envelope(records: 4000), passphrase);
    Timer(const Duration(milliseconds: 1), () => order.add('timer'));
    await pending;
    expect(
      order,
      contains('timer'),
      reason: '进程内实现会在返回 Future 前同步做完编码，这里验证工作确实在 worker 里',
    );
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('worker 帧可被进程内实现解码（同一协议）', () async {
    final port = IsolateSyncCodecPort(iterations: 2000);
    addTearDown(port.dispose);
    final bytes = await port.encrypt(envelope(records: 2), passphrase);
    final decoded = SyncCodec(iterations: 2000).decrypt(bytes, passphrase);
    expect(decoded.recordsOf(SyncCategory.playlistTracks), hasLength(2));
  });
}
