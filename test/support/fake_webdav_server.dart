/// 最小 WebDAV 假服务：MKCOL / PROPFIND / PUT / GET / DELETE + 可选 Basic 鉴权。
///
/// 供传输单测与多设备端到端（`sync_webdav_e2e_test.dart`）共用；版本令牌按
/// PUT 递增（PROPFIND 返回 `getetag`），可用 `includeVersion = false` 模拟
/// 不提供版本的服务端。
library;

import 'dart:io';
import 'dart:typed_data';

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

  /// DELETE 的状态码（默认 204 / 404 由文件是否存在决定）。
  int? deleteStatus;
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
          if (deleteStatus != null) {
            request.response.statusCode = deleteStatus!;
            break;
          }
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
