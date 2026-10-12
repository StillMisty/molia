/// 听歌统计领域模型（纯 Dart，无 Flutter/provider 依赖）。
///
/// 一次播放尝试 = 一行 `play_events`（append-only）：元数据为播放时快照、
/// 自包含（`raw` 供统计页点播）；**聚合口径全部在查询时计算**，采集只负责
/// 忠实记录（口径变化不需要回填数据）。
library;

/// 统计口径常量（采集与查询共用的唯一来源）。
abstract final class PlayStatisticsLimits {
  const PlayStatisticsLimits._();

  /// 有效播放下限：`listenedMs ≥ min(qualifiedMinListenedMs, 50% × 时长)`。
  static const int qualifiedMinListenedMs = 30000;

  /// 有效播放比例下限。
  static const double qualifiedFraction = 0.5;

  /// 完整播放的末尾容差：进度 tick（≤4Hz）的调度抖动内即视为播到末尾。
  static const int completionToleranceMs = 1000;

  /// 导出明细上限（汇总与榜单覆盖全量，明细取最近 N 条）。
  static const int exportEventLimit = 2000;

  /// 有效播放阈值：`min(30s, 50% × 时长)`；时长未知 / 非法取 30s。
  ///
  /// **唯一口径**：SQL 谓词（查询实现内的 `_qualifiedPredicate`）与 AI 跳过
  /// 判定都从这里派生，并由「同一批 fixture 行 → SQL 与 Dart 判定逐行一致」的
  /// 对照测试钉住（`test/play_statistics_formula_test.dart`）。
  static int qualifiedThresholdMs(int? durationMs) {
    if (durationMs == null || durationMs <= 0) return qualifiedMinListenedMs;
    // 向上取整：与 SQL 的 `listenedMs >= durationMs * 0.5` 等价
    // （整数毫秒下 500.5 的门槛只有 ≥501 才满足）。
    final half = (durationMs * qualifiedFraction).ceil();
    return half < qualifiedMinListenedMs ? half : qualifiedMinListenedMs;
  }

  /// 有效播放判定：`listenedMs ≥ qualifiedThresholdMs(durationMs)`。
  static bool isQualified({required int listenedMs, required int? durationMs}) =>
      listenedMs >= qualifiedThresholdMs(durationMs);
}

/// 统计范围：周 / 月 / 全部。
enum PlayStatisticsRange { week, month, all }

/// 范围 → 时间窗口的唯一映射（查询与热力图高亮共用；本地时间）。
extension PlayStatisticsWindow on PlayStatisticsRange {
  /// 窗口起点；[PlayStatisticsRange.all] 为 null。
  DateTime? startOf(DateTime now) => switch (this) {
        PlayStatisticsRange.week => now.subtract(const Duration(days: 7)),
        PlayStatisticsRange.month => now.subtract(const Duration(days: 30)),
        PlayStatisticsRange.all => null,
      };

  /// 查询用的毫秒纪元（与 [startOf] 同一窗口）。
  int? sinceMs(DateTime now) => startOf(now)?.millisecondsSinceEpoch;
}

/// 一次范围查询的全部聚合：统计页只渲染它。
///
/// 范围语义（[PlayStatisticsRange]）与口径（[PlayStatisticsLimits]）都在领域层；
/// 实现（SQL / 分桶 / 去重）在 `lib/data/play_statistics_repository.dart`。
class ListeningStatisticsSnapshot {
  const ListeningStatisticsSnapshot({
    required this.summary,
    required this.topTracks,
    required this.topArtists,
    required this.daily,
    required this.byWeekdayHour,
    required this.sources,
  });

  final PlayStatisticsSummary summary;
  final List<PlayStatTrackEntry> topTracks;
  final List<PlayStatArtistEntry> topArtists;

  /// 日历热力图固定全量历史（范围切换只做高亮 + 数字联动）。
  final List<DayListened> daily;

  final List<WeekdayHourListened> byWeekdayHour;
  final List<SourceListened> sources;
}

/// 播放事件的结束原因（`play_events.endReason` 的持久化取值）。
enum PlayEventEndReason {
  /// 播到末尾（自然播完 / 单曲循环的每一遍）。
  completed('completed'),

  /// 未达末尾被切歌（手动或自动跳到别的曲目）。
  skipped('skipped'),

  /// 播放被停止 / 队列清空（未达末尾）。
  stopped('stopped'),

  /// 同一首从头重播（拖动进度回开头 / 重新点播）。
  restart('restart'),

  /// 进程被杀等外部中断，由启动时 `closeStaleEvents()` 收尾。
  interrupted('interrupted'),

  /// 播放错误终止。
  error('error');

  const PlayEventEndReason(this.storageValue);

  /// 持久化字符串。
  final String storageValue;

  /// 从持久化取值还原；非法值返回 null（损坏数据降级，不影响统计）。
  static PlayEventEndReason? fromStorage(Object? value) {
    for (final reason in values) {
      if (reason.storageValue == value) return reason;
    }
    return null;
  }
}

/// 播放事件（`play_events` 一行）。
class PlayEvent {
  final int id;
  final String sourceKey;
  final String songId;
  final String title;
  final String artist;
  final String album;
  final String? coverUrl;
  final int? durationMs;

