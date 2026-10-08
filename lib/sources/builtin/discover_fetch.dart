/// 发现适配器的请求重试（唯一入口）。
///
/// 各适配器原先各自维护 `{int tryNum = 0}` 守卫 + 「失败递归 +1」，
/// 上限在 2/3/6 之间漂移；本模块把策略收敛为显式参数：
/// [attempt] 返回 `null` 表示本次尝试失败，未达 [maxTries] 时重试，
/// 用尽后抛 [StateError]（保留原有的 `'try max num'` 语义）。
///
/// 说明：跨函数的策略切换（如酷我 digest5 → digest8）各自持有预算，
/// 这是刻意的：一次抓取策略拥有自己的重试策略，便于阅读与测试。
Future<T> retryRequest<T>({
  required int maxTries,
  String message = 'try max num',
  required Future<T?> Function(int tryNum) attempt,
}) async {
  for (var tryNum = 0; tryNum < maxTries; tryNum++) {
    final result = await attempt(tryNum);
    if (result != null) return result;
  }
  throw StateError(message);
}
