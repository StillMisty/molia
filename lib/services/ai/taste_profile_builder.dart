/// 听歌画像构建：把统计仓库与资料库的数据整理成 LLM 提示词输入。
///
/// 上行内容按 [AiPreferences.sections] 裁剪：聚合指标 + Top 艺人与曲目 +
/// 时段/来源分布 + 最近事件明细 + 已听排除清单，可选收藏歌曲与自建歌单。
/// **不含 raw payload、封面、播放链接、设备信息**；数量上限集中在这里
/// （token 预算），资料库读取失败降级为空、不阻塞生成。
///
/// 已听清单拆成两个上限：本地去重仍读 [exclusionLookupLimit] 首，提示词只
/// 发送最近 [exclusionPromptLimit] 首。本地过滤保证不会重复推荐，发送清单
/// 只用于让模型主动避开高频重复。
library;

import 'package:logging/logging.dart';

import '../../data/play_statistics_repository.dart';
import '../../domain/models/ai_dj.dart';
import '../../domain/models/library.dart';
import '../../domain/models/play_statistics.dart';
import '../../domain/ports/library_store.dart';
import 'ai_text.dart';

/// 提示词输入快照。
class TasteProfile {
  final PlayStatisticsSummary summary;
  final List<PlayStatTrackEntry> topTracks;
  final List<PlayStatArtistEntry> topArtists;
  final List<WeekdayHourListened> byWeekdayHour;
  final List<SourceListened> sources;
  final List<PlayEvent> recentEvents;

  /// 收藏歌曲的名称与歌手（仅勾选收藏时读取；上限 [favoritesLimit]）。
  final List<({String title, String artist})> favorites;

  /// 自建歌单名 + 曲目名称与歌手（仅勾选自建歌单时读取）。
  final List<
      ({
        String name,
        List<({String title, String artist})> tracks,
      })> playlists;

  /// 发送给 LLM 的已听清单（`title - artist`，最多 [TasteProfileBuilder.exclusionPromptLimit]）。
  final List<String> exclusionLabels;

  /// 本地去重键（最多 [TasteProfileBuilder.exclusionLookupLimit]，不受发送上限影响）。
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
    this.favorites = const [],
    this.playlists = const [],
  });
}

class TasteProfileBuilder {
  TasteProfileBuilder({
    required PlayStatisticsRepository repository,
    LibraryStore? libraryStore,
  })  : _repository = repository,
        _libraryStore = libraryStore;

  final PlayStatisticsRepository _repository;
  final LibraryStore? _libraryStore;
  final Logger _logger = Logger('molia.ai_taste_profile');

  /// token 预算上限（上行「聚合 + 明细」各段的数量约束）。
  static const int topArtistsLimit = 50;
  static const int topTracksLimit = 50;

  /// 最近播放明细只发 50 条：Top 榜单与排除清单已覆盖长期/重复口味。
  static const int recentEventLimit = 50;

  /// 本地去重读取上限（不随提示词裁剪）。
  static const int exclusionLookupLimit = 500;

  /// 提示词里发送的已听清单上限。
  static const int exclusionPromptLimit = 100;

  /// 收藏歌曲上限。
  static const int favoritesLimit = 100;

  /// 自建歌单上限 / 每单曲目上限 / 歌单曲目总上限。
  static const int playlistLimit = 10;
  static const int playlistTrackLimit = 20;
  static const int playlistTotalTrackLimit = 100;

