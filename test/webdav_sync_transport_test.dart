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

  test('目录准备失败：计为失败对端并带原因（不被判成「没发现对端」）', () async {
    server.mkcolStatus = 500;
    final a = transport('devA');
    addTearDown(() => a.stop());
    await a.start();

    final result = await a.pull();
    // 目录都没准备好 = 一个对端都没接触上：必须计数，否则引擎侧
    // failedPeers=0 会把整轮判成 noPeers 并吞掉错误。
    expect(result.failedPeers, 1);
    expect(result.error?.code, SyncIssueCode.webdavDirFailed);
    expect(result.error?.detail, isNotNull);
  });

  test('目录列表失败：计为失败对端并带原因', () async {
    server.propfindStatus = 500;
    final a = transport('devA');
    addTearDown(() => a.stop());
    await a.start();

    final result = await a.pull();
    expect(result.failedPeers, 1);
    expect(result.error?.code, SyncIssueCode.webdavListFailed);
  });

  test('文件 etag 未变：跳过 GET 并计入 skippedUnchanged', () async {
    final a = transport('devA');
    final b = transport('devB');
    addTearDown(() async {
      await a.stop();
      await b.stop();
    });
    await a.start();
    await b.start();
    await a.push(envelope('devA', value: 'light'));

    final first = await b.pull();
    expect(first.envelopes, hasLength(1));
    expect(first.skippedUnchanged, 0);
    final getsAfterFirst = server.getCount;

    // 远端文件未动：第二轮不 GET、不解密、不合并。
    final decryptionsBefore = codec.decryptions;
    final second = await b.pull();
    expect(second.envelopes, isEmpty);
    expect(second.skippedUnchanged, 1);
    expect(second.bytesIn, 0);
    expect(server.getCount, getsAfterFirst);
    expect(codec.decryptions, decryptionsBefore,
        reason: 'etag 未变：没有解密动作');
  });

  test('文件 etag 变化后重新拉取', () async {
    final a = transport('devA');
    final b = transport('devB');
    addTearDown(() async {
      await a.stop();
      await b.stop();
    });
    await a.start();
    await b.start();
    await a.push(envelope('devA', value: 'light'));
    expect((await b.pull()).envelopes, hasLength(1));

    await a.push(envelope('devA', value: 'dark'));
    final changed = await b.pull();
    expect(changed.envelopes, hasLength(1));
    expect(changed.envelopes.single.recordsOf(SyncCategory.settings).single.data,
        {'v': 'dark'});
    expect(changed.skippedUnchanged, 0);
  });

  test('服务端不返回版本：照常拉取（不跳过）', () async {
    server.includeVersion = false;
    final a = transport('devA');
    final b = transport('devB');
    addTearDown(() async {
      await a.stop();
      await b.stop();
    });
    await a.start();
    await b.start();
    await a.push(envelope('devA'));

    expect((await b.pull()).envelopes, hasLength(1));
    final again = await b.pull();
    expect(again.envelopes, hasLength(1));
    expect(again.skippedUnchanged, 0);
  });
}

/// 最小 WebDAV 假服务：MKCOL / PROPFIND / PUT / GET + 可选 Basic 鉴权。
class FakeWebDavServer {
  final Map<String, List<int>> files = {};

  /// 每个文件的版本令牌（PUT 时递增；PROPFIND 返回 `getetag`）。
  final Map<String, String> etags = {};
  int _etagSeq = 0;
  late HttpServer server;
  int mkcolCount = 0;
  int propfindCount = 0;
  int putCount = 0;
  int getCount = 0;

  /// 覆盖 MKCOL / PROPFIND 的状态码（默认成功路径）。
  int mkcolStatus = 201;
  int propfindStatus = 207;

  /// 是否在 PROPFIND 中返回 `getetag`（false = 模拟不提供版本的服务端）。
  bool includeVersion = true;
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
          request.response.statusCode = mkcolStatus;
        case 'PROPFIND':
          propfindCount++;
          request.response.statusCode = propfindStatus;
          if (propfindStatus >= 400) break;
          final prefix = request.uri.path.endsWith('/')
              ? request.uri.path
              : '${request.uri.path}/';
          final body = files.keys
              .map((name) =>
                  '<d:response><d:href>$prefix$name</d:href>'
                  '${includeVersion ? '<d:propstat><d:prop><d:getetag>'
                      '${etags[name] ?? ''}</d:getetag></d:prop></d:propstat>' : ''}'
                  '</d:response>')
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
          final name = request.uri.path.split('/').last;
          files[name] = builder.toBytes();
          etags[name] = '"${++_etagSeq}"';
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
