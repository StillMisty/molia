import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../../domain/models/device_sync.dart';
import '../../../domain/ports/sync_transport.dart';
import '../../../utils/device_id.dart';
import '../sync_crypto.dart';

/// 局域网直连传输：UDP 广播（+ 手动地址簿单播）发现 + 各设备内置 HTTP 快照端点。
///
/// 协议（明文层只有设备名 / 端口 / 内容指纹，数据全部加密）：
/// - UDP `molia-sync.probe` JSON：`{m, v, deviceId, name, port, reply, snapshotId}`；
///   收到非回复探测时向来源单播应答（携带自己的 HTTP 端口与内容指纹）；
/// - HTTP `GET  /molia-sync/v1/snapshot`：返回本机加密快照；
/// - HTTP `POST /molia-sync/v1/snapshot`：接收对端加密快照。
///
/// 探测应答里的 `snapshotId`（记录集规范化哈希）与本机缓存的「上次拉到的
/// 对端指纹」一致时跳过 GET：内容没变就不传、不解密、不合并。
///
/// 信任模型：数据用同步口令派生密钥加密，能解密者即已授权；HTTP 层不做
/// 额外鉴权（快照是密文，无法解密者拿不到内容）。
///
/// 发现失败（AP 隔离 / 多网段 / 防火墙 / VPN）时用 [manualPeersProvider]
/// 提供的手动地址簿做单播探测；权限被拒（Android 17 起局域网默认阻断）时
/// 传输不启动并把原因记为 `permission_denied`——**手动地址救不了权限**。
class LanSyncTransport implements SyncTransport {
  LanSyncTransport({
    required this.deviceId,
    required String Function() deviceName,
    required SyncCodec codec,
    required Future<String?> Function() passphraseProvider,
    required Future<SyncEnvelope> Function() snapshotProvider,
    String Function()? snapshotIdProvider,
    List<({String host, int port})>? probeTargets,
    List<ManualPeer> Function()? manualPeersProvider,
    void Function(ManualPeer learned)? onPeerResolved,
    int Function()? httpPortProvider,
    void Function(int port)? onHttpPortBound,
    Future<bool> Function()? permissionGate,
    int udpPort = defaultUdpPort,
    Duration probeWindow = const Duration(milliseconds: 1200),
    Duration requestTimeout = const Duration(seconds: 3),
  })  : _deviceName = deviceName,
        _codec = codec,
        _passphraseProvider = passphraseProvider,
        _snapshotProvider = snapshotProvider,
        _snapshotIdProvider = snapshotIdProvider,
        _probeTargets = probeTargets ?? const [],
        _manualPeersProvider = manualPeersProvider,
        _onPeerResolved = onPeerResolved,
        _httpPortProvider = httpPortProvider,
        _onHttpPortBound = onHttpPortBound,
        _permissionGate = permissionGate,
        _udpPort = udpPort,
        _probeWindow = probeWindow,
        _requestTimeout = requestTimeout;

  static const int defaultUdpPort = ManualPeer.defaultProbePort;
  static const String snapshotPath = '/molia-sync/v1/snapshot';

  /// 快照体积上限（含大量统计事件时留足余量；超出视为异常数据丢弃）。
  static const int maxSnapshotBytes = 32 * 1024 * 1024;

  final String deviceId;
  final String Function() _deviceName;
  final SyncCodec _codec;
  final Future<String?> Function() _passphraseProvider;
  final Future<SyncEnvelope> Function() _snapshotProvider;

  /// 本机最近一轮快照的内容指纹（探测应答携带；空 = 尚未产出快照）。
  final String Function()? _snapshotIdProvider;

  /// 测试注入：向指定地址单播探测（空 = 仅广播，生产路径）。
  final List<({String host, int port})> _probeTargets;

  /// 手动对端地址簿（发现失败时的兜底）。
  final List<ManualPeer> Function()? _manualPeersProvider;

  /// 首次接触学到 deviceId / httpPort / 名称后回写地址簿。
  final void Function(ManualPeer learned)? _onPeerResolved;

  /// 本机 HTTP 端口持久化：端口每次随机会让对端记不住本机。
  final int Function()? _httpPortProvider;
  final void Function(int port)? _onHttpPortBound;