  Future<TasteProfile> build({
    AiPreferences preferences = AiPreferences.defaults,
  }) async {
    final sections = preferences.sections;
    final includeSummary = sections.contains(AiUpstreamSection.summary);
    final includeTopTracks = sections.contains(AiUpstreamSection.topTracks);
    final includeTopArtists = sections.contains(AiUpstreamSection.topArtists);
    final includeTimeAndSource =
        sections.contains(AiUpstreamSection.timeAndSource);
    final includeRecent = sections.contains(AiUpstreamSection.recentEvents);
    final includeExclusions =
        sections.contains(AiUpstreamSection.listenedExclusions);

    final results = await Future.wait<Object>([
      if (includeSummary) _repository.summary(),
      if (includeTopTracks) _repository.topTracks(limit: topTracksLimit),
      if (includeTopArtists) _repository.topArtists(limit: topArtistsLimit),
      if (includeTimeAndSource) _repository.listenedByWeekdayHour(),
      if (includeTimeAndSource) _repository.sourceDistribution(),
      if (includeRecent)
        _repository.listEventsForExport(limit: recentEventLimit),
      if (preferences.onlyUnheard || includeExclusions)
        _repository.listPlayedTrackNames(limit: exclusionLookupLimit),
    ]);
    var cursor = 0;
    PlayStatisticsSummary summary = PlayStatisticsSummary.empty;
    if (includeSummary) {
      summary = results[cursor++] as PlayStatisticsSummary;
    }
    List<PlayStatTrackEntry> topTracks = const [];
    if (includeTopTracks) {
      topTracks = results[cursor++] as List<PlayStatTrackEntry>;
    }
    List<PlayStatArtistEntry> topArtists = const [];
    if (includeTopArtists) {
      topArtists = results[cursor++] as List<PlayStatArtistEntry>;
    }
    List<WeekdayHourListened> byWeekdayHour = const [];
    if (includeTimeAndSource) {
      byWeekdayHour = results[cursor++] as List<WeekdayHourListened>;
    }
    List<SourceListened> sources = const [];
    if (includeTimeAndSource) {
      sources = results[cursor++] as List<SourceListened>;
    }
    List<PlayEvent> recentEvents = const [];
    if (includeRecent) {
      recentEvents = results[cursor++] as List<PlayEvent>;
    }
    List<({String title, String artist})> played = const [];
    if (preferences.onlyUnheard || includeExclusions) {
      played = results[cursor++] as List<({String title, String artist})>;
    }

    final labels = <String>[];
    final keys = <String>{};
    void addExclusion(
      String title,
      String artist, {
      bool excludeLocally = true,
    }) {
      final key = aiTrackKey(title, artist);
      if (key == '|' || key.isEmpty) return;
      if (excludeLocally) keys.add(key);
      if (labels.length >= exclusionPromptLimit) return;
      final label = artist.isEmpty ? title : '$title - $artist';
      if (!labels.contains(label)) labels.add(label);
    }

    // 勾选「已听歌曲排除清单」就发送清单；是否在本地强制过滤由
    // 「只推荐没听过的」单独决定（两个开关语义独立）。
    if (includeExclusions || preferences.onlyUnheard) {
      for (final entry in played) {
        addExclusion(
          entry.title,
          entry.artist,
          excludeLocally: preferences.onlyUnheard,
        );
      }
    }

    final favorites = <({String title, String artist})>[];
    final playlists = <({
      String name,
      List<({String title, String artist})> tracks,
    })>[];
    if (_libraryStore != null) {
      if (sections.contains(AiUpstreamSection.favorites)) {
        favorites.addAll(await _readFavorites());
        for (final entry in favorites) {
          addExclusion(entry.title, entry.artist);
        }
      }
      if (sections.contains(AiUpstreamSection.playlists)) {
        playlists.addAll(await _readPlaylists());
        for (final playlist in playlists) {
          for (final entry in playlist.tracks) {
            addExclusion(entry.title, entry.artist);
          }
        }
      }
    }

    return TasteProfile(
      summary: summary,
      topTracks: topTracks,
      topArtists: topArtists,
      byWeekdayHour: byWeekdayHour,
      sources: sources,
      recentEvents: recentEvents,
      exclusionLabels: labels,
      exclusionKeys: keys,
      favorites: favorites,
      playlists: playlists,
    );
  }

  Future<List<({String title, String artist})>> _readFavorites() async {
    final store = _libraryStore;
    if (store == null) return const [];
    try {
      final playlists = await store.listPlaylists();
      PlaylistInfo? favorites;
      for (final playlist in playlists) {
        if (playlist.isFavorites) {
          favorites = playlist;
          break;
        }
      }
      if (favorites == null) return const [];
      // 上限下推到存储层，避免为了 100 首把整张收藏表读进内存。
      final tracks = await store.listPlaylistTracks(
        favorites.id,
        limit: favoritesLimit,
      );
      return [
        for (final track in tracks) (title: track.title, artist: track.artist),
      ];
    } catch (e) {
      _logger.warning('AI 推歌：读取收藏失败，按空处理 $e');
      return const [];
    }
  }

  Future<
      List<
          ({
            String name,
            List<({String title, String artist})> tracks,
          })>> _readPlaylists() async {
    final store = _libraryStore;
    if (store == null) return const [];
    final List<PlaylistInfo> custom;
    try {
      final all = await store.listPlaylists();
      custom = [
        for (final playlist in all)
          if (!playlist.isFavorites) playlist,
      ].take(playlistLimit).toList();
    } catch (e) {
      _logger.warning('AI 推歌：读取自建歌单失败，按空处理 $e');
      return const [];
    }
    // 歌单之间互不依赖：并发读取，每个只取前 [playlistTrackLimit] 首；
    // 单个歌单失败只丢这一段（_readPlaylistTracks 内部降级），不拖垮整份画像。
    final tracksByPlaylist = await Future.wait([
      for (final playlist in custom) _readPlaylistTracks(store, playlist),
    ]);
    final result = <({
      String name,
      List<({String title, String artist})> tracks,
    })>[];
    var total = 0;
    for (var i = 0; i < custom.length; i++) {
      if (total >= playlistTotalTrackLimit) break;
      final room = playlistTotalTrackLimit - total;
      final limit = playlistTrackLimit < room ? playlistTrackLimit : room;
      final entries = [
        for (final track in tracksByPlaylist[i].take(limit))
          (title: track.title, artist: track.artist),
      ];
      if (entries.isEmpty) continue;
      total += entries.length;
      result.add((name: custom[i].name, tracks: entries));
    }
    return result;
  }

  Future<List<PlaylistTrack>> _readPlaylistTracks(
    LibraryStore store,
    PlaylistInfo playlist,
  ) async {
    try {
      return await store.listPlaylistTracks(
        playlist.id,
        limit: playlistTrackLimit,
      );
    } catch (e) {
      _logger.warning('AI 推歌：读取歌单「${playlist.name}」失败，按空处理 $e');
      return const [];
    }
  }
}
