import 'package:logging/logging.dart';

import '../../sources/builtin/kg_lyric.dart';
import '../../sources/builtin/kg_search.dart';
import '../../sources/source_track.dart';
import 'lyric_provider.dart';

/// 酷狗歌词提供者（对照 lx-music-mobile `kg` 音源）：
/// - 搜索复用内置 `kg` 搜索（与内置源同一实现，响应带 `hash`/时长）；
/// - 取词用 [KgLyric]（search + download + KRC 解码），含翻译 / 罗马音 / 逐字。
class KugouProvider extends LyricProvider {
  final Logger _logger = Logger('molia.kugou_provider');

  @override
  String get name => 'kugou';

  @override
  String get channelKey => 'kg';

  /// 搜索歌曲，返回首条匹配
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
      final result = await KgSearch.searchWithMeta(keyword, limit: limit);
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
        'hash': raw['hash']?.toString() ?? '',
        'name': raw['name']?.toString() ?? track.title,
        if (raw['_interval'] != null) '_interval': raw['_interval'],
      },
    );
  }

  /// 只有 songId（无 hash / 时长）时无法走酷狗歌词接口，返回 null。
  @override
  Future<String?> fetchLyric(String songId) async => null;

  @override
  Future<LyricsPayload?> fetchForMatch(SongMatch match) async {
    final hash = match.extra['hash']?.toString() ?? '';
    final name = match.extra['name']?.toString() ?? match.title;
    if (hash.isEmpty || name.isEmpty) return null;
    final seconds = _timelengthSeconds(match);
    try {
      final info = await KgLyric.fetch(
        name: name,
        hash: hash,
        timelengthSeconds: seconds,
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

  static int _timelengthSeconds(SongMatch match) {
    final raw = match.extra['_interval'];
    if (raw is num) return raw.toInt();
    final parsed = raw == null ? null : int.tryParse('$raw');
    if (parsed != null) return parsed;
    return match.duration?.inSeconds ?? 0;
  }
}