  /// 局域网权限门：返回 false 时传输不启动（原因 = permission_denied）。
  final Future<bool> Function()? _permissionGate;

  final int _udpPort;
  final Duration _probeWindow;
  final Duration _requestTimeout;

  final StreamController<SyncEnvelope> _incoming =
      StreamController<SyncEnvelope>.broadcast();
  final List<_Peer> _peers = [];

  /// 上次成功拉到的各对端内容指纹（`deviceId` / 主机 → `snapshotId`）：
  /// 探测应答一致时跳过 GET。进程内缓存，重启后首轮重新拉一次。
  final Map<String, String> _peerSnapshotIds = {};
  final Logger _logger = Logger('molia.sync.lan');

  RawDatagramSocket? _udp;
  HttpServer? _http;
  bool _running = false;

  /// 启动失败的技术细节（端口占用、权限不足等）；null = 未失败。
  String? _startError;
  String? _unavailableReason;

  /// 广播发送失败（网络策略 / 缺少广播 entitlement）。
  bool _broadcastUnavailable = false;

  /// 本进程内曾成功发现过对端：用于区分「一直没对端」与「零应答」——
  /// 后者更可能是网络隔离（AP 隔离 / VPN / 防火墙）而不是没人在线。
  bool _everDiscoveredPeer = false;

  @override
  String get kind => SyncTransportKind.lan;

  @override
  bool get isRunning => _running;

  @override
  String? get unavailableReason =>
      _running ? null : _unavailableReason;

  @override
  String? get unavailableDetail => _running ? null : _startError;

  @override
  Stream<SyncEnvelope> get incoming => _incoming.stream;

  int get _httpPort => _http?.port ?? 0;

