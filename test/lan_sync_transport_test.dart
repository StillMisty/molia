import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_crypto.dart';
import 'package:molia/data/sync/transport/lan_sync_transport.dart';
import 'package:molia/domain/models/device_sync.dart';

/// 局域网直连传输测试：回环上的探测、拉取、推送与口令不匹配跳过。
void main() {
  const passphrase = 'ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789';
  final codec = SyncCodec(iterations: 1000);

  SyncEnvelope envelope(String deviceId, {String value = 'v'}) => SyncEnvelope(
        deviceId: deviceId,
        deviceName: deviceId,
        producedAt: 1,
        records: {
          SyncCategory.settings: [
            SyncRecord(
              key: 'theme_mode',
              version: SyncVersion(physical: 10, deviceId: deviceId),
              data: {'v': value},
            ),
          ],
        },
      );

  test('探测 → 拉取 → 推送：两台设备交换加密快照', () async {
    final envA = envelope('devA', value: 'light');
    final envB = envelope('devB', value: 'dark');
    final transportA = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codec,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envA,
      udpPort: 47891,
    );
    final transportB = LanSyncTransport(
      deviceId: 'devB',
      deviceName: () => '设备B',
      codec: codec,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envB,
      probeTargets: const [(host: '127.0.0.1', port: 47891)],
      probeWindow: const Duration(milliseconds: 250),
      udpPort: 47892,
    );
    addTearDown(() async {
      await transportA.stop();
      await transportB.stop();
    });

    await transportA.start();
    await transportB.start();
    expect(transportA.isRunning, isTrue);

    final pulled = (await transportB.pull()).envelopes;
    expect(pulled, hasLength(1));
    expect(pulled.single.deviceId, 'devA');
    expect(
      pulled.single.recordsOf(SyncCategory.settings).single.data,
      {'v': 'light'},
    );

    final received = transportA.incoming.first;
    await transportB.push(envB);
    final inbound = await received.timeout(const Duration(seconds: 3));
    expect(inbound.deviceId, 'devB');
    expect(
      inbound.recordsOf(SyncCategory.settings).single.data,
      {'v': 'dark'},
    );
  });

  test('口令不同的对端返回空结果（解密失败静默跳过）', () async {
    final transportA = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codec,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA'),
      udpPort: 47893,
    );
    final transportC = LanSyncTransport(
      deviceId: 'devC',
      deviceName: () => '设备C',
      codec: codec,
      passphraseProvider: () async =>
          'ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ',
      snapshotProvider: () async => envelope('devC'),
      probeTargets: const [(host: '127.0.0.1', port: 47893)],
      probeWindow: const Duration(milliseconds: 250),
      udpPort: 47894,
    );
    addTearDown(() async {
      await transportA.stop();
      await transportC.stop();
    });
    await transportA.start();
    await transportC.start();

    final mismatched = await transportC.pull();
    expect(mismatched.envelopes, isEmpty);
    // 唯一对端解密失败 = 不可达：不算接触成功。
    expect(mismatched.contacted, isFalse);
  });

  test('对端 snapshotId 未变：跳过 GET 并计入 skippedUnchanged', () async {
    var envA = envelope('devA', value: 'light').withSnapshotId('hash-1');
    var ownSnapshotId = 'hash-1';
    final transportA = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codec,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envA,
      snapshotIdProvider: () => ownSnapshotId,
      udpPort: 47896,
    );
    final transportB = LanSyncTransport(
      deviceId: 'devB',
      deviceName: () => '设备B',
      codec: codec,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devB'),
      probeTargets: const [(host: '127.0.0.1', port: 47896)],
      probeWindow: const Duration(milliseconds: 250),
      udpPort: 47897,
    );
    addTearDown(() async {
      await transportA.stop();
      await transportB.stop();
    });
    await transportA.start();
    await transportB.start();

    final first = await transportB.pull();
    expect(first.envelopes, hasLength(1));
    expect(first.skippedUnchanged, 0);
    // 第一次拉到快照 = 一次 GET（本用例用单播目标，不涉及广播）。
    expect(transportB.snapshotGetCount, 1);
    expect(transportB.broadcastCount, 0);

    // 探测应答的内容指纹与上次拉到的一致：不 GET、不解密、不传字节。
    final decryptionsBefore = codec.decryptions;
    final derivationsBefore = codec.pbkdf2Derivations;
    final second = await transportB.pull();
    expect(second.envelopes, isEmpty);
    expect(second.skippedUnchanged, 1);
    expect(second.bytesIn, 0);
    expect(codec.decryptions, decryptionsBefore,
        reason: '未变跳过：没有解密动作');
    expect(codec.pbkdf2Derivations, derivationsBefore,
        reason: '未变跳过：没有密钥派生');
    expect(transportB.snapshotGetCount, 1, reason: '未变跳过：没有 GET');

    // 对端内容变化（新指纹）：重新拉取。
    envA = envelope('devA', value: 'dark').withSnapshotId('hash-2');
    ownSnapshotId = 'hash-2';
    final third = await transportB.pull();
    expect(third.envelopes, hasLength(1));
    expect(third.skippedUnchanged, 0);
    expect(
      third.envelopes.single.recordsOf(SyncCategory.settings).single.data,
      {'v': 'dark'},
    );
  });

  test('未启动时 pull/push 为空操作；start/stop 幂等', () async {
    final transport = LanSyncTransport(
      deviceId: 'devX',
      deviceName: () => 'X',
      codec: codec,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devX'),
      udpPort: 47895,
    );
    expect((await transport.pull()).envelopes, isEmpty);
    await transport.push(envelope('devX'));
    await transport.start();
    await transport.start();
    expect(transport.isRunning, isTrue);
    await transport.stop();
    await transport.stop();
    expect(transport.isRunning, isFalse);
  });
}
