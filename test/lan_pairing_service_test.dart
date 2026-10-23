import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:molia/data/sync/pairing/lan_pairing_service.dart';
import 'package:molia/data/sync/pairing/pairing_crypto.dart';
import 'package:molia/data/sync/pairing/pairing_http.dart';
import 'package:molia/data/sync/sync_crypto.dart';
import 'package:molia/data/sync/transport/lan_pairing_packet.dart';
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

    // invite 转移的是发起方口令：接收方拿到的口令必须能解开真实同步载荷。
    final codec = SyncCodec(iterations: 1000);
    final envelope = SyncEnvelope(
      deviceId: 'devA',
      producedAt: 1,
      records: {
        SyncCategory.settings: [
          SyncRecord(
            key: 'theme_mode',
            version: const SyncVersion(physical: 1, deviceId: 'devA'),
            data: const {'v': 'light'},
          ),
        ],
      },
    );
    final decrypted = codec.decrypt(
      codec.encrypt(envelope, a.passphrase!),
      b.passphrase!,
    );
    expect(decrypted.deviceId, 'devA');
  });

  test('invite 接受后等待 complete：complete 成功才返回 accepted', () async {
    final writes = <String>[];
    final endpoints = <LanPeerEndpoint>[];
    final service = await _startService(
      deviceId: 'devB',
      passphrase: null,
      hasGroup: false,
      client: _FakeHttpClient((path, query, body) async {
        throw StateError('接收方不应发起 HTTP 请求');
      }),
      inviteCompleteTimeout: const Duration(seconds: 2),
      writes: writes,
      endpoints: endpoints,
    );
    addTearDown(service.dispose);

    final invite = await _beginInvite(service, requestId: 'req-invite001');
    var resolved = false;
    final respondFuture =
        service.respond(invite.prompt.requestId, accept: true);
    unawaited(respondFuture.whenComplete(() => resolved = true));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(resolved, isFalse, reason: '还没收到 complete 不能返回 accepted');
    expect(writes, isEmpty);
    expect(endpoints, isEmpty);

    final response = await service.handle(PairingHttpRequest(
      method: 'POST',
      path: PairingHttpPaths.complete,
      sourceHost: '10.0.0.9',
      body: _completeBody(invite, passphrase: passA),
    ));
    expect(response.statusCode, 200);
    expect(
      (jsonDecode(response.body) as Map<String, Object?>)['status'],
      SyncPairingStatus.accepted.name,
    );
    expect(
      await respondFuture.timeout(const Duration(seconds: 1)),
      SyncPairingOutcome.accepted,
    );
    expect(writes, [passA]);
    expect(endpoints.map((e) => e.deviceId), contains('devA'));
  });

  test('invite 接受后没有 complete：有界等待后返回 unavailable', () async {
    final writes = <String>[];
    final service = await _startService(
      deviceId: 'devB',
      passphrase: null,
      hasGroup: false,
      client: _FakeHttpClient((path, query, body) async {
        throw StateError('接收方不应发起 HTTP 请求');
      }),
      inviteCompleteTimeout: const Duration(milliseconds: 80),
      writes: writes,
    );
    addTearDown(service.dispose);

    final invite = await _beginInvite(service, requestId: 'req-invite002');
    final stopwatch = Stopwatch()..start();
    final outcome = await service
        .respond(invite.prompt.requestId, accept: true)
        .timeout(const Duration(seconds: 2));
    stopwatch.stop();
    expect(outcome, SyncPairingOutcome.unavailable);
    expect(
      stopwatch.elapsed,
      greaterThanOrEqualTo(const Duration(milliseconds: 60)),
    );
    expect(writes, isEmpty);

    // 超时只代表「对方还没完成」：请求仍在 TTL 内，迟到的 complete 仍生效。
    final response = await service.handle(PairingHttpRequest(
      method: 'POST',
      path: PairingHttpPaths.complete,
      sourceHost: '10.0.0.9',
      body: _completeBody(invite, passphrase: passA),
    ));
    expect(response.statusCode, 200);
    expect(writes, [passA]);
  });

  test('invite 接受后 complete 密封载荷损坏：respond 返回 unavailable', () async {
    final writes = <String>[];
    final service = await _startService(
      deviceId: 'devB',
      passphrase: null,
      hasGroup: false,
      client: _FakeHttpClient((path, query, body) async {
        throw StateError('接收方不应发起 HTTP 请求');
      }),
      inviteCompleteTimeout: const Duration(seconds: 2),
      writes: writes,
    );
    addTearDown(service.dispose);

    final invite = await _beginInvite(service, requestId: 'req-invite003');
    final respondFuture =
        service.respond(invite.prompt.requestId, accept: true);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final response = await service.handle(PairingHttpRequest(
      method: 'POST',
      path: PairingHttpPaths.complete,
      sourceHost: '10.0.0.9',
      body: utf8.encode(jsonEncode({
        'v': 1,
        'requestId': invite.prompt.requestId,
        'deviceId': 'devA',
        'sealed': _token(Uint8List(48)),
      })),
    ));
    expect(response.statusCode, 400);
    expect(
      await respondFuture.timeout(const Duration(seconds: 1)),
      SyncPairingOutcome.unavailable,
    );
    expect(writes, isEmpty);
  });

  test('invite 等待 complete 期间过期：respond 返回 expired', () async {
    final writes = <String>[];
    final service = await _startService(
      deviceId: 'devB',
      passphrase: null,
      hasGroup: false,
      client: _FakeHttpClient((path, query, body) async {
        throw StateError('接收方不应发起 HTTP 请求');
      }),
      requestTtl: const Duration(milliseconds: 300),
      inviteCompleteTimeout: const Duration(seconds: 5),
      writes: writes,
    );
    addTearDown(service.dispose);

    final invite = await _beginInvite(service, requestId: 'req-invite004');
    final outcome = await service
        .respond(invite.prompt.requestId, accept: true)
        .timeout(const Duration(seconds: 2));
    expect(outcome, SyncPairingOutcome.expired);
    expect(writes, isEmpty);
  });

  test('join 不受 invite 等待影响：接受后立即返回 accepted', () async {
    final writes = <String>[];
    final service = await _startService(
      deviceId: 'devB',
      passphrase: passB,
      hasGroup: true,
      client: _FakeHttpClient((path, query, body) async {
        throw StateError('接收方不应发起 HTTP 请求');
      }),
      inviteCompleteTimeout: const Duration(seconds: 30),
      writes: writes,
    );
    addTearDown(service.dispose);

    final promptFuture = service.incomingRequests.first;
    final response = await service.handle(PairingHttpRequest(
      method: 'POST',
      path: PairingHttpPaths.request,
      sourceHost: '10.0.0.9',
      body: _requestBody(
        requestId: 'req-join0001',
        deviceId: 'devA',
        deviceName: '设备A',
        intent: SyncPairingIntent.join,
        hasGroup: false,
      ),
    ));
    expect(response.statusCode, 200);
    final prompt = await promptFuture.timeout(const Duration(seconds: 1));
    final stopwatch = Stopwatch()..start();
    final outcome = await service
        .respond(prompt.requestId, accept: true)
        .timeout(const Duration(seconds: 1));
    stopwatch.stop();
    expect(outcome, SyncPairingOutcome.accepted);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(writes, isEmpty, reason: '已有口令时 join 不需要重写');
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

  test('join 密封载荷按接受时间过期：status 不再吐 sealed，内部也清零', () async {
    final network = _LoopbackNetwork();
    var now = 1000;
    final a = await _Device.start(
      network,
      id: 'devA',
      name: '设备A',
      passphrase: null,
      hasGroup: false,
      requestTtl: const Duration(milliseconds: 1000),
      pollInterval: const Duration(milliseconds: 10),
      clock: () => now,
    );
    final b = await _Device.start(
      network,
      id: 'devB',
      name: '设备B',
      passphrase: passB,
      hasGroup: true,
      requestTtl: const Duration(milliseconds: 1000),
      clock: () => now,
    );
    addTearDown(network.dispose);

    final promptFuture = b.service.incomingRequests.first;
    final resultFuture = a.service.requestPairing(_nearby(b));
    final prompt = await promptFuture.timeout(const Duration(seconds: 2));
    expect(
      await b.service.respond(prompt.requestId, accept: true),
      SyncPairingOutcome.accepted,
    );
    expect(
      (await resultFuture.timeout(const Duration(seconds: 2))).outcome,
      SyncPairingOutcome.accepted,
    );
    expect(b.service.debugSealedPayloadCount, 1);

    now += 1500;
    final response = await b.service.handle(PairingHttpRequest(
      method: 'GET',
      path: PairingHttpPaths.status,
      sourceHost: '10.0.0.9',
      query: {'id': prompt.requestId},
    ));
    expect(response.statusCode, 200);
    final body = jsonDecode(response.body) as Map<String, Object?>;
    expect(body['status'], SyncPairingStatus.expired.name);
    expect(body.containsKey('sealed'), isFalse);
    expect(b.service.debugSealedPayloadCount, 0);
  });

  test('请求表裁剪会释放密封载荷', () async {
    final network = _LoopbackNetwork();
    var now = 1000;
    final b = await _Device.start(
      network,
      id: 'devB',
      name: '设备B',
      passphrase: passB,
      hasGroup: true,
      requestTtl: const Duration(milliseconds: 100),
      maxRequests: 1,
      maxPending: 2,
      clock: () => now,
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

    expect(
      await b.service.respond(prompts.first.requestId, accept: true),
      SyncPairingOutcome.accepted,
    );
    expect(b.service.debugSealedPayloadCount, 1);

    // 直接跑裁剪（不先跑过期清理）：确认 removed entry 的 sealed 被清零。
    b.service.debugTrimRequests(1301);
    expect(b.service.debugRequestCount, 1);
    expect(b.service.debugSealedPayloadCount, 0);
  });

  test('第一次 POST 就 accepted：拒绝，不写口令、不 complete', () async {
    final receiver = PairingCrypto.generateKeyPair();
    addTearDown(receiver.destroy);
    final writes = <String>[];
    final endpoints = <LanPeerEndpoint>[];
    final client = _FakeHttpClient((path, query, body) async {
      expect(path, PairingHttpPaths.request);
      return PairingHttpReply(
        statusCode: 200,
        body: jsonEncode({
          'v': 1,
          'status': SyncPairingStatus.accepted.name,
          'publicKey': _token(receiver.publicKey),
          'nonce': _token(Uint8List(16)),
        }),
      );
    });
    final service = await _startService(
      deviceId: 'devA',
      passphrase: null,
      hasGroup: false,
      client: client,
      writes: writes,
      endpoints: endpoints,
    );
    addTearDown(service.dispose);

    final result = await service
        .requestPairing(_nearbyFrom('devB', '127.0.0.1', 41001))
        .timeout(const Duration(seconds: 2));
    expect(result.outcome, SyncPairingOutcome.unavailable);
    expect(writes, isEmpty);
    expect(client.paths, [PairingHttpPaths.request]);
    expect(endpoints, isEmpty);
  });

  test('状态轮询连续 3 次传输错误 → unreachable；成功响应会重置计数', () async {
    final receiver = PairingCrypto.generateKeyPair();
    addTearDown(receiver.destroy);
    final nonce = Uint8List(16);
    var statusCalls = 0;
    final client = _FakeHttpClient((path, query, body) async {
      switch (path) {
        case PairingHttpPaths.request:
          return PairingHttpReply(
            statusCode: 200,
            body: jsonEncode({
              'v': 1,
              'status': SyncPairingStatus.pending.name,
              'publicKey': _token(receiver.publicKey),
              'nonce': _token(nonce),
            }),
          );
        case PairingHttpPaths.status:
          statusCalls++;
          // 2 次抖动 → 1 次成功 pending（重置计数）→ 再 3 次失败。
          if (statusCalls == 3) {
            return PairingHttpReply(
              statusCode: 200,
              body: jsonEncode({
                'v': 1,
                'status': SyncPairingStatus.pending.name,
                'publicKey': _token(receiver.publicKey),
                'nonce': _token(nonce),
              }),
            );
          }
          throw Exception('模拟网络中断');
        default:
          throw StateError('不应调用 $path');
      }
    });
    final service = await _startService(
      deviceId: 'devA',
      passphrase: null,
      hasGroup: false,
      client: client,
      requestTtl: const Duration(seconds: 10),
      pollInterval: const Duration(milliseconds: 5),
    );
    addTearDown(service.dispose);

    final result = await service
        .requestPairing(_nearbyFrom('devB', '127.0.0.1', 41001))
        .timeout(const Duration(seconds: 2));
    expect(result.outcome, SyncPairingOutcome.unreachable);
    expect(statusCalls, 6, reason: '成功 pending 后计数重置，再累计 3 次失败');
  });

  test('invite complete 返回 200 rejected：不算成功，不保存端点', () async {
    final receiver = PairingCrypto.generateKeyPair();
    addTearDown(receiver.destroy);
    final nonce = Uint8List(16);
    var completeCalls = 0;
    final endpoints = <LanPeerEndpoint>[];
    final client = _FakeHttpClient((path, query, body) async {
      switch (path) {
        case PairingHttpPaths.request:
        case PairingHttpPaths.status:
          return PairingHttpReply(
            statusCode: 200,
            body: jsonEncode({
              'v': 1,
              'status': path == PairingHttpPaths.request
                  ? SyncPairingStatus.pending.name
                  : SyncPairingStatus.accepted.name,
              if (path == PairingHttpPaths.request) ...{
                'publicKey': _token(receiver.publicKey),
                'nonce': _token(nonce),
              },
            }),
          );
        case PairingHttpPaths.complete:
          completeCalls++;
          return PairingHttpReply(
            statusCode: 200,
            body: jsonEncode({
              'v': 1,
              'status': SyncPairingStatus.rejected.name,
            }),
          );
        default:
          throw StateError('不应调用 $path');
      }
    });
    final service = await _startService(
      deviceId: 'devA',
      passphrase: passA,
      hasGroup: true,
      client: client,
      endpoints: endpoints,
      pollInterval: const Duration(milliseconds: 5),
    );
    addTearDown(service.dispose);

    final result = await service
        .requestPairing(_nearbyFrom('devB', '127.0.0.1', 41001))
        .timeout(const Duration(seconds: 2));
    expect(result.outcome, SyncPairingOutcome.rejected);
    expect(completeCalls, 1);
    expect(endpoints, isEmpty);
  });

  test('invite complete 返回 200 坏 JSON：unavailable，不保存端点', () async {
    final receiver = PairingCrypto.generateKeyPair();
    addTearDown(receiver.destroy);
    final nonce = Uint8List(16);
    final endpoints = <LanPeerEndpoint>[];
    final client = _FakeHttpClient((path, query, body) async {
      switch (path) {
        case PairingHttpPaths.request:
        case PairingHttpPaths.status:
          return PairingHttpReply(
            statusCode: 200,
            body: jsonEncode({
              'v': 1,
              'status': path == PairingHttpPaths.request
                  ? SyncPairingStatus.pending.name
                  : SyncPairingStatus.accepted.name,
              if (path == PairingHttpPaths.request) ...{
                'publicKey': _token(receiver.publicKey),
                'nonce': _token(nonce),
              },
            }),
          );
        case PairingHttpPaths.complete:
          return const PairingHttpReply(statusCode: 200, body: 'not-json');
        default:
          throw StateError('不应调用 $path');
      }
    });
    final service = await _startService(
      deviceId: 'devA',
      passphrase: passA,
      hasGroup: true,
      client: client,
      endpoints: endpoints,
      pollInterval: const Duration(milliseconds: 5),
    );
    addTearDown(service.dispose);

    final result = await service
        .requestPairing(_nearbyFrom('devB', '127.0.0.1', 41001))
        .timeout(const Duration(seconds: 2));
    expect(result.outcome, SyncPairingOutcome.unavailable);
    expect(endpoints, isEmpty);
  });

  test('invite 接受后 complete 失败：双方都不落端点；重试成功才落', () async {
    final network = _LoopbackNetwork()..failComplete = true;
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
      // complete 到不了接收方：接受后只能等到有界超时。
      inviteCompleteTimeout: const Duration(milliseconds: 200),
    );
    addTearDown(network.dispose);

    final promptFuture = b.service.incomingRequests.first;
    final resultFuture = a.service.requestPairing(_nearby(b));
    final prompt = await promptFuture.timeout(const Duration(seconds: 2));
    expect(
      await b.service.respond(prompt.requestId, accept: true),
      SyncPairingOutcome.unavailable,
    );
    final failed = await resultFuture.timeout(const Duration(seconds: 2));
    expect(failed.outcome, SyncPairingOutcome.unreachable);
    expect(a.endpoints, isEmpty);
    expect(b.endpoints, isEmpty, reason: '接受 invite 不落端点，等 complete 成功');

    network.failComplete = false;
    final promptAgain = b.service.incomingRequests.first;
    final resultAgain = a.service.requestPairing(_nearby(b));
    final secondPrompt = await promptAgain.timeout(const Duration(seconds: 2));
    expect(
      await b.service.respond(secondPrompt.requestId, accept: true),
      SyncPairingOutcome.accepted,
    );
    expect(
      (await resultAgain.timeout(const Duration(seconds: 2))).outcome,
      SyncPairingOutcome.accepted,
    );
    expect(a.endpoints.map((e) => e.deviceId), contains('devB'));
    expect(b.endpoints.map((e) => e.deviceId), contains('devA'));
  });

  test('发起方地址顺序：来源地址优先，自报地址只留可路由 IP', () async {
    final client = _FakeHttpClient((path, query, body) async {
      throw Exception('模拟不可达');
    });
    final service = await _startService(
      deviceId: 'devA',
      passphrase: null,
      hasGroup: false,
      client: client,
    );
    addTearDown(service.dispose);
    final device = SyncNearbyDevice(
      deviceId: 'devB',
      name: '设备B',
      host: '127.0.0.1',
      httpPort: 41001,
      addresses: const [
        '127.0.0.2',
        '::1',
        'fe80::1',
        'fe80::1%eth0',
        'molia.local',
        '[192.168.1.7]',
        '192.168.1.7',
        '10.0.0.8',
      ],
      lastSeenAt: 1,
    );
    final result = await service
        .requestPairing(device)
        .timeout(const Duration(seconds: 2));
    expect(result.outcome, SyncPairingOutcome.unreachable);
    expect(client.hosts, ['127.0.0.1', '192.168.1.7', '10.0.0.8']);
  });

  test('status 非法 id：400；轮询用独立的宽松限流', () async {
    final network = _LoopbackNetwork();
    final b = await _Device.start(
      network,
      id: 'devB',
      name: '设备B',
      passphrase: passB,
      hasGroup: true,
      statusRateLimit: 3,
    );
    addTearDown(network.dispose);

    Future<int> status(String id) async {
      final response = await b.service.handle(PairingHttpRequest(
        method: 'GET',
        path: PairingHttpPaths.status,
        sourceHost: '10.0.0.9',
        query: {'id': id},
      ));
      return response.statusCode;
    }

    expect(await status('bad id'), 400);
    expect(await status('req-status1'), 200);
    expect(await status('req-status2'), 200);
    expect(await status('req-status3'), 429, reason: '独立限流生效');
  });

  test('手动地址探测：校验 / 归一 host、默认端口、扫描状态与策略拒绝', () async {
    final packets = StreamController<LanPairingDatagram>.broadcast();
    final sent = <({String? host, int? port})>[];
    var canPrompt = true;
    final service = LanPairingService(
      deviceId: 'devA',
      deviceName: () => '设备A',
      readPassphrase: () async => null,
      writePassphrase: (value) async {},
      hasGroup: () => false,
      canPrompt: () => canPrompt,
      isCellular: () => false,
      httpPortProvider: () => 41000,
      probePortProvider: () => 47825,
      localAddressesProvider: () async => const [],
      packets: packets.stream,
      sendPacket: (packet, {host, port}) async {
        sent.add((host: host, port: port));
        return true;
      },
      nowMs: () => 1000,
      sweepInterval: const Duration(milliseconds: 50),
    );
    addTearDown(() async {
      await service.dispose();
      await packets.close();
    });
    await service.start();

    expect(
        await service.probeAddress('[192.168.1.7]', probePort: 47825), isTrue);
    expect(service.scanning, isTrue);
    expect(sent, [(host: '192.168.1.7', port: 47825)]);

    expect(await service.probeAddress('192.168.1.8'), isTrue);
    expect(sent.last, (host: '192.168.1.8', port: ManualPeer.defaultProbePort));

    expect(await service.probeAddress('not a host'), isFalse);
    expect(
        await service.probeAddress('192.168.1.9', probePort: 70000), isFalse);
    canPrompt = false;
    expect(await service.probeAddress('192.168.1.9'), isFalse);
    expect(sent, hasLength(2));
  });

  test('后台停 sweep / 刷新候选，回前台恢复', () async {
    final packets = StreamController<LanPairingDatagram>.broadcast();
    final sent = <({String? host, int? port})>[];
    var canPrompt = true;
    var cellular = false;
    var now = 1000;
    final service = LanPairingService(
      deviceId: 'devA',
      deviceName: () => '设备A',
      readPassphrase: () async => null,
      writePassphrase: (value) async {},
      hasGroup: () => false,
      canPrompt: () => canPrompt,
      isCellular: () => cellular,
      httpPortProvider: () => 41000,
      probePortProvider: () => 47825,
      localAddressesProvider: () async => const [],
      packets: packets.stream,
      sendPacket: (packet, {host, port}) async {
        sent.add((host: host, port: port));
        return true;
      },
      nowMs: () => now,
      sweepInterval: const Duration(milliseconds: 20),
      scanProbeDelaysMs: const [1000],
    );
    addTearDown(() async {
      await service.dispose();
      await packets.close();
    });
    final nearby = <List<SyncNearbyDevice>>[];
    final subscription = service.nearbyDevices.listen(nearby.add);
    addTearDown(subscription.cancel);

    await service.start();
    expect(service.debugSweepScheduled, isTrue);
    expect(await service.startScan(), isTrue);

    service.onAppHidden();
    expect(service.debugSweepScheduled, isFalse);

    final announce = Msp1.encode(Msp1Message(
      type: Msp1.typeAnnounce,
      deviceId: 'devB',
      name: '设备B',
      httpPort: 41001,
      probePort: 47825,
      addresses: const [],
      hasGroup: false,
      bootId: 'boot-b',
      nonce: 'nonce-b',
    ));
    packets.add(LanPairingDatagram(
      message: Msp1.decode(announce)!,
      sourceHost: '192.168.1.9',
      sourcePort: 47825,
      receivedAt: now,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(nearby.last, isEmpty, reason: '后台不刷新候选');

    canPrompt = true;
    service.onAppResumed();
    expect(service.debugSweepScheduled, isTrue);
    packets.add(LanPairingDatagram(
      message: Msp1.decode(announce)!,
      sourceHost: '192.168.1.9',
      sourcePort: 47825,
      receivedAt: now,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(nearby.last.map((d) => d.deviceId), contains('devB'));

    // 蜂窝下同样不再刷新（_canUsePairing=false）。
    cellular = true;
    final before = nearby.last.length;
    packets.add(LanPairingDatagram(
      message: Msp1.decode(announce)!,
      sourceHost: '192.168.1.10',
      sourcePort: 47825,
      receivedAt: now,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(nearby.last, hasLength(before), reason: '蜂窝不刷新候选');
    expect(nearby.last.single.host, '192.168.1.9');
  });
}

class _LoopbackNetwork {
  final Map<int, LanPairingService> services = {};
  late final PairingHttpClient client = _LoopbackClient(this);

  /// 模拟目标机收到 request / status 后，complete 端点失败。
  bool failComplete = false;

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
    if (network.failComplete && path == PairingHttpPaths.complete) {
      return const PairingHttpReply(statusCode: 503, body: '');
    }
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

class _FakeHttpClient implements PairingHttpClient {
  _FakeHttpClient(this.handler);

  final Future<PairingHttpReply> Function(
    String path,
    Map<String, String>? query,
    List<int>? body,
  ) handler;
  final List<String> paths = [];
  final List<String> hosts = [];

  @override
  Future<PairingHttpReply> send({
    required String method,
    required String host,
    required int port,
    required String path,
    Map<String, String>? query,
    List<int>? body,
    required Duration timeout,
  }) {
    paths.add(path);
    hosts.add(host);
    return handler(path, query, body);
  }

  @override
  void close() {}
}

Future<LanPairingService> _startService({
  required String deviceId,
  required String? passphrase,
  required bool hasGroup,
  required PairingHttpClient client,
  bool canPrompt = true,
  bool cellular = false,
  int httpPort = 41000,
  int probePort = 47825,
  Duration requestTtl = const Duration(seconds: 60),
  Duration inviteCompleteTimeout = const Duration(seconds: 5),
  Duration pollInterval = const Duration(milliseconds: 10),
  int Function()? nowMs,
  List<String>? writes,
  List<LanPeerEndpoint>? endpoints,
}) async {
  var ownPassphrase = passphrase;
  final service = LanPairingService(
    deviceId: deviceId,
    deviceName: () => deviceId,
    readPassphrase: () async => ownPassphrase,
    writePassphrase: (value) async {
      ownPassphrase = value;
      writes?.add(value);
    },
    ensurePassphrase: () async {
      final existing = ownPassphrase;
      if (existing != null && SyncPassphrase.normalize(existing).length >= 16) {
        return existing;
      }
      final generated = SyncPassphrase.generate();
      ownPassphrase = generated;
      writes?.add(generated);
      return generated;
    },
    hasGroup: () => hasGroup,
    canPrompt: () => canPrompt,
    isCellular: () => cellular,
    httpPortProvider: () => httpPort,
    probePortProvider: () => probePort,
    addPeerEndpoint: (endpoint) async {
      endpoints?.add(endpoint);
    },
    discoveryKeyProvider: (value) async =>
        SyncCodec(iterations: 1000).discoveryKey(value),
    httpClient: client,
    nowMs: nowMs ?? () => DateTime.now().millisecondsSinceEpoch,
    requestTtl: requestTtl,
    inviteCompleteTimeout: inviteCompleteTimeout,
    statusPollInterval: pollInterval,
    sweepInterval: const Duration(milliseconds: 50),
    logger: Logger('molia.test.pairing.$deviceId'),
  );
  await service.start();
  return service;
}

SyncNearbyDevice _nearbyFrom(String deviceId, String host, int httpPort) =>
    SyncNearbyDevice(
      deviceId: deviceId,
      name: deviceId,
      host: host,
      httpPort: httpPort,
      lastSeenAt: 1,
    );

String _token(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');

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
    this.inviteCompleteTimeout = const Duration(seconds: 5),
    this.pollInterval = const Duration(milliseconds: 20),
    this.requestRateLimit = 10,
    this.statusRateLimit = 240,
    this.maxRequests = 64,
    this.maxPending = 8,
    this.probePort = 47825,
    this.clock,
    this.localAddresses = const [],
  });

  final String id;
  final String name;
  final int httpPort;
  final bool cellular;
  final Duration requestTtl;
  final Duration inviteCompleteTimeout;
  final Duration pollInterval;
  final int requestRateLimit;
  final int statusRateLimit;
  final int maxRequests;
  final int maxPending;
  final int probePort;
  final int Function()? clock;
  final List<String> localAddresses;
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
    Duration inviteCompleteTimeout = const Duration(seconds: 5),
    Duration pollInterval = const Duration(milliseconds: 20),
    int requestRateLimit = 10,
    int statusRateLimit = 240,
    int maxRequests = 64,
    int maxPending = 8,
    int probePort = 47825,
    int Function()? clock,
    List<String> localAddresses = const [],
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
      inviteCompleteTimeout: inviteCompleteTimeout,
      pollInterval: pollInterval,
      requestRateLimit: requestRateLimit,
      statusRateLimit: statusRateLimit,
      maxRequests: maxRequests,
      maxPending: maxPending,
      probePort: probePort,
      clock: clock,
      localAddresses: localAddresses,
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
      probePortProvider: () => device.probePort,
      localAddressesProvider: () async => device.localAddresses,
      addPeerEndpoint: (endpoint) async => device.endpoints.add(endpoint),
      discoveryKeyProvider: (value) async => device.codec.discoveryKey(value),
      httpClient: network.client,
      nowMs: clock ?? () => DateTime.now().millisecondsSinceEpoch,
      requestTtl: requestTtl,
      inviteCompleteTimeout: inviteCompleteTimeout,
      statusPollInterval: pollInterval,
      sweepInterval: const Duration(milliseconds: 50),
      requestRateLimit: requestRateLimit,
      statusRateLimit: statusRateLimit,
      maxRequests: maxRequests,
      maxPending: maxPending,
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

typedef _InviteHandshake = ({
  SyncPairingRequest prompt,
  PairingKeyPair keyPair,
  Uint8List nonce,
  Uint8List receiverPublicKey,
  Uint8List receiverNonce,
});

/// 直接向接收方投递一条 invite 请求，返回发起方侧密封所需的握手材料。
Future<_InviteHandshake> _beginInvite(
  LanPairingService service, {
  required String requestId,
}) async {
  final promptFuture = service.incomingRequests.first;
  final keyPair = PairingCrypto.generateKeyPair();
  addTearDown(keyPair.destroy);
  final nonce = Uint8List.fromList(List<int>.generate(16, (i) => i));
  final response = await service.handle(PairingHttpRequest(
    method: 'POST',
    path: PairingHttpPaths.request,
    sourceHost: '10.0.0.9',
    body: utf8.encode(jsonEncode({
      'v': 1,
      'requestId': requestId,
      'deviceId': 'devA',
      'deviceName': '设备A',
      'intent': SyncPairingIntent.invite.name,
      'publicKey': _token(keyPair.publicKey),
      'nonce': _token(nonce),
      'group': true,
      'http': 42000,
    })),
  ));
  expect(response.statusCode, 200);
  final map = jsonDecode(response.body) as Map<String, Object?>;
  expect(map['status'], SyncPairingStatus.pending.name);
  final prompt = await promptFuture.timeout(const Duration(seconds: 1));
  return (
    prompt: prompt,
    keyPair: keyPair,
    nonce: nonce,
    receiverPublicKey: _decodeToken(map['publicKey']! as String),
    receiverNonce: _decodeToken(map['nonce']! as String),
  );
}

/// 发起方按握手材料密封口令，构造 `/pair/complete` 请求体。
Uint8List _completeBody(
  _InviteHandshake invite, {
  required String passphrase,
}) {
  final key = PairingCrypto.deriveSessionKey(
    privateKey: invite.keyPair.privateKey,
    peerPublicKey: invite.receiverPublicKey,
    initiatorNonce: invite.nonce,
    receiverNonce: invite.receiverNonce,
  );
  final sealed = PairingCrypto.seal(
    key: key,
    plaintext: utf8.encode(passphrase),
    aad: PairingCrypto.aad(
      requestId: invite.prompt.requestId,
      intent: SyncPairingIntent.invite,
      initiatorDeviceId: 'devA',
      receiverDeviceId: 'devB',
    ),
  );
  return Uint8List.fromList(utf8.encode(jsonEncode({
    'v': 1,
    'requestId': invite.prompt.requestId,
    'deviceId': 'devA',
    'sealed': _token(sealed),
  })));
}

Uint8List _decodeToken(String value) =>
    Uint8List.fromList(base64Url.decode(base64Url.normalize(value)));

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
