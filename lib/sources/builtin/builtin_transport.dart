import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../data/cache/request_cache.dart';
import '../../data/http/app_dio.dart';

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
/// 五个平台搜索与发现适配器共用同一条传输路径；测试通过注入 `Dio`
/// （`BuiltinSearch.transport = BuiltinTransport(dio: appDioWith(MockDioAdapter(...)))`）
/// 覆盖 fetch 路径。
class BuiltinTransport {
  BuiltinTransport({Dio? dio, RequestCache? cache})
      : _dio = dio ?? createAppDio(),
        _cache = cache ?? RequestCache(ttl: defaultCacheTtl);

  final Dio _dio;

  /// 内置请求结果的统一缓存（single-flight + LRU + TTL）：发现适配器共用
  /// 此实例；测试注入新 transport 即得到干净缓存。
  final RequestCache _cache;

  /// 统一结果缓存 TTL（发现/热搜等，5 分钟）。
  static const Duration defaultCacheTtl = Duration(minutes: 5);

  /// 缓存入口：key 由调用方按 `{platform}:{type}:{params}` 约定拼装，
  /// [create] 内完成请求与解析（失败不缓存，语义同 [RequestCache]）。
  Future<T> cached<T>(String key, Future<T> Function() create) =>
      _cache.getOrCreate(key, create);

  /// 缓存 + 重试的合并入口（发现适配器的唯一取数方式）。
  ///
  /// 语义（与旧的 `cached(...)` 套 `retryRequest(...)` 完全一致）：
  /// - [attempt] 返回 null = 本次尝试失败（平台业务码异常 / 结构不符），继续重试；
  /// - 抛异常直接向上传播（不吞错、不重试——异常不是「本次尝试失败」）；
  /// - 用尽 [maxTries] 抛 [StateError]（[message] 是调用方与上游约定的信号，
  ///   见 `wy_leaderboard` 对 `'try max num'` 的豁免）；
  /// - 只有成功结果进缓存（失败不缓存）。
  Future<T> cachedRetry<T>(
    String key, {
    required int maxTries,
    String message = 'try max num',
    required Future<T?> Function(int tryNum) attempt,
  }) {
    return cached(key, () async {
      for (var tryNum = 0; tryNum < maxTries; tryNum++) {
        final result = await attempt(tryNum);
        if (result != null) return result;
      }
      throw StateError(message);
    });
  }

  static const Duration defaultTimeout = Duration(seconds: 15);

  /// 统一重试预算（含首次尝试）：平台搜索与发现共用同一策略。
  static const int defaultRetries = 3;

  static const Map<String, String> defaultHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36',
  };

  /// GET + JSON 解码。
  ///
  /// [retryIf] 为响应级重试判定（「响应有效但为空页/业务码异常」的平台语义）；
  /// 重试耗尽后返回最后一次结果，交由调用方处理。
  Future<dynamic> getJson(
    String url, {
    Map<String, String>? headers,
    Duration timeout = defaultTimeout,
    int retries = 1,
    bool Function(dynamic json)? retryIf,
  }) {
    return _attempt(
      (_) => _dio.getUri(
        Uri.parse(url),
        options: Options(headers: _merge(headers)),
      ),
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
      (_) => _dio.getUri(
        Uri.parse(url),
        options: Options(headers: _merge(headers)),
      ),
      decode: bodyText,
      timeout: timeout,
      retries: retries,
    );
  }

  /// GET + 原始字节（酷我 lrcx 等二进制歌词响应）。
  Future<Uint8List> getBytes(
    String url, {
    Map<String, String>? headers,
    Duration timeout = defaultTimeout,
    int retries = 1,
  }) {
    return _attempt(
      (_) => _dio.getUri(
        Uri.parse(url),
        options: Options(headers: _merge(headers)),
      ),
      decode: bodyBytes,
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
    // Content-Type 走 headers 而不是 dio 的 `Options.contentType`：
    // 两者同时设置会触发 RequestOptions 的断言，且 headers 版本能保留
    // 调用点现有的 `putIfAbsent` 覆盖语义。
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
      (_) => _dio.postUri(
        Uri.parse(url),
        data: encodedBody,
        options: Options(headers: requestHeaders),
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
    Future<Response<dynamic>> Function(int attempt) send, {
    required T Function(Response<dynamic> response) decode,
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

  dynamic _decodeJson(Response<dynamic> response) {
    final text = bodyText(response);
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
