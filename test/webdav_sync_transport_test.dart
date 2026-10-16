import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_crypto.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/data/sync/transport/webdav_sync_transport.dart';
import 'package:molia/domain/models/device_sync.dart';

/// WebDAV 传输测试：对本地假 DAV 服务完成推送 / 列表 / 拉取 / 鉴权。
void main() {
  const passphrase = 'ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789';
  final codec = SyncCodec(iterations: 1000);

  late FakeWebDavServer server;

  setUp(() async {
    server = FakeWebDavServer();
    await server.start();
  });

  tearDown(() async {
    await server.stop();
  });

  SyncEnvelope envelope(String deviceId, {String value = 'v'}) => SyncEnvelope(
        deviceId: deviceId,
        deviceName: deviceId,
        producedAt: 1,
        records: {
          SyncCategory.settings: [
            SyncRecord(
              key: 'theme_mode',
              version: SyncVersion(physical: 10, deviceId: deviceId),
              data: {'v': value},
            ),
          ],
        },
      );

  WebDavSyncTransport transport(
    String deviceId, {
    String password = 'secret',
    String? passphraseOverride,
  }) =>
      WebDavSyncTransport(
        deviceId: deviceId,
        codec: codec,
        passphraseProvider: () async => passphraseOverride ?? passphrase,
        configProvider: () => WebDavConfig(
          baseUrl: server.baseUrl,
          username: 'user',
        ),
        passwordProvider: () async => password,
        requestTimeout: const Duration(seconds: 5),
      );

  test('推送 → 拉取：只读取其他设备的快照', () async {
    final a = transport('devA');
    final b = transport('devB');
    addTearDown(() async {
      await a.stop();
      await b.stop();
    });
    await a.start();
    await b.start();

    await a.push(envelope('devA', value: 'light'));
    expect(server.files.keys, contains('devA.msync'));

    await b.push(envelope('devB', value: 'dark'));
    final pulled = (await b.pull()).envelopes;
    expect(pulled, hasLength(1));
    expect(pulled.single.deviceId, 'devA');

    final pulledByA = (await a.pull()).envelopes;
    expect(pulledByA, hasLength(1));
    expect(pulledByA.single.deviceId, 'devB');
  });

  test('口令不同的快照被跳过', () async {
    final a = transport('devA');
    final c = transport('devC',
        passphraseOverride: 'ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ');
    addTearDown(() async {
      await a.stop();
      await c.stop();
    });
    await a.start();
    await c.start();
    await a.push(envelope('devA'));

    expect((await c.pull()).envelopes, isEmpty);
  });

  test('未配置 / 未启动时为空操作', () async {
    final unconfigured = WebDavSyncTransport(
      deviceId: 'devX',
      codec: codec,
      passphraseProvider: () async => passphrase,
      configProvider: () => const WebDavConfig(),
      passwordProvider: () async => '',
    );
    expect((await unconfigured.pull()).envelopes, isEmpty);
    await unconfigured.start();
    await unconfigured.push(envelope('devX'));
    expect(server.files, isEmpty);
    await unconfigured.stop();
    expect((await unconfigured.pull()).envelopes, isEmpty);
  });

  test('404 目录时 MKCOL 自动创建', () async {
    final a = transport('devA');
    addTearDown(() => a.stop());
    await a.start();
    await a.push(envelope('devA'));
    expect(server.mkcolCount, greaterThan(0));
    expect(server.files, contains('devA.msync'));
  });
}

/// 最小 WebDAV 假服务：MKCOL / PROPFIND / PUT / GET + 可选 Basic 鉴权。
class FakeWebDavServer {
  final Map<String, List<int>> files = {};
  late HttpServer server;
  int mkcolCount = 0;
  int propfindCount = 0;
  int putCount = 0;
  int getCount = 0;
  String? expectedAuth;

  String get baseUrl => 'http://127.0.0.1:${server.port}/dav';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
  }

  Future<void> stop() => server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    try {
      final auth = request.headers.value('authorization');
      if (expectedAuth != null && auth != expectedAuth) {
        request.response.statusCode = 401;
        return;
      }
      switch (request.method) {
        case 'MKCOL':
          mkcolCount++;
          request.response.statusCode = 201;
        case 'PROPFIND':
          propfindCount++;
          request.response.statusCode = 207;
          final prefix = request.uri.path.endsWith('/')
              ? request.uri.path
              : '${request.uri.path}/';
          final body = files.keys
              .map((name) =>
                  '<d:response><d:href>$prefix$name</d:href></d:response>')
              .join();
          request.response.write(
              '<?xml version="1.0" encoding="utf-8"?>'
              '<d:multistatus xmlns:d="DAV:">$body</d:multistatus>');
        case 'PUT':
          putCount++;
          final builder = BytesBuilder(copy: false);
          await for (final chunk in request) {
            builder.add(chunk);
          }
          files[request.uri.path.split('/').last] = builder.toBytes();
          request.response.statusCode = 201;
        case 'GET':
          getCount++;
          final data = files[request.uri.path.split('/').last];
          if (data == null) {
            request.response.statusCode = 404;
          } else {
            request.response.headers.contentType = ContentType.binary;
            request.response.add(data);
          }
        default:
          request.response.statusCode = 405;
      }
    } finally {
      await request.response.close();
    }
  }
}
