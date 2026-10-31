/// 局域网发现层（`MSD/1`）：二进制公告 + HMAC + presence + 事件。
///
/// 报文布局：
/// `magic(3,'MSD') | version(1,=1) | type(1) | mac(16) | bodyLen(2, BE) | body`。
/// `type`：1 = announce，2 = ack。`body` 是 UTF-8 JSON（≤1024B）。
///
/// 认证与解析顺序是硬约束：**先按来源 IP 限流 → 验 MAC → 再解析 JSON**。
/// 未通过 MAC 的字节不被当作任何协议（旧版 JSON 探测包首字节是 `{`，这里
/// 直接静默丢弃：不识别、不计数、不提示，见 ADR-0003 的硬断代章节）。
///
/// UDP 只负责发现；载荷与存活检查都走每设备自带的 HTTP 端点。正常空闲轮
/// 不广播，只对 presence / 已知端点做 ≤8 个单播；蜂窝网络下连单播公告也不发。
///
/// IPv4 广播 / 组播除主 wildcard socket 外，还从每个可路由接口的独立 socket
/// 发出（多网卡 / VPN 下不依赖默认路由）；接口 socket 的临时源端口不对外，
/// presence 的探测端口以认证报文里的 `probe` 为准。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../../../domain/models/device_sync.dart';
import '../../../utils/peer_address.dart';
import '../sync_crypto.dart';
import 'lan_pairing_packet.dart';

/// `MSD/1` 线上格式与报文编解码。
abstract final class Msd1 {
  static const String magic = 'MSD';
  static const int version = 1;

  static const int typeAnnounce = 1;
  static const int typeAck = 2;

  /// 固定头：magic(3) + version(1) + type(1) + mac(16) + bodyLen(2)。
  static const int headerLength = 23;
  static const int macOffset = 5;
  static const int bodyLengthOffset = 21;

  static const int maxBodyLength = 1024;
  static const int maxNameRunes = 64;
  static const int maxAddresses = 8;
  static const int maxDeviceIdLength = 128;

  /// IPv4 组播地址（RFC 2365 本地范围；与 v6 的 `ff02::4d4f:4c49` 对应）。
  static const String ipv4MulticastHost = '224.0.0.169';

  /// IPv6 链路本地组播地址（"MOLI" 的十六进制形态）。
  static const String ipv6MulticastHost = 'ff02::4d4f:4c49';

  /// 编码一条报文。MAC 覆盖 `header_without_mac + body`：头部去掉 mac 后为
  /// `magic/version/type/bodyLen`，长度也参与认证，篡改长度会直接认证失败。
  static Uint8List encode(LanDiscoveryMessage message, Uint8List key) {
    final body = _encodeBody(message);
    final packet = BytesBuilder(copy: false)
      ..add(ascii.encode(magic))
      ..addByte(version)
      ..addByte(message.type)
      ..add(Uint8List(16))
      ..addByte((body.length >> 8) & 0xff)
      ..addByte(body.length & 0xff)
      ..add(body);
    final bytes = packet.toBytes();
    final macInput = <int>[
      ...bytes.sublist(0, macOffset),
      ...bytes.sublist(bodyLengthOffset, headerLength),
      ...body,
    ];
    bytes.setRange(
      macOffset,
      macOffset + SyncCodec.discoveryMacLength,
      SyncCodec.discoveryMac(key, macInput),
    );
    return bytes;
  }

  /// 解码并认证；任何失败（长度、magic、版本、类型、MAC、JSON、字段）都
  /// 返回 null。调用方只把它当作未知字节静默丢弃。
  static LanDiscoveryMessage? decode(Uint8List packet, Uint8List key) {
    if (packet.length < headerLength) return null;
    // 旧 JSON 探测包 / 任意文本：首个字节不是 magic，按未知字节丢弃。
    if (packet[0] == 0x7b) return null;
    for (var i = 0; i < magic.length; i++) {
      if (packet[i] != magic.codeUnitAt(i)) return null;
    }
    if (packet[magic.length] != version) return null;
    final type = packet[magic.length + 1];
    if (type != typeAnnounce && type != typeAck) return null;
    final bodyLength =
        (packet[bodyLengthOffset] << 8) | packet[bodyLengthOffset + 1];
    if (bodyLength > maxBodyLength) return null;
    if (packet.length != headerLength + bodyLength) return null;
    final body = Uint8List.sublistView(packet, headerLength);
    final macInput = <int>[
      ...packet.sublist(0, macOffset),
      ...packet.sublist(bodyLengthOffset, headerLength),
      ...body,
    ];
    final expected = SyncCodec.discoveryMac(key, macInput);
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected[i] ^ packet[macOffset + i];
    }
    if (diff != 0) return null;

