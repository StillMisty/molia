/// 听歌同步协议的 HTTP 共用小工具：状态码归类与 Retry-After 解析。
library;

import 'dart:async';

import 'package:dio/dio.dart';

import '../../domain/models/scrobble.dart';

/// 把协议状态码翻译成投递结论。
///
/// 401/403 = 授权失效；429 = 限流（可带 Retry-After）；5xx 与 408 = 短暂
/// 故障；其余 4xx = 请求本身不可能成功。响应体不进入 reason：里面可能回显
/// 请求参数。
ScrobbleDelivery deliveryForStatus(
  int status, {
  Map<String, List<String>> headers = const {},
}) {
  if (status >= 200 && status < 300) {
    return const ScrobbleDelivery.success();
  }
  if (status == 401 || status == 403) {
    return const ScrobbleDelivery.unauthorized();
  }
  if (status == 429) {
    return ScrobbleDelivery.retryable(retryAfter: parseRetryAfter(headers));
  }
  if (status == 408 || status >= 500) {
    return const ScrobbleDelivery.retryable();
  }
  return const ScrobbleDelivery.permanent();
}

/// 连接 / 读取超时（规格：短超时，绝不拖住播放）。
const Duration kScrobbleTimeout = Duration(seconds: 10);

/// Retry-After：秒数优先，其次 HTTP-date；解析不了返回 null。
Duration? parseRetryAfter(Map<String, List<String>> headers) {
  String? raw;
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == 'retry-after' && entry.value.isNotEmpty) {
      raw = entry.value.first.trim();
      break;
    }
  }
  if (raw == null || raw.isEmpty) return null;
  final seconds = int.tryParse(raw);
  if (seconds != null) return Duration(seconds: seconds.clamp(0, 86400));
  final date = DateTime.tryParse(raw);
  if (date == null) return null;
  final delta = date.difference(DateTime.now());
  return delta.isNegative ? Duration.zero : delta;
}

/// 统一异常归类：网络 / 超时 → 可重试。
ScrobbleDelivery deliveryForError(Object error) {
  if (error is TimeoutException) {
    return const ScrobbleDelivery.retryable();
  }
  if (error is DioException) {
    if (error.response != null) {
      return deliveryForStatus(
        error.response?.statusCode ?? 0,
        headers: error.response?.headers.map ?? const {},
      );
    }
    return const ScrobbleDelivery.retryable();
  }
  return const ScrobbleDelivery.retryable();
}
