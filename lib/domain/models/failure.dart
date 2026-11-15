import 'dart:async' show TimeoutException;

/// 统一错误分类（播放错误复用同一模型）。
enum FailureKind {
  network,
  timeout,
  unsupported,
  notFound,
  unauthorized,
  rateLimited,
  scriptError,
  engineRestarting,
  cancelled,
  unknown,

  /// 播放链路错误（取链/解码/播放器失败）。
  playback,
}

/// 领域层统一失败模型：UI 只消费 kind / l10nKey / retryable，不直接渲染异常对象。
///
/// 纯 Dart 实现（不依赖 Flutter / HTTP 包）：`from` 通过类型名与字符串特征
/// 归一化常见错误，避免领域层 import `lib/sources/**`（layering 硬规则）与
/// `dart:io`（`SocketException` / `HttpException` 只按类型名识别）。已知映射：
/// - `LxEngineUnavailableException` → engineRestarting（可恢复，可重试）
/// - `LxResolveRejectedException` → notFound（该档位不可用，不原样重试）
/// - `LxEngineTimeoutException` → timeout
/// - `LxEngineException` → scriptError
/// - `TimeoutException` → timeout
/// - `SocketException` / `ClientException` / `HttpException` → network
/// - 其余 → unknown
class SourceFailure implements Exception {
  final FailureKind kind;

  /// 开发/日志用（英文前缀 + 原始错误）；失败提示文案会插入该原文。
  final String message;

  /// UI 文案 key（由 composition root 的 UiMessenger 映射 l10n）。
  final String? l10nKey;

  final Object? cause;
  final bool retryable;
  final Duration? retryAfter;

  const SourceFailure({
    required this.kind,
    required this.message,
    this.l10nKey,
    this.cause,
    this.retryable = false,
    this.retryAfter,
  });

  /// 归一化任意错误对象（幂等：传入 [SourceFailure] 原样返回）。
  factory SourceFailure.from(Object error) {
    if (error is SourceFailure) return error;

    final message = error is String ? error : error.toString();
    final typeName = error is String ? '' : error.runtimeType.toString();

    // LX 引擎细分错误（`lib/sources/lx/lx_engine_types.dart`）：领域层不能
    // import sources 层，按 runtimeType 名 / `toString` 前缀识别。必须排在
    // 通用 TimeoutException 之前：`LxEngineTimeoutException` 的字符串形态
    // 同样包含 "TimeoutException"。
    if (typeName == 'LxResolveRejectedException' ||
        message.startsWith('LxResolveRejectedException')) {
      // 脚本明确拒绝该档位/该曲目：不是暂时故障，原样重试没有意义。
      return SourceFailure(
        kind: FailureKind.notFound,
        message: message,
        cause: error,
        retryable: false,
      );
    }

    if (typeName == 'LxEngineUnavailableException' ||
        message.startsWith('LxEngineUnavailableException')) {
      // 引擎未运行 / 重启等待超时：请求没执行，恢复后重试即可。
      return SourceFailure(
        kind: FailureKind.engineRestarting,
        message: message,
        cause: error,
        retryable: true,
      );
    }

    if (typeName == 'LxEngineTimeoutException' ||
        message.startsWith('LxEngineTimeoutException')) {
      return SourceFailure(
        kind: FailureKind.timeout,
        message: message,
        cause: error,
        retryable: true,
      );
    }

    if (error is TimeoutException ||
        typeName == 'TimeoutException' ||
        message.startsWith('TimeoutException') ||
        message.contains('TimeoutException')) {
      return SourceFailure(
        kind: FailureKind.timeout,
        message: message,
        cause: error,
        retryable: true,
      );
    }

    // 领域层不能 import lib/sources/**，故按类型名/字符串前缀识别脚本错误。
    if (typeName == 'LxEngineException' ||
        message.startsWith('LxEngineException')) {
      return SourceFailure(
        kind: FailureKind.scriptError,
        message: message,
        cause: error,
        retryable: true,
      );
    }

    // 内置平台传输失败（lib/sources/builtin/builtin_transport.dart，同上按类型名）。
    if (typeName == 'BuiltinHttpException' ||
        message.startsWith('BuiltinHttpException')) {
      return SourceFailure(
        kind: FailureKind.network,
        message: message,
        cause: error,
        retryable: true,
      );
    }

    if (_isNetworkType(typeName) || _looksLikeNetworkMessage(message)) {
      return SourceFailure(
        kind: FailureKind.network,
        message: message,
        cause: error,
        retryable: true,
      );
    }

    return SourceFailure(
      kind: FailureKind.unknown,
      message: message,
      cause: error,
    );
  }

  static bool _isNetworkType(String typeName) {
    switch (typeName) {
      case 'SocketException':
      case 'ClientException':
      case 'HttpException':
      case 'TlsException':
      case 'HandshakeException':
        return true;
      default:
        return false;
    }
  }

  static bool _looksLikeNetworkMessage(String message) {
    return message.startsWith('SocketException') ||
        message.startsWith('ClientException') ||
        message.startsWith('HttpException') ||
        message.contains('Failed host lookup') ||
        message.contains('Connection refused') ||
        message.contains('Connection closed') ||
        message.contains('Connection reset');
  }

  @override
  bool operator ==(Object other) =>
      other is SourceFailure &&
      other.kind == kind &&
      other.message == message &&
      other.l10nKey == l10nKey &&
      other.retryable == retryable;

  @override
  int get hashCode => Object.hash(kind, message, l10nKey, retryable);

  @override
  String toString() => 'SourceFailure(${kind.name}): $message';
}
