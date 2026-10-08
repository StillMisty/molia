import 'package:logger/logger.dart';

import '../../sources/builtin/wy_lyric.dart';
import '../../sources/builtin/wy_search.dart';
import 'lyric_provider.dart';

/// 网易云歌词提供者（公开接口，不依赖自建代理域名）：
/// - 搜索：复用内置 `wy` 搜索（eapi 协议，与内置源同一实现，已夹具验证）；
/// - 歌词：内置 [WyLyric]（eapi `/api/song/lyric/v1`，含 yrc 逐字歌词
///   → LRC/LX 逐字、翻译/罗马音时间轴对齐与时间标签修正）。
///
/// 说明：[WyLyric.fetch] 同时返回 tlyric / rlyric / lxlyric，但当前
/// [LyricProvider] / `LyricsResult` 只承载原文歌词（翻译/罗马音透传需要
/// 歌词模型与展示层支持，Wave 11a 暂不扩展）。
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

  /// 获取歌词（内置 eapi v1 实现）。
  @override
  Future<String?> fetchLyric(String songId) async {
    try {
      final info = await WyLyric.fetch(songId);
      return info.lyric.isEmpty ? null : info.lyric;
    } catch (e, st) {
      _logger.e('获取歌词失败', error: e, stackTrace: st);
      return null;
    }
  }
}
