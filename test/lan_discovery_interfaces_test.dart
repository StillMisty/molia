import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_crypto.dart';
import 'package:molia/data/sync/transport/lan_discovery.dart';

/// 按接口 IPv4 发现：绑定范围、地址变化、失败降级与稳定探测端口。
void main() {
  const passphrase = 'ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789';
  final codec = SyncCodec(iterations: 1000);
  final key = codec.discoveryKey(passphrase);

  LanDiscovery build({
    required List<_BindCall> calls,
    required Future<List<String>> Function() addresses,
    Map<String, InternetAddress> redirect = const {},
    Set<String> failing = const {},
  }) {
    return LanDiscovery(
      deviceId: 'devA',
      deviceName: () => '设备A',
      discoveryKeyProvider: () async => key,
      httpPortProvider: () => 43210,
      probePortProvider: () => 47825,
      localAddressesProvider: addresses,
      udpBinder: _binder(calls, redirect: redirect, failing: failing),
      udpPort: 0,
    );
  }

  test('只为可路由 IPv4 建接口 socket：IPv6 / 回环 / link-local 跳过', () async {
    final calls = <_BindCall>[];
    final discovery = build(
      calls: calls,
      addresses: () async => const [
        '192.168.1.10',
        '10.0.0.5',
        '2409:8a55::1',
        '127.0.0.1',
        '169.254.10.1',
      ],
      redirect: _loopbackRedirect(['192.168.1.10', '10.0.0.5']),
    );
    addTearDown(discovery.stop);
    await discovery.start();

    expect(discovery.debugInterfaceBindAddresses, [
      '192.168.1.10',
      '10.0.0.5',
    ], reason: '只有两个可路由 IPv4 需要独立 socket');
    expect(
      calls.where((call) => call.address == '2409:8a55::1'),
      isEmpty,
      reason: 'IPv6 不建接口 socket（发送仍走主 socket）',
    );
    expect(
      calls.where((call) => call.address == '127.0.0.1'),
      isEmpty,
      reason: '回环不建接口 socket',
    );
    expect(
      calls.where((call) => call.address == '169.254.10.1'),
      isEmpty,
      reason: 'link-local 不建接口 socket',
    );

    final mainV4 = calls.where((call) => call.address == '0.0.0.0').toList();
    expect(mainV4, hasLength(1), reason: '主 v4 socket 仍绑定 wildcard');
    expect(mainV4.single.port, 0);
    for (final host in ['192.168.1.10', '10.0.0.5']) {
      final bind = calls.where((call) => call.address == host).toList();
      expect(bind, hasLength(1), reason: '$host 只绑一次');
      expect(bind.single.port, 0, reason: '接口 socket 用系统分配端口');
    }
    expect(discovery.debugInterfacePorts, everyElement(greaterThan(0)));
    expect(discovery.discoveryPorts.v4, greaterThan(0));
    expect(
      discovery.advertisedProbePort,
      discovery.discoveryPorts.v4,
      reason: '对外探测端口仍是主 socket，不是接口临时端口',
    );
  });

  test('地址变化后重建接口 socket：新地址出现、旧地址消失', () async {
    var addresses = <String>['192.168.1.10'];
    final calls = <_BindCall>[];
    final discovery = build(
      calls: calls,
      addresses: () async => addresses,
      redirect: _loopbackRedirect(['192.168.1.10', '10.0.0.5']),
    );
    addTearDown(discovery.stop);
    await discovery.start();
    expect(discovery.debugInterfaceBindAddresses, ['192.168.1.10']);

    addresses = ['10.0.0.5'];
    await discovery.onNetworkChanged();

    expect(discovery.debugInterfaceBindAddresses, ['10.0.0.5']);
    expect(
      calls.where((call) => call.address == '192.168.1.10'),
      hasLength(1),
      reason: '旧地址只绑过一次，换网只关闭不再重绑',
    );
    expect(calls.where((call) => call.address == '10.0.0.5'), hasLength(1));
    expect(discovery.discoveryPorts.v4, greaterThan(0));
  });

  test('IPv6 混排在前且 IPv4 超过 8 个：完整接口仍全部建 socket', () async {
    final hosts = [for (var i = 0; i < 10; i++) '10.0.0.${i + 1}'];
    final calls = <_BindCall>[];
    final discovery = build(
      calls: calls,
      addresses: () async => [
        '2409:8a55::1',
        ...hosts,
        '192.168.1.10',
        '127.0.0.1',
      ],
      redirect: _loopbackRedirect([...hosts, '192.168.1.10']),
    );
    addTearDown(discovery.stop);
    await discovery.start();

    // 公告候选只有 8 条（IPv6 占 1 条），接口 socket 不受这个上限影响。
    expect(discovery.debugInterfaceBindAddresses, [...hosts, '192.168.1.10']);
    for (final host in [...hosts, '192.168.1.10']) {
      expect(calls.where((call) => call.address == host), hasLength(1));
    }
    expect(
      calls.where((call) => call.address == '2409:8a55::1'),
      isEmpty,
      reason: 'IPv6 仍不建接口 socket',
    );
  });

  test('短回前台（rebind=false）也重建接口 socket，主 socket 不重绑', () async {
    final addresses = <String>['192.168.1.10'];
    final calls = <_BindCall>[];
    final discovery = build(
      calls: calls,
      addresses: () async => addresses,
      redirect: _loopbackRedirect(addresses),
    );
    addTearDown(discovery.stop);
    await discovery.start();
    final mainBinds = calls.where((call) => call.address == '0.0.0.0').length;
    final interfaceBinds = calls
        .where((call) => call.address == '192.168.1.10')
        .length;

    await discovery.onAppResumed();

    expect(
      calls.where((call) => call.address == '192.168.1.10').length,
      interfaceBinds + 1,
      reason: '短隐藏不等 15s 也要重建半死的接口 socket',
    );
    expect(
      calls.where((call) => call.address == '0.0.0.0').length,
      mainBinds,
      reason: 'rebind=false 不重绑主 socket',
    );
    expect(discovery.debugInterfaceBindAddresses, ['192.168.1.10']);
  });

  test('并发换网重绑串行化：最终 socket 有效，stop 后接口清空', () async {
    final calls = <_BindCall>[];
    final discovery = build(
      calls: calls,
      addresses: () async => const ['192.168.1.10', '10.0.0.5'],
      redirect: _loopbackRedirect(['192.168.1.10', '10.0.0.5']),
    );
    addTearDown(discovery.stop);
    await discovery.start();

    await Future.wait([
      discovery.onNetworkChanged(),
      discovery.onNetworkChanged(),
    ]);

    expect(discovery.discoveryPorts.v4, greaterThan(0));
    expect(discovery.debugInterfaceBindAddresses, ['192.168.1.10', '10.0.0.5']);
    expect(discovery.debugInterfacePorts, everyElement(greaterThan(0)));

    await discovery.stop();
    expect(discovery.debugInterfaceBindAddresses, isEmpty);
    expect(discovery.debugInterfacePorts, isEmpty);
    expect(discovery.discoveryPorts, (v4: 0, v6: 0));
  });

  test('单个接口绑定失败：跳过该接口，start 与主 socket 照常', () async {
    final calls = <_BindCall>[];
    final discovery = build(
      calls: calls,
      addresses: () async => const ['192.168.1.10', '10.0.0.5'],
      redirect: _loopbackRedirect(['10.0.0.5']),
      failing: {'192.168.1.10'},
    );
    addTearDown(discovery.stop);
    await discovery.start();

    expect(discovery.debugInterfaceBindAddresses, ['10.0.0.5']);
    expect(discovery.discoveryPorts.v4, greaterThan(0));

    // 主 socket 仍能收公告：接口失败不拖垮发现主路径。
    final emitter = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(emitter.close);
    emitter.send(
      _announce(key, nonce: 'n-main', probePort: 47825),
      InternetAddress.loopbackIPv4,
      discovery.discoveryPorts.v4,
    );
    await _waitFor(() => discovery.presence.isNotEmpty);
    expect(discovery.presence.single.deviceId, 'devPeer');
  });

  test('接口 socket 收到单播：presence 的 probePort 用报文端口而非临时源端口', () async {
    final calls = <_BindCall>[];
    final discovery = build(
      calls: calls,
      addresses: () async => const ['192.168.1.10'],
      redirect: _loopbackRedirect(['192.168.1.10']),
    );
    addTearDown(discovery.stop);
    await discovery.start();

    final interfacePort = discovery.debugInterfacePorts.single;
    final emitter = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(emitter.close);

    emitter.send(
      _announce(key, nonce: 'n-interface', probePort: 47825),
      InternetAddress.loopbackIPv4,
      interfacePort,
    );
    await _waitFor(() => discovery.presence.isNotEmpty);
    expect(discovery.presence.single.host, '127.0.0.1');
    expect(
      discovery.presence.single.probePort,
      47825,
      reason: '接口 socket 的源端口是临时端口，不能写进 presence',
    );

    // 公告没有 probe（0）时才退回来源端口（兼容旧报文）。
    emitter.send(
      _announce(key, nonce: 'n-interface-2', probePort: 0),
      InternetAddress.loopbackIPv4,
      interfacePort,
    );
    await _waitFor(() => discovery.presence.single.probePort == emitter.port);
    expect(discovery.presence.single.probePort, emitter.port);
  });

  test('resolvePresenceProbePort：公告端口优先，0 才回退来源端口', () {
    expect(resolvePresenceProbePort(announced: 47825, source: 50000), 47825);
    expect(resolvePresenceProbePort(announced: 0, source: 50000), 50000);
    expect(resolvePresenceProbePort(announced: 0, source: 0), 0);
  });
}

