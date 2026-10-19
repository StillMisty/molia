/// 内置平台「发现」端点的执行入口（唯一取数路径）。
///
/// 端点变体面收进 [DiscoverCall]：
/// - [DiscoverRequestCall]：常见形状「一次请求 → 无效判定 → 解析」；
/// - [DiscoverAttemptCall]：多步端点（批量补全 / 分页循环 / 短链跳转）直接
///   给出整次尝试。
///
/// [runDiscoverCall] 只执行策略：有稳定 key 走 [BuiltinTransport.cachedRetry]
/// （single-flight 缓存，成功才缓存）；没有 key（外层已经缓存整张结果）走
/// [runBuiltinAttempts]（共享尝试循环）。重试预算在 [BuiltinRetryBudget]，
/// 退避在传输层唯一实现，平台文件只保留 URL / 参数与解析。
library;

import 'dart:async';

import 'builtin_search.dart';
import 'builtin_transport.dart';

/// 一次发现端点调用：缓存键 + 重试预算 + 失败判定 / 尝试。
sealed class DiscoverCall<T> {
  const DiscoverCall({
    required this.key,
    this.budget = BuiltinRetryBudget.discover,
    this.message = 'try max num',
  });

  /// 结果缓存键（`{platform}:{type}:{params}` 约定）。
  ///
  /// null 表示没有稳定 key：调用方外层已经缓存整张结果（如歌单详情内部的
  /// 补全请求、短链跳转），这里只做重试、不再套一层缓存，避免缓存身份漂移。
  final String? key;

  /// 重试预算（含首次尝试），见 [BuiltinRetryBudget]。
  final int budget;

  /// 重试耗尽信号（与上游约定的 message，见 `wy_leaderboard` 的豁免）。
  final String message;
}

/// 常见形状：一次请求 → [isInvalid] 判定 → [parse] 解析。
///
/// 判定为无效或解析返回 null 都表示「本次尝试失败」，交给共享尝试循环继续；
/// 判定 / 解析抛出的异常直接上抛（异常不是「本次尝试失败」）。
final class DiscoverRequestCall<T> extends DiscoverCall<T> {
  const DiscoverRequestCall({
    required this.request,
    required this.isInvalid,
    required this.parse,
    required super.key,
    super.budget,
    super.message,
  });

  /// 发一次请求（URL / 请求头 / 编码在平台文件里构造）。
  final Future<dynamic> Function() request;

  /// 平台业务码异常 / 结构不符 → true（本次尝试失败，继续重试）。
  final bool Function(dynamic response) isInvalid;

  /// 有效响应 → 结果；返回 null 也表示本次尝试失败。
  final FutureOr<T?> Function(dynamic response) parse;
}

/// 多步端点：整次尝试自己给（需要 tryNum 或内部循环时用）。
final class DiscoverAttemptCall<T> extends DiscoverCall<T> {
  const DiscoverAttemptCall({
    required this.attempt,
    required super.key,
    super.budget,
    super.message,
  });

  /// [tryNum] 从 0 开始；返回 null 表示本次尝试失败。
  final Future<T?> Function(int tryNum) attempt;
}

/// 执行一次发现端点调用（唯一入口）。
Future<T> runDiscoverCall<T>(DiscoverCall<T> call) {
  final attempt = _attemptOf(call);
  final key = call.key;
  if (key == null) {
    return runBuiltinAttempts(
      maxTries: call.budget,
      message: call.message,
      attempt: attempt,
    );
  }
  return BuiltinSearch.transport.cachedRetry(
    key,
    maxTries: call.budget,
    message: call.message,
    attempt: attempt,
  );
}

/// 把描述符归一到「第 tryNum 次尝试」闭包。
Future<T?> Function(int tryNum) _attemptOf<T>(DiscoverCall<T> call) {
  switch (call) {
    case DiscoverRequestCall<T>(
        :final request,
        :final isInvalid,
        :final parse,
      ):
      return (_) async {
        final response = await request();
        if (isInvalid(response)) return null;
        return await parse(response);
      };
    case DiscoverAttemptCall<T>(:final attempt):
      return attempt;
  }
}
