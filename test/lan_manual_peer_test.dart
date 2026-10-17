import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_crypto.dart';
import 'package:molia/data/sync/transport/lan_sync_transport.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/ports/sync_transport.dart';

/// 局域网真实 socket 用例：权限门与手动对端地址簿（**不加**
/// `TestWidgetsFlutterBinding`——它会把 HttpClient 桩成 400，HTTP 快照拿不到）。
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

  test('局域网权限被拒：传输不启动，原因可呈现（手动地址也救不了）', () async {
    final transport = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => 'A',
      codec: codec,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA'),
      permissionGate: () async => false,
      udpPort: 47861,
    );
    addTearDown(transport.stop);

    await transport.start();

    expect(transport.isRunning, isFalse);
    expect(transport.unavailableReason, SyncUnavailableReason.permissionDenied);
    final result = await transport.pull();
    // 传输级错误带原因码与启动细节（细节只进日志 / 诊断）。
    expect(result.error?.code, SyncIssueCode.permissionDenied);
    expect(result.error?.detail, isNotNull);
    expect(transport.unavailableDetail, isNotNull);
  });

  test('stop 清掉启动失败原因：关闭后状态面不残留', () async {
    final transport = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => 'A',
      codec: codec,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA'),
      permissionGate: () async => false,
      udpPort: 47862,
    );

    await transport.start();
    expect(transport.unavailableReason, SyncUnavailableReason.permissionDenied);
    expect(transport.unavailableDetail, isNotNull);

    await transport.stop();
    expect(transport.unavailableReason, isNull);
    expect(transport.unavailableDetail, isNull);
  });

  test('此前发现过、本轮零应答：给出 discoverySilent（提示网络隔离）', () async {
    final transportA = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codec,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA'),
      udpPort: 47867,
    );
    final transportB = LanSyncTransport(
      deviceId: 'devB',
      deviceName: () => '设备B',
      codec: codec,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devB'),
      probeTargets: const [(host: '127.0.0.1', port: 47867)],
      probeWindow: const Duration(milliseconds: 150),
      udpPort: 47868,
    );
    addTearDown(() async {
      await transportA.stop();
      await transportB.stop();
    });
    await transportA.start();
    await transportB.start();

    // 第一轮：发现 A，B 记下「已成功发现过对端」。
    expect((await transportB.pull()).peersSeen, 1);

    // A 下线：零应答但此前已成功发现过 → 明确提示（手动地址 / WebDAV 是出路）。
    await transportA.stop();
    final silent = await transportB.pull();
    expect(silent.peersSeen, 0);
    expect(silent.error?.code, SyncIssueCode.discoverySilent);
  });

  test('手动对端：单播探测认领 deviceId 与端点端口', () async {
    final transportA = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codec,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA', value: 'light'),
      udpPort: 47862,
    );
    final learned = <ManualPeer>[];
    final transportB = LanSyncTransport(
      deviceId: 'devB',
      deviceName: () => '设备B',
      codec: codec,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devB'),
      manualPeersProvider: () => const [ManualPeer(host: '127.0.0.1', probePort: 47862)],
      onPeerResolved: learned.add,
      probeWindow: const Duration(milliseconds: 250),
      udpPort: 47863,
    );
    addTearDown(() async {
      await transportA.stop();
      await transportB.stop();
    });
    await transportA.start();
    await transportB.start();

    final pulled = (await transportB.pull()).envelopes;
    expect(pulled.single.deviceId, 'devA');
    expect(learned, isNotEmpty);
    expect(learned.last.deviceId, 'devA');
    expect(learned.last.httpPort, greaterThan(0));
  });

  test('地址簿学到端口后：没有广播应答也能直连', () async {
    final transportA = LanSyncTransport(
      deviceId: 'devA',
      deviceName: () => '设备A',
      codec: codec,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devA', value: 'light'),
      udpPort: 47864,
    );
    // 先接触一次拿到 A 的真实端点端口（模拟上一次同步学到的地址簿）。
    ManualPeer? learned;
    final scout = LanSyncTransport(
      deviceId: 'devScout',
      deviceName: () => 'Scout',
      codec: codec,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devScout'),
      manualPeersProvider: () =>
          const [ManualPeer(host: '127.0.0.1', probePort: 47864)],
      onPeerResolved: (peer) => learned = peer,
      probeWindow: const Duration(milliseconds: 250),
      udpPort: 47865,
    );
    addTearDown(() async {
      await transportA.stop();
      await scout.stop();
    });
    await transportA.start();
    await scout.start();
    await scout.pull();
    expect(learned, isNotNull);

    // 新实例：地址簿端点已知，但探测端口指向没人监听的端口（模拟广播/探测都
    // 不可用的网络）——纯单播直连仍然成立。
    final transportC = LanSyncTransport(
      deviceId: 'devC',
      deviceName: () => '设备C',
      codec: codec,
      passphraseProvider: () async => passphrase,
      snapshotProvider: () async => envelope('devC'),
      manualPeersProvider: () => [learned!.copyWith(probePort: 47999)],
      probeWindow: const Duration(milliseconds: 150),
      udpPort: 47866,
    );
    addTearDown(transportC.stop);
    await transportC.start();

    final pulled = (await transportC.pull()).envelopes;
    expect(pulled.single.deviceId, 'devA');
  });
}
