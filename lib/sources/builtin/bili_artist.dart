/// B 站 UP 主页：用户搜索、UP 资料与投稿视频。
///
/// B 站没有「歌手」实体，UP 主就是曲目页里的 `_artists` 引用；这里把
/// 用户搜索 / 资料 / 投稿都映射成统一的 [ArtistSummary] / [ArtistDetail]，
/// 曲目一律经 `bili_track` 映射（与搜索 / 榜单 / 收藏夹同一份 raw 约定）。
///
/// 投稿接口（`/x/space/wbi/arc/search`）有风控：除 WBI 签名外还要求一组
/// `dm_*` 浏览器指纹参数；`-352` / `v_voucher` 时先刷新会话重试一次，仍失败
/// 才回退到全站视频搜索按 UP mid 过滤（搜索接口对匿名访问友好得多）。
library;

import '../../data/mapping/track_mapper.dart';
import '../../domain/models/artist.dart';
import '../../domain/models/failure.dart';
import '../../domain/models/track.dart';
import '../source_search_result.dart' show parseSourceCount;
import 'artist_source.dart';
import 'bili_api.dart';
import 'bili_track.dart';
import 'builtin_search.dart';

class BiliArtist {
  BiliArtist._();

  /// 用户搜索与搜索兜底都是固定 20 条/页；投稿接口用 30 条/页。
  static const int searchPageSize = 20;
  static const int spacePageSize = 30;
  static const int maxPage = 50;

  /// 投稿接口的风控指纹参数（B 站前端真实请求里的常量）。
  ///
  /// 缺任意一个都会让空间接口更容易返回 `-352`；值与浏览器版本无关，
  /// 平台只校验「像浏览器请求」，不需要跟真实版本同步。
  static const Map<String, String> _dmParams = {
    'dm_img_list': '[]',
    'dm_img_str': 'V2ViR0wgMS4wIChPcGVuR0wgRVMgMi4wIENocm9taXVtKQ',
    'dm_cover_img_str': 'QU5HTEUgKEludGVsLCBJbnRlbChSKSBVSEQgR3JhcGhpY3MgNjMw'
        'ICgweDAwMDAzRTlCKSBEaXJlY3QzRDExIHZzXzVfMCBwc181XzAsIEQzRDExKUdvb2ds'
        'ZSBJbmMuIChJbnRlbCk',
    'dm_img_inter': '{"ds":[],"wh":[0,0,0],"of":[0,0,0]}',
  };

  /// 用户搜索（搜索页「歌手」类型）。
  ///
  /// [limit] 只为适配器签名保留：平台固定 20 条/页，改不了本页条数。
  static Future<ArtistSearchPage> search(
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    final normalizedPage = page.clamp(1, maxPage);
    try {
      final response = await _getWbi(
        '/x/web-interface/wbi/search/type',
        {
          'search_type': 'bili_user',
          'keyword': keyword,
          'page': normalizedPage,
        },
      );
      return parseSearch(response, page: normalizedPage);
    } on SourceFailure {
      rethrow;
    } catch (e) {
      throw SourceFailure.from(e);
    }
  }

  /// 用户搜索响应 → 结果页（供单测复用）。
  static ArtistSearchPage parseSearch(
    dynamic response, {
    required int page,
  }) {
    final code = BiliApi.codeOf(response);
    if (code != 0) {
      throw BiliApi.failureForCode(
        code ?? -1,
        message: 'bili: 用户搜索失败（code=${code ?? '非 JSON'}）',
      );
    }
    final data = response is Map ? response['data'] : null;
    if (data is! Map) {
      throw artistPlatformFailure('bili', '用户搜索响应非法');
    }

    final items = <ArtistSummary>[];
    final rawList = data['result'];
    if (rawList is List) {
      for (final raw in rawList) {
        if (raw is! Map) continue;
        final id = _textOf(raw['mid']);
        final name = biliText(raw['uname']);
        if (id.isEmpty || name.isEmpty) continue;
        items.add(ArtistSummary(
          id: id,
          name: name,
          avatarUrl: biliCoverUrl(raw['upic']),
          songCount: parseSourceCount(raw['videos']),
        ));
      }
    }

    final total = parseSourceCount(data['numResults']);
    final pages = parseSourceCount(data['numPages']);
    // 没有 numPages 时按固定 20 条/页回退；两者都没有就当作末页，
    // 避免 hasMore 永远为真、列表反复请求空页。
    final hasMore = pages != null
        ? page < pages
        : (total != null &&
            total > searchPageSize &&
            page * searchPageSize < total);
    return ArtistSearchPage(items: items, total: total, hasMore: hasMore);
  }

