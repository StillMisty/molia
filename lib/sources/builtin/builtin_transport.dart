import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show compute;

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
/// 内置平台（五个音乐平台 + B 站）搜索 / 发现 / 评论 / 取链适配器共用同一条
/// 传输路径；测试通过注入 `Dio`
/// （`BuiltinSearch.transport = BuiltinTransport(dio: appDioWith(MockDioAdapter(...)))`）
/// 覆盖 fetch 路径。
class BuiltinTransport {
  BuiltinTransport({Dio? dio, RequestCache? cache, this.retryDelay})
      : _dio = dio ?? createAppDio(),
        _cache = cache ?? RequestCache(ttl: defaultCacheTtl);

  final Dio _dio;

  /// 内置请求结果的统一缓存（single-flight + LRU + TTL）：发现适配器共用
  /// 此实例；测试注入新 transport 即得到干净缓存。
  final RequestCache _cache;

  /// 重试退避（可注入；测试传 no-op 避免真实等待）。参数是第几次重试
  /// （从 1 开始）。默认指数退避 + 抖动。
  final Future<void> Function(int attempt)? retryDelay;

  /// 全局测试钩子（`test/flutter_test_config.dart` 置为 no-op）：不逐个
  /// 构造函数注入也能让测试不产生真实等待。生产恒为 null；发现端点走的
  /// [runBuiltinAttempts] 复用同一钩子（两处退避是同一策略）。
  static Future<void> Function(int attempt)? retryDelayOverride;

  /// 默认重试退避：`base × 2^(n-1)` 封顶 [_retryBackoffMax]，叠加 ±30% 抖动。
  ///
  /// 退避而非紧挨着连发：平台限流（403/429）时立刻重发只会把限流打成更长
  /// 的封禁，且弱网下同时挂多个在途请求。
  static const Duration retryBackoffBase = Duration(milliseconds: 300);
  static const Duration _retryBackoffMax = Duration(seconds: 4);
  static final math.Random _backoffJitter = math.Random();

  static Future<void> retryBackoff(int attempt) {
    final exponential =
        retryBackoffBase.inMilliseconds * (1 << (attempt - 1).clamp(0, 5));
    final capped = math.min(exponential, _retryBackoffMax.inMilliseconds);
    final jitter = 0.7 + 0.6 * _backoffJitter.nextDouble();
    return Future<void>.delayed(
      Duration(milliseconds: (capped * jitter).round()),
    );
  }

  Future<void> _delayBefore(int attempt) =>
      (retryDelay ?? retryDelayOverride ?? retryBackoff)(attempt);

  /// 统一结果缓存 TTL（发现/热搜等，5 分钟）。
  static const Duration defaultCacheTtl = Duration(minutes: 5);

  /// 缓存入口：key 由调用方按 `{platform}:{type}:{params}` 约定拼装，
  /// [create] 内完成请求与解析（失败不缓存，语义同 [RequestCache]）。
  Future<T> cached<T>(String key, Future<T> Function() create) =>
      _cache.getOrCreate(key, create);

  /// 缓存 + 重试的合并入口（发现适配器的唯一取数方式）。
  ///
  /// 尝试循环本身在 [runBuiltinAttempts]（唯一实现）；这里只负责把成功结果
  /// 包进 single-flight 缓存：失败/异常时 [RequestCache] 会移除条目，下一次
  /// 调用重新尝试（失败不缓存）。
  Future<T> cachedRetry<T>(
    String key, {
    required int maxTries,
    String message = 'try max num',
    required Future<T?> Function(int tryNum) attempt,
  }) {
    return cached(
      key,
      () => runBuiltinAttempts(
        maxTries: maxTries,
        message: message,
        attempt: attempt,
        delay: _delayBefore,
      ),
    );
  }

  static const Duration defaultTimeout = Duration(seconds: 15);

  /// 统一重试预算（含首次尝试）：平台搜索等 HTTP 取数共用同一策略；
  /// 发现端点的业务级重试预算见 [BuiltinRetryBudget]。
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
    required FutureOr<T> Function(Response<dynamic> response) decode,
    required Duration timeout,
    required int retries,
    bool Function(T decoded)? retryIf,
  }) async {
    final maxAttempts = retries < 1 ? 1 : retries;
    Object? lastError;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (attempt > 0) await _delayBefore(attempt);
      try {
        final response = await send(attempt).timeout(timeout);
        final decoded = await decode(response);
        if (retryIf != null && attempt < maxAttempts - 1 && retryIf(decoded)) {
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

  /// 大响应（万首级歌单等）转独立的 isolate 解码，避免数十 MB JSON 把
  /// UI isolate 卡住（平台接口一次返回整单，解码本身是同步 CPU 工作）。
  static const int decodeIsolateThreshold = 256 * 1024;

  Future<dynamic> _decodeJson(Response<dynamic> response) async {
    final text = bodyText(response);
    if (text.trim().isEmpty) {
      throw BuiltinHttpException('HTTP ${response.statusCode}: empty body');
    }
    try {
      if (text.length >= decodeIsolateThreshold) {
        return await compute(jsonDecode, text);
      }
      return jsonDecode(text);
    } catch (_) {
      throw BuiltinHttpException(
          'HTTP ${response.statusCode}: invalid JSON body');
    }
  }
}

/// 发现 / 端点重试预算（含首次尝试）。
///
/// 数字集中在这里：平台文件按语义引用，避免同一策略在各适配器里漂移成
/// 3/4/6。预算是首屏失败率的一部分，调整前先看对应条目的来由。
abstract final class BuiltinRetryBudget {
  /// 发现端点默认预算：直接引用传输层的 [BuiltinTransport.defaultRetries]
  /// （首次 + 2 次重试），同一数字只声明一处；搜索与发现保持同一重试策略。
  static const int discover = BuiltinTransport.defaultRetries;

  /// 榜单端点：榜单是发现页首屏，kw/kg/mg 沿用既有 4 次；
  /// 比默认多一次，不要按默认 3 收紧。
  static const int leaderboard = 4;

  /// 网易云榜单：与 LX 原实现一致（详情 + 批量歌曲详情两段都可能抖动），
  /// 沿用 6 次；收紧会改变首屏失败率。
  static const int wyLeaderboard = 6;
}

/// 内置端点的共享尝试循环（唯一实现）。
///
/// - [attempt] 返回 `null` 表示本次尝试失败，未达 [maxTries] 时继续；
/// - [attempt] 抛异常直接向上传播（异常不是「本次尝试失败」，不重试也不吞）；
/// - 用尽 [maxTries] 抛 [StateError]（[message] 是调用方与上游约定的信号，
///   见 `wy_leaderboard` 对 `'try max num'` 的豁免）；
/// - 重试之间走 [delay]（传输实例注入）→ [BuiltinTransport.retryDelayOverride]
///   → [BuiltinTransport.retryBackoff]，与传输层同一条指数退避 + 抖动策略。
///
/// 需要缓存时用 [BuiltinTransport.cachedRetry]；这里只负责尝试，不碰缓存。
Future<T> runBuiltinAttempts<T>({
  required int maxTries,
  String message = 'try max num',
  required Future<T?> Function(int tryNum) attempt,
  Future<void> Function(int attempt)? delay,
}) async {
  for (var tryNum = 0; tryNum < maxTries; tryNum++) {
    if (tryNum > 0) {
      final wait = delay ??
          BuiltinTransport.retryDelayOverride ??
          BuiltinTransport.retryBackoff;
      await wait(tryNum);
    }
    final result = await attempt(tryNum);
    if (result != null) return result;
  }
  throw StateError(message);
}
