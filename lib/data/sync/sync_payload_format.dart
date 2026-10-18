/// 载荷编码标识与结构异常（见 `sync_payload.dart`）。
library;

/// 载荷编码标识（帧内明文头的第二个字节）。
abstract final class SyncPayloadCodec {
  /// 列式二进制（线上格式）。
  static const int binary = 1;

  /// JSON 文本（备份 / 测试 / 排障用）。
  static const int json = 0;
}

/// 载荷结构错误：帧层统一转成 `SyncCryptoException`（对端只见
/// 「载荷不可解析」，不泄漏内部异常类型与堆栈）。
class SyncPayloadFormatException implements Exception {
  const SyncPayloadFormatException(this.message);

  final String message;

  @override
  String toString() => 'SyncPayloadFormatException($message)';
}
