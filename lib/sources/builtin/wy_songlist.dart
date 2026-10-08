import 'package:http/http.dart' as http;

import '../../data/cache/request_cache.dart';
import '../../domain/models/discover.dart';
import '../source_track.dart';
import 'builtin_search.dart';
import 'crypto_utils.dart';
import 'discover_fetch.dart';
import 'discover_track_mapper.dart';
import 'wy_music_detail.dart';

/// 网易云歌单（移植自 lx-music-mobile `wy/songList.js`）。
///
/// - 标签：`weapi/playlist/catalogue` + `weapi/playlist/hottags`；
/// - 标签歌单列表：`weapi/playlist/list`（cat/order/limit/offset）；
/// - 歌单详情：链接/ID 解析 → `api/linux/forward` 转发 v3 歌单详情，
///   trackIds 与 privileges 数量一致时直接解析，否则批量歌曲详情补齐；
/// - 歌单搜索：eapi `/api/cloudsearch/pc`（type=1000）。
///
/// 网络结果缓存 5 分钟（[RequestCache]）。
class WySongList {
  WySongList._();

  static const Duration cacheTtl = Duration(minutes: 5);
  static const int limitList = 30;
  static const int limitSong = 100000;

  /// 歌单详情接口需要的登录 cookie（LX 支持 `id###token` 形式追加 MUSIC_U）。
  static String _cookie = 'MUSIC_U=';

  static final RequestCache _tagsCache =
      RequestCache(maxEntries: 4, ttl: cacheTtl);
  static final RequestCache _listCache =
      RequestCache(maxEntries: 32, ttl: cacheTtl);
  static final RequestCache _detailCache =
      RequestCache(maxEntries: 16, ttl: cacheTtl);
  static final RequestCache _searchCache =
      RequestCache(maxEntries: 16, ttl: cacheTtl);

  static final RegExp _listDetailLink =
      RegExp(r'^.+(?:\?|&)id=(\d+)(?:&.*$|#.*$|$)');
  static final RegExp _listDetailLink2 = RegExp(r'^.+\/playlist\/(\d+)\/\d+\/.+$');

  /// 热门标签 + 完整标签目录（两个接口并行，结果缓存 5 分钟）。
  static Future<
      ({List<DiscoverTagCategory> tags, List<DiscoverTag> hotTag})> getTags() {
    return _tagsCache.getOrCreate('wy:playlist-tags', () async {
      final results = await Future.wait([getTag(), getHotTag()]);
      return (
        tags: results[0] as List<DiscoverTagCategory>,
        hotTag: results[1] as List<DiscoverTag>,
      );
    });
  }

  /// 标签目录（`weapi/playlist/catalogue`）。
  static Future<List<DiscoverTagCategory>> getTag() {
    return retryRequest(
      maxTries: 3,
      attempt: (_) async {
        final body = await lxHttpPost(
          'https://music.163.com/weapi/playlist/catalogue',
          form: true,
          body: weapiForm(const {}),
        );
        if (body is! Map || body['code'] != 200) return null;
        return filterTagInfo(
          sub: (body['sub'] as List?) ?? const [],
          categories: (body['categories'] as Map?) ?? const {},
        );
      },
    );
  }

  /// 解析标签目录响应（独立出来便于单元测试）。
  static List<DiscoverTagCategory> filterTagInfo({
    required List<dynamic> sub,
    required Map<dynamic, dynamic> categories,
  }) {
    final subList = <dynamic, List<DiscoverTag>>{};
    for (final item in sub) {
      if (item is! Map) continue;
      final category = item['category'];
      final name = (item['name'] ?? '').toString();
      (subList[category] ??= []).add(DiscoverTag(id: name, name: name));
    }
    final list = <DiscoverTagCategory>[];
    for (final key in categories.keys) {
      list.add(DiscoverTagCategory(
        name: (categories[key] ?? key).toString(),
        tags: subList[key] ?? const [],
      ));
    }
    return list;
  }

