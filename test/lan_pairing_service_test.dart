import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:molia/data/sync/pairing/lan_pairing_service.dart';
import 'package:molia/data/sync/pairing/pairing_crypto.dart';
import 'package:molia/data/sync/pairing/pairing_http.dart';
import 'package:molia/data/sync/sync_crypto.dart';
import 'package:molia/data/sync/sync_passphrase.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/models/sync_nearby_pairing.dart';

/// 配对服务状态机：join / invite / both-none / conflict / sameGroup /
/// reject / timeout / 前台不可用 / body 上限 / 限流 / 单弹窗。
void main() {
  const passA = 'AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH';
  const passB = 'BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH-JJJJ';

  test('join：接收方有组、发起方无组 → 发起方拿到接收方口令', () async {
    final network = _LoopbackNetwork();
    final a = await _Device.start(
      network,
      id: 'devA',
      name: '设备A',
      passphrase: null,
      hasGroup: false,
    );
    final b = await _Device.start(
      network,
      id: 'devB',
      name: '设备B',
      passphrase: passB,
      hasGroup: true,
    );
    addTearDown(network.dispose);

    final attemptFuture = a.service.attempts
        .firstWhere((attempt) => attempt.status == SyncPairingStatus.pending);
    final promptFuture = b.service.incomingRequests.first;
    final resultFuture = a.service.requestPairing(_nearby(b));
    final prompt = await promptFuture.timeout(const Duration(seconds: 2));
    final attempt = await attemptFuture.timeout(const Duration(seconds: 2));

    expect(prompt.intent, SyncPairingIntent.join);
    expect(prompt.peerDeviceId, 'devA');
    expect(prompt.code, hasLength(6));
    expect(attempt.code, prompt.code, reason: '双方确认码必须一致');
    expect(attempt.peerName, '设备B');

    final outcome = await b.service.respond(prompt.requestId, accept: true);
    expect(outcome, SyncPairingOutcome.accepted);
    final result = await resultFuture.timeout(const Duration(seconds: 2));
    expect(result.outcome, SyncPairingOutcome.accepted);
    expect(a.passphrase, passB);
    expect(a.endpoints.map((e) => e.deviceId), contains('devB'));
    expect(b.endpoints.map((e) => e.deviceId), contains('devA'));

    // 新口令能解开真实同步载荷（不是只比较字符串）。
    final codec = SyncCodec(iterations: 1000);
    final envelope = SyncEnvelope(
      deviceId: 'devB',
      producedAt: 1,
      records: {
        SyncCategory.settings: [
          SyncRecord(
            key: 'theme_mode',
            version: const SyncVersion(physical: 1, deviceId: 'devB'),
            data: const {'v': 'dark'},
          ),
        ],
      },
    );
    final decrypted = codec.decrypt(
      codec.encrypt(envelope, a.passphrase!),
      b.passphrase!,
    );
    expect(decrypted.deviceId, 'devB');

    // 口令不进入日志 / toString。
    for (final record in [...a.logs, ...b.logs]) {
      expect(record.message, isNot(contains(passB)));
    }
    expect(result.toString(), isNot(contains(passB)));
    expect(attempt.toString(), isNot(contains(passB)));
  });

  test('invite：发起方有组、接收方无组 → 接收方拿到发起方口令', () async {
    final network = _LoopbackNetwork();
    final a = await _Device.start(
      network,
      id: 'devA',
      name: '设备A',
      passphrase: passA,
      hasGroup: true,
    );
    final b = await _Device.start(
      network,
      id: 'devB',
      name: '设备B',
      passphrase: null,
      hasGroup: false,
    );
    addTearDown(network.dispose);

    final promptFuture = b.service.incomingRequests.first;
    final resultFuture = a.service.requestPairing(_nearby(b));
    final prompt = await promptFuture.timeout(const Duration(seconds: 2));
    expect(prompt.intent, SyncPairingIntent.invite);
    expect(
      await b.service.respond(prompt.requestId, accept: true),
      SyncPairingOutcome.accepted,
    );
    final result = await resultFuture.timeout(const Duration(seconds: 2));
    expect(result.outcome, SyncPairingOutcome.accepted);
    expect(b.passphrase, passA);
    expect(b.endpoints.map((e) => e.deviceId), contains('devA'));
    expect(a.endpoints.map((e) => e.deviceId), contains('devB'));
  });

  test('双方都无组：join 使用接收方已有口令', () async {
    final network = _LoopbackNetwork();
    final a = await _Device.start(
      network,
      id: 'devA',
      name: '设备A',
      passphrase: null,
      hasGroup: false,
    );
    final b = await _Device.start(
      network,
      id: 'devB',
      name: '设备B',
      passphrase: passB,
      hasGroup: false,
    );
    addTearDown(network.dispose);

    final promptFuture = b.service.incomingRequests.first;
    final resultFuture = a.service.requestPairing(_nearby(b));
    final prompt = await promptFuture.timeout(const Duration(seconds: 2));
    expect(prompt.intent, SyncPairingIntent.join);
    await b.service.respond(prompt.requestId, accept: true);
    expect(
      (await resultFuture.timeout(const Duration(seconds: 2))).outcome,
      SyncPairingOutcome.accepted,
    );
    expect(a.passphrase, passB);
  });

  test('双方都在不同组：conflict，不弹窗、不传口令', () async {
    final network = _LoopbackNetwork();
    final a = await _Device.start(
      network,
      id: 'devA',
      name: '设备A',
      passphrase: passA,
      hasGroup: true,
    );
    final b = await _Device.start(
      network,
      id: 'devB',
      name: '设备B',
      passphrase: passB,
      hasGroup: true,
    );
    addTearDown(network.dispose);

    var prompted = false;
    final subscription = b.service.incomingRequests.listen((_) {
      prompted = true;
    });
    addTearDown(subscription.cancel);

    final result = await a.service
        .requestPairing(_nearby(b))
        .timeout(const Duration(seconds: 2));
    expect(result.outcome, SyncPairingOutcome.conflict);
    expect(prompted, isFalse);
    expect(a.passphrase, passA);
    expect(b.passphrase, passB);
    expect(a.endpoints, isEmpty);
    expect(b.endpoints, isEmpty);
  });

  test('同组 proof：sameGroup，直接补端点、不弹窗', () async {
    final network = _LoopbackNetwork();
    final a = await _Device.start(
      network,
      id: 'devA',
      name: '设备A',
      passphrase: passA,
      hasGroup: true,
    );
    final b = await _Device.start(
      network,
      id: 'devB',
      name: '设备B',
      passphrase: passA,
      hasGroup: true,
    );
    addTearDown(network.dispose);

    var prompted = false;
    final subscription = b.service.incomingRequests.listen((_) {
      prompted = true;
    });
    addTearDown(subscription.cancel);

    final result = await a.service
        .requestPairing(_nearby(b))
        .timeout(const Duration(seconds: 2));
    expect(result.outcome, SyncPairingOutcome.sameGroup);
    expect(prompted, isFalse);
    expect(a.endpoints.map((e) => e.deviceId), contains('devB'));
    expect(b.endpoints.map((e) => e.deviceId), contains('devA'));
  });

  test('拒绝：发起方得到 rejected，口令不变', () async {
    final network = _LoopbackNetwork();
    final a = await _Device.start(
      network,
      id: 'devA',
      name: '设备A',
      passphrase: null,
      hasGroup: false,
    );
    final b = await _Device.start(
      network,
      id: 'devB',
      name: '设备B',
      passphrase: passB,
      hasGroup: true,
    );
    addTearDown(network.dispose);

    final promptFuture = b.service.incomingRequests.first;
    final resultFuture = a.service.requestPairing(_nearby(b));
    final prompt = await promptFuture.timeout(const Duration(seconds: 2));
    expect(
      await b.service.respond(prompt.requestId, accept: false),
      SyncPairingOutcome.rejected,
    );
    final result = await resultFuture.timeout(const Duration(seconds: 2));
    expect(result.outcome, SyncPairingOutcome.rejected);
    expect(a.passphrase, isNull);
    expect(a.endpoints, isEmpty);
  });

  test('超时：未接受 → 双方都进入 expired（pending TTL）', () async {
    final network = _LoopbackNetwork();
    final a = await _Device.start(
      network,
      id: 'devA',
      name: '设备A',
      passphrase: null,
      hasGroup: false,
      requestTtl: const Duration(milliseconds: 150),
      pollInterval: const Duration(milliseconds: 20),
    );
    final b = await _Device.start(
      network,
      id: 'devB',
      name: '设备B',
      passphrase: passB,
      hasGroup: true,
      requestTtl: const Duration(milliseconds: 100),
    );
    addTearDown(network.dispose);

    final promptFuture = b.service.incomingRequests.first;
    final result = await a.service
        .requestPairing(_nearby(b))
        .timeout(const Duration(seconds: 2));
    final prompt = await promptFuture.timeout(const Duration(seconds: 2));
    expect(result.outcome, SyncPairingOutcome.expired);
    expect(
      await b.service.respond(prompt.requestId, accept: true),
      SyncPairingOutcome.expired,
    );
    expect(a.passphrase, isNull);
  });

  test('前台不可用：后台 / 锁屏 / 省电不弹窗，返回 unavailable', () async {
    final network = _LoopbackNetwork();
    final a = await _Device.start(
      network,
      id: 'devA',
      name: '设备A',
      passphrase: null,
      hasGroup: false,
    );
    final b = await _Device.start(
      network,
      id: 'devB',
      name: '设备B',
      passphrase: passB,
      hasGroup: true,
      canPrompt: false,
    );
    addTearDown(network.dispose);

    var prompted = false;
    final subscription = b.service.incomingRequests.listen((_) {
      prompted = true;
    });
    addTearDown(subscription.cancel);
    final result = await a.service
        .requestPairing(_nearby(b))
        .timeout(const Duration(seconds: 2));
    expect(result.outcome, SyncPairingOutcome.unavailable);
    expect(prompted, isFalse);
    expect(a.passphrase, isNull);
  });

  test('body 超 8KB：413，不解析、不弹窗', () async {
    final network = _LoopbackNetwork();
    final b = await _Device.start(
      network,
      id: 'devB',
      name: '设备B',
      passphrase: passB,
      hasGroup: true,
    );
    addTearDown(network.dispose);
    final response = await b.service.handle(PairingHttpRequest(
      method: 'POST',
      path: PairingHttpPaths.request,
      sourceHost: '10.0.0.9',
      body: Uint8List(pairingMaxBodyBytes + 1),
    ));
    expect(response.statusCode, 413);
  });

  test('每来源限流：第 3 条请求返回 429 busy', () async {
    final network = _LoopbackNetwork();
    final b = await _Device.start(
      network,
      id: 'devB',
      name: '设备B',
      passphrase: passB,
      hasGroup: true,
      requestRateLimit: 2,
    );
    addTearDown(network.dispose);
    expect(b.service.requestRateLimit, 2);

    Future<int> send(String requestId) async {
      final response = await b.service.handle(PairingHttpRequest(
        method: 'POST',
        path: PairingHttpPaths.request,
        sourceHost: '10.0.0.9',
        body: _requestBody(
          requestId: requestId,
          deviceId: 'devX',
          deviceName: '设备X',
          intent: SyncPairingIntent.join,
          hasGroup: false,
        ),
      ));
      return response.statusCode;
    }

    expect(await send('req-aaaaaaaa'), 200);
    expect(await send('req-bbbbbbbb'), 200);
    expect(await send('req-cccccccc'), 429);
  });

  test('坏公钥：400，不产生待确认请求', () async {
    final network = _LoopbackNetwork();
    final b = await _Device.start(
      network,
      id: 'devB',
      name: '设备B',
      passphrase: passB,
      hasGroup: true,
    );
    addTearDown(network.dispose);
    var prompted = false;
    final subscription = b.service.incomingRequests.listen((_) {
      prompted = true;
    });
    addTearDown(subscription.cancel);

    final body = _requestBody(
      requestId: 'req-badkey1',
      deviceId: 'devX',
      deviceName: '设备X',
      intent: SyncPairingIntent.join,
      hasGroup: false,
      publicKey: Uint8List(65)..[0] = 0x04,
    );
    final response = await b.service.handle(PairingHttpRequest(
      method: 'POST',
      path: PairingHttpPaths.request,
      sourceHost: '10.0.0.9',
      body: body,
    ));
    expect(response.statusCode, 400);
    expect(prompted, isFalse);
  });

  test('同一时间只弹一个：响应后队列里的下一条才出现', () async {
    final network = _LoopbackNetwork();
    final b = await _Device.start(
      network,
      id: 'devB',
      name: '设备B',
      passphrase: passB,
      hasGroup: true,
      requestRateLimit: 20,
    );
    addTearDown(network.dispose);

    final prompts = <SyncPairingRequest>[];
    final subscription = b.service.incomingRequests.listen(prompts.add);
    addTearDown(subscription.cancel);

    Future<void> send(String requestId, String deviceId) async {
      await b.service.handle(PairingHttpRequest(
        method: 'POST',
        path: PairingHttpPaths.request,
        sourceHost: '10.0.0.9',
        body: _requestBody(
          requestId: requestId,
          deviceId: deviceId,
          deviceName: deviceId,
          intent: SyncPairingIntent.join,
          hasGroup: false,
        ),
      ));
    }

    await send('req-first001', 'devX');
    await send('req-second02', 'devY');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(prompts, hasLength(1));
    expect(prompts.single.peerDeviceId, 'devX');

    await b.service.respond(prompts.single.requestId, accept: false);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(prompts, hasLength(2));
    expect(prompts.last.peerDeviceId, 'devY');
  });
}

