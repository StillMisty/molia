/// `MSP/1` 局域网配对发现报文：编解码、独立限流与候选缓存。
///
/// 报文布局：
/// `magic(3,'MSP') | version(1,=1) | type(1) | bodyLen(2 BE) | body`。
/// `type`：1 = probe，2 = announce。`body` 是 UTF-8 JSON（≤512B）。
///
/// 与 `MSD/1` 刻意分开：MSP **没有 MAC**，只用于「附近有谁」的候选发现。
/// 它绝不写 presence / 名册 `lastSeenAt` / 调度器 sightings，也不触发同步
/// 轮次——真正的信任判定在 HTTP 配对 + 6 位确认码。
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../../domain/models/sync_nearby_pairing.dart';
import '../../../utils/peer_address.dart';

/// `MSP/1` 线上格式与编解码。
abstract final class Msp1 {
  static const String magic = 'MSP';
  static const int version = 1;

  static const int typeProbe = 1;
  static const int typeAnnounce = 2;

  /// magic(3) + version(1) + type(1) + bodyLen(2)。
  static const int headerLength = 7;
  static const int bodyLengthOffset = 5;

  static const int maxBodyLength = 512;
  static const int maxNameRunes = 64;
  static const int maxAddresses = 8;
  static const int maxDeviceIdLength = 128;
  static const int maxNonceLength = 64;

  /// 编码一条报文；超长字段逐级截断，保证 body ≤512B。
  static Uint8List encode(Msp1Message message) {
    final body = _encodeBody(message);
    final packet = BytesBuilder(copy: false)
      ..add(ascii.encode(magic))
      ..addByte(version)
      ..addByte(message.type)
      ..addByte((body.length >> 8) & 0xff)
      ..addByte(body.length & 0xff)
      ..add(body);
    return packet.toBytes();
  }

  /// 仅按前 3 字节判断是否像 MSP（分派前用，避免把 MSD 报文送进 JSON 解析）。
  static bool looksLike(Uint8List packet) {
    if (packet.length < magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (packet[i] != magic.codeUnitAt(i)) return false;
    }
    return true;
  }

  /// 解码；任何结构问题（长度 / magic / 版本 / 类型 / JSON / 字段）返回 null。
  static Msp1Message? decode(Uint8List packet) {
    if (packet.length < headerLength || !looksLike(packet)) return null;
    if (packet[magic.length] != version) return null;
    final type = packet[magic.length + 1];
    if (type != typeProbe && type != typeAnnounce) return null;
    final bodyLength =
        (packet[bodyLengthOffset] << 8) | packet[bodyLengthOffset + 1];
    if (bodyLength > maxBodyLength) return null;
    if (packet.length != headerLength + bodyLength) return null;

    final Object? raw;
    try {
      raw =
          jsonDecode(utf8.decode(Uint8List.sublistView(packet, headerLength)));
    } catch (_) {
      return null;
    }
    if (raw is! Map) return null;
    final map = raw.cast<String, dynamic>();

    final deviceId = map['id'];
    if (deviceId is! String ||
        deviceId.isEmpty ||
        deviceId.length > maxDeviceIdLength) {
      return null;
    }
    final nonce = map['nonce'];
    if (nonce is! String || nonce.isEmpty || nonce.length > maxNonceLength) {
      return null;
    }
    final bootId = map['boot'];
    if (bootId is! String || bootId.isEmpty || bootId.length > 32) return null;
    final httpPort = _port(map['http']);
    // 没有 HTTP 端点的应答无法配对，直接丢弃（不产生不可用候选）。
    if (type == typeAnnounce && httpPort <= 0) return null;

    return Msp1Message(
      type: type,
      deviceId: deviceId,
      name: _clampRunes(
        map['name'] is String ? map['name'] as String : '',
        maxNameRunes,
      ),
      httpPort: httpPort,
      probePort: _port(map['probe']),
      addresses: _stringList(map['addrs'], maxAddresses),
      hasGroup: map['group'] == true,
      bootId: bootId,
      nonce: nonce,
    );
  }

