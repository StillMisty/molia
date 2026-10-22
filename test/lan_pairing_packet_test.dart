import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/transport/lan_discovery.dart';
import 'package:molia/data/sync/transport/lan_pairing_packet.dart';

/// `MSP/1` 编解码 / 限流 / 候选缓存，以及与 MSD presence 的隔离。
void main() {
  Msp1Message message({
    int type = Msp1.typeAnnounce,
    String deviceId = 'devA',
    String name = '设备A',
    int httpPort = 43210,
    List<String> addresses = const ['192.168.1.7'],
    bool hasGroup = true,
  }) =>
      Msp1Message(
        type: type,
        deviceId: deviceId,
        name: name,
        httpPort: httpPort,
        probePort: 47825,
        addresses: addresses,
        hasGroup: hasGroup,
        bootId: 'boot-1',
        nonce: 'nonce-1',
      );

  test('probe / announce 往返：字段逐项还原，body ≤512B', () {
    for (final type in [Msp1.typeProbe, Msp1.typeAnnounce]) {
      final packet = Msp1.encode(message(type: type));
      expect(utf8.decode(packet.sublist(0, 3)), 'MSP');
      expect(packet[3], Msp1.version);
      expect(packet[4], type);
      expect(packet[5], 0, reason: 'reserved 字节');
      final bodyLength = (packet[Msp1.bodyLengthOffset] << 8) |
          packet[Msp1.bodyLengthOffset + 1];
      expect(bodyLength, packet.length - Msp1.headerLength);
      expect(bodyLength, lessThanOrEqualTo(Msp1.maxBodyLength));

      final decoded = Msp1.decode(packet)!;
      expect(decoded.type, type);
      expect(decoded.deviceId, 'devA');
      expect(decoded.name, '设备A');
      expect(decoded.httpPort, 43210);
      expect(decoded.probePort, 47825);
      expect(decoded.addresses, ['192.168.1.7']);
      expect(decoded.hasGroup, isTrue);
      expect(decoded.bootId, 'boot-1');
      expect(decoded.nonce, 'nonce-1');
      expect(decoded.isProbe, type == Msp1.typeProbe);
      expect(decoded.isAnnounce, type == Msp1.typeAnnounce);
    }
  });

  test('malformed：magic / version / type / 长度 / JSON / 字段缺失一律 null', () {
    final packet = Msp1.encode(message());
    expect(Msp1.decode(Uint8List(0)), isNull);
    expect(Msp1.decode(Uint8List(4)), isNull);

    final badMagic = Uint8List.fromList(packet);
    badMagic[0] = 0x58;
    expect(Msp1.decode(badMagic), isNull);

    final badVersion = Uint8List.fromList(packet);
    badVersion[3] = 2;
    expect(Msp1.decode(badVersion), isNull);

    final unknownType = Uint8List.fromList(packet);
    unknownType[4] = 3;
    expect(Msp1.decode(unknownType), isNull);

    final badReserved = Uint8List.fromList(packet);
    badReserved[5] = 1;
    expect(Msp1.decode(badReserved), isNull);

    final badLength = Uint8List.fromList(packet);
    badLength[Msp1.bodyLengthOffset] = 0x7f;
    badLength[Msp1.bodyLengthOffset + 1] = 0xff;
    expect(Msp1.decode(badLength), isNull);

    final truncated = Uint8List.sublistView(packet, 0, packet.length - 2);
    expect(Msp1.decode(truncated), isNull);

    final notJson = _packet(Msp1.typeProbe, utf8.encode('not-json'));
    expect(Msp1.decode(notJson), isNull);

    final missingId = _packet(
      Msp1.typeProbe,
      utf8.encode(jsonEncode({'nonce': 'n', 'boot': 'b'})),
    );
    expect(Msp1.decode(missingId), isNull);

    final announceWithoutHttp = _packet(
      Msp1.typeAnnounce,
      utf8.encode(jsonEncode({
        'id': 'devA',
        'nonce': 'n',
        'boot': 'b',
        'http': 0,
      })),
    );
    expect(Msp1.decode(announceWithoutHttp), isNull,
        reason: '没有 HTTP 端点的 announce 不产生不可配对候选');
  });

  test('超长字段：编码时逐级截断，body 不超 512B', () {
    final packet = Msp1.encode(message(
      deviceId: 'd' * Msp1.maxDeviceIdLength,
      name: '很长的设备名' * 40,
      addresses: [for (var i = 0; i < 40; i++) '10.0.0.$i'],
    ));
    final bodyLength = (packet[Msp1.bodyLengthOffset] << 8) |
        packet[Msp1.bodyLengthOffset + 1];
    expect(bodyLength, lessThanOrEqualTo(Msp1.maxBodyLength));
    final decoded = Msp1.decode(packet)!;
    expect(decoded.name.runes.length, lessThanOrEqualTo(Msp1.maxNameRunes));
    expect(decoded.addresses.length, lessThanOrEqualTo(Msp1.maxAddresses));
  });

  test('bodyLen 超上限：认证前就拒绝', () {
    final packet = _packet(
      Msp1.typeProbe,
      Uint8List(Msp1.maxBodyLength + 1),
    );
    expect(Msp1.decode(packet), isNull);
  });

  test('限流：每来源 10 包/10s、全局 50 包/10s，来源表有界', () {
    final limiter = MspRateLimiter();
    for (var i = 0; i < 10; i++) {
      expect(limiter.allow('10.0.0.1', 1000 + i), isTrue);
    }
    expect(limiter.allow('10.0.0.1', 1030), isFalse);
    expect(limiter.allow('10.0.0.2', 1030), isTrue, reason: '限流按来源独立');

    final global = MspRateLimiter();
    for (var i = 0; i < 50; i++) {
      expect(global.allow('10.0.1.${i % 40}', 1000 + i), isTrue);
    }
    expect(global.allow('10.0.2.1', 1200), isFalse);

    final bounded = MspRateLimiter(
      perSourceLimit: 100,
      globalLimit: 100000,
    );
    for (var i = 0; i < 500; i++) {
      expect(bounded.allow('source-$i', 1000 + i), isTrue);
    }
    expect(bounded.sourceCount, bounded.maxSources);
  });

  test('候选缓存：按 deviceId 去重、15s TTL、上限 32', () {
    final cache = PairingCandidateCache();
    expect(
      cache.upsert(
        message: message(),
        sourceHost: '192.168.1.10',
        sourcePort: 47825,
        nowMs: 1000,
      ),
      isTrue,
    );
    expect(cache.current(1000), hasLength(1));
    expect(cache.current(1000).single.deviceId, 'devA');

    // 同一设备的新观测覆盖旧值，不新增条目。
    expect(
      cache.upsert(
        message: message(name: '设备A2'),
        sourceHost: '192.168.1.11',
        sourcePort: 47826,
        nowMs: 2000,
      ),
      isTrue,
    );
    expect(cache.current(2000), hasLength(1));
    expect(cache.current(2000).single.name, '设备A2');
    expect(cache.current(2000).single.host, '192.168.1.11');

    // 15s 过期（按最后一次观测 2000ms 起算）。
    expect(cache.current(16999), hasLength(1));
    expect(cache.current(17001), isEmpty);

    for (var i = 0; i < 40; i++) {
      cache.upsert(
        message: message(deviceId: 'dev$i'),
        sourceHost: '10.0.0.$i',
        sourcePort: 47825,
        nowMs: 20000 + i,
      );
    }
    final candidates = cache.current(20050);
    expect(candidates, hasLength(PairingCandidateCache().maxCandidates));
  });

  test('MSP 走独立通道：不写 presence / sightings，且不需要 discovery key', () async {
    const udpPort = 48041;
    var keyDerivations = 0;
    final discovery = LanDiscovery(
      deviceId: 'devLocal',
      deviceName: () => '本机',
      discoveryKeyProvider: () async {
        keyDerivations++;
        throw StateError('无口令');
      },
      httpPortProvider: () => 40000,
      localAddressesProvider: () async => const [],
      udpPort: udpPort,
      nowMs: () => DateTime.now().millisecondsSinceEpoch,
    );
    final sender = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() async {
      await discovery.stop();
      sender.close();
    });
    await discovery.start();

    final received = discovery.pairingDatagrams.first;
    final probe = Msp1.encode(message(type: Msp1.typeProbe));
    sender.send(probe, InternetAddress.loopbackIPv4, udpPort);

    final datagram = await received.timeout(const Duration(seconds: 3));
    expect(datagram.message.deviceId, 'devA');
    expect(datagram.message.isProbe, isTrue);
    expect(datagram.sourceHost, '127.0.0.1');
    expect(datagram.sourcePort, sender.port);
    // MSP 不依赖同步口令：连发现密钥都派生失败也能收到。
    expect(keyDerivations, greaterThan(0));
    expect(discovery.presence, isEmpty, reason: 'MSP 不写 presence');
  });
}

Uint8List _packet(int type, List<int> body) {
  final header = BytesBuilder()
    ..add(ascii.encode('MSP'))
    ..addByte(1)
    ..addByte(type)
    ..addByte(0)
    ..addByte((body.length >> 8) & 0xff)
    ..addByte(body.length & 0xff)
    ..add(body);
  return header.toBytes();
}