  /// UP 资料 + 一页投稿视频。
  ///
  /// 资料接口（`card`）失败时回退 `space/wbi/acc/info`；投稿接口失败时回退
  /// 全站视频搜索。两条回退都失败（或搜索无结果）时仍返回资料页 + 空列表，
  /// 不让「这个 UP 暂时被风控」表现成整页打不开。
  static Future<ArtistDetail> fetch(
    String artistId, {
    int page = 1,
    int limit = kArtistPageSize,
  }) async {
    final mid = artistId.trim();
    if (mid.isEmpty) {
      throw artistPlatformFailure('bili', '缺少 UP mid');
    }
    final normalizedPage = page.clamp(1, maxPage);
    final profile = await _fetchProfile(mid);
    final content = await _fetchVideos(mid, normalizedPage, profile.name);
    return ArtistDetail(
      id: mid,
      name: profile.name,
      avatarUrl: profile.avatarUrl,
      description: profile.sign,
      tracks: content.tracks,
      hasMore: content.hasMore,
    );
  }

  /// 资料：`card`（免 WBI）→ `space/wbi/acc/info`（WBI）兜底。
  static Future<({String name, String? avatarUrl, String sign})> _fetchProfile(
    String mid,
  ) async {
    SourceFailure? failure;
    try {
      final session = await BiliApi.session();
      final uri = Uri.parse('${BiliApi.baseUrl}/x/web-interface/card')
          .replace(queryParameters: {'mid': mid});
      final response = await BuiltinSearch.transport.getJson(
        uri.toString(),
        headers: session.apiHeaders,
      );
      final card = _mapOf(response);
      if (card != null && BiliApi.codeOf(response) == 0) {
        final info = card['card'];
        final profile = _profileOf(info);
        if (profile != null) return profile;
      }
      failure = artistPlatformFailure('bili', 'UP 资料不存在');
    } on SourceFailure catch (e) {
      failure = e;
    } catch (e) {
      failure = SourceFailure.from(e);
    }

    try {
      final response = await _getWbi(
        '/x/space/wbi/acc/info',
        {'mid': mid},
      );
      if (BiliApi.codeOf(response) == 0) {
        final profile = _profileOf(_mapOf(response));
        if (profile != null) return profile;
      }
      failure = artistPlatformFailure('bili', 'UP 资料不存在');
    } on SourceFailure catch (e) {
      failure = e;
    } catch (e) {
      failure = SourceFailure.from(e);
    }
    throw failure;
  }

  static ({String name, String? avatarUrl, String sign})? _profileOf(
    dynamic raw,
  ) {
    if (raw is! Map) return null;
    final name = biliText(raw['name']);
    if (name.isEmpty) return null;
    return (
      name: name,
      avatarUrl: biliCoverUrl(raw['face']),
      sign: biliText(raw['sign']),
    );
  }

  /// 投稿：空间接口优先，风控 / 结构异常时回退全站视频搜索。
  static Future<({List<Track> tracks, bool hasMore})> _fetchVideos(
    String mid,
    int page,
    String name,
  ) async {
    try {
      final response = await _getWbi(
        '/x/space/wbi/arc/search',
        {
          'mid': mid,
          'pn': page,
          'ps': spacePageSize,
          'order': 'pubdate',
          ..._dmParams,
        },
      );
      final parsed = _parseSpace(response, page: page);
      if (parsed != null) return parsed;
    } catch (_) {
      // 网络 / 签名失败也走搜索兜底：UP 页至少还能看到公开投稿。
    }
    return _searchVideos(mid, page, name);
  }