  /// 热门标签（`weapi/playlist/hottags`）。
  static Future<List<DiscoverTag>> getHotTag() {
    return retryRequest(
      maxTries: 3,
      attempt: (_) async {
        final body = await lxHttpPost(
          'https://music.163.com/weapi/playlist/hottags',
          form: true,
          body: weapiForm(const {}),
        );
        if (body is! Map || body['code'] != 200) return null;
        return filterHotTagInfo((body['tags'] as List?) ?? const []);
      },
    );
  }

  /// 解析热门标签响应（独立出来便于单元测试）。
  static List<DiscoverTag> filterHotTagInfo(List<dynamic> rawList) {
    final list = <DiscoverTag>[];
    for (final item in rawList) {
      if (item is! Map) continue;
      final tag = item['playlistTag'];
      final name = tag is Map ? (tag['name'] ?? '').toString() : '';
      if (name.isEmpty) continue;
      list.add(DiscoverTag(id: name, name: name));
    }
    return list;
  }

  /// 按标签取歌单列表（[sortId] 固定 `hot`，[tagId] 空表示全部）。
  static Future<DiscoverPlaylistPage> getList(
    String sortId,
    String tagId,
    int page,
  ) {
    final key = 'wy:playlists:$sortId:$tagId:$page';
    return _listCache.getOrCreate(
      key,
      () => _fetchList(sortId, tagId, page),
    );
  }

  static Future<DiscoverPlaylistPage> _fetchList(
    String sortId,
    String tagId,
    int page,
  ) {
    return retryRequest(
      maxTries: 3,
      attempt: (_) async {
        final body = await lxHttpPost(
          'https://music.163.com/weapi/playlist/list',
          form: true,
          body: weapiForm({
            'cat': tagId.isEmpty ? '全部' : tagId,
            'order': sortId,
            'limit': limitList,
            'offset': limitList * (page - 1),
            'total': true,
          }),
        );
        if (body is! Map || body['code'] != 200) return null;
        return DiscoverPlaylistPage(
          playlists: filterList((body['playlists'] as List?) ?? const []),
          total: int.tryParse('${body['total']}') ?? 0,
          page: page,
          limit: limitList,
        );
      },
    );
  }

  /// 解析歌单概要列表（独立出来便于单元测试）。
  static List<DiscoverPlaylist> filterList(List<dynamic> rawData) {
    final list = <DiscoverPlaylist>[];
    for (final item in rawData) {
      if (item is! Map) continue;
      final creator = item['creator'];
      final createTime = item['createTime'];
      final createMs = createTime is num ? createTime.toInt() : null;
      list.add(DiscoverPlaylist(
        id: '${item['id']}',
        name: (item['name'] ?? '').toString(),
        coverUrl: _nonEmpty(item['coverImgUrl']),
        author: creator is Map ? (creator['nickname'] ?? '').toString() : '',
        playCount:
            item['playCount'] is num ? (item['playCount'] as num).toInt() : 0,
        trackCount:
            item['trackCount'] is num ? (item['trackCount'] as num).toInt() : 0,
        description: _nonEmpty(item['description']),
        createdAt: createMs == null ? null : _formatDateYMD(createMs),
      ));
    }
    return list;
  }

  /// 歌单详情（支持链接 / ID / `id###token`；结果缓存 5 分钟）。
  static Future<DiscoverDetail> getListDetail(String rawId, int page) {
    final key = 'wy:playlist-detail:$rawId:$page';
    return _detailCache.getOrCreate(
      key,
      () => _fetchListDetail(rawId, page),
    );
  }

