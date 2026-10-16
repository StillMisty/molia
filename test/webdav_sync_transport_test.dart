import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_crypto.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/data/sync/transport/webdav_sync_transport.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/ports/sync_transport.dart';

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
    bool ignored = false,
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
        ignoredPeersProvider: (peerId) => ignored && peerId == deviceId,
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
    expect(server.files.keys, contains('devA.snapshot.msync'));

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
    expect(server.files, contains('devA.snapshot.msync'));
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
    expect(result.contacted, isFalse);
  });

  test('目录可读但零快照：接触成功（首台设备 PUT 失败仍是部分失败）', () async {
    server.putStatus = 500;
    final a = transport('devA');
    addTearDown(() => a.stop());
    await a.start();

    // 目录可读、还没有其他设备的快照：远端可达，零快照也算接触。
    final pulled = await a.pull();
    expect(pulled.envelopes, isEmpty);
    expect(pulled.peersSeen, 0);
    expect(pulled.contacted, isTrue);

    // 首台设备的写入失败：推送失败有原因，但接触面是成功的。
    final pushed = await a.push(envelope('devA'));
    expect(pushed.failedPeers, 1);
    expect(pushed.error?.code, SyncIssueCode.webdavUploadFailed);
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

    // 远端文件未动 + 本机游标已到上次读到的头部：第二轮不 GET、不解密、不合并。
    final decryptionsBefore = codec.decryptions;
    final second = await b.pull(
      const SyncPullRequest(cursors: {'devA': 0}),
    );
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

  test('增量窗口与全量快照分开文件：日常只重写增量', () async {
    final a = transport('devA');
    addTearDown(() => a.stop());
    await a.start();

    await a.push(SyncEnvelope(
      deviceId: 'devA',
      producedAt: 1,
      journalHead: 3,
      baseSeq: 0,
      windowStart: 3,
      windowEnd: 3,
      journal: [
        SyncJournalEntry(
          seq: 3,
          category: SyncCategory.settings,
          record: SyncRecord(
            key: 'theme_mode',
            version: const SyncVersion(physical: 10, deviceId: 'devA'),
            data: const {'v': 'dark'},
          ),
        ),
      ],
    ));
    expect(server.files.keys, contains('devA.journal.msync'));
    expect(server.files.keys, isNot(contains('devA.snapshot.msync')));

    await a.push(envelope('devA'));
    expect(server.files.keys, contains('devA.snapshot.msync'));
  });

  test('幽灵 / 旧版文件不参与合并；载荷身份不符的文件跳过', () async {
    // 非本协议命名的残留（幽灵设备遗留）与身份不符的日志文件。
    server.files['ghost.msync'] = codec.encrypt(envelope('ghost'), passphrase);
    server.files['fake.journal.msync'] =
        codec.encrypt(envelope('someone-else'), passphrase);
    final a = transport('devA');
    final b = transport('devB');
    addTearDown(() async {
      await a.stop();
      await b.stop();
    });
    await a.start();
    await b.start();
    await a.push(envelope('devA', value: 'light'));

    final pulled = await b.pull();
    expect(pulled.envelopes, hasLength(1));
    expect(pulled.envelopes.single.deviceId, 'devA');
    expect(pulled.peersSeen, 1, reason: '幽灵文件不算对端');
    expect(pulled.failedPeers, 0);
  });

  test('本地忽略的设备：不读取它的远端文件（幽灵设备处置）', () async {
    final a = transport('devA');
    final ghost = transport('ghost', ignored: true);
    addTearDown(() async {
      await a.stop();
      await ghost.stop();
    });
    await a.start();
    await ghost.start();
    await a.push(envelope('devA', value: 'light'));
    // 幽灵设备的文件（旧 deviceId）留在远端。
    server.files['ghost.snapshot.msync'] =
        codec.encrypt(envelope('ghost'), passphrase);
    server.files['ghost.journal.msync'] =
        codec.encrypt(envelope('ghost'), passphrase);

    final pulled = await ghost.pull();
    expect(pulled.envelopes, hasLength(1));
    expect(pulled.envelopes.single.deviceId, 'devA');
    expect(pulled.peersSeen, 1, reason: '忽略的设备不算对端');
  });

  test('显式清理远端文件：删除该设备的日志 / 快照 / 其它命名残留', () async {
    final a = transport('devA');
    addTearDown(() => a.stop());
    await a.start();
    await a.push(envelope('devA'));
    server.files['devA.journal.msync'] = server.files['devA.snapshot.msync']!;
    server.files['devA.msync'] = server.files['devA.snapshot.msync']!;

    expect(await a.deleteRemote('devA'), isTrue);
    expect(server.files.keys, isNot(contains('devA.snapshot.msync')));
    expect(server.files.keys, isNot(contains('devA.journal.msync')));
    expect(server.files.keys, isNot(contains('devA.msync')));
    // 没有文件可删时不算失败。
    expect(await a.deleteRemote('devA'), isFalse);
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

  /// 覆盖 MKCOL / PROPFIND / PUT 的状态码（默认成功路径）。
  int mkcolStatus = 201;
  int propfindStatus = 207;
  int putStatus = 201;

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
          request.response.statusCode = putStatus;
          if (putStatus >= 400) break;
          final name = request.uri.path.split('/').last;
          files[name] = builder.toBytes();
          etags[name] = '"${++_etagSeq}"';
        case 'DELETE':
          final name = request.uri.path.split('/').last;
          if (files.remove(name) != null) {
            etags.remove(name);
            request.response.statusCode = 204;
          } else {
            request.response.statusCode = 404;
          }
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
