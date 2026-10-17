import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/sync_pairing.dart';

/// 配对码（`molia-pair:1:<base64url(json)>`）：往返 / 严格校验 / 归一。
void main() {
  const passphrase = 'ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789';

  SyncPairingCode roundTrip(SyncPairingCode code) =>
      SyncPairingCode.tryParse(code.encode())!;

  test('往返：设备名 / 设备 id / 口令 / 地址 / HTTP 端口原样保留', () {
    const code = SyncPairingCode(
      deviceName: '书房台式机',
      deviceId: 'dev1234567890',
      passphrase: passphrase,
      addresses: [
        SyncPairingAddress(host: '192.168.1.10', probePort: 47825),
        SyncPairingAddress(host: '2409:8a55::5', probePort: 51000),
      ],
      httpPort: 40000,
    );
    final decoded = roundTrip(code);
    expect(decoded.deviceName, '书房台式机');
    expect(decoded.deviceId, 'dev1234567890');
    expect(decoded.passphrase, passphrase);
    expect(decoded.httpPort, 40000);
    expect(decoded.addresses, const [
      SyncPairingAddress(host: '192.168.1.10', probePort: 47825),
      SyncPairingAddress(host: '2409:8a55::5', probePort: 51000),
    ]);
    expect(code.encode(), startsWith('molia-pair:1:'));
  });

  test('方括号 IPv6 与空白：归一后解析（首尾空白 / 换行容忍）', () {
    final code = const SyncPairingCode(
      deviceName: 'A',
      deviceId: 'devA',
      passphrase: passphrase,
      addresses: [SyncPairingAddress(host: '[2409:8a55::5]', probePort: 47825)],
    ).encode();
    final decoded = SyncPairingCode.tryParse('\n  $code  \n')!;
    expect(decoded.addresses.single.host, '2409:8a55::5');
  });

  test('非法输入：不是配对码 / 版本不符 / base64 损坏 / JSON 缺必填 → null', () {
    expect(SyncPairingCode.tryParse(''), isNull);
    expect(SyncPairingCode.tryParse('192.168.1.23'), isNull);
    expect(SyncPairingCode.tryParse('molia-pair:2:AAAA'), isNull);
    expect(SyncPairingCode.tryParse('molia-pair:1:not-base64!!'), isNull);

    String encodePayload(Map<String, Object?> payload) =>
        'molia-pair:1:${base64Url.encode(utf8.encode(jsonEncode(payload)))}';

    // 缺设备 id / 口令 / 空值。
    expect(
      SyncPairingCode.tryParse(encodePayload({'p': passphrase})),
      isNull,
    );
    expect(
      SyncPairingCode.tryParse(encodePayload({'i': 'devA'})),
      isNull,
    );
    expect(
      SyncPairingCode.tryParse(encodePayload({'i': '', 'p': passphrase})),
      isNull,
    );
    // 载荷不是 JSON 对象。
    expect(SyncPairingCode.tryParse('molia-pair:1:WzFd'), isNull);
    // addresses 不是数组 → 整体拒绝（结构不对）。
    expect(
      SyncPairingCode.tryParse(
          encodePayload({'i': 'devA', 'p': passphrase, 'a': 'x'})),
      isNull,
    );
  });

  test('地址条目校验：非法 host / 端口跳过，去重，最多 8 条', () {
    final payload = <String, Object?>{
      'i': 'devA',
      'p': passphrase,
      'a': [
        ['192.168.1.10', 47825],
        ['not a host', 47825],
        ['192.168.1.10', 47825],
        ['2409:8a55::5', 0],
        ['[2409:8a55::9]', 70000],
        for (var i = 0; i < 10; i++) ['10.0.0.$i', 47825],
      ],
    };
    final code = SyncPairingCode.tryParse(
      'molia-pair:1:${base64Url.encode(utf8.encode(jsonEncode(payload)))}',
    )!;
    expect(code.addresses, hasLength(SyncPairingCode.maxAddresses));
    expect(code.addresses.first,
        const SyncPairingAddress(host: '192.168.1.10', probePort: 47825));
    // 端口 0 = 用默认端口（合法）；越界端口 + 非法 host 被跳过。
    expect(
      code.addresses.any((address) => address.host == '2409:8a55::5'),
      isTrue,
    );
    expect(
      code.addresses.any((address) => address.host == '2409:8a55::9'),
      isFalse,
    );
  });

  test('HTTP 端口越界按未提供处理；缺省字段给默认值', () {
    final code = SyncPairingCode.tryParse(
      'molia-pair:1:${base64Url.encode(utf8.encode(jsonEncode({'i': 'devA', 'p': passphrase, 'h': 70000})))}',
    )!;
    expect(code.httpPort, 0);
    expect(code.deviceName, '');
    expect(code.addresses, isEmpty);
  });

  test('encode 缺必填字段抛 ArgumentError（不产出无法解析的码）', () {
    expect(
      () => const SyncPairingCode(deviceName: 'A', deviceId: '', passphrase: passphrase)
          .encode(),
      throwsArgumentError,
    );
    expect(
      () => const SyncPairingCode(deviceName: 'A', deviceId: 'devA', passphrase: '')
          .encode(),
      throwsArgumentError,
    );
  });

  test('looksLikeCode 只认前缀（带空白 / 换行）', () {
    expect(SyncPairingCode.looksLikeCode('molia-pair:1:AAAA'), isTrue);
    expect(SyncPairingCode.looksLikeCode(' \nmolia-pair:1:AAAA'), isTrue);
    expect(SyncPairingCode.looksLikeCode('molia-pairx:1:AAAA'), isFalse);
    expect(SyncPairingCode.looksLikeCode('192.168.1.23'), isFalse);
  });
}