  static Future<DiscoverDetail> _fetchListDetail(
    String rawId,
    int page,
  ) async {
    final parsed = await parseListId(rawId);
    if (parsed.cookie != null) _cookie = parsed.cookie!;

    return retryRequest(
      maxTries: 3,
      attempt: (_) async {
        dynamic body;
        try {
          body = await lxHttpPost(
            'https://music.163.com/api/linux/forward',
            form: true,
            headers: {'Cookie': _cookie},
            body: {
              'eparams': linuxapiParams({
                'method': 'POST',
                'url': 'https://music.163.com/api/v3/playlist/detail',
                'params': {'id': parsed.id, 'n': limitSong, 's': 8},
              }),
            },
          );
        } catch (_) {
          return null;
        }
        if (body is! Map || body['code'] != 200) return null;

        final playlist = body['playlist'];
        if (playlist is! Map) return null;
        final trackIds = (playlist['trackIds'] as List?) ?? const [];
        final privileges = body['privileges'];

        // 与 LX 一致：privileges 与 trackIds 数量一致时直接用响应内 tracks。
        const limit = 1000;
        final rangeStart = (page - 1) * limit;
        List<SourceTrack> tracks;
        if (privileges is List && trackIds.length == privileges.length) {
          tracks = filterListDetail(
            tracks: (playlist['tracks'] as List?) ?? const [],
            privileges: privileges,
          );
        } else {
          final ids = <Object>[
            for (final trackId in trackIds.skip(rangeStart).take(limit))
              if (trackId is Map && trackId['id'] != null) trackId['id'],
          ];
          try {
            tracks = await WyMusicDetail.getList(ids);
          } catch (e) {
            if (e is StateError && e.message == 'try max num') rethrow;
            return null;
          }
        }

        final creator = playlist['creator'];
        final playCount = playlist['playCount'];
        return DiscoverDetail(
          info: DiscoverPlaylist(
            id: parsed.id,
            name: (playlist['name'] ?? '').toString(),
            coverUrl: _nonEmpty(playlist['coverImgUrl']),
            author:
                creator is Map ? (creator['nickname'] ?? '').toString() : '',
            playCount: playCount is num ? playCount.toInt() : 0,
            trackCount: trackIds.length,
            description: _nonEmpty(playlist['description']),
          ),
          tracks: tracks.map(discoverTrackOf).toList(),
        );
      },
    );
  }

  /// 解析歌单详情响应中的曲目（移植自 LX `filterListDetail`）。
  ///
  /// 与 [WyMusicDetail.filterList] 的差异（保持 LX 原样）：
  /// - flac 不取 `sq.size`（固定 null）；
  /// - 歌手名做 HTML 实体解码后拼接。
  static List<SourceTrack> filterListDetail({
    required List<dynamic> tracks,
    required List<dynamic> privileges,
  }) {
    final list = <SourceTrack>[];
    for (var index = 0; index < tracks.length; index++) {
      final item = tracks[index];
      if (item is! Map) continue;

      Map<dynamic, dynamic>? privilege =
          index < privileges.length && privileges[index] is Map
              ? privileges[index] as Map
              : null;
      if (privilege == null || privilege['id'] != item['id']) {
        privilege = privileges.whereType<Map>().firstWhere(
              (p) => p['id'] == item['id'],
              orElse: () => const {},
            );
        if (privilege.isEmpty) continue;
      }

      final typeMap = WyMusicDetail.buildTypes(
        privilege: privilege,
        song: item,
        // LX 此处 flac 固定 size=null。
        flacSize: null,
      );
      final reversedTypes = WyMusicDetail.typeList(typeMap);

      final album = item['al'];
      final albumId = album is Map ? album['id'] : null;
      final img = album is Map ? (album['picUrl'] ?? '') : '';
      final dt = item['dt'];
      final durationMs = dt is num ? dt.toInt() : int.tryParse('$dt') ?? 0;

      final String singer;
      final String name;
      final String albumName;
      final pc = item['pc'];
      if (pc is Map) {
        singer = (pc['ar'] ?? '').toString();
        name = (pc['sn'] ?? '').toString();
        albumName = (pc['alb'] ?? '').toString();
      } else {
        singer = _formatSingerName(item['ar']);
        name = (item['name'] ?? '').toString();
        albumName = album is Map ? (album['name'] ?? '').toString() : '';
      }

      list.add(WyMusicDetail.buildTrack(
        songId: item['id'],
        name: name,
        singer: singer,
        albumName: albumName,
        albumId: albumId,
        img: img,
        intervalText: formatPlayTime(durationMs / 1000),
        duration: durationMs > 0 ? Duration(milliseconds: durationMs) : null,
        types: reversedTypes,
        typeMap: typeMap,
      ));
    }
    return list;
  }

