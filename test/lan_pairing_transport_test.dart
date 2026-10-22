import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/pairing/lan_pairing_service.dart';
import 'package:molia/data/sync/sync_codec_port.dart';
import 'package:molia/data/sync/sync_crypto.dart';
import 'package:molia/data/sync/sync_passphrase.dart';
import 'package:molia/data/sync/transport/lan_pairing_packet.dart';
import 'package:molia/data/sync/transport/lan_sync_transport.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/models/sync_nearby_pairing.dart';

/// 回环端到端：两个真实 `LanSyncTransport` 走 UDP 发现 + HTTP 配对。
void main() {
  const passA = 'AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH';
  const passB = 'BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH-JJJJ';
  final codec = SyncCodec(iterations: 1000);
  final codecPort = InlineSyncCodecPort(codec);

  SyncEnvelope envelope(String deviceId) => SyncEnvelope(
        deviceId: deviceId,
        deviceName: deviceId,
        producedAt: 1,
      );

  test('发现 + join：真实传输完成配对，新口令可解真实载荷', () async {
    final a = await _LanPeer.start(
      id: 'devA',
      name: '设备A',
      passphrase: null,
      hasGroup: false,
      udpPort: 48371,
      codec: codecPort,
      envelope: () => envelope('devA'),
    );
    final b = await _LanPeer.start(
      id: 'devB',
      name: '设备B',
      passphrase: passB,
      hasGroup: true,
      udpPort: 48372,
      codec: codecPort,
      envelope: () => envelope('devB'),
    );
    addTearDown(() async {
      await a.dispose();
      await b.dispose();
    });

    // 手动单播一条 MSP probe（回环上广播不可靠），走真实发现 socket。
    final nearbyFuture = a.service.nearbyDevices.firstWhere(
      (devices) => devices.isNotEmpty,
    );
    expect(await a.service.startScan(), isTrue);
    final probe = Msp1.encode(Msp1Message(
      type: Msp1.typeProbe,
      deviceId: a.id,
      name: a.name,
      httpPort: a.transport.httpPort,
      probePort: a.transport.advertisedProbePort,
      addresses: const [],
      hasGroup: a.hasGroup,
      bootId: 'boot-a',
      nonce: 'probe-nonce',
    ));
    expect(
      await a.transport.sendPairingDatagram(
        probe,
        host: '127.0.0.1',
        port: b.transport.discoveryPorts.v4,
      ),
      isTrue,
    );
    final nearby = await nearbyFuture.timeout(const Duration(seconds: 3));
    expect(nearby.single.deviceId, 'devB');
    expect(nearby.single.httpPort, b.transport.httpPort);
    // MSP 不写 MSD presence：双方都还没跑同步轮次。
    expect(a.transport.presenceCount, 0);
    expect(b.transport.presenceCount, 0);

    final promptFuture = b.service.incomingRequests.first;
    final resultFuture = a.service.requestPairing(nearby.single);
    final prompt = await promptFuture.timeout(const Duration(seconds: 3));
    expect(prompt.peerDeviceId, 'devA');
    expect(prompt.code, hasLength(6));
    expect(
      await b.service.respond(prompt.requestId, accept: true),
      SyncPairingOutcome.accepted,
    );
    final result = await resultFuture.timeout(const Duration(seconds: 3));
    expect(result.outcome, SyncPairingOutcome.accepted);
    expect(a.passphrase, passB);
    expect(a.endpoints.map((e) => e.deviceId), contains('devB'));
    expect(b.endpoints.map((e) => e.deviceId), contains('devA'));

    final decrypted = codec.decrypt(
      codec.encrypt(envelope('devB'), a.passphrase!),
      b.passphrase!,
    );
    expect(decrypted.deviceId, 'devB');
  });

  test('invite：真实传输把发起方口令交给接收方', () async {
    final a = await _LanPeer.start(
      id: 'devA',
      name: '设备A',
      passphrase: passA,
      hasGroup: true,
      udpPort: 48373,
      codec: codecPort,
      envelope: () => envelope('devA'),
    );
    final b = await _LanPeer.start(
      id: 'devB',
      name: '设备B',
      passphrase: null,
      hasGroup: false,
      udpPort: 48374,
      codec: codecPort,
      envelope: () => envelope('devB'),
    );
    addTearDown(() async {
      await a.dispose();
      await b.dispose();
    });

    final nearby = SyncNearbyDevice(
      deviceId: b.id,
      name: b.name,
      host: '127.0.0.1',
      httpPort: b.transport.httpPort,
      probePort: b.transport.advertisedProbePort,
      lastSeenAt: DateTime.now().millisecondsSinceEpoch,
    );
    final promptFuture = b.service.incomingRequests.first;
    final resultFuture = a.service.requestPairing(nearby);
    final prompt = await promptFuture.timeout(const Duration(seconds: 3));
    expect(prompt.intent, SyncPairingIntent.invite);
    await b.service.respond(prompt.requestId, accept: true);
    final result = await resultFuture.timeout(const Duration(seconds: 3));
    expect(result.outcome, SyncPairingOutcome.accepted);
    expect(b.passphrase, passA);
    expect(b.endpoints.map((e) => e.deviceId), contains('devA'));
  });

  test('旧路径 / 未知路径 404；配对停止后 HTTP 不再接受请求', () async {
    final b = await _LanPeer.start(
      id: 'devB',
      name: '设备B',
      passphrase: passB,
      hasGroup: true,
      udpPort: 48375,
      codec: codecPort,
      envelope: () => envelope('devB'),
    );
    addTearDown(b.dispose);

    Future<int> status(String path) async {
      final client = HttpClient();
      try {
        final request = await client
            .getUrl(Uri.parse('http://127.0.0.1:${b.transport.httpPort}$path'));
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      } finally {
        client.close(force: true);
      }
    }

    expect(await status('/molia-sync/v1/pair/status?id=x'), 404);
    expect(await status('/molia-sync/v2/pair/unknown'), 404);
    expect(await status('/molia-sync/v2/pair/status'), 400);

    await b.transport.stop();
    // 传输停止 = HTTP 端点关闭；配对服务同时停止，不能残留监听。
    await expectLater(
      status('/molia-sync/v2/pair/status?id=x'),
      throwsA(isA<SocketException>()),
    );
  });
}

