import 'dart:convert';

import '../../domain/models/discover.dart';
import '../source_search_result.dart';
import 'builtin_search.dart';
import 'crypto_utils.dart';
import 'discover_fetch.dart';
import 'discover_source.dart';
import 'discover_track_mapper.dart';
import 'tx_search.dart';

/// QQ 音乐「发现」（移植自 lx-music-mobile `tx/leaderboard.js`、
/// `tx/songList.js`、`tx/hotSearch.js`）。
///
/// - 热榜：静态榜单表 + `musicu.fcg` toplist GetDetail；
/// - 歌单：标签目录（`get_all_categories` + 热门标签 HTML）、分类歌单
///   （推荐流 / `get_category_content`）、详情（`fcg_ucc_getcdinfo_byids_cp`
///   → `uniform_get_Dissinfo` 兜底）、歌单搜索；
/// - 热搜词：`musicu.fcg` hotkey。
///
/// 网络结果缓存 5 分钟（统一走 `BuiltinSearch.transport.cached`）。
class TxDiscoverSource extends DiscoverSource {
  const TxDiscoverSource();

  static const int _limitList = 36;
  static const int _limitSong = 100000;

  static const String _msieUa =
      'Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; WOW64; Trident/5.0)';

  @override
  String get sourceKey => 'tx';

  /// LX 静态榜单表（`tx/leaderboard.js`）。
  @override
  List<DiscoverLeaderboard> get leaderboards => boards;

  static const List<DiscoverLeaderboard> boards = [
    DiscoverLeaderboard(id: 'tx__4', name: '流行指数榜', bangid: '4'),
    DiscoverLeaderboard(id: 'tx__26', name: '热歌榜', bangid: '26'),
    DiscoverLeaderboard(id: 'tx__27', name: '新歌榜', bangid: '27'),
    DiscoverLeaderboard(id: 'tx__62', name: '飙升榜', bangid: '62'),
    DiscoverLeaderboard(id: 'tx__58', name: '说唱榜', bangid: '58'),
    DiscoverLeaderboard(id: 'tx__57', name: '喜力电音榜', bangid: '57'),
    DiscoverLeaderboard(id: 'tx__28', name: '网络歌曲榜', bangid: '28'),
    DiscoverLeaderboard(id: 'tx__5', name: '内地榜', bangid: '5'),
    DiscoverLeaderboard(id: 'tx__3', name: '欧美榜', bangid: '3'),
    DiscoverLeaderboard(id: 'tx__59', name: '香港地区榜', bangid: '59'),
    DiscoverLeaderboard(id: 'tx__16', name: '韩国榜', bangid: '16'),
    DiscoverLeaderboard(id: 'tx__60', name: '抖快榜', bangid: '60'),
    DiscoverLeaderboard(id: 'tx__29', name: '影视金曲榜', bangid: '29'),
    DiscoverLeaderboard(id: 'tx__17', name: '日本榜', bangid: '17'),
    DiscoverLeaderboard(
        id: 'tx__52', name: '腾讯音乐人原创榜', bangid: '52'),
    DiscoverLeaderboard(id: 'tx__36', name: 'K歌金曲榜', bangid: '36'),
    DiscoverLeaderboard(id: 'tx__61', name: '台湾地区榜', bangid: '61'),
    DiscoverLeaderboard(id: 'tx__63', name: 'DJ舞曲榜', bangid: '63'),
    DiscoverLeaderboard(id: 'tx__64', name: '综艺新歌榜', bangid: '64'),
    DiscoverLeaderboard(id: 'tx__65', name: '国风热歌榜', bangid: '65'),
    DiscoverLeaderboard(id: 'tx__67', name: '听歌识曲榜', bangid: '67'),
    DiscoverLeaderboard(id: 'tx__72', name: '动漫音乐榜', bangid: '72'),
    DiscoverLeaderboard(id: 'tx__73', name: '游戏音乐榜', bangid: '73'),
    DiscoverLeaderboard(id: 'tx__75', name: '有声榜', bangid: '75'),
    DiscoverLeaderboard(
        id: 'tx__131', name: '校园音乐人排行榜', bangid: '131'),
  ];

  // ————————————————————————— 热榜 —————————————————————————