  /// 歌单搜索（eapi `/api/cloudsearch/pc`，type=1000）。
  static Future<DiscoverPlaylistPage> search(
    String text,
    int page, {
    int limit = 20,
  }) {
    final key = 'wy:playlist-search:$text:$page:$limit';
    return _searchCache.getOrCreate(
      key,
      () => _fetchSearch(text, page, limit),
    );
  }

  static Future<DiscoverPlaylistPage> _fetchSearch(
    String text,
    int page,
    int limit,
  ) {
    return retryRequest(
      maxTries: 3,
      attempt: (_) async {
        final body = await lxHttpPost(
          'http://interface.music.163.com/eapi/batch',
          form: true,
          headers: {'origin': 'https://music.163.com'},
          body: {
            'params': eapiParams('/api/cloudsearch/pc', {
              's': text,
              'type': 1000,
              'limit': limit,
              'total': page == 1,
              'offset': limit * (page - 1),
            }),
          },
        );
        if (body is! Map || body['code'] != 200) return null;
        final result = body['result'];
        final playlists = (result is Map ? result['playlists'] : null);
        return DiscoverPlaylistPage(
          playlists: filterList(playlists is List ? playlists : const []),
          total: result is Map
              ? int.tryParse('${result['playlistCount']}') ?? 0
              : 0,
          page: page,
          limit: limit,
        );
      },
    );
  }

  /// 解析歌单链接 / ID：`id`、完整链接、`id###MUSIC_U token`。
  static Future<({String id, String? cookie})> parseListId(String rawId) async {
    var id = rawId;
    String? cookie;
    if (id.contains('###')) {
      final parts = id.split('###');
      id = parts[0];
      cookie = 'MUSIC_U=${parts.length > 1 ? parts[1] : ''}';
    }
    if (RegExp(r'[?&:/]').hasMatch(id)) {
      if (_listDetailLink.hasMatch(id)) {
        id = id.replaceFirstMapped(_listDetailLink, (m) => m.group(1)!);
      } else if (_listDetailLink2.hasMatch(id)) {
        id = id.replaceFirstMapped(_listDetailLink2, (m) => m.group(1)!);
      } else {
        id = await _followRedirect(id);
      }
    }
    return (id: id, cookie: cookie);
  }

  /// 跟随短链/分享链接重定向到最终地址，再解析歌单 id。
  static Future<String> _followRedirect(String link) {
    return retryRequest(
      maxTries: 3,
      message: 'link try max num',
      attempt: (_) async {
        var current = link;
        for (var hop = 0; hop < 5; hop++) {
          final request = http.Request('GET', Uri.parse(current))
            ..followRedirects = false
            ..headers.addAll(BuiltinSearch.defaultHeaders);
          final response = await request
              .send()
              .timeout(BuiltinSearch.defaultTimeout);
          if (response.statusCode > 400) return null;
          if (response.statusCode >= 300 && response.statusCode < 400) {
            final location = response.headers['location'];
            if (location == null || location.isEmpty) break;
            current = Uri.parse(current).resolve(location).toString();
            continue;
          }
          break;
        }
        if (_listDetailLink.hasMatch(current)) {
          return current.replaceFirstMapped(
              _listDetailLink, (m) => m.group(1)!);
        }
        return current.replaceFirstMapped(
            _listDetailLink2, (m) => m.group(1)!);
      },
    );
  }

  /// `formatSingerName`：HTML 实体解码 + `、` 拼接。
  static String _formatSingerName(Object? artists) {
    if (artists is! List) return decodeName(artists?.toString());
    final names = <String>[];
    for (final artist in artists) {
      final name = artist is Map ? artist['name'] : null;
      if (name == null || name.toString().isEmpty) continue;
      names.add(name.toString());
    }
    return decodeName(names.join('、'));
  }

  static String? _nonEmpty(Object? value) {
    final text = value?.toString();
    return (text == null || text.isEmpty) ? null : text;
  }

  static String _formatDateYMD(int milliseconds) {
    final date = DateTime.fromMillisecondsSinceEpoch(milliseconds);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)}';
  }

  /// 供测试重置内部 cookie（不用于生产路径）。
  static void resetCookieForTest() => _cookie = 'MUSIC_U=';
}
