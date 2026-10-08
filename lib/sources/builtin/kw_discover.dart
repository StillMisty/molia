import 'dart:convert';

import '../../data/cache/request_cache.dart';
import '../../domain/models/discover.dart';
import '../source_track.dart';
import '../source_search_result.dart';
import 'builtin_search.dart';
import 'crypto_utils.dart';
import 'discover_fetch.dart';
import 'discover_source.dart';
import 'discover_track_mapper.dart';
import 'kw_search.dart';

/// 酷我音乐「发现」（移植自 lx-music-mobile `kw/leaderboard.js`、
/// `kw/songList.js`、`kw/hotSearch.js`）。
///
/// - 热榜：静态榜单表 + `wbd/.../bang_info`（AES-128-ECB + sign）；
/// - 歌单：标签（`getTagList` / `getRcmTagList`）、推荐/标签歌单
///   （`getRcmPlayList` / `getTagPlayList`）、详情（`nplserver` / `qukudata`）、
///   歌单搜索（`search.kuwo.cn`，伪 JSON 需转义）；
/// - 热搜词：`hotword.kuwo.cn`。
///
/// 网络结果缓存 5 分钟（[RequestCache]）。
class KwDiscoverSource extends DiscoverSource {
  const KwDiscoverSource();

  static const Duration _cacheTtl = Duration(minutes: 5);
  static const int _limitList = 36;
  static const int _limitSong = 1000;

  static final RequestCache _leaderboardCache =
      RequestCache(maxEntries: 16, ttl: _cacheTtl);
  static final RequestCache _tagsCache =
      RequestCache(maxEntries: 4, ttl: _cacheTtl);
  static final RequestCache _listCache =
      RequestCache(maxEntries: 32, ttl: _cacheTtl);
  static final RequestCache _detailCache =
      RequestCache(maxEntries: 16, ttl: _cacheTtl);
  static final RequestCache _searchCache =
      RequestCache(maxEntries: 16, ttl: _cacheTtl);
  static final RequestCache _hotSearchCache =
      RequestCache(maxEntries: 2, ttl: _cacheTtl);

  static final RegExp _listDetailLink =
      RegExp(r'^.+\/playlist(?:_detail)?\/(\d+)(?:\?.*|&.*$|#.*$|$)');

  @override
  String get sourceKey => 'kw';

  /// LX 静态榜单表（`kw/leaderboard.js`）。
  @override
  List<DiscoverLeaderboard> get leaderboards => boards;

