/// 播放音量的淡入淡出包络（纯数值，可单测）。
///
/// 这里只算「当前该乘多少」：播放服务把用户音量与包络相乘后写给播放器，
/// 包络本身不持有播放器、不发通知，也不进任何状态快照。
library;

/// 最短可听淡变窗口：短于它的请求直接落到目标值。
///
/// 低于约 50ms 时人耳听到的是「咔哒」而不是渐变；平台音量调用本身也可能
/// 比这个窗口更慢，强行分步只会让结果不可预测。
const Duration kMinimumAudibleFade = Duration(milliseconds: 50);

/// 当前时间点应使用的增益倍数（0..1）。
///
/// 曲线在两端都平缓（smoothstep），避免起止点出现音量台阶；[from] / [to]
/// 允许从当前电平出发（快速播放 / 暂停时从半程反向），因此结果始终落在
/// 两端点之间，且随 [elapsed] 单调移动。
double fadeGainAt({
  required Duration elapsed,
  required Duration duration,
  required double from,
  required double to,
}) {
  if (duration < kMinimumAudibleFade || duration <= Duration.zero) {
    return to.clamp(0.0, 1.0);
  }
  final t = (elapsed.inMicroseconds / duration.inMicroseconds).clamp(0.0, 1.0);
  final eased = t * t * (3 - 2 * t);
  final value = from + (to - from) * eased;
  return value.clamp(0.0, 1.0);
}

/// 一次淡变：起点 / 终点 / 时长固定，按已过时间取样。
///
/// 时长在创建时固定：用户中途改设置只影响下一次过渡，不会把正在跑的
/// 淡变拉长或截短。
class FadeRamp {
  const FadeRamp({
    required this.from,
    required this.to,
    required this.duration,
  });

  final double from;
  final double to;
  final Duration duration;

  /// 时长低于可听窗口：创建方应直接写目标值，不进入分步循环。
  bool get isImmediate => duration < kMinimumAudibleFade;

  double gainAt(Duration elapsed) =>
      fadeGainAt(elapsed: elapsed, duration: duration, from: from, to: to);

  bool isComplete(Duration elapsed) => elapsed >= duration;
}
