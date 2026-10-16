/// 近 24 小时的同步活动汇总（同步页观测面）。
library;

/// 一轮同步的活动记录（只保留统计所需的最小字段）。
///
/// 与展示日志（`SyncLogEntry`，上限 20 条）分开维护：观测面的「近 24 小时」
/// 不能受展示保留量截断。
class SyncActivityEntry {
  const SyncActivityEntry({
    required this.at,
    this.bytesIn = 0,
    this.bytesOut = 0,
    this.applied = 0,
  });

  /// 轮次完成时间（本机时钟，毫秒）。
  final int at;

  final int bytesIn;
  final int bytesOut;

  /// 本轮落地的记录数（变更量）。
  final int applied;

  /// 是否有实际数据流转或落地（有效传输）。
  bool get effective => bytesIn + bytesOut > 0 || applied > 0;

  Map<String, dynamic> toJson() => {
        'at': at,
        if (bytesIn > 0) 'bytesIn': bytesIn,
        if (bytesOut > 0) 'bytesOut': bytesOut,
        if (applied > 0) 'applied': applied,
      };

  static SyncActivityEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final at = raw['at'];
    if (at is! num) return null;
    return SyncActivityEntry(
      at: at.toInt(),
      bytesIn: (raw['bytesIn'] as num?)?.toInt() ?? 0,
      bytesOut: (raw['bytesOut'] as num?)?.toInt() ?? 0,
      applied: (raw['applied'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 近 24 小时的同步活动汇总。
class SyncActivitySummary {
  const SyncActivitySummary({
    required this.rounds,
    required this.effectiveRounds,
    required this.bytesIn,
    required this.bytesOut,
  });

  /// 汇总窗口（状态存储按更宽松的上限保留条目，窗口在此过滤）。
  static const Duration window = Duration(hours: 24);

  /// 窗口内触发的轮数。
  final int rounds;

  /// 其中有效传输的轮数：有字节流转或有记录落地。
  final int effectiveRounds;

  final int bytesIn;
  final int bytesOut;

  int get bytes => bytesIn + bytesOut;

  bool get isEmpty => rounds == 0;

  static SyncActivitySummary fromEntries(
    Iterable<SyncActivityEntry> entries, {
    required int nowMs,
  }) {
    final cutoff = nowMs - window.inMilliseconds;
    var rounds = 0;
    var effective = 0;
    var bytesIn = 0;
    var bytesOut = 0;
    for (final entry in entries) {
      // 只按「早于窗口」过滤：时间戳可能来自略快的时钟，不应被丢弃。
      if (entry.at < cutoff) continue;
      rounds++;
      bytesIn += entry.bytesIn;
      bytesOut += entry.bytesOut;
      if (entry.effective) effective++;
    }
    return SyncActivitySummary(
      rounds: rounds,
      effectiveRounds: effective,
      bytesIn: bytesIn,
      bytesOut: bytesOut,
    );
  }
}
