/// 听歌画像构建：把统计仓库的数据整理成 LLM 提示词输入。
///
/// 上行内容（已与项目 owner 拍板）：聚合指标 + Top 艺人与曲目 +
/// 时段/来源分布 + 最近事件明细 + 全量已听排除清单。
/// **不含 raw payload、不含设备信息**；数量上限集中在这里（token 预算）。
library;

import '../../data/play_statistics_repository.dart';
import '../../domain/models/play_statistics.dart';
import 'ai_text.dart';

/// 提示词输入快照。
class TasteProfile {
  final PlayStatisticsSummary summary;
  final List<PlayStatTrackEntry> topTracks;
  final List<PlayStatArtistEntry> topArtists;
  final List<WeekdayHourListened> byWeekdayHour;
  final List<SourceListened> sources;
  final List<PlayEvent> recentEvents;

  /// 已听排除清单（`title - artist` 原始标签，规范化去重、最近优先）。
  final List<String> exclusionLabels;

  /// 排除清单的规范化键（批内去重/跨批去重用）。
  final Set<String> exclusionKeys;

  const TasteProfile({
    required this.summary,
    required this.topTracks,
    required this.topArtists,
    required this.byWeekdayHour,
    required this.sources,
    required this.recentEvents,
    required this.exclusionLabels,
    required this.exclusionKeys,
  });
}

class TasteProfileBuilder {
  TasteProfileBuilder({required PlayStatisticsRepository repository})
      : _repository = repository;

  final PlayStatisticsRepository _repository;

  /// token 预算上限（与 issue #9 的「聚合 + 明细」约定一致）。
  static const int topArtistsLimit = 50;
  static const int topTracksLimit = 50;
  static const int recentEventLimit = 200;
  static const int exclusionLimit = 500;

  Future<TasteProfile> build() async {
    final results = await Future.wait([
      _repository.summary(),
      _repository.topTracks(limit: topTracksLimit),
      _repository.topArtists(limit: topArtistsLimit),
      _repository.listenedByWeekdayHour(),
      _repository.sourceDistribution(),
      _repository.listEventsForExport(limit: recentEventLimit),
      _repository.listPlayedTrackNames(),
    ]);
    final played = results[6] as List<({String title, String artist})>;

    final labels = <String>[];
    final keys = <String>{};
    for (final entry in played) {
      final key = aiTrackKey(entry.title, entry.artist);
      if (key == '|' || key.isEmpty) continue;
      if (!keys.add(key)) continue;
      labels.add(
        entry.artist.isEmpty ? entry.title : '${entry.title} - ${entry.artist}',
      );
      if (labels.length >= exclusionLimit) break;
    }

    return TasteProfile(
      summary: results[0] as PlayStatisticsSummary,
      topTracks: results[1] as List<PlayStatTrackEntry>,
      topArtists: results[2] as List<PlayStatArtistEntry>,
      byWeekdayHour: results[3] as List<WeekdayHourListened>,
      sources: results[4] as List<SourceListened>,
      recentEvents: results[5] as List<PlayEvent>,
      exclusionLabels: labels,
      exclusionKeys: keys,
    );
  }
}