typedef _BindCall = ({String address, int port});

Future<RawDatagramSocket> Function(InternetAddress, int) _binder(
  List<_BindCall> calls, {
  Map<String, InternetAddress> redirect = const {},
  Set<String> failing = const {},
}) {
  return (address, port) async {
    calls.add((address: address.address, port: port));
    if (failing.contains(address.address)) {
      throw const SocketException('模拟接口绑定失败');
    }
    return RawDatagramSocket.bind(
      redirect[address.address] ?? address,
      port,
      reuseAddress: true,
    );
  };
}

/// 测试机没有这些网卡地址：把接口 socket 落到回环，保留真实 socket 生命周期。
Map<String, InternetAddress> _loopbackRedirect(List<String> hosts) => {
  for (final host in hosts) host: InternetAddress.loopbackIPv4,
};

Uint8List _announce(
  Uint8List key, {
  required String nonce,
  required int probePort,
}) => Msd1.encode(
  LanDiscoveryMessage(
    type: Msd1.typeAnnounce,
    deviceId: 'devPeer',
    name: '对端',
    httpPort: 43210,
    probePort: probePort,
    addresses: const [],
    snapshotId: '',
    journalHead: null,
    categories: const [],
    nonce: nonce,
    bootId: 'boot-peer',
  ),
  key,
);

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待条件超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