  static List<int> _encodeBody(Msp1Message message) {
    var name = _clampRunes(message.name, maxNameRunes);
    var addresses = message.addresses.take(maxAddresses).toList();

    List<int> build() => utf8.encode(jsonEncode({
          'id': message.deviceId,
          'name': name,
          'http': message.httpPort,
          'probe': message.probePort,
          'addrs': addresses,
          'group': message.hasGroup,
          'boot': message.bootId,
          'nonce': message.nonce,
        }));

    var body = build();
    if (body.length <= maxBodyLength) return body;
    addresses = const [];
    body = build();
    if (body.length <= maxBodyLength) return body;
    name = _clampRunes(name, 32);
    body = build();
    if (body.length <= maxBodyLength) return body;
    name = '';
    body = build();
    if (body.length > maxBodyLength) {
      throw ArgumentError('局域网配对公告超过 $maxBodyLength 字节上限');
    }
    return body;
  }

  static int _port(Object? raw) {
    if (raw is! num) return 0;
    final value = raw.toInt();
    return value < 0 || value > 65535 ? 0 : value;
  }

  static List<String> _stringList(Object? raw, int limit) {
    if (raw is! List) return const [];
    final values = <String>[];
    for (final item in raw) {
      if (item is! String || item.isEmpty) continue;
      values.add(_clampRunes(item, 128));
      if (values.length >= limit) break;
    }
    return values;
  }

  static String _clampRunes(String value, int limit) {
    if (value.runes.length <= limit) return value;
    return String.fromCharCodes(value.runes.take(limit));
  }
}

/// 一条解码后的 `MSP/1` 报文。
class Msp1Message {
  const Msp1Message({
    required this.type,
    required this.deviceId,
    required this.name,
    required this.httpPort,
    required this.probePort,
    required this.addresses,
    required this.hasGroup,
    required this.bootId,
    required this.nonce,
  });

  final int type;
  final String deviceId;
  final String name;
  final int httpPort;
  final int probePort;
  final List<String> addresses;

  /// 对端是否已有同步组（只作提示；group proof 才是判定依据）。
  final bool hasGroup;
  final String bootId;
  final String nonce;

  bool get isProbe => type == Msp1.typeProbe;
  bool get isAnnounce => type == Msp1.typeAnnounce;
}

/// 发现层交给配对服务的一条 MSP 包（来源地址 / 端口来自 UDP 观测，不用 body）。
class LanPairingDatagram {
  const LanPairingDatagram({
    required this.message,
    required this.sourceHost,
    required this.sourcePort,
    required this.receivedAt,
  });

  final Msp1Message message;
  final String sourceHost;
  final int sourcePort;
  final int receivedAt;
}

/// MSP 专用限流：每来源 10 包/10s、全局 50 包/10s。
///
/// 与 `MSD/1` 的限流完全独立：伪造 MSP 包不能挤掉正常同步公告，反之亦然。
/// 来源表有界，超过上限时淘汰最久没活动的来源（只淘汰记账）。
class MspRateLimiter {
  MspRateLimiter({
    this.perSourceLimit = 10,
    this.globalLimit = 50,
    this.maxSources = 64,
    this.window = const Duration(seconds: 10),
  });

  final int perSourceLimit;
  final int globalLimit;
  final int maxSources;
  final Duration window;

  final Map<String, List<int>> _bySource = {};
  final List<int> _global = [];

  int get sourceCount => _bySource.length;

  bool allow(String source, int nowMs) {
    final cutoff = nowMs - window.inMilliseconds;
    var events = _bySource[source];
    if (events == null) {
      _bySource.removeWhere((_, values) => values.isEmpty);
      if (_bySource.length >= maxSources) _evictOldestSource();
      events = <int>[];
      _bySource[source] = events;
    }
    events.removeWhere((at) => at <= cutoff);
    if (events.length >= perSourceLimit) return false;
    _global.removeWhere((at) => at <= cutoff);
    if (_global.length >= globalLimit) return false;
    events.add(nowMs);
    _global.add(nowMs);
    return true;
  }

  void clear() {
    _bySource.clear();
    _global.clear();
  }

