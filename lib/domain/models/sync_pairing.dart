import 'dart:convert';

import '../../utils/peer_address.dart';

/// 配对码里的一个地址候选（`host` + 该主机的 UDP 探测端口）。
class SyncPairingAddress {
  const SyncPairingAddress({required this.host, this.probePort = 0});

  /// 地址（IP 字面量或域名；不带方括号 / 端口）。
  final String host;

  /// UDP 探测端口（0 = 用对端默认端口）。
  final int probePort;

  @override
  bool operator ==(Object other) =>
      other is SyncPairingAddress &&
      other.host == host &&
      other.probePort == probePort;

  @override
  int get hashCode => Object.hash(host, probePort);

  @override
  String toString() => probePort > 0 ? '$host:$probePort' : host;
}

/// 配对信息（二维码 / 文本）：把「设备名 + 设备 id + 同步口令 + 地址候选 +
/// HTTP 端点端口」打包成一段可复制的自包含文本。
///
/// 格式：`molia-pair:2:<base64url(utf8(json))>`，JSON 字段短名：
/// - `n` 设备名（展示用，可空）；
/// - `i` 设备 id（必需）；
/// - `p` 同步口令（必需）；
/// - `a` 地址候选 `[[host, probePort], …]`（可空）；
/// - `h` HTTP 端点端口（可选；0 / 缺省 = 未提供）。
///
/// 口令随码传递是刻意的取舍：信任模型 = 口令即信任根（ADR-0003），持有这段
/// 文本等同「已授权读取全部同步数据」，所以 UI 在展示二维码前必须明确警告。
///
/// 编解码是纯 Dart、strict：decode 对任何结构问题返回 null（不抛），
/// host 先归一（去方括号）再按 [isValidPeerHost] 校验，端口按
/// [isValidPeerPort] 校验。
class SyncPairingCode {
  const SyncPairingCode({
    required this.deviceName,
    required this.deviceId,
    required this.passphrase,
    this.addresses = const [],
    this.httpPort = 0,
  });

  /// 文本前缀（人工识别 + [tryParse] 判定）。
  static const String scheme = 'molia-pair';

  /// 当前格式版本（不认识的版本一律拒绝，不做「尽力解析」）。
  static const int version = 2;

  /// 地址候选上限（与探测包 `addrs` 同口径，防止二维码无限膨胀）。
  static const int maxAddresses = 8;

  final String deviceName;
  final String deviceId;
  final String passphrase;
  final List<SyncPairingAddress> addresses;

  /// 对端 HTTP 端点端口（0 = 未提供 / 未知）。
  final int httpPort;

  /// 是否是配对码文本（允许首尾空白 / 换行）。
  static bool looksLikeCode(String raw) {
    final compact = _compact(raw);
    return compact.startsWith('$scheme:');
  }

  /// 尝试解析：不是配对码 / 校验失败返回 null（不抛）。
  static SyncPairingCode? tryParse(String raw) {
    final compact = _compact(raw);
    if (!compact.startsWith('$scheme:')) return null;
    final parts = compact.split(':');
    // `molia-pair:<version>:<payload>`；payload 可含 `:` 时按剩余部分拼接。
    if (parts.length < 3) return null;
    if (int.tryParse(parts[1]) != version) return null;
    final payload = parts.sublist(2).join(':');
    if (payload.isEmpty) return null;

    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(payload))));
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;

    final deviceId = decoded['i'];
    if (deviceId is! String || deviceId.trim().isEmpty) return null;
    final passphrase = decoded['p'];
    if (passphrase is! String || passphrase.trim().isEmpty) return null;

    final rawAddresses = decoded['a'];
    if (rawAddresses != null && rawAddresses is! List) return null;
    final addresses = <SyncPairingAddress>[];
    if (rawAddresses is List) {
      for (final item in rawAddresses) {
        if (addresses.length >= maxAddresses) break;
        if (item is! List || item.length != 2) continue;
        final host = item[0];
        final port = item[1];
        if (host is! String) continue;
        final normalized = normalizePeerHost(host);
        if (!isValidPeerHost(normalized)) continue;
        final parsedPort = port is num ? port.toInt() : -1;
        if (parsedPort < 0 || (parsedPort > 0 && !isValidPeerPort(parsedPort))) {
          continue;
        }
        final address = SyncPairingAddress(
          host: normalized,
          probePort: parsedPort,
        );
        if (addresses.contains(address)) continue;
        addresses.add(address);
      }
    }

    final rawHttpPort = decoded['h'];
    var httpPort = rawHttpPort is num ? rawHttpPort.toInt() : 0;
    if (httpPort > 0 && !isValidPeerPort(httpPort)) httpPort = 0;

    return SyncPairingCode(
      deviceName: decoded['n'] is String ? (decoded['n'] as String).trim() : '',
      deviceId: deviceId.trim(),
      passphrase: passphrase.trim(),
      addresses: List.unmodifiable(addresses),
      httpPort: httpPort,
    );
  }

  /// 编码为可复制 / 可生成二维码的文本。
  ///
  /// 缺少设备 id 或口令时抛 [ArgumentError]（没有口令的配对码毫无意义，
  /// 静默产出会被当成「配对过了但同步不上」）。
  String encode() {
    if (deviceId.trim().isEmpty) {
      throw ArgumentError('Pairing code requires a device id');
    }
    if (passphrase.trim().isEmpty) {
      throw ArgumentError('Pairing code requires a passphrase');
    }
    final payload = <String, Object?>{
      'n': deviceName,
      'i': deviceId,
      'p': passphrase,
      'a': [
        for (final address in _validAddresses())
          [address.host, address.probePort],
      ],
      if (httpPort > 0) 'h': httpPort,
    };
    return '$scheme:$version:'
        '${base64Url.encode(utf8.encode(jsonEncode(payload)))}';
  }

  /// 去重 / 过滤非法条目并按上限截断（encode 侧也校验一遍，避免产出
  /// 自己解析不了的码）。
  List<SyncPairingAddress> _validAddresses() {
    final valid = <SyncPairingAddress>[];
    for (final address in addresses) {
      final host = normalizePeerHost(address.host);
      if (!isValidPeerHost(host)) continue;
      if (address.probePort > 0 && !isValidPeerPort(address.probePort)) continue;
      final normalized = SyncPairingAddress(
        host: host,
        probePort: address.probePort,
      );
      if (valid.contains(normalized)) continue;
      valid.add(normalized);
      if (valid.length >= maxAddresses) break;
    }
    return valid;
  }

  /// 去掉所有空白：二维码 / 复制的文本可能带换行（用户粘贴整段消息时）。
  static String _compact(String raw) => raw.replaceAll(RegExp(r'\s'), '');
}
