import 'package:logging/logging.dart';

import '../../sources/builtin/kw_lyric.dart';
import '../../sources/builtin/kw_search.dart';
import '../../sources/source_track.dart';
import 'lyric_provider.dart';

/// 酷我歌词提供者（对照 lx-music-mobile `kw` 音源）：
/// - 搜索复用内置 `kw` 搜索（与内置源同一实现）；
/// - 取词用 [KwLyric]（`mlyric` LRCX 解码 + H5 兜底），含逐字与翻译。
class KuwoProvider extends LyricProvider {
  final Logger _logger = Logger('molia.kuwo_provider');

  @override
  String get name => 'kuwo';

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
      final result = await KwSearch.searchWithMeta(keyword, limit: limit);
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
    );
  }

  @override
  Future<String?> fetchLyric(String songId) async =>
      (await fetchLyrics(songId))?.lyric;

  @override
  Future<LyricsPayload?> fetchLyrics(String songId) async {
    try {
      final info = await KwLyric.fetch(songId);
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