class _LoopbackNetwork {
  final Map<int, LanPairingService> services = {};
  late final PairingHttpClient client = _LoopbackClient(this);

  Future<void> dispose() async {
    for (final service in services.values) {
      await service.dispose();
    }
    services.clear();
  }
}

class _LoopbackClient implements PairingHttpClient {
  _LoopbackClient(this.network);

  final _LoopbackNetwork network;

  @override
  Future<PairingHttpReply> send({
    required String method,
    required String host,
    required int port,
    required String path,
    Map<String, String>? query,
    List<int>? body,
    required Duration timeout,
  }) async {
    final service = network.services[port];
    if (service == null) {
      return const PairingHttpReply(statusCode: 404, body: '');
    }
    final response = await service.handle(PairingHttpRequest(
      method: method,
      path: path,
      sourceHost: '127.0.0.1',
      query: query ?? const {},
      body: body ?? const [],
    ));
    return PairingHttpReply(
      statusCode: response.statusCode,
      body: response.body,
    );
  }

  @override
  void close() {}
}

class _Device {
  _Device({
    required this.id,
    required this.name,
    required this.httpPort,
    this.passphrase,
    required this.hasGroup,
    this.canPrompt = true,
    this.cellular = false,
    this.requestTtl = const Duration(seconds: 60),
    this.pollInterval = const Duration(milliseconds: 20),
    this.requestRateLimit = 10,
  });

