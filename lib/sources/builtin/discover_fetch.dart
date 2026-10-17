import 'builtin_transport.dart';

/// 发现适配器的请求重试（唯一入口）。
///
/// 策略为显式参数：[attempt] 返回 `null` 表示本次尝试失败，未达 [maxTries]
/// 时重试，用尽后抛 [StateError]（`'try max num'` 语义）。
///
/// 重试之间有指数退避 + 抖动（与传输层同一策略与同一测试钩子）：紧挨着连发
/// 在平台限流（403/429）时只会把限流打成更长的封禁。
///
/// 说明：跨函数的策略切换（如酷我 digest5 → digest8）各自持有预算，
/// 这是刻意的：一次抓取策略拥有自己的重试策略，便于阅读与测试。
Future<T> retryRequest<T>({
  required int maxTries,
  String message = 'try max num',
  required Future<T?> Function(int tryNum) attempt,
}) async {
  for (var tryNum = 0; tryNum < maxTries; tryNum++) {
    if (tryNum > 0) {
      final delay = BuiltinTransport.retryDelayOverride ??
          BuiltinTransport.retryBackoff;
      await delay(tryNum);
    }
    final result = await attempt(tryNum);
    if (result != null) return result;
  }
  throw StateError(message);
}
