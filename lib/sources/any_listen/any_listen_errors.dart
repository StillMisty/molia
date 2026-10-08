/// any-listen 接入的错误模型。
///
/// 设计目标（与「未配置/连接失败时对现有功能零影响」一致）：
/// - 所有失败都归一化为 [AnyListenException]（kind + 可读中文 message），
///   绝不让 SocketException / FormatException 等原始异常泄漏到 UI；
/// - UI 可依据 [AnyListenErrorKind] 给出不同提示，[retryable] 标记是否可重试。
///
/// Wave 7：错误分类 [AnyListenErrorKind] 迁入 domain（`AnyListenTestResult`
/// 的公开字段类型），这里 export 保持既有 import 兼容。
library;

import 'dart:async';

import '../../domain/models/any_listen.dart';

export '../../domain/models/any_listen.dart' show AnyListenErrorKind;

/// any-listen 相关失败的统一异常。
///
/// 适配器与 SourceManager 的路由方法都会抛出它；`fetchLyric/fetchPic`
/// 等「允许失败」的契约在 SourceManager 层会吞掉异常并返回 null。
class AnyListenException implements Exception {
  final AnyListenErrorKind kind;

  /// 可读的中文描述，可直接展示给用户。
  final String message;

  /// 触发错误的 HTTP 状态码（如果有）。
  final int? statusCode;

  /// 原始异常，仅用于日志排查，不展示给用户。
  final Object? cause;

  const AnyListenException(
    this.kind,
    this.message, {
    this.statusCode,
    this.cause,
  });

  /// 连接层失败可重试；其余（配置错误/格式错误/鉴权）重试意义不大。
  bool get retryable => kind == AnyListenErrorKind.connectionFailed;

  factory AnyListenException.notConfigured() => const AnyListenException(
        AnyListenErrorKind.notConfigured,
        '未配置 any-listen 服务器地址，或未启用 any-listen 接入',
      );

  static AnyListenException badResponse(String message, {Object? cause}) =>
      AnyListenException(AnyListenErrorKind.badResponse, message, cause: cause);

  /// 把任意底层异常归类为可读错误。
  ///
  /// 注意：[error] 已是 [AnyListenException] 时原样返回，避免重复包装。
  static AnyListenException from(Object error, {String? detail}) {
    if (error is AnyListenException) return error;
    if (error is TimeoutException) {
      return AnyListenException(
        AnyListenErrorKind.connectionFailed,
        detail ?? '请求 any-listen 服务器超时',
        cause: error,
      );
    }
    if (error is FormatException) {
      return AnyListenException(
        AnyListenErrorKind.badResponse,
        detail ?? 'any-listen 响应不是合法 JSON',
        cause: error,
      );
    }
    return AnyListenException(
      AnyListenErrorKind.connectionFailed,
      detail ?? '无法连接 any-listen 服务器：$error',
      cause: error,
    );
  }

  /// 按 HTTP 状态码归类。
  static AnyListenException fromHttpStatus(int statusCode) {
    if (statusCode == 401 || statusCode == 403) {
      return AnyListenException(
        AnyListenErrorKind.unauthorized,
        'any-listen 鉴权失败（HTTP $statusCode），请检查令牌是否正确',
        statusCode: statusCode,
      );
    }
    if (statusCode >= 500) {
      return AnyListenException(
        AnyListenErrorKind.connectionFailed,
        'any-listen 服务器错误（HTTP $statusCode）',
        statusCode: statusCode,
      );
    }
    return AnyListenException(
      AnyListenErrorKind.badResponse,
      'any-listen 返回异常状态（HTTP $statusCode）',
      statusCode: statusCode,
    );
  }

  @override
  String toString() => 'AnyListenException(${kind.name}): $message';
}
