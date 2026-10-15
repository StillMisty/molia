import '../source_search_result.dart';
import '../source_track.dart';
import 'builtin_search.dart';
import 'builtin_transport.dart';
import 'crypto_utils.dart';
import 'lyric_hit.dart';
import 'wy_music_detail.dart';

/// 网易云音乐「按歌词搜歌」（`api/search/get/web?type=1006`，免签名）。
///
/// 搜索响应是**旧版字段**（`artists` / `album` / `duration`）且不带音质，
/// 因此与歌手歌曲同一流程：取 song id → [WyMusicDetail.getList]
/// （`weapi/v3/song/detail`）补成规范 raw；命中片段来自高亮 `lyrics`
/// 数组（命中词带 `<b>`），取命中行起 3 行、去标签作为副标题。
///
/// 开发环境已抓到真实响应，见 test/fixtures/lyric_search/wy_*.json。
class WyLyricSearch {
  WyLyricSearch._();

  static const int _searchTypeLyric = 1006;

  static Future<LyricSearchPage> search(
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    final body = await lxHttpGet(
      'https://music.163.com/api/search/get/web'
      '?s=${Uri.encodeComponent(keyword)}'
      '&type=$_searchTypeLyric&offset=${(page - 1) * limit}&limit=$limit',
      headers: const {'Referer': 'https://music.163.com/'},
      retries: BuiltinTransport.defaultRetries,
    );
    final ids = idsOf(body);
    final tracks =
        ids.isEmpty ? const <SourceTrack>[] : await WyMusicDetail.getList(ids);
    return buildPage(
      body: body,
      tracks: tracks,
      page: page,
      limit: limit,
    );
  }

  /// 搜索响应里的曲目 id（用于二次补全规范 raw）；结构不符抛失败。
  static List<Object> idsOf(dynamic body) {
    final songs = _songsOf(body);
    final ids = <Object>[];
    for (final raw in songs) {
      if (raw is! Map) continue;
      final id = raw['id'];
      if (id != null) ids.add(id);
    }
    return ids;
  }

  /// 搜索响应 + 已补全的曲目 → 结果页（供单测复用；`search` 只负责发请求）。
  static LyricSearchPage buildPage({
    required dynamic body,
    required List<SourceTrack> tracks,
    required int page,
    required int limit,
  }) {
    final songs = _songsOf(body);
    final snippets = <String, String>{};
    for (final raw in songs) {
      if (raw is! Map) continue;
      final id = raw['id']?.toString() ?? '';
      final snippet = lyricSnippetOf(raw['lyrics']);
      if (id.isNotEmpty && snippet != null) snippets[id] = snippet;
    }
    final result = (body is Map) ? body['result'] : null;
    final total = parseSourceCount(result is Map ? result['songCount'] : null);
    return LyricSearchPage(
      hits: [
        for (final track in tracks)
          SourceLyricHit(
            track: track,
            snippet: snippets[track.raw['songmid']?.toString() ?? ''],
          ),
      ],
      total: total,
      hasMore: total != null && total > 0 && page * limit < total,
    );
  }

  /// 搜索结果列表（结构不符抛失败）。
  static List<dynamic> _songsOf(dynamic body) {
    final result = (body is Map) ? body['result'] : null;
    final songs = (result is Map) ? result['songs'] : null;
    if (songs is! List) {
      throw builtinPlatformFailure('wy', '歌词搜索响应非法');
    }
    return songs;
  }

  /// 高亮歌词（`lyrics` 数组，命中词带 `<b>`）→ 片段：命中行起 3 行、去标签。
  ///
  /// 找不到高亮行时退回首行；空数组 / 全空行为 null（UI 回退歌手名）。
  static String? lyricSnippetOf(dynamic lyrics) {
    if (lyrics is! List || lyrics.isEmpty) return null;
    final lines = [
      for (final line in lyrics) decodeName(line?.toString() ?? ''),
    ];
    var start = lines.indexWhere((line) => line.contains('<b>'));
    if (start < 0) {
      start = lines.indexWhere((line) => _stripTags(line).trim().isNotEmpty);
      if (start < 0) return null;
    }
    final parts = <String>[
      for (var index = start; index < lines.length && index < start + 3; index++)
        if (_stripTags(lines[index]).trim().isNotEmpty)
          _stripTags(lines[index]).trim(),
    ];
    final text = parts.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.isEmpty ? null : text;
  }

  static String _stripTags(String text) =>
      text.replaceAll(RegExp('<[^>]*>'), '');
}