  @override
  Future<List<DiscoverTrack>> leaderboardTracks(String bangid) {
    return BuiltinSearch.transport.cached(
      'tx:leaderboard:$bangid',
      () => _fetchLeaderboard(bangid),
    );
  }

  static Future<List<DiscoverTrack>> _fetchLeaderboard(String bangid) async {
    final body = await lxHttpPost(
      'https://u.y.qq.com/cgi-bin/musicu.fcg',
      headers: {'User-Agent': _msieUa},
      body: {
        'toplist': {
          'module': 'musicToplist.ToplistInfoServer',
          'method': 'GetDetail',
          'param': {
            'topid': int.tryParse(bangid) ?? bangid,
            'num': 300,
          },
        },
        'comm': {'uin': 0, 'format': 'json', 'ct': 20, 'cv': 1859},
      },
    );
    if (body is! Map || body['code'] != 0) {
      throw StateError('tx 榜单获取失败');
    }
    final data = (body['toplist'] as Map?)?['data'];
    final songList = (data is Map) ? data['songInfoList'] : null;
    if (songList is! List) throw StateError('tx 榜单解析失败');
    return [
      for (final item in songList)
        if (TxSearch.parseSongItem(item) case final track?)
          discoverTrackOf(track),
    ];
  }

  // ————————————————————————— 歌单 —————————————————————————

  @override
  Future<DiscoverTags> tags() {
    return BuiltinSearch.transport.cached('tx:tags', () async {
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
        final data = jsonEncode({
          'tags': {
            'method': 'get_all_categories',
            'param': {'qq': ''},
            'module': 'playlist.PlaylistAllCategoriesServer',
          },
        });
        final body = await lxHttpGet(
          'https://u.y.qq.com/cgi-bin/musicu.fcg?loginUin=0&hostUin=0&format=json'
          '&inCharset=utf-8&outCharset=utf-8&notice=0&platform=wk_v15.json'
          '&needNewCode=0&data=${Uri.encodeComponent(data)}',
        );
        if (body is! Map || body['code'] != 0) return null;
        final groups = ((body['tags'] as Map?)?['data'] as Map?)?['v_group'];
        if (groups is! List) return null;
        return filterTagInfo(groups);
      },
    );
  }

  /// 解析标签目录（独立出来便于单元测试）。
  static List<DiscoverTagCategory> filterTagInfo(List<dynamic> groups) {
    final list = <DiscoverTagCategory>[];
    for (final group in groups) {
      if (group is! Map) continue;
      final items = group['v_item'];
      list.add(DiscoverTagCategory(
        name: (group['group_name'] ?? '').toString(),
        tags: [
          for (final item in (items is List ? items : const []))
            if (item is Map)
              DiscoverTag(
                id: (item['id'] ?? '').toString(),
                name: (item['name'] ?? '').toString(),
              ),
        ],
      ));
    }
    return list;
  }

  static Future<List<DiscoverTag>> _fetchHotTag() async {
    final html = await lxHttpGetText(
      'https://c.y.qq.com/node/pc/wk_v15/category_playlist.html',
    );
    return filterInfoHotTag(html);
  }

  /// 从 HTML 解析热门标签（独立出来便于单元测试）。
  static List<DiscoverTag> filterInfoHotTag(String html) {
    final items = RegExp(
      r'class="c_bg_link js_tag_item" data-id="\w+">.+?<\/a>',
    ).allMatches(html);
    final tags = <DiscoverTag>[];
    for (final item in items) {
      final match =
          RegExp(r'data-id="(\w+)">(.+?)<\/a>').firstMatch(item.group(0)!);
      if (match == null) continue;
      tags.add(DiscoverTag(id: match.group(1)!, name: match.group(2)!));
    }
    return tags;
  }

  @override
  Future<DiscoverPlaylistPage> playlists(String tagId, int page) {
    return BuiltinSearch.transport.cached('tx:playlists:$tagId:$page', () {
      return tagId.isEmpty ? _fetchRecommend(page) : _fetchCategory(tagId, page);
    });
  }