    final Object? raw;
    try {
      raw = jsonDecode(utf8.decode(body));
    } catch (_) {
      return null;
    }
    if (raw is! Map) return null;
    final map = raw.cast<String, dynamic>();
    final deviceId = map['id'];
    final nonce = map['nonce'];
    final boot = map['boot'];
    if (deviceId is! String ||
        deviceId.isEmpty ||
        deviceId.length > maxDeviceIdLength) {
      return null;
    }
    if (nonce is! String || nonce.isEmpty || nonce.length > 64) return null;
    if (boot is! String || boot.isEmpty || boot.length > 32) return null;
    return LanDiscoveryMessage(
      type: type,
      deviceId: deviceId,
      name: _clampRunes(
          map['name'] is String ? map['name'] as String : '', maxNameRunes),
      httpPort: _port(map['http']),
      probePort: _port(map['probe']),
      addresses: _stringList(map['addrs'], maxAddresses),
      snapshotId:
          map['snap'] is String ? _clampRunes(map['snap'] as String, 128) : '',
      journalHead: map['head'] is num ? (map['head'] as num).toInt() : null,
      categories: _stringList(map['cats'], 16),
      nonce: nonce,
      bootId: boot,
    );
  }

  static List<int> _encodeBody(LanDiscoveryMessage message) {
    var name = _clampRunes(message.name, maxNameRunes);
    var addresses = message.addresses.take(maxAddresses).toList();
    var categories = message.categories.take(16).toList();
    var snapshotId = _clampRunes(message.snapshotId, 128);

    List<int> build() => utf8.encode(jsonEncode({
          'id': message.deviceId,
          'name': name,
          'http': message.httpPort,
          'probe': message.probePort,
          'addrs': addresses,
          'snap': snapshotId,
          'head': message.journalHead,
          'cats': categories,
          'nonce': message.nonce,
          'boot': message.bootId,
        }));

    var body = build();
    if (body.length <= maxBodyLength) return body;
    // 超限逐级截断（地址 → 分类 → 指纹 → 名称），保证不会产生 IP 分片。
    addresses = const [];
    body = build();
    if (body.length <= maxBodyLength) return body;
    categories = const [];
    body = build();
    if (body.length <= maxBodyLength) return body;
    snapshotId = '';
    name = _clampRunes(name, 32);
    body = build();
    if (body.length <= maxBodyLength) return body;
    name = '';
    body = build();
    if (body.length > maxBodyLength) {
      throw ArgumentError('局域网公告超过 $maxBodyLength 字节上限');
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

  /// 按 Unicode 码点截断（不能用 `substring` 切开代理对，否则 JSON 编码会
  /// 产生非法 UTF-8）。
  static String _clampRunes(String value, int limit) {
    if (value.runes.length <= limit) return value;
    return String.fromCharCodes(value.runes.take(limit));
  }
}

/// 一条认证通过的 `MSD/1` 公告 / 应答。
class LanDiscoveryMessage {
  const LanDiscoveryMessage({
    required this.type,
    required this.deviceId,
    required this.name,
    required this.httpPort,
    required this.probePort,
    required this.addresses,
    required this.snapshotId,
    required this.journalHead,
    required this.categories,
    required this.nonce,
    required this.bootId,
  });

  final int type;
  final String deviceId;
  final String name;
  final int httpPort;
  final int probePort;
  final List<String> addresses;
  final String snapshotId;
  final int? journalHead;
  final List<String> categories;

  /// 同一 burst 复用（接收端按 `(deviceId, nonce)` 30 秒去重）。
  final String nonce;

  /// 每次进程启动随机生成；对端重启后即使 head 未变也视为重新上线。
  final String bootId;

  bool get isAnnounce => type == Msd1.typeAnnounce;
  bool get isAck => type == Msd1.typeAck;
}

/// 发现的在线对端（`deviceId → 端点 / 内容指纹 / 最近听到`）。
class LanPresence {
  const LanPresence({
    required this.deviceId,
    required this.name,
    required this.host,
    required this.httpPort,
    required this.probePort,
    required this.addresses,
    required this.snapshotId,
    required this.journalHead,
    required this.bootId,
    required this.lastHeardAt,
    required this.epoch,
  });

  final String deviceId;
  final String name;

  /// UDP 来源地址（真实可达的观测值；候选 `addresses` 只用于优先尝试）。
  final String host;
  final int httpPort;
  final int probePort;
  final List<String> addresses;
  final String snapshotId;
  final int? journalHead;
  final String bootId;
  final int lastHeardAt;

  /// 产生这条记录时的网络代次（换网后旧代次的记录不再作为首选）。
  final int epoch;

  LanPeerSighting toSighting() => LanPeerSighting(
        deviceId: deviceId,
        name: name,
        host: host,
        httpPort: httpPort,
        probePort: probePort,
        snapshotId: snapshotId,
        journalHead: journalHead,
        bootId: bootId,
        observedAt: lastHeardAt,
      );
}

/// `(deviceId, nonce)` 去重：广播 + 组播重复到达只产生一次 sighting。
class DiscoveryNonceCache {
  DiscoveryNonceCache({
    this.window = const Duration(seconds: 30),
    this.maxEntries = 512,
  });

  final Duration window;
  final int maxEntries;
  final Map<String, int> _seen = {};

  /// 返回 true = 第一次见到；false = 窗口内重复。
  bool accept(String deviceId, String nonce, int nowMs) {
    final expiry = nowMs + window.inMilliseconds;
    _seen.removeWhere((_, expiresAt) => expiresAt <= nowMs);
    final key = '$deviceId\u0000$nonce';
    final existing = _seen[key];
    if (existing != null && existing > nowMs) return false;
    if (_seen.length >= maxEntries) {
      _seen.remove(_seen.keys.first);
    }
    _seen[key] = expiry;
    return true;
  }

  void clear() => _seen.clear();
}

/// 入站限流：每来源 20 包/10s、全局 100 包/10s。先限流再验 MAC。
///
/// 来源表必须有界：源 IP 可以伪造，按来源建 map 不能无限增长。超过
/// [maxSources] 时淘汰最久没有活动的来源（只淘汰记账，不影响已通过限流
/// 的包）。
class DiscoveryRateLimiter {
  DiscoveryRateLimiter({
    this.perSourceLimit = 20,
    this.globalLimit = 100,
    this.maxSources = 64,
    this.window = const Duration(seconds: 10),
  });

  final int perSourceLimit;
  final int globalLimit;
  final int maxSources;
  final Duration window;
  final Map<String, List<int>> _bySource = {};
  final List<int> _global = [];

  /// 当前记账的来源数（测试 / 诊断用；有界）。
  int get sourceCount => _bySource.length;

  bool allow(String source, int nowMs) {
    final cutoff = nowMs - window.inMilliseconds;
    var sourceEvents = _bySource[source];
    if (sourceEvents == null) {
      // 新来源：先腾出位置。淘汰按“最后活动时间”，没有活动的旧条目优先。
      _bySource.removeWhere((_, events) => events.isEmpty);
      if (_bySource.length >= maxSources) _evictOldestSource();
      sourceEvents = <int>[];
      _bySource[source] = sourceEvents;
    }
    sourceEvents.removeWhere((at) => at <= cutoff);
    if (sourceEvents.length >= perSourceLimit) return false;
    _global.removeWhere((at) => at <= cutoff);
    if (_global.length >= globalLimit) return false;
    sourceEvents.add(nowMs);
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

/// 已知端点的单播探测目标。
typedef LanProbeTarget = ({String host, int port});

/// presence 的探测端口：报文里的 `probe` 已通过 MAC 认证，优先采用。
///
/// 按接口 socket 的源端口是系统临时分配的，重启 / 换接口后不可达，不能写进
/// 候选 / `lanEndpoints`；只有旧报文没有 `probe`（0）时才退回来源端口。
int resolvePresenceProbePort({required int announced, required int source}) =>
    announced > 0 ? announced : source;

/// 发现层：UDP 绑定 / 公告 burst / presence / 事件流。
///
/// 只处理发现，不碰 HTTP；传输层把 presence 与手动 / 持久化端点合并成候选。
class LanDiscovery {
  LanDiscovery({
    required this.deviceId,
    required this._deviceName,
    required this._discoveryKeyProvider,
    required this._httpPortProvider,
    this._probePortProvider,
    this._snapshotIdProvider,
    this._journalHeadProvider,
    this._categoriesProvider,
    this._knownPeersProvider,
    this._probeTargetsProvider,
    this._localAddressesProvider,
    Future<RawDatagramSocket> Function(InternetAddress address, int port)?
        udpBinder,
    this._udpPort = defaultUdpPort,
    this.candidateWindow = const Duration(milliseconds: 400),
    this.fullWindow = const Duration(milliseconds: 1200),
    this.supplementaryWindow = const Duration(milliseconds: 800),
    int Function()? nowMs,
    this._isCellular,
  })  : _udpBinder = udpBinder ?? _bindDatagram,
        _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  static const int defaultUdpPort = ManualPeer.defaultProbePort;

  /// presence 上限（防伪造公告灌爆内存）。
  static const int maxPeers = 32;

  /// 每次公告 / 单播探测最多带 8 个已知端点。
  static const int maxUnicastTargets = 8;

  /// 公告 burst 的发送时刻（启动 / 回前台 / 换网）。
  static const List<int> burstDelaysMs = [100, 500, 2000];

  /// 本机接口指纹刷新节流：换网要尽快发现，但不能每轮都枚举接口。
  static const Duration interfaceScanInterval = Duration(seconds: 60);

  /// 进程启动随机 boot id（同进程多实例共用；对端据此识别重启）。
  static final String bootId = _base64Url(_randomBytes(8));

  final String deviceId;
  final String Function() _deviceName;
  final Future<Uint8List> Function() _discoveryKeyProvider;
  final int Function() _httpPortProvider;
  final int Function()? _probePortProvider;
  final String Function()? _snapshotIdProvider;
  final int Function()? _journalHeadProvider;
  final List<String> Function()? _categoriesProvider;
  final List<LanPeerEndpoint> Function()? _knownPeersProvider;
  final List<LanProbeTarget> Function()? _probeTargetsProvider;
  final Future<List<String>> Function()? _localAddressesProvider;
  final Future<RawDatagramSocket> Function(InternetAddress address, int port)
      _udpBinder;
  final int _udpPort;
  final int Function() _nowMs;
  final bool Function()? _isCellular;

  final Duration candidateWindow;
  final Duration fullWindow;
  final Duration supplementaryWindow;

  final Logger _logger = Logger('molia.sync.discovery');
  final StreamController<LanPeerSighting> _sightings =
      StreamController<LanPeerSighting>.broadcast();

  /// MSP 配对发现事件：与 sightings / presence 完全分开，不写名册。
  final StreamController<LanPairingDatagram> _pairingDatagrams =
      StreamController<LanPairingDatagram>.broadcast();
  final Map<String, LanPresence> _presence = {};
  final DiscoveryNonceCache _nonces = DiscoveryNonceCache();
  final DiscoveryRateLimiter _rateLimiter = DiscoveryRateLimiter();

  /// MSP 独立限流：伪造配对包不能挤掉正常同步公告。
  final MspRateLimiter _pairingRateLimiter = MspRateLimiter();

  RawDatagramSocket? _udp4;
  RawDatagramSocket? _udp6;
  StreamSubscription<RawSocketEvent>? _sub4;
  StreamSubscription<RawSocketEvent>? _sub6;

  /// 每个可路由 IPv4 接口一个 socket（port 0）；用于让广播 / 组播真正从该
  /// 接口出去，不依赖系统默认路由。
  final Map<String, _InterfaceSocket> _interfaceSockets = {};

  /// 串行化接口 socket 重建：换网事件可能连续到达，不能让两次绑定交错。
  Future<void> _interfaceSyncTail = Future<void>.value();

  /// 串行化主 socket 重绑：connectivity 事件与 discover 可能同时触发。
  Future<void> _udpRebindTail = Future<void>.value();

  /// 主 socket 按接口加入组播的记账（按 socket identity 失效）。
  final _MulticastJoinTracker _ipv4MulticastJoins = _MulticastJoinTracker();
  final _MulticastJoinTracker _ipv6MulticastJoins = _MulticastJoinTracker();

  Uint8List? _key;
  bool _running = false;
  bool _hidden = false;
  int _networkEpoch = 0;
  String _interfaceFingerprint = '';
  bool _interfaceScanned = false;
  int? _lastInterfaceScanAt;

  /// 公告 `addrs` 候选（≤8 条，含 IPv6）。
  List<String> _ownAddresses = const [];

  /// 全部可路由 IPv4 接口（不参与 `addrs` 的 8 条上限）：每个都要建发送
  /// socket，不能因为 IPv6 混排或接口多而被截断。
  List<String> _interfaceIpv4Addresses = const [];
  bool _broadcastUnavailable = false;
  int _broadcastCount = 0;
  final List<Timer> _burstTimers = [];

  /// 认证通过的公告 / 应答事件（重复 nonce 已抑制）。
  Stream<LanPeerSighting> get sightings => _sightings.stream;

  /// MSP 配对探测 / 应答事件（无 MAC、不进 presence / 名册 / 调度器）。
  Stream<LanPairingDatagram> get pairingDatagrams => _pairingDatagrams.stream;

  List<LanPresence> get presence => List.unmodifiable(_presence.values);

  ({int v4, int v6}) get discoveryPorts => (
        v4: _running ? (_udp4?.port ?? 0) : 0,
        v6: _running ? (_udp6?.port ?? 0) : 0,
      );

  /// 拉取轮里主动广播的次数（测试断言「空闲轮 0 广播」用；公告 burst 不计）。
  int get broadcastCount => _broadcastCount;

  bool get broadcastUnavailable => _broadcastUnavailable;

  /// 网络代次（首次枚举 = 1，接口指纹变化时 +1）。
  int get networkEpoch => _networkEpoch;

  bool get isHidden => _hidden;

  /// 单端口提示（协议只有一格；取首选族，实际回包按来源端口走）。
  int get advertisedProbePort {
    final ports = discoveryPorts;
    return ports.v4 > 0 ? ports.v4 : ports.v6;
  }

  /// 已绑定按接口 IPv4 socket 的地址（测试 / 诊断；不含主 wildcard socket）。
  List<String> get debugInterfaceBindAddresses =>
      List.unmodifiable(_interfaceSockets.keys);

  /// 按接口 IPv4 socket 的本地端口（与 [debugInterfaceBindAddresses] 同序）。
  ///
  /// 这些是系统临时端口：接口 socket 只负责从该接口发送广播 / 组播，并接收
  /// 对端回给这个临时源端口的单播；47825 上的组播接收由主 wildcard socket
  /// 按接口 join 承担。对外探测端口仍是 [discoveryPorts] 里的主 socket 端口。
  List<int> get debugInterfacePorts => List.unmodifiable([
        for (final entry in _interfaceSockets.values) entry.socket.port,
      ]);

  /// 发送一条 MSP 包；[host] 为空时走 v4 广播 + v4/v6 组播，否则单播。
  ///
  /// 后台 / 蜂窝下直接拒绝：配对发现不能绕过与 MSD 相同的省电 / 流量策略。
  /// 返回 false = 未运行 / 策略禁止 / 发送失败。
  Future<bool> sendPairingPacket(
    Uint8List packet, {
    String? host,
    int? port,
  }) async {
    if (!_running || _hidden || _isCellularNow) return false;
    if (host == null || host.trim().isEmpty) {
      // MSP 探测与 MSD 公告复用同一广播路径：多网卡下也从每个接口各发一份，
      // 首次配对不必依赖默认路由。MSP 没有 nonce 去重，重复应答由
      // LanPairingService 的候选缓存按 deviceId upsert，不产生额外状态。
      return _sendBroadcast(packet, trackAvailability: false);
    }
    return _sendTo(packet, host, port ?? _udpPort);
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;
    _hidden = false;
    _broadcastCount = 0;
    _broadcastUnavailable = false;
    await _ensureKey();
    // 先枚举本机地址：接口 socket 需要完整接口列表才能建。
    await _refreshNetwork(force: true);
    await _bindSockets(_udpPort, _udpPort);
    await _syncInterfaceSockets();
    await _joinIpv4Interfaces();
    await _joinIpv6Interfaces();
    if (_udp4 == null && _udp6 == null) {
      _logger.warning('UDP 发现不可用（两族绑定均失败）：只剩手动地址直连');
    }
    if (_hasSockets && !_isCellularNow) _scheduleBurst();
  }

  Future<void> stop() async {
    _running = false;
    _hidden = false;
    _cancelBurst();
    // 先等在途重绑（它内部会等接口重建），再收接口、主 socket：停服后不能
    // 再挂上新监听。
    await _udpRebindTail;
    await _interfaceSyncTail;
    await _closeInterfaceSockets();
    await _closeMainSockets();
    _ipv4MulticastJoins.reset();
    _ipv6MulticastJoins.reset();
    _presence.clear();
    _nonces.clear();
    _rateLimiter.clear();
    _pairingRateLimiter.clear();
    _ownAddresses = const [];
    _interfaceIpv4Addresses = const [];
    _interfaceFingerprint = '';
    _interfaceScanned = false;
    _lastInterfaceScanAt = null;
    _networkEpoch = 0;
    _key = null;
    _broadcastCount = 0;
    _broadcastUnavailable = false;
  }

  /// 更新发现密钥（口令变化时由传输层传入；MAC 计算只在主 isolate）。
  void updateKey(Uint8List key) => _key = key;

  Future<void> _ensureKey() async {
    if (_key != null) return;
    try {
      _key = await _discoveryKeyProvider();
    } catch (e) {
      _logger.warning('派生局域网发现密钥失败（收到公告时无法认证）', e);
    }
  }

  /// 回前台：隐藏超过阈值由传输层决定是否重绑 UDP；这里只刷新地址与公告。
  Future<void> onAppResumed({bool rebind = false}) async {
    if (!_running) return;
    _hidden = false;
    await _refreshNetwork(force: true);
    if (rebind) {
      await _rebindUdp();
    } else {
      // 短隐藏也可能让旧接口 socket 半死：主 socket 按原逻辑不重绑，但接口
      // socket 无条件重建；组播按接口重新加入（幂等）。
      await _syncInterfaceSockets(rebuild: true);
      await _joinIpv4Interfaces();
      await _joinIpv6Interfaces();
    }
    if (_hasSockets && !_isCellularNow) _scheduleBurst();
  }

  /// 后台：取消所有公告计时器；不主动探测。
  void onAppHidden() {
    _hidden = true;
    _cancelBurst();
  }

  /// 换网：收到 connectivity 事件就重绑 UDP（Wi-Fi 重连可能 IP 不变但旧
  /// socket 已死）；只有接口指纹变化时才清 presence / nonce，旧端点仍可先试。
  Future<void> onNetworkChanged() async {
    if (!_running) return;
    final changed = await _refreshNetwork(force: true);
    await _rebindUdp();
    if (changed) {
      _presence.clear();
      _nonces.clear();
    }
    if (!_hidden && _hasSockets && !_isCellularNow) _scheduleBurst();
  }

  /// 跑一轮发现：有候选只单播并等 [candidateWindow]；无候选 / 强制广播并等
  /// [fullWindow]。蜂窝与后台不发任何 UDP。
  Future<void> discover({required bool force}) async {
    if (!_running) return;
    await _ensureKey();
    if (_hidden || _isCellularNow) return;
    final changed = await _refreshNetwork(force: false);
    // 60s 节流窗口内换网（例如 DHCP 续租 / 静默切 Wi-Fi）时，发现层可能
    // 先看到新地址但 socket 还绑在旧接口上：立即重绑再发包。presence 保留，
    // 旧端点仍可先试。
    if (changed) await _rebindUdp();
    if (_key == null) return;
    final ports = discoveryPorts;
    // 两族都绑不上：不会再有新应答，直接让传输层走候选 HTTP 直连。
    if (ports.v4 == 0 && ports.v6 == 0) return;

    final hasCandidates = _hasCandidates;
    final broadcast = force || !hasCandidates;
    _sendAnnouncement(broadcast: broadcast, countBroadcast: broadcast);
    if (broadcast) {
      await Future<void>.delayed(fullWindow);
    } else {
      await Future<void>.delayed(candidateWindow);
    }
  }

  /// 全部 HTTP 失败后的补一次广播探测（不无限重试）。
  Future<void> rediscover() async {
    if (!_running || _hidden || _isCellularNow) return;
    await _ensureKey();
    if (_key == null) return;
    final ports = discoveryPorts;
    if (ports.v4 == 0 && ports.v6 == 0) return;
    _sendAnnouncement(broadcast: true, countBroadcast: true);
    await Future<void>.delayed(supplementaryWindow);
  }

  /// 本地变更但本轮推送零对端：单次定向公告（只单播，不再广播）。
  Future<void> announceLocalChange() async {
    if (!_running || _hidden || _isCellularNow) return;
    await _ensureKey();
    if (_key == null) return;
    _sendAnnouncement(broadcast: false);
  }

  /// 已通过验证的持久化端点（公告 burst / 单播探测目标来源）。
  List<LanPeerEndpoint> get knownPeers =>
      _knownPeersProvider?.call() ?? const [];

  List<LanProbeTarget> get probeTargets =>
      _probeTargetsProvider?.call() ?? const [];

  bool get _hasCandidates =>
      _presence.isNotEmpty ||
      knownPeers.any((peer) => peer.httpPort > 0) ||
      probeTargets.isNotEmpty;

  bool get _isCellularNow => _isCellular?.call() ?? false;

  bool get _hasSockets => _udp4 != null || _udp6 != null;

  void _scheduleBurst() {
    _cancelBurst();
    final nonce = _newNonce();
    // 同一 burst 的 3 次发送复用同一份字节与 nonce：对端按
    // `(deviceId, nonce)` 去重，广播 + 组播重复到达只产生一次 sighting。
    final packet = _buildPacket(Msd1.typeAnnounce, nonce: nonce);
    for (final delay in burstDelaysMs) {
      _burstTimers.add(Timer(Duration(milliseconds: delay), () {
        if (!_running || _hidden || _isCellularNow) return;
        _sendAnnouncement(
          broadcast: true,
          countBroadcast: false,
          trackBroadcastAvailability: false,
          packet: packet,
        );
      }));
    }
  }

  void _cancelBurst() {
    for (final timer in _burstTimers) {
      timer.cancel();
    }
    _burstTimers.clear();
  }

  /// 发一条公告：`broadcast` 时加 v4 广播 + v4/v6 组播，否则只单播。
  void _sendAnnouncement({
    String? nonce,
    bool broadcast = true,
    bool countBroadcast = false,
    bool trackBroadcastAvailability = true,
    Uint8List? packet,
  }) {
    final bytes = packet ?? _buildPacket(Msd1.typeAnnounce, nonce: nonce);
    if (bytes == null) return;
    if (broadcast) {
      _sendBroadcast(bytes, trackAvailability: trackBroadcastAvailability);
      if (countBroadcast) _broadcastCount++;
    }
    for (final target in _unicastTargets()) {
      _sendTo(bytes, target.host, target.port);
    }
  }

  LanDiscoveryMessage? _buildMessage(int type, {String? nonce}) {
    final key = _key;
    if (key == null) return null;
    return LanDiscoveryMessage(
      type: type,
      deviceId: deviceId,
      name: _deviceName(),
      httpPort: _httpPortProvider(),
      probePort: _probePortProvider?.call() ?? advertisedProbePort,
      addresses: _ownAddresses,
      snapshotId: _snapshotIdProvider?.call() ?? '',
      journalHead: _journalHeadProvider?.call(),
      categories: _categoriesProvider?.call() ??
          [for (final category in SyncCategory.values) category.name],
      nonce: nonce ?? _newNonce(),
      bootId: bootId,
    );
  }

  Uint8List? _buildPacket(int type, {String? nonce}) {
    final message = _buildMessage(type, nonce: nonce);
    final key = _key;
    if (message == null || key == null) return null;
    return Msd1.encode(message, key);
  }

  List<LanProbeTarget> _unicastTargets() {
    final targets = <LanProbeTarget>[];
    void add(String host, int port) {
      final normalized = normalizePeerHost(host);
      if (normalized.isEmpty || port <= 0) return;
      if (targets.any((t) => t.host == normalized && t.port == port)) return;
      if (targets.length >= maxUnicastTargets) return;
      targets.add((host: normalized, port: port));
    }

    for (final target in probeTargets) {
      add(target.host, target.port);
    }
    for (final peer in knownPeers) {
      if (peer.deviceId == deviceId) continue;
      add(peer.host, peer.probePort > 0 ? peer.probePort : _udpPort);
    }
    for (final peer in _presence.values) {
      add(peer.host, peer.probePort > 0 ? peer.probePort : _udpPort);
    }
    return targets;
  }

  /// v4 广播 + v4 组播 + v6 组播；失败只记「广播不可用」，单播照常。
  ///
  /// v4 除了主 wildcard socket，还从每个按接口 socket 各发一遍：多网卡 /
  /// 全隧道 VPN 下默认路由未必指向对端所在链路，任一接口成功即算发出；
  /// 接口 socket 全部不可用时仍保留主 socket 的旧行为。
  bool _sendBroadcast(Uint8List packet, {bool trackAvailability = true}) {
    var sent = false;
    final broadcast = InternetAddress('255.255.255.255');
    final multicast4 = InternetAddress(Msd1.ipv4MulticastHost);
    void sendV4(RawDatagramSocket socket) {
      for (final target in [broadcast, multicast4]) {
        try {
          if (socket.send(packet, target, _udpPort) > 0) sent = true;
        } catch (_) {
          // 广播 / 组播被系统策略拒绝（iOS entitlement / 网络策略）或该
          // 接口没有组播路由：其他接口与主 socket 继续尝试。
        }
      }
    }

    final v4 = _udp4;
    final v6 = _udp6;
    if (v4 != null) sendV4(v4);
    for (final entry in _interfaceSockets.values) {
      sendV4(entry.socket);
    }
    if (v6 != null) {
      try {
        if (v6.send(
              packet,
              InternetAddress(Msd1.ipv6MulticastHost),
              _udpPort,
            ) >
            0) {
          sent = true;
        }
      } catch (_) {
        // 无 v6 组播接口（errno 99 等）：v4 路径照常。
      }
    }
    if (trackAvailability) _broadcastUnavailable = !sent;
    return sent;
  }

  bool _sendTo(Uint8List packet, String host, int port) {
    final address = InternetAddress.tryParse(normalizePeerHost(host));
    if (address == null || port <= 0) return false;
    final sockets = address.type == InternetAddressType.IPv6
        ? [_udp6, _udp4]
        : [_udp4, _udp6];
    for (final socket in sockets) {
      if (socket == null) continue;
      try {
        if (socket.send(packet, address, port) > 0) return true;
      } catch (_) {
        // 换另一族再试；族不匹配时换过去也只会失败。
      }
    }
    return false;
  }

  Future<void> _bindSockets(int v4Port, int v6Port) async {
    // 新 socket 需要重新按接口加入组播；旧记账立即失效。
    _ipv4MulticastJoins.reset();
    _ipv6MulticastJoins.reset();
    _udp4 = await _bindFamily(InternetAddress.anyIPv4, v4Port);
    _udp6 = await _bindFamily(InternetAddress.anyIPv6, v6Port);
    final v4 = _udp4;
    final v6 = _udp6;
    if (v4 != null) {
      _sub4 = v4.listen(
        (event) => _onDatagram(v4, event),
        onError: (Object _) {},
      );
    }
    if (v6 != null) {
      _sub6 = v6.listen(
        (event) => _onDatagram(v6, event),
        onError: (Object _) {},
      );
    }
  }

  Future<RawDatagramSocket?> _bindFamily(
    InternetAddress address,
    int preferredPort,
  ) async {
    final ports = preferredPort > 0 ? [preferredPort, 0] : [0];
    for (final port in ports) {
      try {
        final socket = await _udpBinder(address, port);
        try {
          if (address.type == InternetAddressType.IPv4) {
            socket.broadcastEnabled = true;
            socket.multicastHops = 1;
            socket.joinMulticast(InternetAddress(Msd1.ipv4MulticastHost));
          } else {
            socket.joinMulticast(InternetAddress(Msd1.ipv6MulticastHost));
            socket.multicastHops = 1;
          }
        } catch (e) {
          // iOS 缺 multicast entitlement / 系统策略拦截：该能力不可用，
          // 单播与 HTTP 照常。
          _logger.warning('UDP ${address.address}:$port 组播能力启用失败', e);
        }
        return socket;
      } on SocketException catch (e) {
        final fallback = port == preferredPort && preferredPort > 0;
        _logger.warning(
          'UDP 绑定 ${address.address}:$port 失败'
          '（errno=${e.osError?.errorCode}）'
          '${fallback ? '，改绑系统分配端口' : '，该族发现不可用'}',
        );
      } catch (e) {
        _logger.warning('UDP 绑定 ${address.address}:$port 失败', e);
      }
    }
    return null;
  }

  /// 重绑主 socket；并发调用排队执行，避免两次 `_bindSockets` 交错覆盖
  /// `_udp4/_udp6` 并泄漏旧订阅。
  Future<void> _rebindUdp() {
    final next = _udpRebindTail.then((_) => _rebindUdpNow());
    _udpRebindTail = next.catchError((Object e) {
      _logger.warning('UDP 主 socket 重绑失败（保留现有发现能力）', e);
    });
    return _udpRebindTail;
  }

  Future<void> _rebindUdpNow() async {
    if (!_running) return;
    final v4Port = _udp4?.port ?? 0;
    final v6Port = _udp6?.port ?? 0;
    await _closeMainSockets();
    if (!_running) return;
    await _bindSockets(
      v4Port > 0 ? v4Port : _udpPort,
      v6Port > 0 ? v6Port : _udpPort,
    );
    if (!_running) {
      // stop 在 bind 期间到达：不要留下 main socket 的订阅。
      await _closeMainSockets();
      return;
    }
    // Wi-Fi 重连可能 IP 不变但旧接口 socket 已死：主 socket 重绑后一并重建。
    await _syncInterfaceSockets(rebuild: true);
    if (!_running) return;
    await _joinIpv4Interfaces();
    await _joinIpv6Interfaces();
  }

  Future<void> _closeMainSockets() async {
    await _sub4?.cancel();
    _sub4 = null;
    await _sub6?.cancel();
    _sub6 = null;
    _udp4?.close();
    _udp4 = null;
    _udp6?.close();
    _udp6 = null;
  }

  /// 按 [_interfaceIpv4Addresses] 重建接口 socket；调用串行化，地址连续
  /// 变化时不会出现两次绑定交错。
  Future<void> _syncInterfaceSockets({bool rebuild = false}) {
    final next = _interfaceSyncTail.then((_) async {
      if (!_running) {
        await _closeInterfaceSockets();
        return;
      }
      if (rebuild) await _closeInterfaceSockets();
      await _reconcileInterfaceSockets();
    });
    _interfaceSyncTail = next.catchError((Object e) {
      _logger.warning('按接口 UDP socket 同步失败（降级为默认路由发现）', e);
    });
    return _interfaceSyncTail;
  }

  Future<void> _reconcileInterfaceSockets() async {
    if (!_running) return;
    // 用完整列表而不是公告用的 `_ownAddresses`（后者被 8 条上限截断）。
    final desired = _interfaceIpv4Addresses;
    for (final host in [
      for (final host in _interfaceSockets.keys)
        if (!desired.contains(host)) host,
    ]) {
      final entry = _interfaceSockets.remove(host);
      await entry?.close();
    }
    for (final host in desired) {
      if (_interfaceSockets.containsKey(host)) continue;
      await _bindInterfaceSocket(host);
    }
  }

  /// 为单个 IPv4 接口绑定临时端口 socket；失败只跳过该接口。
  Future<void> _bindInterfaceSocket(String host) async {
    final address = InternetAddress.tryParse(host);
    if (address == null || address.type != InternetAddressType.IPv4) return;
    final RawDatagramSocket socket;
    try {
      socket = await _udpBinder(address, 0);
    } on SocketException catch (e) {
      _logger.warning(
        '按接口 UDP 绑定 $host 失败（errno=${e.osError?.errorCode}），跳过该接口',
      );
      return;
    } catch (e) {
      _logger.warning('按接口 UDP 绑定 $host 失败，跳过该接口', e);
      return;
    }
    // 绑定期间可能已经 stop / 换网：不能再把 socket 挂进来。
    if (!_running) {
      socket.close();
      return;
    }
    try {
      socket.broadcastEnabled = true;
      socket.multicastHops = 1;
      // 不在这里 join 组播：本 socket 绑的是临时端口，join 只服务该端口，
      // 收不到发往 47825 的公告。47825 的组播接收由主 socket 按接口 join。
    } catch (e) {
      // 该接口没有广播 / 组播发送权限：跳过发送能力，单播回包仍可用。
      _logger.warning('接口 $host 广播能力启用失败（保留单播回包）', e);
    }
    final subscription = socket.listen(
      (event) => _onDatagram(socket, event),
      onError: (Object _) {},
    );
    _interfaceSockets[host] = _InterfaceSocket(
      socket: socket,
      subscription: subscription,
    );
  }

  Future<void> _closeInterfaceSockets() async {
    final entries = _interfaceSockets.values.toList();
    _interfaceSockets.clear();
    for (final entry in entries) {
      try {
        await entry.close();
      } catch (e) {
        _logger.fine('关闭按接口 UDP socket 失败', e);
      }
    }
  }

  /// IPv4 组播接收：主 wildcard socket 按接口加入 `224.0.0.169`。
  ///
  /// 接口 socket 的临时端口只接收单播回包，不承担 47825 的组播接收。
  Future<void> _joinIpv4Interfaces() => _joinMulticastByInterface(
        socket: _udp4,
        currentSocket: () => _udp4,
        type: InternetAddressType.IPv4,
        groupHost: Msd1.ipv4MulticastHost,
        tracker: _ipv4MulticastJoins,
        label: 'IPv4',
      );

  /// IPv6 组播接收按接口加入：发送侧仍只走主 v6 socket 的系统默认路由
  /// （Dart 没有跨平台的 `IPV6_MULTICAST_IF`），失败只影响该接口接收。
  Future<void> _joinIpv6Interfaces() => _joinMulticastByInterface(
        socket: _udp6,
        currentSocket: () => _udp6,
        type: InternetAddressType.IPv6,
        groupHost: Msd1.ipv6MulticastHost,
        tracker: _ipv6MulticastJoins,
        label: 'IPv6',
      );

  /// 主 wildcard socket 按接口 join 组播。join 与归属都绑定 socket identity：
  /// 重绑后的旧调用不能把接口名写进新 socket 的记账。
  Future<void> _joinMulticastByInterface({
    required RawDatagramSocket? socket,
    required RawDatagramSocket? Function() currentSocket,
    required InternetAddressType type,
    required String groupHost,
    required _MulticastJoinTracker tracker,
    required String label,
  }) async {
    if (socket == null) {
      tracker.reset();
      return;
    }
    List<NetworkInterface> interfaces;
    try {
      interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: type,
      );
    } catch (e) {
      _logger.fine('枚举 $label 接口失败（组播接收仅走默认接口）', e);
      return;
    }
    if (!_running || !identical(currentSocket(), socket)) return;
    if (!identical(tracker.socket, socket)) {
      tracker.reset();
      tracker.socket = socket;
    }
    // 接口消失后剪掉记账：同名接口重新出现时能重新 join。
    final present = {for (final interface in interfaces) interface.name};
    tracker.interfaces.removeWhere((name) => !present.contains(name));
    for (final interface in interfaces) {
      if (tracker.interfaces.contains(interface.name)) continue;
      try {
        socket.joinMulticast(InternetAddress(groupHost), interface);
      } catch (e) {
        // 主 socket 绑定时已按「无指定接口」join 过一次，默认接口重复
        // join 会报 EADDRINUSE；这表示该接口已经收得到组播，按已加入记账。
        if (!_isAlreadyJoined(e)) {
          // 加组失败只影响该接口的组播接收，广播发送仍保留。
          _logger.fine('$label 组播加入 ${interface.name} 失败（仅影响该接口接收）', e);
          continue;
        }
      }
      // join 期间可能已经重绑：旧 socket 的接口名不能写进新记账。
      if (!_running || !identical(currentSocket(), socket)) return;
      if (!identical(tracker.socket, socket)) return;
      tracker.interfaces.add(interface.name);
    }
  }

  /// 同一 socket 重复加入同一接口组播：Linux 98 / macOS 48 / Windows 10048。
  static bool _isAlreadyJoined(Object error) {
    final int? code;
    if (error is SocketException) {
      code = error.osError?.errorCode;
    } else if (error is OSError) {
      code = error.errorCode;
    } else {
      code = null;
    }
    return code == 98 || code == 48 || code == 10048;
  }

  void _onDatagram(RawDatagramSocket socket, RawSocketEvent event) {
    if (!_running || event != RawSocketEvent.read) return;
    final datagram = socket.receive();
    if (datagram == null) return;
    final now = _nowMs();
    final source = datagram.address.address;
    // MSP（配对发现）与 MSD（同步发现）是两套独立协议：MSP 没有 MAC，也不
    // 写 presence / 名册 / 调度器。先按 magic 分派，再各自限流。
    if (Msp1.looksLike(datagram.data)) {
      if (!_pairingRateLimiter.allow(source, now)) return;
      final pairing = Msp1.decode(datagram.data);
      if (pairing == null || pairing.deviceId == deviceId) return;
      if (!_pairingDatagrams.isClosed) {
        _pairingDatagrams.add(LanPairingDatagram(
          message: pairing,
          sourceHost: source,
          sourcePort: datagram.port,
          receivedAt: now,
        ));
      }
      return;
    }
    // 顺序是安全边界：先限流，再验 MAC，最后才解析 JSON。
    if (!_rateLimiter.allow(source, now)) return;
    final key = _key;
    if (key == null) return;
    final message = Msd1.decode(datagram.data, key);
    if (message == null) return;
    if (message.deviceId == deviceId) return;
    if (!_nonces.accept(message.deviceId, message.nonce, now)) return;
    if (message.httpPort <= 0) return;

    final presence = LanPresence(
      deviceId: message.deviceId,
      name: message.name,
      host: source,
      httpPort: message.httpPort,
      // 接口 socket 的源端口是临时端口：优先用认证报文里的主 socket 端口。
      probePort: resolvePresenceProbePort(
        announced: message.probePort,
        source: datagram.port > 0 ? datagram.port : _udpPort,
      ),
      addresses: [
        for (final address in message.addresses)
          if (isRoutablePeerAddress(address)) normalizePeerHost(address),
      ],
      snapshotId: message.snapshotId,
      journalHead: message.journalHead,
      bootId: message.bootId,
      lastHeardAt: now,
      epoch: _networkEpoch,
    );
    _upsertPresence(presence);
    if (!_sightings.isClosed) _sightings.add(presence.toSighting());

    if (message.isAnnounce) {
      final ack = _buildPacket(
        Msd1.typeAck,
        nonce: message.nonce,
      );
      if (ack != null) {
        try {
          socket.send(ack, datagram.address, datagram.port);
        } catch (_) {
          // 应答失败只让对端本轮多等一会儿，不影响本机。
        }
      }
    }
  }

  void _upsertPresence(LanPresence presence) {
    _presence[presence.deviceId] = presence;
    if (_presence.length <= maxPeers) return;
    // 淘汰最久没听到的对端（防伪造公告灌爆内存）。
    String? oldestId;
    var oldestAt = 1 << 62;
    for (final entry in _presence.entries) {
      if (entry.value.lastHeardAt < oldestAt) {
        oldestAt = entry.value.lastHeardAt;
        oldestId = entry.key;
      }
    }
    if (oldestId != null) _presence.remove(oldestId);
  }

  /// 枚举本机接口 / 注入地址并比较指纹；返回是否发生变化。
  Future<bool> _refreshNetwork({required bool force}) async {
    final now = _nowMs();
    final last = _lastInterfaceScanAt;
    if (!force &&
        last != null &&
        now - last < interfaceScanInterval.inMilliseconds) {
      return false;
    }
    _lastInterfaceScanAt = now;
    late final String fingerprint;
    late final List<String> addresses;
    late final List<String> interfaceIpv4Addresses;
    try {
      final provider = _localAddressesProvider;
      if (provider != null) {
        final raw = await provider();
        fingerprint = (raw.map(normalizePeerHost).toList()..sort()).join('|');
        addresses = _limitAddresses(raw);
        interfaceIpv4Addresses = _routableIpv4Addresses(raw);
      } else {
        final interfaces = await NetworkInterface.list(
          includeLoopback: false,
          type: InternetAddressType.any,
        );
        final parts = <String>[];
        final hosts = <String>[];
        for (final interface in interfaces) {
          for (final address in interface.addresses) {
            parts.add('${interface.name}|${address.address}');
            final host = address.address.trim();
            if (isRoutablePeerAddress(host)) hosts.add(host);
          }
        }
        parts.sort();
        fingerprint = parts.join('|');
        addresses = _limitAddresses(hosts);
        interfaceIpv4Addresses = _routableIpv4Addresses(hosts);
      }
    } catch (e) {
      _logger.fine('枚举本机地址失败（公告将不带地址候选）', e);
      // 失败不占用 60s 节流窗口：下一轮再试，避免一次瞬时错误让地址候选
      // 空置一整分钟。
      _lastInterfaceScanAt = null;
      return false;
    }
    final firstScan = !_interfaceScanned;
    final changed = !firstScan && fingerprint != _interfaceFingerprint;
    _interfaceScanned = true;
    _interfaceFingerprint = fingerprint;
    _ownAddresses = addresses;
    // 接口 socket 不参与 `addrs` 的 8 条上限：IPv6 混排 / 接口多时也不能漏。
    _interfaceIpv4Addresses = interfaceIpv4Addresses;
    if (firstScan) {
      _networkEpoch = 1;
    } else if (changed) {
      _networkEpoch++;
      _logger.info('本机接口指纹变化，局域网发现进入第 $_networkEpoch 代');
    }
    return changed;
  }

  static List<String> _limitAddresses(Iterable<String> addresses) {
    final hosts = <String>[];
    for (final raw in addresses) {
      final host = normalizePeerHost(raw);
      if (!isRoutablePeerAddress(host)) continue;
      if (hosts.contains(host)) continue;
      hosts.add(host);
      if (hosts.length >= Msd1.maxAddresses) break;
    }
    return hosts;
  }

  /// 完整可路由 IPv4 接口列表（去重，不受公告 8 条上限约束）。
  static List<String> _routableIpv4Addresses(Iterable<String> addresses) {
    final hosts = <String>[];
    for (final raw in addresses) {
      final host = normalizePeerHost(raw);
      if (!isRoutablePeerAddress(host)) continue;
      final address = InternetAddress.tryParse(host);
      if (address == null || address.type != InternetAddressType.IPv4) continue;
      if (hosts.contains(host)) continue;
      hosts.add(host);
    }
    return hosts;
  }

  static String _newNonce() => _base64Url(_randomBytes(16));

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes;
  }

  static String _base64Url(Uint8List bytes) =>
      base64UrlEncode(bytes).replaceAll('=', '');

  static Future<RawDatagramSocket> _bindDatagram(
    InternetAddress address,
    int port,
  ) =>
      RawDatagramSocket.bind(address, port, reuseAddress: true);
}

/// 一个按接口绑定的 IPv4 socket 及其事件订阅。
class _InterfaceSocket {
  _InterfaceSocket({
    required this.socket,
    required this.subscription,
  });

  final RawDatagramSocket socket;
  final StreamSubscription<RawSocketEvent> subscription;

  Future<void> close() async {
    await subscription.cancel();
    socket.close();
  }
}

/// 主 socket 的按接口组播加入记账；socket 一变整份作废。
class _MulticastJoinTracker {
  RawDatagramSocket? socket;
  final Set<String> interfaces = {};

  void reset() {
    socket = null;
    interfaces.clear();
  }
}
