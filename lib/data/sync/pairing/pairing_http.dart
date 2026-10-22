/// 配对 HTTP 的传输边界：服务只处理纯数据请求 / 响应，`dart:io` 细节收在
/// 传输层与默认客户端里。
///
/// 这样配对状态机可以在不绑真实端口的情况下测试（注入 [PairingHttpClient]
/// 或直接调用 [PairingHttpHandler.handle]），而生产仍走真实回环 / 局域网。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../../utils/peer_address.dart';

/// `/pair/*` 路径常量（版本是硬断代：旧路径一律 404）。
abstract final class PairingHttpPaths {
  static const String prefix = '/molia-sync/v2/pair';
  static const String request = '$prefix/request';
  static const String status = '$prefix/status';
  static const String complete = '$prefix/complete';
}

/// 配对 JSON body 上限（8KB）。
const int pairingMaxBodyBytes = 8 * 1024;

/// 传输层交给配对服务的一条 HTTP 请求。
class PairingHttpRequest {
  const PairingHttpRequest({
    required this.method,
    required this.path,
    required this.sourceHost,
    this.query = const {},
    this.body = const [],
  });

  final String method;
  final String path;

  /// TCP 来源地址（限流键；不写入任何持久化状态）。
  final String sourceHost;
  final Map<String, String> query;
  final List<int> body;

  int get bodyLength => body.length;
}

/// 配对服务返回给传输层的一条 HTTP 响应。
class PairingHttpResponse {
  const PairingHttpResponse({
    required this.statusCode,
    required this.body,
    this.contentType = 'application/json; charset=utf-8',
  });

  final int statusCode;
  final String body;
  final String contentType;

  static PairingHttpResponse json(
    Map<String, Object?> body, {
    int statusCode = HttpStatus.ok,
  }) =>
      PairingHttpResponse(
        statusCode: statusCode,
        body: jsonEncode(body),
      );
}

/// 接收方 HTTP 端点：由 `LanSyncTransport` 在 `/pair/*` 路径上调用。
abstract interface class PairingHttpHandler {
  Future<void> start();

  Future<void> stop();

  Future<PairingHttpResponse> handle(PairingHttpRequest request);

  /// 退后台：取消待确认弹窗 / 扫描；传输层转发。
  void onAppHidden();

  /// 回前台：若仍在扫描则补一次探测；传输层转发。
  void onAppResumed();
}

/// 一次 HTTP 调用的结果（客户端实现可注入）。
class PairingHttpReply {
  const PairingHttpReply({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

/// 发起方 HTTP 客户端接口（生产 = [IoPairingHttpClient]）。
abstract interface class PairingHttpClient {
  Future<PairingHttpReply> send({
    required String method,
    required String host,
    required int port,
    required String path,
    Map<String, String>? query,
    List<int>? body,
    required Duration timeout,
  });

  void close();
}

/// 生产客户端：每次请求新建一个 `HttpClient`，连接 / 整请求超时都由调用方
/// 给定；响应体限制在 64KB，避免对端异常响应撑爆内存。
class IoPairingHttpClient implements PairingHttpClient {
  /// 单个响应体上限（正常状态响应只有几百字节）。
  static const int maxResponseBytes = 64 * 1024;

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
    final normalized = normalizePeerHost(host);
    final uri = Uri(
      scheme: 'http',
      host: normalized,
      port: port,
      path: path,
      queryParameters: query == null || query.isEmpty ? null : query,
    );
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = method == 'POST'
          ? await client.postUrl(uri).timeout(timeout)
          : await client.getUrl(uri).timeout(timeout);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.add(body);
      }
      final response = await request.close().timeout(timeout);
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
        if (builder.length > maxResponseBytes) {
          throw const FormatException('配对响应过大');
        }
      }
      return PairingHttpReply(
        statusCode: response.statusCode,
        body: utf8.decode(builder.toBytes(), allowMalformed: true),
      );
    } finally {
      client.close(force: true);
    }
  }

  @override
  void close() {}
}