  static const List<DiscoverLeaderboard> boards = [
    DiscoverLeaderboard(id: 'kw__93', name: '飙升榜', bangid: '93'),
    DiscoverLeaderboard(id: 'kw__17', name: '新歌榜', bangid: '17'),
    DiscoverLeaderboard(id: 'kw__16', name: '热歌榜', bangid: '16'),
    DiscoverLeaderboard(id: 'kw__158', name: '抖音热歌榜', bangid: '158'),
    DiscoverLeaderboard(id: 'kw__292', name: '铃声榜', bangid: '292'),
    DiscoverLeaderboard(id: 'kw__284', name: '热评榜', bangid: '284'),
    DiscoverLeaderboard(id: 'kw__290', name: 'ACG新歌榜', bangid: '290'),
    DiscoverLeaderboard(id: 'kw__286', name: '台湾KKBOX榜', bangid: '286'),
    DiscoverLeaderboard(id: 'kw__279', name: '冬日暖心榜', bangid: '279'),
    DiscoverLeaderboard(id: 'kw__281', name: '巴士随身听榜', bangid: '281'),
    DiscoverLeaderboard(id: 'kw__255', name: 'KTV点唱榜', bangid: '255'),
    DiscoverLeaderboard(id: 'kw__280', name: '家务进行曲榜', bangid: '280'),
    DiscoverLeaderboard(id: 'kw__282', name: '熬夜修仙榜', bangid: '282'),
    DiscoverLeaderboard(id: 'kw__283', name: '枕边轻音乐榜', bangid: '283'),
    DiscoverLeaderboard(id: 'kw__278', name: '古风音乐榜', bangid: '278'),
    DiscoverLeaderboard(id: 'kw__264', name: 'Vlog音乐榜', bangid: '264'),
    DiscoverLeaderboard(id: 'kw__242', name: '电音榜', bangid: '242'),
    DiscoverLeaderboard(id: 'kw__187', name: '流行趋势榜', bangid: '187'),
    DiscoverLeaderboard(id: 'kw__204', name: '现场音乐榜', bangid: '204'),
    DiscoverLeaderboard(id: 'kw__186', name: 'ACG神曲榜', bangid: '186'),
    DiscoverLeaderboard(id: 'kw__185', name: '最强翻唱榜', bangid: '185'),
    DiscoverLeaderboard(id: 'kw__26', name: '经典怀旧榜', bangid: '26'),
    DiscoverLeaderboard(id: 'kw__104', name: '华语榜', bangid: '104'),
    DiscoverLeaderboard(id: 'kw__182', name: '粤语榜', bangid: '182'),
    DiscoverLeaderboard(id: 'kw__22', name: '欧美榜', bangid: '22'),
    DiscoverLeaderboard(id: 'kw__184', name: '韩语榜', bangid: '184'),
    DiscoverLeaderboard(id: 'kw__183', name: '日语榜', bangid: '183'),
    DiscoverLeaderboard(id: 'kw__145', name: '会员畅听榜', bangid: '145'),
    DiscoverLeaderboard(id: 'kw__153', name: '网红新歌榜', bangid: '153'),
    DiscoverLeaderboard(id: 'kw__64', name: '影视金曲榜', bangid: '64'),
    DiscoverLeaderboard(id: 'kw__176', name: 'DJ嗨歌榜', bangid: '176'),
    DiscoverLeaderboard(id: 'kw__106', name: '真声音', bangid: '106'),
    DiscoverLeaderboard(id: 'kw__12', name: 'Billboard榜', bangid: '12'),
    DiscoverLeaderboard(id: 'kw__49', name: 'iTunes音乐榜', bangid: '49'),
    DiscoverLeaderboard(id: 'kw__180', name: 'beatport电音榜', bangid: '180'),
    DiscoverLeaderboard(id: 'kw__13', name: '英国UK榜', bangid: '13'),
    DiscoverLeaderboard(id: 'kw__164', name: '百大DJ榜', bangid: '164'),
    DiscoverLeaderboard(id: 'kw__246', name: 'YouTube音乐排行榜', bangid: '246'),
    DiscoverLeaderboard(id: 'kw__265', name: '韩国Genie榜', bangid: '265'),
    DiscoverLeaderboard(id: 'kw__14', name: '韩国M-net榜', bangid: '14'),
    DiscoverLeaderboard(id: 'kw__8', name: '香港电台榜', bangid: '8'),
    DiscoverLeaderboard(id: 'kw__15', name: '日本公信榜', bangid: '15'),
    DiscoverLeaderboard(id: 'kw__151', name: '腾讯音乐人原创榜', bangid: '151'),
  ];

  // ————————————————————————— 热榜 —————————————————————————

  @override
  Future<List<DiscoverTrack>> leaderboardTracks(String bangid) {
    return _leaderboardCache.getOrCreate(
      'kw:leaderboard:$bangid',
      () => _fetchLeaderboard(bangid),
    );
  }

  static Future<List<DiscoverTrack>> _fetchLeaderboard(String bangid) {
    return retryRequest(
      maxTries: 4,
      attempt: (_) async {
        final body = {
          'uid': '',
          'devId': '',
          'sFrom': 'kuwo_sdk',
          'user_type': 'AP',
          'carSource': 'kwplayercar_ar_6.0.1.0_apk_keluze.apk',
          'id': bangid,
          'pn': 0,
          'rn': 100,
        };
        final url =
            'https://wbd.kuwo.cn/api/bd/bang/bang_info?${kwWbdBuildParam(body)}';
        final text = await lxHttpGetText(url);
        dynamic decoded;
        try {
          decoded = kwWbdDecodeData(text);
        } catch (_) {
          return null;
        }
        if (decoded is! Map || decoded['code'] != 200) return null;
        final data = decoded['data'];
        final musicList = (data is Map) ? data['musiclist'] : null;
        if (musicList is! List) return null;
        return [
          for (final item in musicList)
            if (filterDataItem(item) case final track?) discoverTrackOf(track),
        ];
      },
    );
  }

