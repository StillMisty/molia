import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// 内置平台请求失败：传输异常重试耗尽 / 空响应 / 非法 JSON。
class BuiltinHttpException implements Exception {
  BuiltinHttpException(this.message, {this.attempts = 1});

  final String message;
  final int attempts;

  @override
  String toString() => 'BuiltinHttpException($message, attempts=$attempts)';
}

/// 内置平台 HTTP 传输：客户端注入、统一请求头/超时、响应级重试与解码。
///
/// 五个平台搜索与发现适配器共用同一条传输路径；测试通过注入 `http.Client`
/// （`BuiltinSearch.transport = BuiltinTransport(client: MockClient(...))`）
/// 覆盖 fetch 路径，不再依赖全局 `http.get`（旧实现 fetch 完全不可测）。
class BuiltinTransport {
  BuiltinTransport({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const Duration defaultTimeout = Duration(seconds: 15);

  /// 统一重试预算（含首次尝试）：平台搜索与发现共用同一策略，
  /// 不再各自漂移（旧实现 2/3/5/3/3 并存）。
  static const int defaultRetries = 3;

  static const Map<String, String> defaultHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36',
  };

  /// GET + JSON 解码。
  ///
  /// [retryIf] 为响应级重试判定（「响应有效但为空页/业务码异常」的平台语义）；
  /// 重试耗尽后返回最后一次结果，由调用方按原有分支处理。
  Future<dynamic> getJson(
    String url, {
    Map<String, String>? headers,
    Duration timeout = defaultTimeout,
    int retries = 1,
    bool Function(dynamic json)? retryIf,
  }) {
    return _attempt(
      (_) => _client.get(Uri.parse(url), headers: _merge(headers)),
      decode: _decodeJson,
      timeout: timeout,
      retries: retries,
      retryIf: retryIf,
    );
  }

  /// GET + 文本（HTML 页面等非 JSON 响应）。
  Future<String> getText(
    String url, {
    Map<String, String>? headers,
    Duration timeout = defaultTimeout,
    int retries = 1,
  }) {
    return _attempt(
      (_) => _client.get(Uri.parse(url), headers: _merge(headers)),
      decode: (response) =>
          utf8.decode(response.bodyBytes, allowMalformed: true),
      timeout: timeout,
      retries: retries,
    );
  }

  /// POST + JSON 解码（[form] 为表单编码，否则 JSON body）。
  Future<dynamic> postJson(
    String url, {
    Map<String, String>? headers,
    Object? body,
    bool form = false,
    Duration timeout = defaultTimeout,
    int retries = 1,
    bool Function(dynamic json)? retryIf,
  }) {
    final requestHeaders = _merge(headers);
    Object? encodedBody;
    if (form) {
      requestHeaders.putIfAbsent(
        'Content-Type',
        () => 'application/x-www-form-urlencoded',
      );
      if (body is Map) {
        encodedBody = body.entries
            .map((entry) =>
                '${Uri.encodeQueryComponent(entry.key.toString())}=${Uri.encodeQueryComponent(entry.value.toString())}')
            .join('&');
      } else {
        encodedBody = body?.toString();
      }
    } else {
      requestHeaders.putIfAbsent('Content-Type', () => 'application/json');
      encodedBody = body is String ? body : jsonEncode(body);
    }
    return _attempt(
      (_) => _client.post(
        Uri.parse(url),
        headers: requestHeaders,
        body: encodedBody,
      ),
      decode: _decodeJson,
      timeout: timeout,
      retries: retries,
      retryIf: retryIf,
    );
  }

  Map<String, String> _merge(Map<String, String>? headers) =>
      {...defaultHeaders, ...?headers};

  /// 统一尝试循环：传输异常与 [retryIf] 响应都可重试；
  /// 空 body / 非法 JSON 属响应语义错误，不重试直接抛出。
  Future<T> _attempt<T>(
    Future<http.Response> Function(int attempt) send, {
    required T Function(http.Response response) decode,
    required Duration timeout,
    required int retries,
    bool Function(T decoded)? retryIf,
  }) async {
    final maxAttempts = retries < 1 ? 1 : retries;
    Object? lastError;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        final response = await send(attempt).timeout(timeout);
        final decoded = decode(response);
        if (retryIf != null &&
            attempt < maxAttempts - 1 &&
            retryIf(decoded)) {
          continue;
        }
        return decoded;
      } on BuiltinHttpException {
        rethrow;
      } catch (e) {
        lastError = e;
      }
    }
    throw BuiltinHttpException('$lastError', attempts: maxAttempts);
  }

  dynamic _decodeJson(http.Response response) {
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (text.trim().isEmpty) {
      throw BuiltinHttpException('HTTP ${response.statusCode}: empty body');
    }
    try {
      return jsonDecode(text);
    } catch (_) {
      throw BuiltinHttpException(
          'HTTP ${response.statusCode}: invalid JSON body');
    }
  }
}
