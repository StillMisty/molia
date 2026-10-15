import '../source_search_result.dart';
import 'builtin_search.dart';
import 'builtin_transport.dart';
import 'crypto_utils.dart';
import 'kg_search.dart';
import 'lyric_search.dart';

/// 酷狗音乐「按歌词搜歌」（`songsearch.kugou.com/lyric_search`）。
///
/// 条目字段与单曲搜索**不完全同构**：音质在 `FileHash` / `320Hash` / `SQHash`
/// 与 `Res`（无损 24bit），歌名歌手在 `SongName` / `SingerName`（无专辑名），
/// 封面 `Image` 带 `{size}` 占位，命中的歌词段落是 `Lyric`。
///
/// 开发环境已抓到真实响应，见 test/fixtures/lyric_search/kg.json。
class KgLyricSearch {
  KgLyricSearch._();

  static Future<LyricSearchPage> search(
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    final body = await lxHttpGet(
      'https://songsearch.kugou.com/lyric_search'
      '?keyword=${Uri.encodeComponent(keyword)}&page=$page&pagesize=$limit',
      retries: BuiltinTransport.defaultRetries,
    );
    return parseSearch(body, page: page, limit: limit);
  }

  /// 歌词搜索响应 → 结果页（供单测复用）。
  static LyricSearchPage parseSearch(
    dynamic body, {
    required int page,
    required int limit,
  }) {
    final data = (body is Map) ? body['data'] : null;
    final rawList = (data is Map) ? data['lists'] : null;
    if (rawList is! List) {
      throw builtinPlatformFailure('kg', '歌词搜索响应非法');
    }
    final hits = <SourceLyricHit>[];
    for (final raw in rawList) {
      final hit = parseItem(raw);
      if (hit != null) hits.add(hit);
    }
    final total = parseSourceCount(data is Map ? data['total'] : null);
    return LyricSearchPage(
      hits: hits,
      total: total,
      hasMore: total != null && total > 0 && page * limit < total,
    );
  }

  /// 歌词搜索条目 → 命中项（供单测复用）。
  static SourceLyricHit? parseItem(dynamic raw) {
    if (raw is! Map) return null;
    final songId = raw['MixSongID']?.toString() ?? '';
    final hash = raw['FileHash']?.toString() ?? '';
    if (songId.isEmpty || hash.isEmpty) return null;

    final types = <String, Map<String, dynamic>>{};
    KgSearch.addKgQuality(types, '128k',
        size: raw['FileSize'], hash: hash, requireHash: true);
    KgSearch.addKgQuality(types, '320k',
        size: raw['320Size'], hash: raw['320Hash'], requireHash: true);
    KgSearch.addKgQuality(types, 'flac',
        size: raw['SQSize'], hash: raw['SQHash'], requireHash: true);
    final res = raw['Res'];
    if (res is Map) {
      KgSearch.addKgQuality(types, 'flac24bit',
          size: res['FileSize'], hash: res['Hash'], requireHash: true);
    }

    final duration = parseSourceCount(raw['TimeLength']) ?? 0;
    final image = raw['Image']?.toString() ?? '';
    final track = KgSearch.buildTrack(
      songId: songId,
      name: decodeName(raw['SongName']?.toString()),
      artist: decodeName(raw['SingerName']?.toString()),
      artists: KgSearch.artistRefsOf(raw['Singers']),
      // 歌词搜索响应不含专辑名（只有 id）；专辑行据此隐藏。
      album: '',
      albumId: raw['AlbumID']?.toString() ?? '',
      hash: hash,
      intervalText: duration > 0 ? formatPlayTime(duration) : null,
      duration: duration > 0 ? Duration(seconds: duration) : null,
      types: types,
      rawInterval: duration,
      img: image.isEmpty ? null : image.replaceAll('{size}', '480'),
    );
    return SourceLyricHit(
      track: track,
      snippet: _normalize(raw['Lyric']?.toString()),
    );
  }

  static String? _normalize(String? text) {
    final decoded =
        decodeName(text).replaceAll(RegExp(r'\s+'), ' ').trim();
    return decoded.isEmpty ? null : decoded;
  }
}
