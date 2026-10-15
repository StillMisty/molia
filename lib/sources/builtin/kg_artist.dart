import '../../domain/models/artist.dart';
import '../../domain/models/track.dart';
import '../raw_track.dart';
import '../source_search_result.dart';
import 'artist_source.dart';
import 'builtin_search.dart';
import 'builtin_transport.dart';
import 'crypto_utils.dart';
import 'kg_search.dart';

/// 酷狗音乐歌手（`mobiles.kugou.com`）。
///
/// - 搜索：`GET api/v3/search/singer?keyword=&page=&pagesize=&showtype=1`
///   （`data` 为数组、**无 total**；`pagesize` 被平台忽略，固定返回 10 条
///   → 单页，`hasMore=false`）；
/// - 详情：`GET api/v5/singer/info?singerid=`（名字 / 头像 / 简介 / 别名 / 计数）；
/// - 歌曲：`GET api/v5/singer/song?singerid=&page=&pagesize=`（`data.total` 分页；
///   条目字段与专辑歌曲接口同构，歌名歌手由 `filename` 拆分）。
///
/// 开发环境已抓到真实响应，见 test/fixtures/artists/kg_*.json。
class KgArtist {
  KgArtist._();

  /// 歌手搜索（平台固定一页，[page]/[limit] 仍按平台参数传入）。
  static Future<ArtistSearchPage> search(
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    final body = await lxHttpGet(
      'https://mobiles.kugou.com/api/v3/search/singer'
      '?keyword=${Uri.encodeComponent(keyword)}'
      '&page=$page&pagesize=$limit&showtype=1',
      retries: BuiltinTransport.defaultRetries,
      retryIf: _isInvalid,
    );
    return parseSearch(body);
  }

  /// 歌手搜索响应 → 结果页（供单测复用；平台无分页信息）。
  static ArtistSearchPage parseSearch(dynamic body) {
    if (body is! Map || body['data'] is! List) {
      throw artistPlatformFailure('kg', '歌手搜索响应非法');
    }
    final artists = <ArtistSummary>[];
    for (final raw in body['data'] as List) {
      if (raw is! Map) continue;
      final id = raw['singerid']?.toString() ?? '';
      final name = decodeName(raw['singername']?.toString());
      if (id.isEmpty || name.isEmpty) continue;
      // 搜索条目无头像（详情接口才有）；卡片回退名字首字占位。
      artists.add(ArtistSummary(id: id, name: name));
    }
    return ArtistSearchPage(items: artists);
  }

  /// 歌手详情 + 一页歌曲。
  ///
  /// 详情接口 best-effort：失败时退回入口携带的名字，不阻断歌曲列表。
  static Future<ArtistDetail> fetch(
    String artistId, {
    int page = 1,
    int limit = kArtistPageSize,
  }) async {
    final songs = await lxHttpGet(
      'http://mobiles.kugou.com/api/v5/singer/song'
      '?singerid=$artistId&page=$page&pagesize=$limit',
      retries: BuiltinTransport.defaultRetries,
      retryIf: _isInvalid,
    );
    dynamic info;
    try {
      info = await lxHttpGet(
        'http://mobiles.kugou.com/api/v5/singer/info?singerid=$artistId',
        retries: BuiltinTransport.defaultRetries,
        retryIf: _isInvalid,
      );
    } catch (_) {
      info = null;
    }
    return parse(
      info: info,
      songs: songs,
      artistId: artistId,
      page: page,
      limit: limit,
    );
  }

  /// 详情 + 歌曲响应 → 领域模型（供单测复用）。
  static ArtistDetail parse({
    required dynamic info,
    required dynamic songs,
    required String artistId,
    int page = 1,
    int limit = kArtistPageSize,
  }) {
    final data = (songs is Map) ? songs['data'] : null;
    final rawList = (data is Map) ? data['info'] : null;
    if (rawList is! List) {
      throw artistPlatformFailure('kg', '获取歌手歌曲失败（结构不符）');
    }

    final infoData =
        (info is Map && info['data'] is Map) ? info['data'] as Map : const {};
    final name = decodeName(infoData['singername']?.toString());
    final tracks = <Track>[];
    for (final raw in rawList) {
      final track = KgSearch.parseListSong(
        raw,
        albumName: decodeName((raw is Map ? raw['album_name'] : null)?.toString()),
        albumId: (raw is Map ? raw['album_id'] : null)?.toString() ?? '',
        fallbackArtist: name,
        // 歌手页曲目的歌手引用已知：id 即当前歌手。
        artists: name.isEmpty ? null : [SourceArtistRef(name: name, id: artistId)],
      );
      if (track != null) tracks.add(track);
    }

    final img = infoData['imgurl']?.toString() ?? '';
    final total = parseSourceCount(data is Map ? data['total'] : null);
    return ArtistDetail(
      id: artistId,
      name: name,
      avatarUrl: img.isEmpty ? null : img.replaceAll('{size}', '480'),
      description: _firstNonEmpty(
        decodeName(infoData['intro']?.toString()),
        decodeName(infoData['mix_intro']?.toString()),
      ),
      tracks: tracks,
      hasMore: total != null && total > 0 && page * limit < total,
    );
  }

  /// `mobiles.kugou.com` 业务码判定（`status=1` + `errcode=0` 为正常）。
  static bool _isInvalid(dynamic response) =>
      response is! Map || response['status'] != 1 || response['errcode'] != 0;

  static String _firstNonEmpty(String first, String second) =>
      first.isEmpty ? second : first;
}
