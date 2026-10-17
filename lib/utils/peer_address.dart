/// 手动对端地址与探测端口的校验（添加设备表单与单测共用）。
///
/// 地址只接受主机本身（IPv4 / IPv6 / 域名），端口单独填写——把「地址」
/// 与「端口」拆开才能让探测端口有独立默认值与范围校验。
library;

/// 地址归一：去首尾空白与 IPv6 方括号（`[2409:8a55::1]` → `2409:8a55::1`）。
///
/// 输入侧允许方括号写法（用户从浏览器地址栏 / 对端界面复制过来），存储与
/// 比较一律用归一形式，避免同一地址因文本写法差异被当成两个条目。
String normalizePeerHost(String value) {
  var host = value.trim();
  if (host.length >= 2 && host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1).trim();
  }
  return host;
}

/// 地址是否可用（空串、残缺的 IPv4、带端口 / 协议的输入都不接受）。
///
/// IPv6 允许带方括号写法（先归一再校验）。
bool isValidPeerHost(String value) {
  final host = normalizePeerHost(value);
  if (host.isEmpty) return false;
  // 纯数字与点：只可能是 IPv4，按 IPv4 严格校验（挡掉 `192.168.1` 这种残缺输入）。
  if (RegExp(r'^[0-9.]+$').hasMatch(host)) return _isValidIpv4(host);
  if (host.contains(':')) return _isValidIpv6(host);
  return _isValidHostname(host);
}

/// 探测端口是否在合法范围（1–65535）。
bool isValidPeerPort(int port) => port >= 1 && port <= 65535;

/// 解析探测端口输入：空串 = 0（用传输默认端口）；非法返回 null。
int? parseProbePort(String value) {
  final text = value.trim();
  if (text.isEmpty) return 0;
  final port = int.tryParse(text);
  if (port == null || !isValidPeerPort(port)) return null;
  return port;
}

bool _isValidIpv4(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return false;
  for (final part in parts) {
    if (part.isEmpty || part.length > 3) return false;
    if (part.length > 1 && part.startsWith('0')) return false;
    final value = int.tryParse(part);
    if (value == null || value > 255) return false;
  }
  return true;
}

/// IPv6 的基本格式校验：十六进制组 / `::` 缩写 / 允许内嵌 IPv4 写法。
bool _isValidIpv6(String host) {
  if (!host.contains(':')) return false;
  if (RegExp(r'[^0-9a-fA-F:.]').hasMatch(host)) return false;
  final hasShortcut = host.contains('::');
  if ('::'.allMatches(host).length > 1) return false;
  var groups = 0;
  for (final segment in host.split(':')) {
    if (segment.isEmpty) continue; // `::` 缩写产生的空段
    if (segment.contains('.')) {
      if (!_isValidIpv4(segment)) return false;
      groups += 2; // 内嵌 IPv4 占两组
      continue;
    }
    if (segment.length > 4) return false;
    groups++;
  }
  return hasShortcut ? groups < 8 : groups == 8;
}

final RegExp _hostnameLabel = RegExp(r'^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$');

bool _isValidHostname(String host) {
  if (host.length > 253) return false;
  for (final label in host.split('.')) {
    if (label.isEmpty || label.length > 63) return false;
    if (!_hostnameLabel.hasMatch(label)) return false;
  }
  return true;
}
