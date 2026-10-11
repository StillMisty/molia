import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../../domain/models/device_sync.dart';
import '../../../domain/ports/sync_transport.dart';
import '../sync_crypto.dart';

/// 局域网直连传输：UDP 广播发现 + 各设备内置 HTTP 快照端点。
///
/// 协议（明文层只有设备名与端口，数据全部加密）：
/// - UDP `molia-sync.probe` JSON：`{m, v, deviceId, name, port, reply}`；
///   收到非回复探测时向来源单播应答（携带自己的 HTTP 端口）；
/// - HTTP `GET  /molia-sync/v1/snapshot`：返回本机加密快照；
/// - HTTP `POST /molia-sync/v1/snapshot`：接收对端加密快照。
///
/// 信任模型：数据用同步口令派生密钥加密，能解密者即已授权；HTTP 层不再
/// 鉴权（快照是密文，无法解密者拿不到内容）。
class LanSyncTransport implements SyncTransport {
  LanSyncTransport({
    required this.deviceId,
    required String Function() deviceName,
    required SyncCodec codec,
    required Future<String?> Function() passphraseProvider,
    required Future<SyncEnvelope> Function() snapshotProvider,
    List<({String host, int port})>? probeTargets,
    int udpPort = defaultUdpPort,
    Duration probeWindow = const Duration(milliseconds: 1200),
    Duration requestTimeout = const Duration(seconds: 3),
  })  : _deviceName = deviceName,
        _codec = codec,
        _passphraseProvider = passphraseProvider,
        _snapshotProvider = snapshotProvider,
        _probeTargets = probeTargets ?? const [],
        _udpPort = udpPort,
        _probeWindow = probeWindow,
        _requestTimeout = requestTimeout;

  static const int defaultUdpPort = 47825;
  static const String snapshotPath = '/molia-sync/v1/snapshot';

  /// 快照体积上限（含大量统计事件时留足余量；超出视为异常数据丢弃）。
  static const int maxSnapshotBytes = 32 * 1024 * 1024;

  final String deviceId;
  final String Function() _deviceName;
  final SyncCodec _codec;
  final Future<String?> Function() _passphraseProvider;
  final Future<SyncEnvelope> Function() _snapshotProvider;

  /// 测试注入：向指定地址单播探测（空 = 仅广播，生产路径）。
  final List<({String host, int port})> _probeTargets;
  final int _udpPort;
  final Duration _probeWindow;
  final Duration _requestTimeout;

  final StreamController<SyncEnvelope> _incoming =
      StreamController<SyncEnvelope>.broadcast();
  final List<_Peer> _peers = [];

  RawDatagramSocket? _udp;
  HttpServer? _http;
  bool _running = false;

  @override
  String get kind => 'lan';

  @override
  bool get isRunning => _running;

  @override
  Stream<SyncEnvelope> get incoming => _incoming.stream;

  int get _httpPort => _http?.port ?? 0;

  @override
  Future<void> start() async {
    if (_running || kIsWeb) return;
    _udp = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      _udpPort,
      reuseAddress: true,
    );
    _udp!.broadcastEnabled = true;
    _udp!.listen(_onDatagram);

    _http = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _http!.listen(_onHttpRequest);
    _running = true;
  }

  @override
  Future<void> stop() async {
    _running = false;
    _peers.clear();
    _udp?.close();
    _udp = null;
    await _http?.close(force: true);
    _http = null;
  }

  @override
  Future<List<SyncEnvelope>> pull() async {
    if (!_running) return const [];
    final passphrase = await _passphraseProvider();
    if (passphrase == null || passphrase.trim().isEmpty) return const [];

    final peers = await _discoverPeers();
    final result = <SyncEnvelope>[];
    for (final peer in peers) {
      final bytes = await _fetchSnapshot(peer);
      if (bytes == null) continue;
      try {
        result.add(_codec.decrypt(bytes, passphrase));
      } on SyncCryptoException {
        // 对端口令不同 / 数据损坏：跳过该对端，不影响其他设备。
      }
    }
    return result;
  }

  @override
  Future<void> push(SyncEnvelope envelope) async {
    if (!_running) return;
    final passphrase = await _passphraseProvider();
    if (passphrase == null || passphrase.trim().isEmpty) return;
    final payload = _codec.encrypt(envelope, passphrase);
    for (final peer in List.of(_peers)) {
      await _postSnapshot(peer, payload);
    }
  }

  /// 广播探测并收集应答（清空过期对端；仅保留本轮应答者）。
  Future<List<_Peer>> _discoverPeers() async {
    _peers.clear();
    final socket = _udp;
    if (socket == null) return const [];
    final probe = utf8.encode(jsonEncode({
      'm': 'molia-sync.probe',
      'v': 1,
      'deviceId': deviceId,
      'name': _deviceName(),
      'port': _httpPort,
      'reply': false,
    }));
    if (_probeTargets.isEmpty) {
      try {
        socket.send(probe, InternetAddress('255.255.255.255'), _udpPort);
      } catch (_) {
        // 广播被系统策略拒绝时不影响单播对端（如测试注入目标）。
      }
    } else {
      for (final target in _probeTargets) {
        try {
          socket.send(probe, InternetAddress(target.host), target.port);
        } catch (_) {
          // 个别目标不可达时跳过。
        }
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
      _rememberPeer(_Peer(
        deviceId: peerId,
        host: datagram.address.address,
        port: port.toInt(),
        name: message['name'] is String ? message['name'] as String : '',
      ));
      return;
    }
    // 应答探测：单播回来源地址。
    final reply = utf8.encode(jsonEncode({
      'm': 'molia-sync.probe',
      'v': 1,
      'deviceId': deviceId,
      'name': _deviceName(),
      'port': _httpPort,
      'reply': true,
    }));
    try {
      socket.send(reply, datagram.address, datagram.port);
    } catch (_) {
      // 应答失败仅让该对端本轮发现不到本机。
    }
  }

  void _rememberPeer(_Peer peer) {
    _peers.removeWhere((existing) => existing.deviceId == peer.deviceId);
    _peers.add(peer);
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

  Future<void> _postSnapshot(_Peer peer, Uint8List payload) async {
    final client = HttpClient()..connectionTimeout = _requestTimeout;
    try {
      final request = await client
          .postUrl(Uri.parse('http://${peer.host}:${peer.port}$snapshotPath'))
          .timeout(_requestTimeout);
      request.headers.contentType = ContentType.binary;
      request.add(payload);
      final response = await request.close().timeout(_requestTimeout);
      await response.drain<void>();
    } catch (_) {
      // 推送失败交由对端下一轮拉取兜底。
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

  const _Peer({
    required this.deviceId,
    required this.host,
    required this.port,
    required this.name,
  });
}