  void _evictOldestSource() {
    String? oldestSource;
    var oldestAt = 1 << 62;
    for (final entry in _bySource.entries) {
      final lastAt = entry.value.isEmpty ? -1 : entry.value.last;
      if (lastAt < oldestAt) {
        oldestAt = lastAt;
        oldestSource = entry.key;
      }
    }
    if (oldestSource != null) _bySource.remove(oldestSource);
  }
}

/// 附近候选缓存：按 `deviceId` 去重、TTL 15s、上限 32。
///
/// 候选只来自 announce（probe 的发送方不进入候选表：它可能只是来问「有谁」，
/// 还没证明自己能接受 HTTP 请求）。
class PairingCandidateCache {
  PairingCandidateCache({
    this.ttl = const Duration(seconds: 15),
    this.maxCandidates = 32,
  });

  final Duration ttl;
  final int maxCandidates;

  final Map<String, _Candidate> _candidates = {};

  /// 写入 / 刷新一条应答；返回是否产生了变化。
  bool upsert({
    required Msp1Message message,
    required String sourceHost,
    required int sourcePort,
    required int nowMs,
  }) {
    if (message.deviceId.isEmpty || message.httpPort <= 0) return false;
    final previous = _candidates[message.deviceId];
    final next = _Candidate(
      device: SyncNearbyDevice(
        deviceId: message.deviceId,
        name: message.name,
        host: sourceHost,
        httpPort: message.httpPort,
        probePort: message.probePort > 0 ? message.probePort : sourcePort,
        // `addrs` 没有 MAC / 签名：只接受可路由 IP 字面量，回环、link-local
        //（含 zone）与域名都不进入候选。UDP 来源地址是真实观测值，另行保留。
        addresses: List.unmodifiable(_routableAddresses(message.addresses)),
        hasGroup: message.hasGroup,
        bootId: message.bootId,
        lastSeenAt: nowMs,
      ),
      expiresAt: nowMs + ttl.inMilliseconds,
    );
    _candidates[message.deviceId] = next;
    _trim();
    if (previous == null) return true;
    final before = previous.device;
    final after = next.device;
    return before.name != after.name ||
        before.host != after.host ||
        before.httpPort != after.httpPort ||
        before.probePort != after.probePort ||
        before.hasGroup != after.hasGroup ||
        before.bootId != after.bootId ||
        !_sameStrings(before.addresses, after.addresses);
  }

  static List<String> _routableAddresses(List<String> raw) {
    final seen = <String>{};
    final values = <String>[];
    for (final item in raw) {
      final host = normalizePeerHost(item);
      if (host.isEmpty || !isRoutablePeerAddress(host)) continue;
      if (!seen.add(host)) continue;
      values.add(host);
      if (values.length >= Msp1.maxAddresses) break;
    }
    return values;
  }

  /// 当前候选（已剪掉过期项；最近听到的在前）。
  List<SyncNearbyDevice> current(int nowMs) {
    _prune(nowMs);
    final devices = [for (final entry in _candidates.values) entry.device]
      ..sort((a, b) => b.lastSeenAt.compareTo(a.lastSeenAt));
    return List.unmodifiable(devices);
  }

  /// 清掉过期项；返回是否真的移除了条目。
  bool sweep(int nowMs) {
    final before = _candidates.length;
    _prune(nowMs);
    return _candidates.length != before;
  }

  void clear() => _candidates.clear();

  void _prune(int nowMs) {
    _candidates.removeWhere((_, candidate) => candidate.expiresAt <= nowMs);
  }

  void _trim() {
    if (_candidates.length <= maxCandidates) return;
    String? oldestId;
    var oldestAt = 1 << 62;
    for (final entry in _candidates.entries) {
      if (entry.value.expiresAt < oldestAt) {
        oldestAt = entry.value.expiresAt;
        oldestId = entry.key;
      }
    }
    if (oldestId != null) _candidates.remove(oldestId);
  }

  static bool _sameStrings(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _Candidate {
  const _Candidate({required this.device, required this.expiresAt});

  final SyncNearbyDevice device;
  final int expiresAt;
}