  /// 取链参数（`Track.payload` 的持久化形态），供统计页点播旧曲目。
  final Map<String, dynamic> raw;

  final int startedAt;

  /// 收尾时间；null = 进行中（仍在播放或进程被杀遗留）。
  final int? endedAt;

  /// 实际收听时长（剔除 seek 跳变）。
  final int listenedMs;

  /// 本次播放到达的最大位置（完整播放判定的原始依据）。
  final int maxPositionMs;

  final PlayEventEndReason? endReason;

  const PlayEvent({
    required this.id,
    required this.sourceKey,
    required this.songId,
    required this.title,
    this.artist = '',
    this.album = '',
    this.coverUrl,
    this.durationMs,
    this.raw = const {},
    required this.startedAt,
    this.endedAt,
    this.listenedMs = 0,
    this.maxPositionMs = 0,
    this.endReason,
  });

  String get key => '$sourceKey:$songId';

  bool get isFinished => endedAt != null;

  @override
  String toString() =>
      'PlayEvent($key, $startedAt, ${endReason?.storageValue})';
}

/// 范围内汇总（error 事件不计入计数与比率，其数据只保留在原始事件里）。
class PlayStatisticsSummary {
  /// 非 error 的已收尾事件数。
  final int playCount;

  /// 有效播放次数（[PlayStatisticsLimits] 口径）。
  final int qualifiedPlayCount;

  /// 总收听时长（非 error 事件之和）。
  final int totalListenedMs;

  /// 去重曲目数（`sourceKey:songId`）。
  final int uniqueTrackCount;

  /// 完整播放率 = completed / playCount。
  final double completionRate;

  /// 跳过率 = skipped 且未达有效阈值 / playCount。
  final double skipRate;

  /// 全局首播时间（**不受范围过滤影响**，用于「数据起始日」）。
  final int? firstPlayedAt;

  const PlayStatisticsSummary({
    required this.playCount,
    required this.qualifiedPlayCount,
    required this.totalListenedMs,
    required this.uniqueTrackCount,
    required this.completionRate,
    required this.skipRate,
    this.firstPlayedAt,
  });

  static const PlayStatisticsSummary empty = PlayStatisticsSummary(
    playCount: 0,
    qualifiedPlayCount: 0,
    totalListenedMs: 0,
    uniqueTrackCount: 0,
    completionRate: 0,
    skipRate: 0,
  );
}

/// Top 曲目条目（按曲目聚合）。
class PlayStatTrackEntry {
  final String sourceKey;
  final String songId;
  final String title;
  final String artist;
  final String album;
  final String? coverUrl;
  final int? durationMs;

  /// 取链参数：统计页点播需要原样回传。
  final Map<String, dynamic> raw;

  /// 有效播放次数。
  final int playCount;

  /// 该曲目在此范围内的总收听时长。
  final int listenedMs;

  /// 最近一次播放开始时间。
  final int lastPlayedAt;

  const PlayStatTrackEntry({
    required this.sourceKey,
    required this.songId,
    required this.title,
    this.artist = '',
    this.album = '',
    this.coverUrl,
    this.durationMs,
    this.raw = const {},
    required this.playCount,
    required this.listenedMs,
    required this.lastPlayedAt,
  });

  String get key => '$sourceKey:$songId';
}

/// Top 歌手条目（artist 串已拆分；同一事件的多位歌手各计一次）。
class PlayStatArtistEntry {
  final String artist;
  final int playCount;
  final int listenedMs;

  const PlayStatArtistEntry({
    required this.artist,
    required this.playCount,
    required this.listenedMs,
  });
}

/// 单日收听聚合（`day` 为本地时区零点）。
class DayListened {
  final DateTime day;
  final int listenedMs;

  /// 有效播放次数。
  final int playCount;

  const DayListened({
    required this.day,
    required this.listenedMs,
    required this.playCount,
  });
}

/// 单小时（0-23，本地时区）收听聚合。
class HourListened {
  final int hour;
  final int listenedMs;

  /// 有效播放次数。
  final int playCount;

  const HourListened({
    required this.hour,
    required this.listenedMs,
    required this.playCount,
  });
}

/// 星期 × 时段聚合（作息热力图：`weekday` 0=周一，`hour` 0-23，本地时区）。
class WeekdayHourListened {
  final int weekday;
  final int hour;
  final int listenedMs;

  /// 有效播放次数。
  final int playCount;

  const WeekdayHourListened({
    required this.weekday,
    required this.hour,
    required this.listenedMs,
    required this.playCount,
  });
}

/// 来源分布条目（`sourceKey` 维度）。
class SourceListened {
  final String sourceKey;
  final int listenedMs;
  final int playCount;

  const SourceListened({
    required this.sourceKey,
    required this.listenedMs,
    required this.playCount,
  });
}

/// 某一天的播放明细（热力图点按弹层用）。
class DayPlayEvents {
  /// 本地时区零点。
  final DateTime day;
  final int listenedMs;

  /// 有效播放次数。
  final int playCount;

  /// 当天事件（startedAt 升序；不含 error）。
  final List<PlayEvent> events;

  const DayPlayEvents({
    required this.day,
    required this.listenedMs,
    required this.playCount,
    this.events = const [],
  });
}
