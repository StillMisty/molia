import 'sync_state_store.dart';

/// 近 24 小时的同步活动汇总（同步页观测面）。
///
/// 基于状态存储保留的最近日志条目：轮数超过保留量时按保留量展示，观测面
/// 只承诺「最近可见窗口」的口径，不另做一份计数。
class SyncActivitySummary {
  const SyncActivitySummary({
    required this.rounds,
    required this.effectiveRounds,
    required this.bytesIn,
    required this.bytesOut,
  });

  static const Duration window = Duration(hours: 24);

  /// 窗口内触发的轮数。
  final int rounds;

  /// 其中有效传输的轮数：有字节流转或有记录落地。
  final int effectiveRounds;

  final int bytesIn;
  final int bytesOut;

  int get bytes => bytesIn + bytesOut;

  bool get isEmpty => rounds == 0;

  static SyncActivitySummary fromLog(
    Iterable<SyncLogEntry> log, {
    required int nowMs,
  }) {
    final cutoff = nowMs - window.inMilliseconds;
    var rounds = 0;
    var effective = 0;
    var bytesIn = 0;
    var bytesOut = 0;
    for (final entry in log) {
      // 只按「早于窗口」过滤：日志里的时间戳可能来自略快的时钟，不应被丢弃。
      if (entry.at < cutoff) continue;
      rounds++;
      bytesIn += entry.bytesIn;
      bytesOut += entry.bytesOut;
      if (entry.bytesIn + entry.bytesOut > 0 || entry.applied > 0) {
        effective++;
      }
    }
    return SyncActivitySummary(
      rounds: rounds,
      effectiveRounds: effective,
      bytesIn: bytesIn,
      bytesOut: bytesOut,
    );
  }
}