  /// 推荐歌单（LX 默认排序 = 推荐）。
  static Future<DiscoverPlaylistPage> _fetchRecommend(int page) {
    return retryRequest(
      maxTries: 3,
      attempt: (_) async {
        final data = jsonEncode({
          'comm': {'cv': 1602, 'ct': 20},
          'playlist': {
            'module': 'music.playlist.PlaylistSquare',
            'method': 'GetRecommendWhole',
            'param': {
              'IsReqFeed': true,
              'FeedReq': {'From': (page - 1) * _limitList, 'Size': _limitList},
            },
          },
        });
        final body = await lxHttpGet(
          'https://u.y.qq.com/cgi-bin/musicu.fcg?loginUin=0&hostUin=0&format=json'
          '&inCharset=utf-8&outCharset=utf-8&notice=0&platform=wk_v15.json'
          '&needNewCode=0&data=${Uri.encodeComponent(data)}',
        );
        if (body is! Map || body['code'] != 0) return null;
        final feed =
            ((body['playlist'] as Map?)?['data'] as Map?)?['FeedRsp'];
        final items = (feed is Map) ? feed['List'] : null;
        final playlists = <DiscoverPlaylist>[];
        if (items is List) {
          for (final item in items) {
            if (item is! Map) continue;
            final basic = item['Playlist'] is Map
                ? (item['Playlist'] as Map)['basic']
                : null;
            if (basic is Map) playlists.add(_playlistFromBasic(basic));
          }
        }
        return DiscoverPlaylistPage(
          playlists: playlists,
          page: page,
          limit: _limitList,
          total: (feed is Map ? parseSourceCount(feed['FromLimit']) : 0) ?? 0,
        );
      },
    );
  }

  /// 分类歌单（`get_category_content`）。
  static Future<DiscoverPlaylistPage> _fetchCategory(String tagId, int page) {
    return retryRequest(
      maxTries: 3,
      attempt: (_) async {
        final id = int.tryParse(tagId) ?? tagId;
        final data = jsonEncode({
          'comm': {'cv': 1602, 'ct': 20},
          'playlist': {
            'method': 'get_category_content',
            'param': {
              'titleid': id,
              'caller': '0',
              'category_id': id,
              'size': _limitList,
              'page': page - 1,
              'use_page': 1,
            },
            'module': 'playlist.PlayListCategoryServer',
          },
        });
        final body = await lxHttpGet(
          'https://u.y.qq.com/cgi-bin/musicu.fcg?loginUin=0&hostUin=0&format=json'
          '&inCharset=utf-8&outCharset=utf-8&notice=0&platform=wk_v15.json'
          '&needNewCode=0&data=${Uri.encodeComponent(data)}',
        );
        if (body is! Map || body['code'] != 0) return null;
        final content =
            ((body['playlist'] as Map?)?['data'] as Map?)?['content'];
        if (content is! Map) return null;
        final items = content['v_item'];
        return DiscoverPlaylistPage(
          playlists: [
            for (final item in (items is List ? items : const []))
              if (item is Map && item['basic'] is Map)
                _playlistFromBasic(item['basic'] as Map),
          ],
          page: page,
          limit: _limitList,
          total: parseSourceCount(content['total_cnt']) ?? 0,
        );
      },
    );
  }

  static DiscoverPlaylist _playlistFromBasic(Map basic) {
    final cover = basic['cover'];
    final creator = basic['creator'];
    return DiscoverPlaylist(
      id: (basic['tid'] ?? '').toString(),
      name: decodeName((basic['title'] ?? '').toString()),
      coverUrl: _coverUrl(cover),
      author: creator is Map ? (creator['nick'] ?? '').toString() : '',
      playCount: parseSourceCount(basic['play_cnt']) ?? 0,
      trackCount: parseSourceCount(basic['song_cnt']) ?? 0,
      description: _cleanDesc(basic['desc']),
    );
  }

  static String? _coverUrl(dynamic cover) {
    if (cover is! Map) return null;
    final url = (cover['medium_url'] ?? cover['default_url'])?.toString();
    return (url == null || url.isEmpty) ? null : url;
  }

  static String? _cleanDesc(dynamic desc) {
    if (desc == null) return null;
    final text = decodeName(desc.toString()).replaceAll('<br>', '\n');
    return text.isEmpty ? null : text;
  }