  /// 解析酷我榜单曲目（`n_minfo` 音质段；独立出来便于单元测试）。
  static SourceTrack? filterDataItem(dynamic rawItem) {
    if (rawItem is! Map) return null;
    final types = KwSearch.parseNMinfo(rawItem['n_minfo']?.toString() ?? '');
    // LX `sortQualityArray`：按音质从低到高排序
    const order = ['128k', '320k', 'flac', 'flac24bit'];
    final sorted = <String, Map<String, dynamic>>{
      for (final type in order)
        if (types.containsKey(type)) type: types[type]!,
    };

    final duration =
        int.tryParse(rawItem['duration']?.toString() ?? '') ?? 0;
    return KwSearch.buildTrack(
      songId: rawItem['id']?.toString() ?? '',
      name: decodeName(rawItem['name']?.toString()),
      artist: formatSinger(decodeName(rawItem['artist']?.toString())),
      album: decodeName(rawItem['album']?.toString()),
      albumId: rawItem['albumId']?.toString() ?? '',
      intervalSeconds: duration,
      types: sorted,
      img: rawItem['pic']?.toString(),
    );
  }

  // ————————————————————————— 歌单 —————————————————————————

  @override
  Future<DiscoverTags> tags() {
    return _tagsCache.getOrCreate('kw:tags', () async {
      final results = await Future.wait([_fetchTag(), _fetchHotTag()]);
      return DiscoverTags(
        categories: results[0] as List<DiscoverTagCategory>,
        hotTags: results[1] as List<DiscoverTag>,
      );
    });
  }

  static Future<List<DiscoverTagCategory>> _fetchTag() {
    return retryRequest(
      maxTries: 3,
      attempt: (_) async {
        final body = await lxHttpGet(
          'http://wapi.kuwo.cn/api/pc/classify/playlist/getTagList'
          '?cmd=rcm_keyword_playlist&user=0&prod=kwplayer_pc_9.0.5.0'
          '&vipver=9.0.5.0&source=kwplayer_pc_9.0.5.0&loginUid=0&loginSid=0'
          '&appUid=76039576',
        );
        if (body is! Map || body['code'] != 200) return null;
        return filterTagInfo(body['data'] as List? ?? const []);
      },
    );
  }

  /// 解析标签目录（独立出来便于单元测试）。
  static List<DiscoverTagCategory> filterTagInfo(List<dynamic> rawList) => [
        for (final type in rawList)
          if (type is Map)
            DiscoverTagCategory(
              name: (type['name'] ?? '').toString(),
              tags: [
                for (final item in (type['data'] as List? ?? const []))
                  if (item is Map)
                    DiscoverTag(
                      id: '${item['id']}-${item['digest']}',
                      name: (item['name'] ?? '').toString(),
                    ),
              ],
            ),
      ];

  static Future<List<DiscoverTag>> _fetchHotTag() {
    return retryRequest(
      maxTries: 3,
      attempt: (_) async {
        final body = await lxHttpGet(
          'http://wapi.kuwo.cn/api/pc/classify/playlist/getRcmTagList'
          '?loginUid=0&loginSid=0&appUid=76039576',
        );
        if (body is! Map || body['code'] != 200) return null;
        final data = body['data'];
        final rawList = (data is List && data.isNotEmpty && data[0] is Map)
            ? (data[0] as Map)['data']
            : null;
        return filterInfoHotTag(rawList is List ? rawList : const []);
      },
    );
  }

  /// 解析热门标签（独立出来便于单元测试）。
  static List<DiscoverTag> filterInfoHotTag(List<dynamic> rawList) => [
        for (final item in rawList)
          if (item is Map)
            DiscoverTag(
              id: '${item['id']}-${item['digest']}',
              name: (item['name'] ?? '').toString(),
            ),
      ];

  @override
  Future<DiscoverPlaylistPage> playlists(String tagId, int page) {
    return _listCache.getOrCreate('kw:playlists:$tagId:$page', () {
      return tagId.isEmpty
          ? _fetchRecommend(page)
          : _fetchTagPlaylist(tagId, page);
    });
  }