  /// 空间投稿响应 → 曲目 + 分页；结构不符返回 null（触发搜索兜底）。
  static ({List<Track> tracks, bool hasMore})? _parseSpace(
    dynamic response, {
    required int page,
  }) {
    if (BiliApi.codeOf(response) != 0) return null;
    final data = _mapOf(response);
    final list = data?['list'];
    final vlist = list is Map ? list['vlist'] : null;
    if (vlist is! List) return null;

    final tracks = <Track>[];
    for (final item in vlist) {
      if (item is! Map) continue;
      final track = biliTrackFromItem(item);
      if (track != null) tracks.add(trackFromSourceTrack(track));
    }

    final pageMap = data?['page'];
    final total = pageMap is Map ? parseSourceCount(pageMap['count']) : null;
    // 有投稿总数却给空 vlist 不是「这个 UP 没有投稿」，而是空间接口的风控 /
    // 降级响应（code 仍是 0）；交给搜索兜底，避免把空页当成真实结果。
    if (vlist.isEmpty && (total ?? 0) > 0) return null;
    final bool hasMore;
    if (total != null) {
      hasMore = page * spacePageSize < total;
    } else {
      // 没有总数时按「本页是否满页」推断；空页必然是末页。
      hasMore = vlist.length >= spacePageSize;
    }
    return (tracks: tracks, hasMore: hasMore);
  }

  /// 搜索兜底：按 UP 名搜视频，再按 mid（或同名作者）过滤。
  static Future<({List<Track> tracks, bool hasMore})> _searchVideos(
    String mid,
    int page,
    String name,
  ) async {
    try {
      final response = await _getWbi(
        '/x/web-interface/wbi/search/type',
        {
          'search_type': 'video',
          'keyword': name,
          // 不能用 pubdate：按发布时间搜「UP 名」常常一条该 UP 的投稿都不
          // 返回（实测 0 命中），totalrank 才会把该 UP 的代表作排在前面。
          'order': 'totalrank',
          'page': page,
        },
      );
      if (BiliApi.codeOf(response) != 0) {
        return (tracks: const <Track>[], hasMore: false);
      }
      final data = _mapOf(response);
      final result = data?['result'];
      if (result is! List) {
        return (tracks: const <Track>[], hasMore: false);
      }

      final tracks = <Track>[];
      for (final item in result) {
        if (item is! Map) continue;
        final itemMid = _textOf(item['mid']);
        // 老条目可能没有 mid：同名作者是唯一可用的身份线索。
        final matches = itemMid.isNotEmpty
            ? itemMid == mid
            : biliText(item['author']) == name;
        if (!matches) continue;
        final track = biliTrackFromItem(item);
        if (track != null) tracks.add(trackFromSourceTrack(track));
      }
      final pages = parseSourceCount(data?['numPages']);
      return (
        tracks: tracks,
        hasMore: tracks.isNotEmpty && pages != null && page < pages,
      );
    } catch (_) {
      // 回退也失败：返回空列表，UP 资料本身仍然可用。
      return (tracks: const <Track>[], hasMore: false);
    }
  }

  /// 带 WBI 签名的 GET；风控时刷新会话重试一次（与搜索 / 取链同一语义）。
  static Future<dynamic> _getWbi(
    String path,
    Map<String, Object?> params,
  ) async {
    var session = await BiliApi.session();
    final url = session.signUrl('${BiliApi.baseUrl}$path', params);
    var response = await BuiltinSearch.transport.getJson(
      url,
      headers: session.apiHeaders,
    );
    if (!_needsRefresh(response)) return response;

    session = await BiliApi.refresh();
    response = await BuiltinSearch.transport.getJson(
      session.signUrl('${BiliApi.baseUrl}$path', params),
      headers: session.apiHeaders,
    );
    return response;
  }

  /// 风控判定：`-403/-412/-352` 或空间接口的 `v_voucher` 挑战。
  static bool _needsRefresh(dynamic response) {
    final code = BiliApi.codeOf(response);
    if (BiliApi.isRiskControl(code) || code == -352) return true;
    final data = response is Map ? response['data'] : null;
    return data is Map && data['v_voucher'] != null;
  }

  static Map? _mapOf(dynamic response) {
    final data = response is Map ? response['data'] : null;
    return data is Map ? data : null;
  }

  static String _textOf(Object? value) => value?.toString().trim() ?? '';
}
