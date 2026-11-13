import '../data/library_repository.dart';
import '../data/play_statistics_repository.dart';

/// 「最近听过」证据：给随机播放提供一份只读曲目 id 集合。
///
/// 播放层只接收 `Set<String>`，不认识统计 / 历史服务；这个模块由组合根创建，
/// 负责把两套本地数据收敛成同一种身份串（`sourceKey:songId`，与
/// `SourceTrack.id` / `TrackId.uri` 同源）。
///
/// 证据是设备本地、按需计算、失败静默：随机播放读不到历史时退回均匀洗牌，
/// 而不是抛错或阻止起播。
class PlaybackRecentTracks {
  PlaybackRecentTracks({
    required PlayStatisticsRepository statistics,
    required LibraryRepository history,
    required bool Function() statisticsEnabled,
    DateTime Function()? now,
  }) : // ignore: prefer_initializing_formals
       _statistics = statistics, // ignore: prefer_initializing_formals
       _history = history, // ignore: prefer_initializing_formals
       // ignore: prefer_initializing_formals
       _statisticsEnabled = statisticsEnabled,
       _now = now ?? DateTime.now;

  /// 最近窗口：7 天内听过的都算「最近」。
  static const Duration window = Duration(days: 7);

  /// 最近事件条数：与 7 天窗口取并集，谁更大用谁。
  static const int recentEventLimit = 50;

  final PlayStatisticsRepository _statistics;
  final LibraryRepository _history;
  final bool Function() _statisticsEnabled;
  final DateTime Function() _now;

  /// 当前「最近听过」的曲目 id 集合；失败返回空集合（调用方降级均匀洗牌）。
  Future<Set<String>> recentTrackIds() async {
    final since = _now().subtract(window).millisecondsSinceEpoch;
    if (_statisticsEnabled()) {
      try {
        return await _statistics.recentTrackKeys(
          since: since,
          limit: recentEventLimit,
        );
      } catch (_) {
        // 统计不可用：历史是同一个问题的另一种记录，继续走兜底。
      }
    }
    try {
      final entries = await _history.listHistory(
        limit: LibraryRepository.historyLimit,
      );
      return {
        for (final entry in entries)
          if (entry.playedAt >= since) entry.key,
        for (final entry in entries.take(recentEventLimit)) entry.key,
      };
    } catch (_) {
      return const {};
    }
  }
}