  /// 推荐歌单（LX 默认排序 = 最新）。
  static Future<DiscoverPlaylistPage> _fetchRecommend(int page) {
    return retryRequest(
      maxTries: 3,
      attempt: (_) async {
        final body = await lxHttpGet(
          'http://wapi.kuwo.cn/api/pc/classify/playlist/getRcmPlayList'
          '?loginUid=0&loginSid=0&appUid=76039576&pn=$page&rn=$_limitList'
          '&order=new',
        );
        if (body is! Map || body['code'] != 200) return null;
        final data = body['data'];
        if (data is! Map) return null;
        return DiscoverPlaylistPage(
          playlists: filterList(data['data'] as List? ?? const []),
          page: page,
          limit: _limitList,
          total: parseSourceCount(data['total']) ?? 0,
        );
      },
    );
  }

  /// 解析歌单概要（独立出来便于单元测试）。
  static List<DiscoverPlaylist> filterList(List<dynamic> rawData) {
    final list = <DiscoverPlaylist>[];
    for (final item in rawData) {
      if (item is! Map) continue;
      final id = 'digest-${item['digest']}__${item['id']}';
      list.add(DiscoverPlaylist(
        id: id,
        name: (item['name'] ?? '').toString(),
        coverUrl: (item['img']?.toString().isNotEmpty ?? false)
            ? item['img'].toString()
            : null,
        author: (item['uname'] ?? '').toString(),
        playCount: parseSourceCount(item['listencnt']) ?? 0,
        trackCount: parseSourceCount(item['total']) ?? 0,
        description: (item['desc']?.toString().isNotEmpty ?? false)
            ? item['desc'].toString()
            : null,
      ));
    }
    return list;
  }

  static Future<DiscoverPlaylistPage> _fetchTagPlaylist(
    String tagId,
    int page,
  ) {
    return retryRequest(
      maxTries: 3,
      attempt: (_) async {
        final parts = tagId.split('-');
        final id = parts.first;
        final type = parts.length > 1 ? parts[1] : null;

        if (type == '43') {
          // 旧版聚合数据（mobileinterfaces）：响应为数组，含 songlist/list/album。
          final body = await lxHttpGet(
            'http://mobileinterfaces.kuwo.cn/er.s?type=get_pc_qz_data&f=web'
            '&id=$id&prod=pc',
          );
          if (body is! List) return null;
          return DiscoverPlaylistPage(
            playlists: filterList2(body),
            page: page,
            limit: 1000,
            total: 1000,
          );
        }

        final body = await lxHttpGet(
          'http://wapi.kuwo.cn/api/pc/classify/playlist/getTagPlayList'
          '?loginUid=0&loginSid=0&appUid=76039576&pn=$page&id=$id&rn=$_limitList',
        );
        if (body is! Map || body['code'] != 200) return null;
        final data = body['data'];
        if (data is! Map) return null;
        return DiscoverPlaylistPage(
          playlists: filterList(data['data'] as List? ?? const []),
          page: page,
          limit: _limitList,
          total: parseSourceCount(data['total']) ?? 0,
        );
      },
    );
  }

  /// 解析聚合歌单数据（`get_pc_qz_data`；独立出来便于单元测试）。
  static List<DiscoverPlaylist> filterList2(List<dynamic> rawData) {
    const allowedTypes = ['songlist', 'list', 'album'];
    final list = <DiscoverPlaylist>[];
    for (final group in rawData) {
      if (group is! Map) continue;
      final items = group['list'];
      if (items is! List) continue;
      for (final item in items) {
        if (item is! Map) continue;
        if (!allowedTypes.contains(item['type'])) continue;
        list.add(DiscoverPlaylist(
          id: 'digest-${item['digest']}__${item['id']}',
          name: (item['name'] ?? '').toString(),
          coverUrl: (item['img']?.toString().isNotEmpty ?? false)
              ? item['img'].toString()
              : null,
          author: (item['uname'] ?? '').toString(),
          playCount: parseSourceCount(item['listencnt']) ?? 0,
          trackCount: parseSourceCount(item['total']) ?? 0,
          description: (item['desc']?.toString().isNotEmpty ?? false)
              ? item['desc'].toString()
              : null,
        ));
      }
    }
    return list;
  }

