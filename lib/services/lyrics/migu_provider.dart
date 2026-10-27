import 'package:logging/logging.dart';

import '../../sources/builtin/mg_lyric.dart';
import '../../sources/builtin/mg_search.dart';
import '../../sources/source_track.dart';
import 'lyric_provider.dart';

/// 咪咕歌词提供者（对照 lx-music-mobile `mg` 音源）：
/// - 搜索复用内置 `mg` 搜索（与内置源同一实现，响应带 mrc/lrc/trc URL）；
/// - 取词用 [MgLyric]（MRC 解密 + 逐字；缺 URL 时按 songId 走资源信息兜底）。
class MiguProvider extends LyricProvider {
  final Logger _logger = Logger('molia.migu_provider');

  @override
  String get name => 'migu';

  @override
  String get channelKey => 'mg';

  @override
  Future<SongMatch?> search(String title, String artist) async {
    final results = await searchMultiple(title, artist, limit: 1);
    return results.isNotEmpty ? results.first : null;
  }

  @override
  Future<List<SongMatch>> searchMultiple(String title, String artist,
      {int limit = 3}) async {
    try {
      final keyword = '$title $artist'.trim();
      final result = await MgSearch.searchWithMeta(keyword, limit: limit);
      return [
        for (final track in result.tracks.take(limit)) _toMatch(track),
      ];
    } catch (e, st) {
      _logger.severe('搜索失败', e, st);
      return [];
    }
  }

  static SongMatch _toMatch(SourceTrack track) {
    final raw = track.raw;
    return SongMatch(
      songId: raw['songmid']?.toString() ?? track.id,
      title: track.title,
      artist: track.artist,
      album: track.album,
      duration: track.duration,
      extra: {
        if (raw['mrcUrl'] != null) 'mrcUrl': raw['mrcUrl'],
        if (raw['lrcUrl'] != null) 'lrcUrl': raw['lrcUrl'],
        if (raw['trcUrl'] != null) 'trcUrl': raw['trcUrl'],
      },
    );
  }

  @override
  Future<String?> fetchLyric(String songId) async =>
      (await fetchLyrics(songId))?.lyric;

  @override
  Future<LyricsPayload?> fetchLyrics(String songId) async =>
      _fetch(songId: songId);

  @override
  Future<LyricsPayload?> fetchForMatch(SongMatch match) async => _fetch(
        songId: match.extra['songId']?.toString() ?? match.songId,
        mrcUrl: match.extra['mrcUrl']?.toString(),
        lrcUrl: match.extra['lrcUrl']?.toString(),
        trcUrl: match.extra['trcUrl']?.toString(),
      );

  Future<LyricsPayload?> _fetch({
    required String songId,
    String? mrcUrl,
    String? lrcUrl,
    String? trcUrl,
  }) async {
    try {
      final info = await MgLyric.fetch(
        songId: songId,
        mrcUrl: mrcUrl,
        lrcUrl: lrcUrl,
        trcUrl: trcUrl,
      );
      if (info == null || info.isEmpty) return null;
      return LyricsPayload(
        lyric: info.lyric,
        translation: info.tlyric,
        roma: info.rlyric,
        lxlyric: info.lxlyric,
      );
    } catch (e, st) {
      _logger.severe('取词失败', e, st);
      return null;
    }
  }
}
