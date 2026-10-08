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

/// 领域层统一失败模型：UI 只消费 kind / l10nKey / retryable，不再显示 `$e`。
///
/// 纯 Dart 实现（不依赖 Flutter / HTTP 包）：`from` 通过类型名与字符串特征
/// 归一化常见错误，避免领域层 import `lib/sources/**`（layering 硬规则）与
/// `dart:io`（Web 构建兼容）。已知映射：
/// - `LxEngineException` → scriptError
/// - `TimeoutException` → timeout
/// - `SocketException` / `ClientException` / `HttpException` → network
/// - 其余 → unknown
class SourceFailure implements Exception {
  final FailureKind kind;

  /// 开发/日志用（英文前缀 + 原始错误），兼容期也直接作为提示正文。
  final String message;

  /// UI 文案 key（阶段 1 起由 composition root 的 UiMessenger 映射 l10n）。
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