  @override
  Future<DiscoverPlaylistPage> searchPlaylists(String keyword, int page) {
    return _searchCache.getOrCreate('kw:playlist-search:$keyword:$page', () async {
      final text = await lxHttpGetText(
        'http://search.kuwo.cn/r.s?all=${Uri.encodeComponent(keyword)}'
        '&pn=${page - 1}&rn=20&rformat=json&encoding=utf8&ver=mbox'
        '&vipver=MUSIC_8.7.7.0_BCS37&plat=pc&devid=28156413&ft=playlist'
        '&pay=0&needliveshow=0',
      );
      final body = objStr2JSON(text);
      if (body is! Map) throw StateError('kw 歌单搜索失败');
      final rawList = body['abslist'];
      final playlists = <DiscoverPlaylist>[];
      if (rawList is List) {
        for (final item in rawList) {
          if (item is! Map) continue;
          playlists.add(DiscoverPlaylist(
            id: (item['playlistid'] ?? '').toString(),
            name: decodeName(item['name']?.toString()),
            coverUrl: (item['pic']?.toString().isNotEmpty ?? false)
                ? item['pic'].toString()
                : null,
            author: decodeName(item['nickname']?.toString()),
            playCount: parseSourceCount(item['playcnt']) ?? 0,
            trackCount: parseSourceCount(item['songnum']) ?? 0,
            description: (item['intro']?.toString().isNotEmpty ?? false)
                ? decodeName(item['intro']?.toString())
                : null,
          ));
        }
      }
      return DiscoverPlaylistPage(
        playlists: playlists,
        page: page,
        limit: 20,
        total: parseSourceCount(body['TOTAL']) ?? 0,
      );
    });
  }

  /// 酷我伪 JSON → JSON（`{'a':'b'}` → `{"a":"b"}`；移植 LX `objStr2JSON`）。
  static dynamic objStr2JSON(String str) {
    final replaced = str.replaceAllMapped(
      RegExp("('(?=(,\\s*')))|('(?=:))|((?<=([:,]\\s*))')|((?<={)')|('(?=}))"),
      (_) => '"',
    );
    return jsonDecode(replaced);
  }

  @override
  Future<DiscoverDetail> playlistDetail(String rawId, int page) {
    final id = _parsePlaylistId(rawId);
    if (id == null) throw StateError('kw 歌单 id 解析失败');
    return _detailCache.getOrCreate('kw:playlist-detail:$id', () {
      return _fetchDetail(id);
    });
  }

  /// 从 `digest-5__123` / 链接 / 纯 ID 中提取可请求的 id 与 digest。
  static String? _parsePlaylistId(String rawId) {
    if (rawId.contains('?') ||
        rawId.contains('&') ||
        rawId.contains(':') ||
        rawId.contains('/')) {
      final match = _listDetailLink.firstMatch(rawId);
      return match?.group(1);
    }
    return rawId;
  }

  static Future<DiscoverDetail> _fetchDetail(String id) {
    if (id.startsWith('digest-')) {
      final parts = id.split('__');
      final digest = parts.first.replaceFirst('digest-', '');
      final realId = parts.length > 1 ? parts[1] : '';
      if (digest == '5') {
        return _fetchDetailDigest5(realId);
      }
      if (digest == '13') {
        throw UnsupportedError('kw 专辑暂不支持');
      }
      if (realId.isEmpty) throw StateError('kw 歌单 id 解析失败');
      return _fetchDetailDigest8(realId);
    }
    return _fetchDetailDigest8(id);
  }

