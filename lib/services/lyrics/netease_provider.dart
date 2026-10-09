import 'package:logger/logger.dart';

import '../../sources/builtin/wy_lyric.dart';
import '../../sources/builtin/wy_search.dart';
import 'lyric_provider.dart';

/// 网易云歌词提供者（公开接口，不依赖自建代理域名）：
/// - 搜索：复用内置 `wy` 搜索（eapi 协议，与内置源同一实现，已夹具验证）；
/// - 歌词：内置 [WyLyric]（eapi `/api/song/lyric/v1`，含 yrc 逐字歌词
///   → LRC/LX 逐字、翻译/罗马音时间轴对齐与时间标签修正）。
///
/// 说明：[WyLyric.fetch] 同时返回 tlyric / rlyric / lxlyric；原文与
/// 翻译 / 罗马音经 [fetchLyrics] 结构化透传（tlyric / rlyric 内部已完成
/// 时间轴对齐与时间标签修正）。
class NetEaseProvider extends LyricProvider {
  final Logger _logger = Logger();

  @override
  String get name => 'netease';

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
      final keyword = '$title $artist';
      final tracks = await WySearch.search(keyword, limit: limit);
      return [
        for (final track in tracks.take(limit))
          SongMatch(
            // 平台 song id（非 `wy:` 前缀的全局 id），供歌词接口使用。
            songId: track.raw['songmid']?.toString() ?? track.id,
            title: track.title,
            artist: track.artist,
          ),
      ];
    } catch (e, st) {
      _logger.e('搜索失败', error: e, stackTrace: st);
      return [];
    }
  }

  /// 获取歌词原文（内置 eapi v1 实现）。
  @override
  Future<String?> fetchLyric(String songId) async =>
      (await fetchLyrics(songId))?.lyric;

  /// 获取结构化歌词：原文 + 翻译（tlyric）+ 罗马音（rlyric）。
  @override
  Future<LyricsPayload?> fetchLyrics(String songId) async {
    try {
      final info = await WyLyric.fetch(songId);
      if (info.lyric.isEmpty) return null;
      return LyricsPayload(
        lyric: info.lyric,
        translation: info.tlyric.isEmpty ? null : info.tlyric,
        roma: info.rlyric.isEmpty ? null : info.rlyric,
      );
    } catch (e, st) {
      _logger.e('获取歌词失败', error: e, stackTrace: st);
      return null;
    }
  }
}
