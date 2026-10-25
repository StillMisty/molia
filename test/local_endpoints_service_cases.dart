import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/local_endpoints_service.dart';

/// 本机地址枚举：过滤回环 / link-local / zone、去重、私网优先排序。
void main() {
  LocalEndpointsService serviceWith(List<LocalEndpoint> endpoints) =>
      LocalEndpointsService(enumerate: () async => endpoints);

  test('过滤回环 / link-local / 带 zone / 非法字面量', () async {
    final service = serviceWith(const [
      LocalEndpoint(interfaceName: 'lo', address: '127.0.0.1'),
      LocalEndpoint(interfaceName: 'lo', address: '::1'),
      LocalEndpoint(interfaceName: 'eth0', address: '169.254.10.1'),
      LocalEndpoint(interfaceName: 'eth0', address: 'fe80::1%eth0'),
      LocalEndpoint(interfaceName: 'eth0', address: 'fe80::1'),
      LocalEndpoint(interfaceName: 'eth0', address: 'not-an-ip'),
      LocalEndpoint(interfaceName: 'eth0', address: ''),
      LocalEndpoint(interfaceName: 'wlan0', address: '192.168.1.10'),
    ]);
    final endpoints = await service.list();
    expect(endpoints.map((endpoint) => endpoint.address), ['192.168.1.10']);
    expect(endpoints.single.interfaceName, 'wlan0');
  });

  test('去重：同一地址只保留首次出现的接口名', () async {
    final service = serviceWith(const [
      LocalEndpoint(interfaceName: 'wlan0', address: '192.168.1.10'),
      LocalEndpoint(interfaceName: 'eth0', address: '192.168.1.10'),
    ]);
    final endpoints = await service.list();
    expect(endpoints, hasLength(1));
    expect(endpoints.single.interfaceName, 'wlan0');
  });

  test('排序：私网 IPv4 → 其它 IPv4 → ULA IPv6 → 全局 IPv6（同档保持枚举顺序）', () async {
    final service = serviceWith(const [
      LocalEndpoint(interfaceName: 'eth0', address: '2409:8a55::5'), // 全局 v6
      LocalEndpoint(interfaceName: 'eth0', address: '8.8.8.8'), // 公网 v4
      LocalEndpoint(interfaceName: 'eth0', address: 'fd00::1'), // ULA
      LocalEndpoint(interfaceName: 'wlan0', address: '172.16.0.2'), // 私网 v4
      LocalEndpoint(interfaceName: 'wlan0', address: '10.0.0.2'), // 私网 v4
    ]);
    final addresses =
        (await service.list()).map((endpoint) => endpoint.address).toList();
    expect(addresses, [
      '172.16.0.2',
      '10.0.0.2',
      '8.8.8.8',
      'fd00::1',
      '2409:8a55::5',
    ]);
  });

  test('hosts() 只要地址字符串；缓存一次枚举（invalidate 后重取）', () async {
    var calls = 0;
    final service = LocalEndpointsService(enumerate: () async {
      calls++;
      return const [LocalEndpoint(interfaceName: 'wlan0', address: '192.168.1.10')];
    });
    expect(await service.hosts(), ['192.168.1.10']);
    expect(await service.hosts(), ['192.168.1.10']);
    expect(calls, 1, reason: '缓存：枚举只跑一次');
    service.invalidate();
    expect(await service.hosts(), ['192.168.1.10']);
    expect(calls, 2);
  });

  test('hostsFresh / listFresh：每次都重新枚举（传输层换网用）', () async {
    var calls = 0;
    final service = LocalEndpointsService(enumerate: () async {
      calls++;
      return [
        LocalEndpoint(
          interfaceName: 'wlan0',
          address: calls == 1 ? '192.168.1.10' : '192.168.1.20',
        ),
      ];
    });
    expect(await service.hostsFresh(), ['192.168.1.10']);
    expect(await service.hosts(), ['192.168.1.10'], reason: 'fresh 结果进缓存');
    expect(await service.hostsFresh(), ['192.168.1.20']);
    expect((await service.listFresh()).single.address, '192.168.1.20');
    expect(calls, 3);
  });
}