class _LanPeer {
  _LanPeer({
    required this.id,
    required this.name,
    required this.transport,
    required this.service,
    required this.endpoints,
  });

  final String id;
  final String name;
  final LanSyncTransport transport;
  final LanPairingService service;
  final List<LanPeerEndpoint> endpoints;

  String? passphrase;
  bool hasGroup = false;

  static Future<_LanPeer> start({
    required String id,
    required String name,
    required String? passphrase,
    required bool hasGroup,
    required int udpPort,
    required SyncCodecPort codec,
    required SyncEnvelope Function() envelope,
  }) async {
    final pairingCodec = SyncCodec(iterations: 1000);
    final endpoints = <LanPeerEndpoint>[];
    late final _LanPeer peer;
    final transport = LanSyncTransport(
      deviceId: id,
      deviceName: () => name,
      codec: codec,
      passphraseProvider: () async => peer.passphrase,
      snapshotProvider: () async => envelope(),
      localAddressesProvider: () async => const [],
      udpPort: udpPort,
      probeWindow: const Duration(milliseconds: 300),
    );
    final service = LanPairingService(
      deviceId: id,
      deviceName: () => name,
      readPassphrase: () async => peer.passphrase,
      writePassphrase: (value) async => peer.passphrase = value,
      ensurePassphrase: () async {
        final existing = peer.passphrase;
        if (existing != null &&
            SyncPassphrase.normalize(existing).length >= 16) {
          return existing;
        }
        final generated = SyncPassphrase.generate();
        peer.passphrase = generated;
        return generated;
      },
      hasGroup: () => peer.hasGroup,
      canPrompt: () => true,
      isCellular: () => false,
      httpPortProvider: () => transport.httpPort,
      probePortProvider: () => transport.advertisedProbePort,
      localAddressesProvider: () async => const [],
      addPeerEndpoint: (endpoint) async => endpoints.add(endpoint),
      discoveryKeyProvider: (value) async => pairingCodec.discoveryKey(value),
      packets: transport.pairingDatagrams,
      sendPacket: transport.sendPairingDatagram,
    );
    transport.attachPairing(service);
    peer = _LanPeer(
      id: id,
      name: name,
      transport: transport,
      service: service,
      endpoints: endpoints,
    )
      ..passphrase = passphrase
      ..hasGroup = hasGroup;
    await transport.start();
    return peer;
  }

  Future<void> dispose() async {
    await transport.stop();
    await service.dispose();
  }
}