  @override
  Future<DiscoverPlaylistPage> searchPlaylists(String keyword, int page) {
    return BuiltinSearch.transport.cached('tx:playlist-search:$keyword:$page', () async {
      final body = await lxHttpGet(
        'https://c.y.qq.com/soso/fcgi-bin/client_music_search_songlist'
        '?page_no=${page - 1}&num_per_page=20&format=json'
        '&query=${Uri.encodeComponent(keyword)}'
        '&remoteplace=txt.yqq.playlist&inCharset=utf8&outCharset=utf-8',
        headers: {'Referer': 'https://y.qq.com/portal/search.html'},
      );
      if (body is! Map || body['code'] != 0) {
        throw StateError('tx 歌单搜索失败');
      }
      final data = body['data'];
      final items = (data is Map) ? data['list'] : null;
      final playlists = <DiscoverPlaylist>[];
      if (items is List) {
        for (final item in items) {
          if (item is! Map) continue;
          final creator = item['creator'];
          playlists.add(DiscoverPlaylist(
            id: (item['dissid'] ?? '').toString(),
            name: decodeName((item['dissname'] ?? '').toString()),
            coverUrl: _nonEmpty(item['imgurl']?.toString()),
            author: creator is Map
                ? decodeName((creator['name'] ?? '').toString())
                : '',
            playCount: parseSourceCount(item['listennum']) ?? 0,
            trackCount: parseSourceCount(item['song_count']) ?? 0,
            description: _cleanDesc(item['introduction']),
          ));
        }
      }
      return DiscoverPlaylistPage(
        playlists: playlists,
        page: page,
        limit: 20,
        total: (data is Map ? parseSourceCount(data['sum']) : null) ?? 0,
      );
    });
  }

  @override
  Future<DiscoverDetail> playlistDetail(String rawId, int page) {
    final id = _parseListId(rawId);
    if (id == null) throw StateError('tx 歌单 id 解析失败');
    return BuiltinSearch.transport.cached('tx:playlist-detail:$id', () async {
      try {
        return await _fetchDetailByCgi(id);
      } catch (_) {
        return _fetchDetailByMusicu(id);
      }
    });
  }

  static String? _parseListId(String rawId) {
    if (RegExp(r'\d').hasMatch(rawId) && !RegExp(r'[?&:/]').hasMatch(rawId)) {
      return rawId;
    }
    final match = RegExp(r'/playlist/(\d+)').firstMatch(rawId) ??
        RegExp(r'id=(\d+)').firstMatch(rawId);
    return match?.group(1);
  }

  static Future<DiscoverDetail> _fetchDetailByCgi(String id) async {
    final body = await lxHttpGet(
      'https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg'
      '?type=1&json=1&utf8=1&onlysong=0&new_format=1&disstid=$id'
      '&loginUin=0&hostUin=0&format=json&inCharset=utf8&outCharset=utf-8'
      '&notice=0&platform=yqq.json&needNewCode=0',
      headers: {
        'Origin': 'https://y.qq.com',
        'Referer': 'https://y.qq.com/n/yqq/playsquare/$id.html',
      },
    );
    if (body is! Map || body['code'] != 0 || body['subcode'] != 0) {
      throw StateError('tx 歌单详情失败');
    }
    final cdlist = body['cdlist'];
    if (cdlist is! List || cdlist.isEmpty || cdlist[0] is! Map) {
      throw StateError('tx 歌单详情为空');
    }
    final cd = cdlist[0] as Map;
    final songList = cd['songlist'];
    final tracks = <DiscoverTrack>[];
    if (songList is List) {
      for (final item in songList) {
        final track = TxSearch.parseSongItem(item);
        if (track != null) {
          tracks.add(discoverTrackOf(track));
        }
      }
    }
    return DiscoverDetail(
      info: DiscoverPlaylist(
        id: id,
        name: decodeName((cd['dissname'] ?? '').toString()),
        coverUrl: _nonEmpty(cd['logo']?.toString()),
        author: (cd['nickname'] ?? '').toString(),
        playCount: parseSourceCount(cd['visitnum']) ?? 0,
        trackCount: tracks.length,
        description: _cleanDesc(cd['desc']),
      ),
      tracks: tracks,
    );
  }

