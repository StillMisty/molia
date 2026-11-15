/// 取链重试策略（纯函数，便于单测）。
///
/// 取链比搜索更「贵」：失败一次往往要等满脚本超时，且重试会推迟起播。
/// 所以这里只做**一次**重试 + 硬性总预算，且只在失败语义明确是暂时性时重试；
/// 「该档位没地址」交给 `SourceManager` 降档，「地址彻底失效」交给换源。
library;

import 'dart:math' as math;

import '../../domain/models/failure.dart';

/// 单曲取链最多尝试次数（首次 + 一次重试）。
const int kResolveMaxAttempts = 2;

/// 单曲取链总预算（硬截止，含重试与退避）。
///
/// 每次尝试只拿「剩余预算」当超时提示并叠加 `.timeout` 兜底，所以总耗时不会
/// 因为重试而翻倍；超过后不再发起新尝试。
const Duration kResolveBudget = Duration(seconds: 25);

/// 重试基础退避；实际值带 ±30% 抖动，避免多个失败请求同时重发。
const Duration kResolveRetryBackoff = Duration(milliseconds: 300);

/// 失败是否值得在同一音源、同一档位上重试。
///
/// 只重试「暂时性」失败：网络抖动、超时、限流、脚本一过性报错、引擎正在重启。
/// `notFound` / `unsupported` 是「这个档位/曲目没有地址」，重发同一请求没有意义；
/// `unauthorized` / `cancelled` / `playback` / `unknown` 同理。
bool shouldRetryResolve(SourceFailure failure) {
  if (!failure.retryable) return false;
  switch (failure.kind) {
    case FailureKind.network:
    case FailureKind.timeout:
    case FailureKind.rateLimited:
    case FailureKind.scriptError:
    case FailureKind.engineRestarting:
      return true;
    case FailureKind.notFound:
    case FailureKind.unsupported:
    case FailureKind.unauthorized:
    case FailureKind.cancelled:
    case FailureKind.playback:
    case FailureKind.unknown:
      return false;
  }
}

/// 第 [attempt] 次尝试失败后、下一次重试前的等待时长。
///
/// [attempt] 从 1 开始；基础退避按尝试序号线性增长（第 2 次重试等 2 倍），
/// 再叠加 ±30% 抖动。当前上限是 2 次尝试，实际只会用到 [attempt] = 1。
Duration resolveRetryDelay(int attempt, {math.Random? random}) {
  final steps = attempt < 1 ? 1 : attempt;
  final jitter = 0.7 + (random ?? math.Random()).nextDouble() * 0.6;
  final micros = (kResolveRetryBackoff.inMicroseconds * steps * jitter).round();
  return Duration(microseconds: micros);
}
