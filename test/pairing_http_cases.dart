import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/pairing/pairing_http.dart';

/// 生产 HTTP 客户端的资源边界：响应体上限与读取超时。
void main() {
  test('响应体超过 64KB：抛 FormatException，不把整段读进内存', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.statusCode = 200;
      request.response.add(
        List<int>.filled(IoPairingHttpClient.maxResponseBytes + 1, 0x41),
      );
      await request.response.close();
    });

    final client = IoPairingHttpClient();
    await expectLater(
      client.send(
        method: 'GET',
        host: '127.0.0.1',
        port: server.port,
        path: '/pair/status',
        timeout: const Duration(seconds: 2),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('只发一部分响应体后停顿：读取按同一个请求预算超时', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final hold = Completer<void>();
    addTearDown(() async {
      if (!hold.isCompleted) hold.complete();
      await server.close(force: true);
    });
    server.listen((request) async {
      request.response.statusCode = 200;
      request.response.add(const [0x7b]); // '{'
      await request.response.flush();
      await hold.future;
      try {
        await request.response.close();
      } catch (_) {
        // 客户端超时后已强制断开。
      }
    });

    final client = IoPairingHttpClient();
    final stopwatch = Stopwatch()..start();
    await expectLater(
      client.send(
        method: 'GET',
        host: '127.0.0.1',
        port: server.port,
        path: '/pair/status',
        timeout: const Duration(milliseconds: 100),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
  });
}
