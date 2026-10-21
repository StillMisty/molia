import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_crypto.dart';
import 'package:molia/data/sync/transport/lan_discovery.dart';

/// `MSD/1` 协议层测试：编解码、认证、截断、去重与限流。
void main() {
  const passphrase = 'ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789';
  final codec = SyncCodec(iterations: 1000);
  final key = codec.discoveryKey(passphrase);

  LanDiscoveryMessage message({
    int type = Msd1.typeAnnounce,
    String deviceId = 'devA',
    String name = '设备A',
    List<String> addresses = const ['192.168.1.7'],
    int? journalHead = 12,
  }) =>
      LanDiscoveryMessage(
        type: type,
        deviceId: deviceId,
        name: name,
        httpPort: 43210,
        probePort: 47825,
        addresses: addresses,
        snapshotId: 'snap-1',
        journalHead: journalHead,
        categories: const ['settings', 'history'],
        nonce: 'nonce-1',
        bootId: 'boot-1',
      );

  test('announce / ack round-trip：字段逐项还原', () {
    for (final type in [Msd1.typeAnnounce, Msd1.typeAck]) {
      final packet = Msd1.encode(message(type: type), key);
      final decoded = Msd1.decode(packet, key);
      expect(decoded, isNotNull);
      expect(decoded!.type, type);
      expect(decoded.deviceId, 'devA');
      expect(decoded.name, '设备A');
      expect(decoded.httpPort, 43210);
      expect(decoded.probePort, 47825);
      expect(decoded.addresses, ['192.168.1.7']);
      expect(decoded.snapshotId, 'snap-1');
      expect(decoded.journalHead, 12);
      expect(decoded.categories, ['settings', 'history']);
      expect(decoded.nonce, 'nonce-1');
      expect(decoded.bootId, 'boot-1');
      expect(decoded.isAnnounce, type == Msd1.typeAnnounce);
      expect(decoded.isAck, type == Msd1.typeAck);
    }
  });

  test('头部与 body 长度：magic / version / bodyLen 大端编码', () {
    final packet = Msd1.encode(message(), key);
    expect(utf8.decode(packet.sublist(0, 3)), 'MSD');
    expect(packet[3], Msd1.version);
    expect(packet[4], Msd1.typeAnnounce);
    final bodyLength = (packet[Msd1.bodyLengthOffset] << 8) |
        packet[Msd1.bodyLengthOffset + 1];
    expect(bodyLength, packet.length - Msd1.headerLength);
    expect(bodyLength, lessThanOrEqualTo(Msd1.maxBodyLength));
  });

  test('错误 MAC / 篡改 body / 错误版本 / 截断一律返回 null', () {
    final packet = Msd1.encode(message(), key);

    final badMac = Uint8List.fromList(packet);
    badMac[Msd1.macOffset] ^= 0xff;
    expect(Msd1.decode(badMac, key), isNull);

    final tampered = Uint8List.fromList(packet);
    tampered[tampered.length - 1] ^= 0x01;
    expect(Msd1.decode(tampered, key), isNull);

    final badVersion = Uint8List.fromList(packet);
    badVersion[3] = 2;
    expect(Msd1.decode(badVersion, key), isNull);

    final truncated = Uint8List.sublistView(packet, 0, packet.length - 3);
    expect(Msd1.decode(truncated, key), isNull);

    expect(Msd1.decode(Uint8List(0), key), isNull);
    expect(Msd1.decode(Uint8List(10), key), isNull);
  });

  test('不同口令派生不同 discoveryKey：对端解析失败', () {
    final otherKey = codec.discoveryKey(
      'ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ',
    );
    expect(otherKey, isNot(equals(key)));
    final packet = Msd1.encode(message(), key);
    expect(Msd1.decode(packet, otherKey), isNull);
    // 同一口令重复派生稳定（根密钥缓存 + 固定 info）。
    expect(codec.discoveryKey(passphrase), equals(key));
  });

  test('超长 body：name 截到 64 字、addrs 截到 8 条，整体 ≤1024B', () {
    final packet = Msd1.encode(
      message(
        name: '很长的设备名' * 40,
        addresses: [for (var i = 0; i < 40; i++) '10.0.0.$i'],
      ),
      key,
    );
    final bodyLength = (packet[Msd1.bodyLengthOffset] << 8) |
        packet[Msd1.bodyLengthOffset + 1];
    expect(bodyLength, lessThanOrEqualTo(Msd1.maxBodyLength));
    final decoded = Msd1.decode(packet, key)!;
    expect(decoded.name.runes.length, Msd1.maxNameRunes);
    expect(decoded.addresses, hasLength(Msd1.maxAddresses));
  });

  test('bodyLen 超上限 / 与包长不符：认证前就拒绝', () {
    final packet = Uint8List(Msd1.headerLength + 4);
    packet.setRange(0, 3, ascii.encode('MSD'));
    packet[3] = Msd1.version;
    packet[4] = Msd1.typeAnnounce;
    packet[Msd1.bodyLengthOffset] = 0x7f;
    packet[Msd1.bodyLengthOffset + 1] = 0xff;
    expect(Msd1.decode(packet, key), isNull);
  });

  test('旧 JSON 探测包静默丢弃：不识别、不抛错', () {
    final legacy = Uint8List.fromList(utf8.encode(jsonEncode({
      'm': 'molia-sync.probe',
      'v': 1,
      'deviceId': 'devOld',
      'port': 1234,
    })));
    expect(legacy.first, 0x7b);
    expect(Msd1.decode(legacy, key), isNull);
  });

  test('deviceId 超过 128 字符拒绝；128 字符可解析', () {
    final tooLong = Msd1.encode(
      message(deviceId: 'd' * (Msd1.maxDeviceIdLength + 1)),
      key,
    );
    expect(Msd1.decode(tooLong, key), isNull);

    final atLimit = Msd1.encode(
      message(deviceId: 'd' * Msd1.maxDeviceIdLength),
      key,
    );
    expect(Msd1.decode(atLimit, key)?.deviceId.length, Msd1.maxDeviceIdLength);
  });

  test('nonce 去重：同一 (deviceId, nonce) 30 秒内只接受一次', () {
    final cache = DiscoveryNonceCache();
    expect(cache.accept('devA', 'n1', 1000), isTrue);
    expect(cache.accept('devA', 'n1', 2000), isFalse);
    // 不同来源的相同 nonce 互不影响。
    expect(cache.accept('devB', 'n1', 2000), isTrue);
    // 30 秒窗口过后重新接受。
    expect(cache.accept('devA', 'n1', 32000), isTrue);
  });

  test('入站限流：每来源 20 包/10s、全局 100 包/10s', () {
    final limiter = DiscoveryRateLimiter();
    for (var i = 0; i < 20; i++) {
      expect(limiter.allow('10.0.0.1', 1000 + i), isTrue);
    }
    expect(limiter.allow('10.0.0.1', 1030), isFalse, reason: '单来源到上限');
    expect(limiter.allow('10.0.0.2', 1030), isTrue, reason: '限流按来源独立');

    // 10 秒后窗口滑动，旧计数清掉。
    expect(limiter.allow('10.0.0.1', 12000), isTrue);

    final global = DiscoveryRateLimiter();
    for (var i = 0; i < 100; i++) {
      expect(global.allow('10.0.1.${i % 40}', 1000 + i), isTrue);
    }
    expect(global.allow('10.0.2.1', 1200), isFalse, reason: '全局到上限');
  });

  test('来源表有界：大量不同来源不会超过上限，淘汰最久未活动者', () {
    final limiter = DiscoveryRateLimiter(
      perSourceLimit: 100,
      globalLimit: 100000,
    );
    for (var i = 0; i < 500; i++) {
      expect(limiter.allow('source-$i', 1000 + i), isTrue);
    }
    expect(limiter.sourceCount, limiter.maxSources);
    // 最早的来源已被淘汰，再出现时按新来源正常放行。
    expect(limiter.allow('source-0', 2000), isTrue);
    expect(limiter.sourceCount, limiter.maxSources);
  });
}