  @override
  Future<void> start() async {
    if (_running || kIsWeb) return;

    // 权限在前：Android 17 起局域网默认阻断，没有权限时绑定 / 收发包都会失败，
    // 直接给用户可行动的状态（授权 或 转 WebDAV），不做无意义的尝试。
    final gate = _permissionGate;
    if (gate != null && !await gate()) {
      _unavailableReason = SyncUnavailableReason.permissionDenied;
      _startError = '局域网访问权限未授予';
      _logger.warning('局域网权限未授予，传输不启动');
      return;
    }

    try {
      _udp = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _udpPort,
        reuseAddress: true,
      );
      _udp!.broadcastEnabled = true;
      _udp!.listen(_onDatagram);

      // 端口持久化：对端要记住本机才能主动连，随机端口等于每次都要重新发现。
      final rememberedPort = _httpPortProvider?.call() ?? 0;
      _http = await _bindHttp(rememberedPort);
      _http!.listen(_onHttpRequest);
      _running = true;
      _startError = null;
      _unavailableReason = null;
      if (_http!.port != rememberedPort) _onHttpPortBound?.call(_http!.port);
    } catch (e) {
      // 启动失败不能静默：开关显示「已打开」而实际没有监听，是用户实测
      // 「同步不生效」却查不出原因的主要来源。清掉半开资源并把原因留在
      // [unavailableReason] 供 UI 呈现。
      _startError = '$e';
      _unavailableReason = SyncUnavailableReason.startFailed;
      _logger.warning('局域网传输启动失败', e);
      _udp?.close();
      _udp = null;
      await _http?.close(force: true);
      _http = null;
    }
  }

  /// 优先绑定记忆端口；被占用时退回随机端口（并把新端口回写持久化）。
  Future<HttpServer> _bindHttp(int preferredPort) async {
    if (preferredPort > 0) {
      try {
        return await HttpServer.bind(InternetAddress.anyIPv4, preferredPort);
      } catch (_) {
        // 端口被占用 / 无权限：退回随机端口。
      }
    }
    return HttpServer.bind(InternetAddress.anyIPv4, 0);
  }

  @override
  Future<void> stop() async {
    _running = false;
    // 关闭后不残留上次的失败原因：状态面只表达「已关闭」，重新启用时由
    // start 重新判定可用性。
    _unavailableReason = null;
    _startError = null;
    _peers.clear();
    _udp?.close();
    _udp = null;
    await _http?.close(force: true);
    _http = null;
  }

  @override
  Future<SyncPullResult> pull() async {
    if (!_running) {
      return SyncPullResult(
        error: SyncIssue(
          code: _unavailableReason ?? SyncIssueCode.startFailed,
          detail: _startError,
        ),
      );
    }
    final passphrase = await _passphraseProvider();
    if (passphrase == null || passphrase.trim().isEmpty) {
      return const SyncPullResult(
        error: SyncIssue(code: SyncIssueCode.noPassphrase),
      );
    }

    final peers = await _discoverPeers();
    final envelopes = <SyncEnvelope>[];
    var failed = 0;
    var skipped = 0;
    var bytesIn = 0;
    SyncIssue? firstError;
    for (final peer in peers) {
      // 探测应答的内容指纹与本机上次拉到的对端指纹一致：内容没变，
      // 跳过 GET + 解密 + 合并（对端清单为空时不可能命中）。
      final cached = _peerSnapshotIds[peer.key];
      if (peer.snapshotId.isNotEmpty && cached == peer.snapshotId) {
        skipped++;
        continue;
      }
      final bytes = await _fetchSnapshot(peer);
      if (bytes == null) {
        failed++;
        firstError ??= SyncIssue(
          code: SyncIssueCode.peerReadFailed,
          args: {'peer': peer.label},
        );
        continue;
      }
      bytesIn += bytes.length;
      try {
        final envelope = _codec.decrypt(bytes, passphrase);
        envelopes.add(envelope);
        final fingerprint = envelope.snapshotId.isNotEmpty
            ? envelope.snapshotId
            : peer.snapshotId;
        if (fingerprint.isNotEmpty) {
          _peerSnapshotIds[peer.key] = fingerprint;
        }
      } on SyncCryptoException {
        // 对端口令不同 / 数据损坏：跳过该对端，不影响其他设备。
        failed++;
        firstError ??= SyncIssue(
          code: SyncIssueCode.peerDecryptFailed,
          args: {'peer': peer.label},
        );
      }
    }
    return SyncPullResult(
      envelopes: envelopes,
      peersSeen: peers.length,
      skippedUnchanged: skipped,
      failedPeers: failed,
      bytesIn: bytesIn,
      // 至少一个对端可达（拉到或未变跳过）才算接触成功；探测到但全部
      // 读取 / 解密失败仍是「所有对端都不可达」。
      contacted: peers.length > failed,
      error: firstError ?? _discoveryIssue(peers),
    );
  }

  /// 未发现任何对端时的原因（有对端则为 null）。
  ///
  /// 广播发送失败优先；其次是「此前成功发现过、本轮零应答」——后者通常是
  /// 网络隔离（AP 隔离 / VPN / 防火墙），提示手动地址与 WebDAV 出路。
  SyncIssue? _discoveryIssue(List<_Peer> peers) {
    if (peers.isNotEmpty) return null;
    if (_broadcastUnavailable) {
      return const SyncIssue(code: SyncIssueCode.broadcastUnavailable);
    }
    final manual = _manualPeersProvider?.call() ?? const <ManualPeer>[];
    if (_everDiscoveredPeer && manual.isEmpty) {
      return const SyncIssue(code: SyncIssueCode.discoverySilent);
    }
    return null;
  }

  @override
  Future<SyncPushResult> push(SyncEnvelope envelope) async {
    if (!_running) return SyncPushResult.none;
    final passphrase = await _passphraseProvider();
    if (passphrase == null || passphrase.trim().isEmpty) {
      return const SyncPushResult(
        error: SyncIssue(code: SyncIssueCode.noPassphrase),
      );
    }
    final payload = _codec.encrypt(envelope, passphrase);
    final succeededIds = <String>[];
    final failedIds = <String>[];
    SyncIssue? firstError;
    for (final peer in List.of(_peers)) {
      if (await _postSnapshot(peer, payload)) {
        succeededIds.add(peer.deviceId);
      } else {
        failedIds.add(peer.deviceId);
        firstError ??= SyncIssue(
          code: SyncIssueCode.peerPushFailed,
          args: {'peer': peer.label},
        );
      }
    }
    return SyncPushResult(
      succeededPeers: succeededIds.length,
      failedPeers: failedIds.length,
      succeededIds: succeededIds,
      failedIds: failedIds,
      bytesOut: payload.length * succeededIds.length,
      error: firstError,
    );
  }

  /// 广播探测 + 地址簿单播探测，收集应答（清空过期对端；仅保留本轮应答者）。
  Future<List<_Peer>> _discoverPeers() async {
    _peers.clear();
    final socket = _udp;
    if (socket == null) return const [];
    final manualPeers = _manualPeersProvider?.call() ?? const <ManualPeer>[];

    // 地址簿里已学到端口的对端先入队：即使探测应答被网络策略吞掉也能直连
    // （端口是学到的、不是猜的；连不上会被如实计为失败）。
    for (final manual in manualPeers) {
      if (manual.httpPort <= 0) continue;
      _rememberPeer(_Peer(
        deviceId: manual.deviceId,
        host: manual.host,
        port: manual.httpPort,
        name: manual.name,
      ));
    }

    final probe = utf8.encode(jsonEncode({
      'm': 'molia-sync.probe',
      'v': 1,
      'deviceId': deviceId,
      'name': _deviceName(),
      'port': _httpPort,
      'reply': false,
      if (_snapshotIdProvider?.call().isNotEmpty ?? false)
        'snapshotId': _snapshotIdProvider!.call(),
    }));
    if (_probeTargets.isEmpty) {
      try {
        socket.send(probe, InternetAddress('255.255.255.255'), _udpPort);
        _broadcastUnavailable = false;
      } catch (_) {
        // 广播被系统策略拒绝时不影响单播对端（如测试注入目标 / 手动地址簿）；
        // 记下来给「未发现对端」时的提示用（iOS 缺 multicast entitlement 也会走到这里）。
        _broadcastUnavailable = true;
      }
    }
    // 单播目标：测试注入 + 手动地址簿（探测端口缺省用本传输的 UDP 端口，
    // 生产里所有设备同端口；测试 / 多实例场景可显式指定）。
    final targets = <({String host, int port})>[
      ..._probeTargets,
      for (final manual in manualPeers)
        (host: manual.host, port: manual.probePort > 0 ? manual.probePort : _udpPort),
    ];
    for (final target in targets) {
      try {
        socket.send(probe, InternetAddress(target.host), target.port);
      } catch (_) {
        // 个别目标不可达时跳过。
      }
    }
    await Future<void>.delayed(_probeWindow);
    return List.of(_peers);
  }

  void _onDatagram(RawSocketEvent event) {
    final socket = _udp;
    if (socket == null || event != RawSocketEvent.read) return;
    final datagram = socket.receive();
    if (datagram == null) return;
    Map<String, dynamic> message;
    try {
      final decoded = jsonDecode(utf8.decode(datagram.data));
      if (decoded is! Map) return;
      message = decoded.cast<String, dynamic>();
    } catch (_) {
      return;
    }
    if (message['m'] != 'molia-sync.probe') return;
    final peerId = message['deviceId'];
    if (peerId is! String || peerId.isEmpty || peerId == deviceId) return;
    final port = message['port'];
    if (port is! num) return;

    if (message['reply'] == true) {
      _everDiscoveredPeer = true;
      final peer = _Peer(
        deviceId: peerId,
        host: datagram.address.address,
        port: port.toInt(),
        name: message['name'] is String ? message['name'] as String : '',
        snapshotId:
            message['snapshotId'] is String ? message['snapshotId'] as String : '',
      );
      _rememberPeer(peer);
      _resolveManualPeer(peer);
      return;
    }
    // 应答探测：单播回来源地址（携带本机端口与内容指纹）。
    final ownSnapshotId = _snapshotIdProvider?.call() ?? '';
    final reply = utf8.encode(jsonEncode({
      'm': 'molia-sync.probe',
      'v': 1,
      'deviceId': deviceId,
      'name': _deviceName(),
      'port': _httpPort,
      'reply': true,
      if (ownSnapshotId.isNotEmpty) 'snapshotId': ownSnapshotId,
    }));
    try {
      socket.send(reply, datagram.address, datagram.port);
    } catch (_) {
      // 应答失败仅让该对端本轮发现不到本机。
    }
  }

  void _rememberPeer(_Peer peer) {
    _peers.removeWhere((existing) => existing.key == peer.key);
    _peers.add(peer);
  }

  /// 手动条目首次接触（或地址 / 端口变化）后回写学到的信息。
  void _resolveManualPeer(_Peer peer) {
    final manualPeers = _manualPeersProvider?.call() ?? const <ManualPeer>[];
    for (final entry in manualPeers) {
      if (entry.host != peer.host) continue;
      if (entry.deviceId == peer.deviceId && entry.httpPort == peer.port) return;
      _onPeerResolved?.call(entry.mergeLearned(
        httpPort: peer.port,
        deviceId: peer.deviceId,
        name: peer.name,
      ));
      return;
    }
  }

  Future<Uint8List?> _fetchSnapshot(_Peer peer) async {
    final client = HttpClient()..connectionTimeout = _requestTimeout;
    try {
      final request = await client
          .getUrl(Uri.parse('http://${peer.host}:${peer.port}$snapshotPath'))
          .timeout(_requestTimeout);
      final response = await request.close().timeout(_requestTimeout);
      if (response.statusCode != HttpStatus.ok) return null;
      return await _readBody(response);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _postSnapshot(_Peer peer, Uint8List payload) async {
    final client = HttpClient()..connectionTimeout = _requestTimeout;
    try {
      final request = await client
          .postUrl(Uri.parse('http://${peer.host}:${peer.port}$snapshotPath'))
          .timeout(_requestTimeout);
      request.headers.contentType = ContentType.binary;
      request.add(payload);
      final response = await request.close().timeout(_requestTimeout);
      await response.drain<void>();
      return response.statusCode == HttpStatus.ok;
    } catch (_) {
      // 推送失败交由对端下一轮拉取兜底（失败计数上抛给报告）。
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _onHttpRequest(HttpRequest request) async {
    try {
      if (request.uri.path != snapshotPath) {
        request.response.statusCode = HttpStatus.notFound;
      } else if (request.method == 'GET') {
        final passphrase = await _passphraseProvider();
        if (passphrase == null || passphrase.trim().isEmpty) {
          request.response.statusCode = HttpStatus.serviceUnavailable;
        } else {
          final envelope = await _snapshotProvider();
          final payload = _codec.encrypt(envelope, passphrase);
          request.response.headers.contentType = ContentType.binary;
          request.response.add(payload);
        }
      } else if (request.method == 'POST') {
        final bytes = await _readBody(request);
        if (bytes == null) {
          request.response.statusCode = HttpStatus.badRequest;
        } else {
          final passphrase = await _passphraseProvider();
          if (passphrase == null || passphrase.trim().isEmpty) {
            request.response.statusCode = HttpStatus.serviceUnavailable;
          } else {
            try {
              final envelope = _codec.decrypt(bytes, passphrase);
              if (!_incoming.isClosed) _incoming.add(envelope);
            } on SyncCryptoException {
              request.response.statusCode = HttpStatus.badRequest;
            }
          }
        }
      } else {
        request.response.statusCode = HttpStatus.methodNotAllowed;
      }
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
      } catch (_) {
        // 连接可能已断开。
      }
    } finally {
      try {
        await request.response.close();
      } catch (_) {
        // 同上。
      }
    }
  }

  Future<Uint8List?> _readBody(Stream<List<int>> stream) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
      if (builder.length > maxSnapshotBytes) return null;
    }
    return builder.toBytes();
  }
}

class _Peer {
  final String deviceId;
  final String host;
  final int port;
  final String name;

  /// 对端探测应答携带的内容指纹（空 = 对端未提供 / 尚未产出快照）。
  final String snapshotId;

  const _Peer({
    required this.deviceId,
    required this.host,
    required this.port,
    required this.name,
    this.snapshotId = '',
  });

  /// 去重键：认领到设备 id 后按 id，未认领（手动地址首轮）按主机。
  String get key => deviceId.isNotEmpty ? deviceId : 'host:$host';

  /// 日志 / 错误文案用的人类可读标识（设备名 > 设备 id 短号 > 主机）。
  String get label {
    if (name.isNotEmpty) return name;
    if (deviceId.isNotEmpty) return shortDeviceId(deviceId);
    return host;
  }
}