  /// digest 8：歌曲类歌单（`nplserver/pl.svc`）。
  static Future<DiscoverDetail> _fetchDetailDigest8(String id) {
    return retryRequest(
      maxTries: 3,
      attempt: (_) async {
        final body = await lxHttpGet(
          'http://nplserver.kuwo.cn/pl.svc?op=getlistinfo&pid=$id&pn=0'
          '&rn=$_limitSong&encode=utf8&keyset=pl2012&identity=kuwo&pcmp4=1'
          '&vipver=MUSIC_9.0.5.0_W1&newver=1',
        );
        if (body is! Map || body['result'] != 'ok') return null;
        final tracks =
            _mapTracks(filterListDetail(body['musiclist'] as List? ?? const []));
        return DiscoverDetail(
          info: DiscoverPlaylist(
            id: id,
            name: (body['title'] ?? '').toString(),
            coverUrl: _nonEmpty(body['pic']?.toString()),
            author: (body['uname'] ?? '').toString(),
            playCount: parseSourceCount(body['playnum']) ?? 0,
            trackCount: parseSourceCount(body['total']) ?? tracks.length,
            description: (body['info']?.toString().isNotEmpty ?? false)
                ? body['info'].toString()
                : null,
          ),
          tracks: tracks,
        );
      },
    );
  }

  /// digest 5：推荐歌单（先 `qukudata` 换算 sourceid，再取曲目）。
  static Future<DiscoverDetail> _fetchDetailDigest5(String id) {
    return retryRequest(
      maxTries: 3,
      attempt: (_) async {
        final infoBody = await lxHttpGet(
          'http://qukudata.kuwo.cn/q.k?op=query&cont=ninfo&node=$id&pn=0&rn=1'
          '&fmt=json&src=mbox&level=2',
        );
        final child = (infoBody is Map) ? infoBody['child'] : null;
        final sourceId = (child is List && child.isNotEmpty && child[0] is Map)
            ? (child[0] as Map)['sourceid']?.toString()
            : null;
        if (sourceId == null || sourceId.isEmpty) return null;
        return _fetchDetailDigest8(sourceId);
      },
    );
  }

  static List<DiscoverTrack> _mapTracks(List<SourceTrack> tracks) => [
        for (final track in tracks) discoverTrackOf(track),
      ];

  /// 解析歌单曲目（`N_MINFO` 音质段；独立出来便于单元测试）。
  static List<SourceTrack> filterListDetail(List<dynamic> rawData) {
    final list = <SourceTrack>[];
    for (final item in rawData) {
      if (item is! Map) continue;
      final types = KwSearch.parseNMinfo(item['N_MINFO']?.toString() ?? '');
      const order = ['128k', '320k', 'flac', 'flac24bit'];
      final sorted = <String, Map<String, dynamic>>{
        for (final type in order)
          if (types.containsKey(type)) type: types[type]!,
      };

      final duration =
          int.tryParse(item['duration']?.toString() ?? '') ?? 0;
      list.add(KwSearch.buildTrack(
        songId: item['id']?.toString() ?? '',
        name: decodeName(item['name']?.toString()),
        artist: formatSinger(decodeName(item['artist']?.toString())),
        album: decodeName(item['album']?.toString()),
        albumId: item['albumid']?.toString() ?? '',
        intervalSeconds: duration,
        types: sorted,
        img: null,
      ));
    }
    return list;
  }

  // ————————————————————————— 热搜 —————————————————————————

  @override
  Future<List<String>> hotSearches() {
    return _hotSearchCache.getOrCreate('kw:hot-search', _fetchHotSearch);
  }

  static Future<List<String>> _fetchHotSearch() {
    return retryRequest(
      maxTries: 3,
      attempt: (_) async {
        final body = await lxHttpGet(
          'http://hotword.kuwo.cn/hotword.s?prod=kwplayer_ar_9.3.0.1&corp=kuwo'
          '&newver=2&vipver=9.3.0.1&source=kwplayer_ar_9.3.0.1_40.apk&p2p=1'
          '&notrace=0&uid=0&plat=kwplayer_ar&rformat=json&encoding=utf8&tabid=1',
          headers: {'User-Agent': 'Dalvik/2.1.0 (Linux; U; Android 9;)'},
        );
        if (body is! Map || body['status'] != 'ok') return null;
        final rawList = body['tagvalue'];
        if (rawList is! List) return null;
        return [
          for (final item in rawList)
            if (item is Map && (item['key']?.toString().isNotEmpty ?? false))
              item['key'].toString(),
        ];
      },
    );
  }

  static String? _nonEmpty(String? text) =>
      (text == null || text.isEmpty) ? null : text;
}

/// 酷我歌手名 `&` → `、`（与搜索模块同一约定）。
String formatSinger(String raw) => raw.replaceAll('&', '、');
