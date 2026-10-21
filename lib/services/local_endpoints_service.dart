import 'dart:io';

import '../utils/peer_address.dart';

/// 本机可路由网络端点（接口名 + IP 字面量）。
class LocalEndpoint {
  const LocalEndpoint({required this.interfaceName, required this.address});

  /// 接口名（`eth0` / `wlan0` / `en0`；设置页用它区分多地址的来路）。
  final String interfaceName;

  /// IP 字面量（IPv4 或全局 / ULA IPv6；不含 zone）。
  final String address;

  /// 是否 IPv6：配对码按地址族取对应的探测端口（v4 / v6 可独立降级）。
  bool get isIpv6 =>
      InternetAddress.tryParse(address)?.type == InternetAddressType.IPv6;

  @override
  String toString() => '$address ($interfaceName)';
}

/// 枚举本机可路由地址的入口：设置页地址列表、配对码与局域网探测的 `addrs`
/// 候选三处共用（口径一致才不会「界面显示的地址连不上」）。
///
/// 过滤判定与传输侧共用 [isRoutablePeerAddress]（非回环、非 link-local、
/// 非 `%zone`、IP 字面量），本类只负责枚举与去重 / 排序：RFC1918 私网 IPv4
/// → 其它 IPv4 → ULA IPv6 → 全局 IPv6。结果按进程缓存一次枚举，
/// [invalidate] 在设置页进入时（`SyncProvider.refreshLocalEndpoints`）
/// 失效，网络切换后重进设置页即可看到新地址。
///
/// [enumerate] 供测试注入假接口数据（`dart:io` 的真实枚举在 widget 测试里
/// 依赖宿主网卡，不可断言）。
class LocalEndpointsService {
  LocalEndpointsService({Future<List<LocalEndpoint>> Function()? enumerate})
      : _enumerate = enumerate ?? _enumerateInterfaces;

  final Future<List<LocalEndpoint>> Function() _enumerate;
  Future<List<LocalEndpoint>>? _cached;

  /// 当前可路由端点（已过滤 / 去重 / 排序）。
  Future<List<LocalEndpoint>> list() =>
      _cached ??= _enumerate().then(_normalize);

  /// 重新枚举一次（绕过进程缓存）。
  ///
  /// 传输层在换网 / 回前台时用：旧地址缓存会让探测包带上已经失效的 IP；
  /// 设置页仍走 [list] 的缓存（进入页面时才失效）。
  Future<List<LocalEndpoint>> listFresh() {
    _cached = null;
    return list();
  }

  /// 只要地址字符串（局域网探测的 `addrs` 候选）。
  Future<List<String>> hosts() async =>
      [for (final endpoint in await list()) endpoint.address];

  /// 重新枚举后的地址字符串（传输层换网 / 回前台使用）。
  Future<List<String>> hostsFresh() async =>
      [for (final endpoint in await listFresh()) endpoint.address];

  /// 失效缓存：真实失效点是设置页进入（见类注释），下次读取重新枚举。
  void invalidate() => _cached = null;

  static Future<List<LocalEndpoint>> _enumerateInterfaces() async {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.any,
    );
    return [
      for (final interface in interfaces)
        for (final address in interface.addresses)
          LocalEndpoint(
            interfaceName: interface.name,
            address: address.address.trim(),
          ),
    ];
  }

  static List<LocalEndpoint> _normalize(List<LocalEndpoint> raw) {
    final seen = <String>{};
    final unique = <LocalEndpoint>[];
    for (final endpoint in raw) {
      final address = normalizePeerHost(endpoint.address);
      if (!isRoutablePeerAddress(address)) continue;
      if (!seen.add(address)) continue;
      unique.add(LocalEndpoint(
        interfaceName: endpoint.interfaceName,
        address: address,
      ));
    }
    // 稳定排序：同档位保持枚举顺序（List.sort 不保证稳定，这里按索引决平局）。
    final ranked = <(int, int, LocalEndpoint)>[
      for (var i = 0; i < unique.length; i++)
        (_rank(unique[i].address), i, unique[i]),
    ]..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
    return List.unmodifiable([for (final entry in ranked) entry.$3]);
  }

  /// 展示 / 尝试顺序：私网 IPv4（局域网最常见）在前，公网 IPv6 在后。
  static int _rank(String address) {
    final parsed = InternetAddress.tryParse(address);
    if (parsed == null) return 4;
    if (parsed.type == InternetAddressType.IPv4) {
      return _isPrivateIpv4(parsed) ? 0 : 1;
    }
    return _isUniqueLocalIpv6(parsed) ? 2 : 3;
  }

  static bool _isPrivateIpv4(InternetAddress address) {
    final bytes = address.rawAddress;
    if (bytes.length != 4) return false;
    if (bytes[0] == 10) return true;
    if (bytes[0] == 192 && bytes[1] == 168) return true;
    if (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) return true;
    return false;
  }

  /// ULA（`fc00::/7`；家用 / 企业内网 IPv6）。
  static bool _isUniqueLocalIpv6(InternetAddress address) {
    final bytes = address.rawAddress;
    if (bytes.length != 16) return false;
    return bytes[0] & 0xfe == 0xfc;
  }
}