  final String id;
  final String name;
  final int httpPort;
  final bool cellular;
  final Duration requestTtl;
  final Duration pollInterval;
  final int requestRateLimit;
  final List<LanPeerEndpoint> endpoints = [];
  final List<LogRecord> logs = [];
  final SyncCodec codec = SyncCodec(iterations: 1000);

  String? passphrase;
  bool hasGroup;
  bool canPrompt;
  late final LanPairingService service;

  static Future<_Device> start(
    _LoopbackNetwork network, {
    required String id,
    required String name,
    required String? passphrase,
    required bool hasGroup,
    bool canPrompt = true,
    bool cellular = false,
    Duration requestTtl = const Duration(seconds: 60),
    Duration pollInterval = const Duration(milliseconds: 20),
    int requestRateLimit = 10,
  }) async {
    final port = 41000 + network.services.length;
    final device = _Device(
      id: id,
      name: name,
      httpPort: port,
      passphrase: passphrase,
      hasGroup: hasGroup,
      canPrompt: canPrompt,
      cellular: cellular,
      requestTtl: requestTtl,
      pollInterval: pollInterval,
      requestRateLimit: requestRateLimit,
    );
    final logger = Logger('molia.test.pairing.$id');
    logger.onRecord.listen(device.logs.add);
    device.service = LanPairingService(
      deviceId: id,
      deviceName: () => device.name,
      readPassphrase: () async => device.passphrase,
      writePassphrase: (value) async => device.passphrase = value,
      ensurePassphrase: () async {
        final existing = device.passphrase;
        if (existing != null &&
            SyncPassphrase.normalize(existing).length >= 16) {
          return existing;
        }
        final generated = SyncPassphrase.generate();
        device.passphrase = generated;
        return generated;
      },
      hasGroup: () => device.hasGroup,
      canPrompt: () => device.canPrompt,
      isCellular: () => device.cellular,
      httpPortProvider: () => device.httpPort,
      probePortProvider: () => 47825,
      addPeerEndpoint: (endpoint) async => device.endpoints.add(endpoint),
      discoveryKeyProvider: (value) async => device.codec.discoveryKey(value),
      httpClient: network.client,
      nowMs: () => DateTime.now().millisecondsSinceEpoch,
      requestTtl: requestTtl,
      statusPollInterval: pollInterval,
      sweepInterval: const Duration(milliseconds: 50),
      requestRateLimit: requestRateLimit,
      logger: logger,
    );
    network.services[port] = device.service;
    await device.service.start();
    return device;
  }
}

SyncNearbyDevice _nearby(_Device device) => SyncNearbyDevice(
      deviceId: device.id,
      name: device.name,
      host: '127.0.0.1',
      httpPort: device.httpPort,
      probePort: 47825,
      hasGroup: device.hasGroup,
      lastSeenAt: DateTime.now().millisecondsSinceEpoch,
    );

Uint8List _requestBody({
  required String requestId,
  required String deviceId,
  required String deviceName,
  required SyncPairingIntent intent,
  required bool hasGroup,
  Uint8List? publicKey,
}) {
  final keyPair = PairingCrypto.generateKeyPair();
  final key = publicKey ?? keyPair.publicKey;
  final body = utf8.encode(jsonEncode({
    'v': 1,
    'requestId': requestId,
    'deviceId': deviceId,
    'deviceName': deviceName,
    'intent': intent.name,
    'publicKey': base64UrlEncode(key).replaceAll('=', ''),
    'nonce':
        base64UrlEncode(List<int>.generate(16, (i) => i)).replaceAll('=', ''),
    'group': hasGroup,
    'http': 42000,
  }));
  keyPair.destroy();
  return Uint8List.fromList(body);
}