  /// 备用详情接口（`uniform_get_Dissinfo`，与 LX `getListDetail2` 一致）。
  static Future<DiscoverDetail> _fetchDetailByMusicu(String id) async {
    final body = await lxHttpPost(
      'https://u.y.qq.com/cgi-bin/musicu.fcg',
      headers: {
        'Origin': 'https://y.qq.com',
        'Referer': 'https://y.qq.com/n/yqq/playsquare/$id.html',
      },
      body: {
        'comm': {
          'cv': 4747474,
          'ct': 24,
          'format': 'json',
          'inCharset': 'utf-8',
          'outCharset': 'utf-8',
          'platform': 'yqq.json',
          'needNewCode': 1,
          'uin': 0,
        },
        'req_1': {
          'module': 'music.srfDissInfo.aiDissInfo',
          'method': 'uniform_get_Dissinfo',
          'param': {
            'disstid': int.tryParse(id) ?? id,
            'userinfo': 1,
            'tag': 1,
            'orderlist': 1,
            'song_begin': 0,
            'song_num': _limitSong,
            'onlysonglist': 0,
            'enc_host_uin': '',
          },
        },
      },
    );
    if (body is! Map || body['code'] != 0) throw StateError('tx 歌单详情失败');
    final req = body['req_1'];
    final data = (req is Map && req['code'] == 0) ? req['data'] : null;
    if (data is! Map) throw StateError('tx 歌单详情失败');
    final dirinfo = data['dirinfo'];
    final songList = data['songlist'];
    final tracks = <DiscoverTrack>[];
    if (songList is List) {
      for (final item in songList) {
        final track = TxSearch.parseSongItem(item);
        if (track != null) {
          tracks.add(discoverTrackOf(track));
        }
      }
    }
    final info = (dirinfo is Map) ? dirinfo : const {};
    return DiscoverDetail(
      info: DiscoverPlaylist(
        id: id,
        name: decodeName((info['title'] ?? '').toString()),
        coverUrl: _nonEmpty(info['picurl']?.toString()),
        author: (info['host_nick'] ?? '').toString(),
        playCount: parseSourceCount(info['listennum']) ?? 0,
        trackCount: parseSourceCount(data['total_song_num']) ?? tracks.length,
        description: _cleanDesc(info['desc']),
      ),
      tracks: tracks,
    );
  }

  @override
  Future<List<String>> hotSearches() {
    return BuiltinSearch.transport.cached('tx:hot-search', _fetchHotSearch);
  }

  static Future<List<String>> _fetchHotSearch() {
    return retryRequest(
      maxTries: 3,
      attempt: (_) async {
        final body = await lxHttpPost(
          'https://u.y.qq.com/cgi-bin/musicu.fcg',
          headers: {'Referer': 'https://y.qq.com/portal/player.html'},
          body: {
            'comm': {
              'ct': '19',
              'cv': '1803',
              'guid': '0',
              'patch': '118',
              'psrf_access_token_expiresAt': 0,
              'psrf_qqaccess_token': '',
              'psrf_qqopenid': '',
              'psrf_qqunionid': '',
              'tmeAppID': 'qqmusic',
              'tmeLoginType': 0,
              'uin': '0',
              'wid': '0',
            },
            'hotkey': {
              'method': 'GetHotkeyForQQMusicPC',
              'module': 'tencent_musicsoso_hotkey.HotkeyService',
              'param': {'search_id': '', 'uin': 0},
            },
          },
        );
        if (body is! Map || body['code'] != 0) return null;
        final vec =
            ((body['hotkey'] as Map?)?['data'] as Map?)?['vec_hotkey'];
        if (vec is! List) return null;
        return filterHotSearch(vec);
      },
    );
  }

  /// 解析热搜词（独立出来便于单元测试）。
  static List<String> filterHotSearch(List<dynamic> rawList) => [
        for (final item in rawList)
          if (item is Map && (item['query']?.toString().isNotEmpty ?? false))
            item['query'].toString(),
      ];

  static String? _nonEmpty(String? text) =>
      (text == null || text.isEmpty) ? null : text;
}
