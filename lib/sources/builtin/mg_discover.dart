import '../../data/cache/request_cache.dart';
import '../../domain/models/discover.dart';
import '../source_track.dart';
import '../source_search_result.dart';
import 'builtin_search.dart';
import 'crypto_utils.dart';
import 'discover_fetch.dart';
import 'discover_source.dart';
import 'discover_track_mapper.dart';
import 'mg_search.dart';

/// 咪咕音乐「发现」（移植自 lx-music-mobile `mg/leaderboard.js`、
/// `mg/songList.js`、`mg/hotSearch.js`、`mg/musicInfo.js`）。
///
/// - 热榜：静态榜单表 + `querycontentbyId.do`；
/// - 歌单：标签（`musiclistplaza-taglist`）、推荐/标签歌单
///   （`playlist-square-recommend` / `musiclistplaza-listbytag`）、详情
///   （`resource/playlist` + `resource/playlist/song`）、歌单搜索（jadeite）；
/// - 热搜词：jadeite `hotword`。
///
/// 网络结果缓存 5 分钟（[RequestCache]）。
class MgDiscoverSource extends DiscoverSource {
  const MgDiscoverSource();

  static const Duration _cacheTtl = Duration(minutes: 5);
  static const int _limitList = 30;
  static const int _limitSong = 30;

  /// 单次详情最多拉取页数（每页 30 首，防止超长歌单请求过多）。
  static const int _maxDetailPages = 10;

  static const String _deviceId = '963B7AA0D21511ED807EE5846EC87D20';
  static const String _signatureMd5 = '6cdc72a439cef99a3418d2a78aa28c73';
  static const String _successCode = '000000';
  static const String _mobileUa =
      'Mozilla/5.0 (Linux; Android 5.1.1; Nexus 6 Build/LYZ28E) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/59.0.3071.115 '
      'Mobile Safari/537.36';
  static const String _searchUa =
      'Mozilla/5.0 (Linux; U; Android 11.0.0; zh-cn; MI 11 '
      'Build/OPR1.170623.032) AppleWebKit/534.30 (KHTML, like Gecko) '
      'Version/4.0 Mobile Safari/534.30';

  static const Map<String, String> _songListHeaders = {
    'User-Agent':
        'Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 '
        'Mobile/15E148 Safari/604.1',
    'Referer': 'https://m.music.migu.cn/',
  };

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

  @override
  String get sourceKey => 'mg';

  /// LX 静态榜单表（`mg/leaderboard.js`）。
  @override
  List<DiscoverLeaderboard> get leaderboards => boards;

  static const List<DiscoverLeaderboard> boards = [
    DiscoverLeaderboard(id: 'mg__27553319', name: '新歌榜', bangid: '27553319'),
    DiscoverLeaderboard(id: 'mg__27186466', name: '热歌榜', bangid: '27186466'),
    DiscoverLeaderboard(id: 'mg__27553408', name: '原创榜', bangid: '27553408'),
    DiscoverLeaderboard(id: 'mg__75959118', name: '音乐风向榜', bangid: '75959118'),
    DiscoverLeaderboard(id: 'mg__76557036', name: '彩铃分贝榜', bangid: '76557036'),
    DiscoverLeaderboard(id: 'mg__76557745', name: '会员臻爱榜', bangid: '76557745'),
    DiscoverLeaderboard(id: 'mg__23189800', name: '港台榜', bangid: '23189800'),
    DiscoverLeaderboard(id: 'mg__23189399', name: '内地榜', bangid: '23189399'),
    DiscoverLeaderboard(id: 'mg__19190036', name: '欧美榜', bangid: '19190036'),
    DiscoverLeaderboard(id: 'mg__83176390', name: '国风金曲榜', bangid: '83176390'),
    DiscoverLeaderboard(id: 'mg__23603721', name: '影视榜', bangid: '23603721'),
    DiscoverLeaderboard(id: 'mg__23603926', name: '华语内地榜', bangid: '23603926'),
    DiscoverLeaderboard(id: 'mg__23603954', name: '华语港台榜', bangid: '23603954'),
    DiscoverLeaderboard(id: 'mg__23603974', name: '欧美榜', bangid: '23603974'),
    DiscoverLeaderboard(id: 'mg__23603982', name: '日韩榜', bangid: '23603982'),
    DiscoverLeaderboard(id: 'mg__23604058', name: '网络榜', bangid: '23604058'),
    DiscoverLeaderboard(id: 'mg__23604023', name: '彩铃榜', bangid: '23604023'),
    DiscoverLeaderboard(id: 'mg__23604040', name: 'KTV榜', bangid: '23604040'),
  ];

  // ————————————————————————— 热榜 —————————————————————————

  @override
  Future<List<DiscoverTrack>> leaderboardTracks(String bangid) {
    return _leaderboardCache.getOrCreate(
      'mg:leaderboard:$bangid',
      () => _fetchLeaderboard(bangid),
    );
  }

  static Future<List<DiscoverTrack>> _fetchLeaderboard(String bangid) {
    return retryRequest(
      maxTries: 4,
      attempt: (_) async {
        final body = await lxHttpGet(
          'https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/querycontentbyId.do'
          '?columnId=$bangid&needAll=0',
          headers: {
            'Referer': 'https://app.c.nf.migu.cn/',
            'User-Agent': _mobileUa,
            'channel': '0146921',
          },
        );
        if (body is! Map || body['code'] != _successCode) return null;
        final columnInfo = body['columnInfo'];
        final contents = (columnInfo is Map) ? columnInfo['contents'] : null;
        if (contents is! List) return null;
        final tracks = filterMusicInfoList([
          for (final item in contents)
            if (item is Map && item['objectInfo'] != null) item['objectInfo'],
        ]);
        return [for (final track in tracks) discoverTrackOf(track)];
      },
    );
  }

  /// 解析榜单/搜索曲目（`mg/musicInfo.js` filterMusicInfoList）。
  static List<SourceTrack> filterMusicInfoList(List<dynamic> rawList) {
    final ids = <String>{};
    final list = <SourceTrack>[];
    for (final item in rawList) {
      if (item is! Map) continue;
      final songId = item['songId']?.toString() ?? '';
      if (songId.isEmpty || !ids.add(songId)) continue;

      final types = MgSearch.parseTypes(item['newRateFormats']);
      final length = item['length']?.toString() ?? '';
      final intervalMatch = RegExp(r'(\d\d:\d\d)$').firstMatch(length);

      final singer = MgSearch.joinSingerNames(item['artists']);
      final name = (item['songName'] ?? '').toString();
      final albumName = (item['album'] ?? '').toString();
      final img = _albumImg(item['albumImgs']);

      list.add(MgSearch.buildTrack(
        songId: songId,
        copyrightId: item['copyrightId']?.toString() ?? '',
        name: name,
        artist: singer,
        album: albumName,
        albumId: item['albumId']?.toString() ?? '',
        intervalText: intervalMatch?.group(1),
        duration: _durationFromInterval(intervalMatch?.group(1)),
        types: types,
        img: img,
        lrcUrl: item['lrcUrl']?.toString(),
        mrcUrl: item['mrcUrl']?.toString(),
        trcUrl: item['trcUrl']?.toString(),
      ));
    }
    return list;
  }

  /// 解析歌单详情曲目（`mg/musicInfo.js` filterMusicInfoListV5）。
  static List<SourceTrack> filterMusicInfoListV5(List<dynamic> rawList) {
    final ids = <String>{};
    final list = <SourceTrack>[];
    for (final item in rawList) {
      if (item is! Map) continue;
      final songId = item['songId']?.toString() ?? '';
      if (songId.isEmpty || !ids.add(songId)) continue;

      final duration =
          int.tryParse(item['duration']?.toString() ?? '') ?? 0;
      list.add(MgSearch.buildTrack(
        songId: songId,
        copyrightId: item['copyrightId']?.toString() ?? '',
        name: (item['songName'] ?? '').toString(),
        artist: MgSearch.joinSingerNames(item['singerList']),
        album: (item['album'] ?? '').toString(),
        albumId: item['albumId']?.toString() ?? '',
        intervalText: formatPlayTime(duration),
        duration: duration > 0 ? Duration(seconds: duration) : null,
        types: MgSearch.parseTypes(item['audioFormats']),
        img: MgSearch.fixCoverUrl(item['img3'] ?? item['img2'] ?? item['img1']),
        lrcUrl: item['lrcUrl']?.toString(),
        mrcUrl: item['mrcUrl']?.toString(),
        trcUrl: item['trcUrl']?.toString(),
      ));
    }
    return list;
  }

  static String? _albumImg(dynamic albumImgs) {
    if (albumImgs is! List || albumImgs.isEmpty) return null;
    final first = albumImgs[0];
    if (first is! Map) return null;
    return MgSearch.fixCoverUrl(first['img']);
  }

  static Duration? _durationFromInterval(String? interval) {
    if (interval == null) return null;
    final parts = interval.split(':');
    if (parts.length != 2) return null;
    final minutes = int.tryParse(parts[0]);
    final seconds = int.tryParse(parts[1]);
    if (minutes == null || seconds == null) return null;
    return Duration(minutes: minutes, seconds: seconds);
  }

  // ————————————————————————— 歌单 —————————————————————————

  @override
  Future<DiscoverTags> tags() {
    return _tagsCache.getOrCreate('mg:tags', () async {
      final body = await lxHttpGet(
        'https://app.c.nf.migu.cn/pc/v1.0/template/'
        'musiclistplaza-taglist/release',
        headers: _songListHeaders,
      );
      if (body is! Map || body['code'] != _successCode) {
        throw StateError('mg 标签获取失败');
      }
      final data = body['data'];
      if (data is! List) throw StateError('mg 标签解析失败');
      return filterTagInfo(data);
    });
  }

  /// 解析标签目录（独立出来便于单元测试）。
  static DiscoverTags filterTagInfo(List<dynamic> rawList) {
    List<DiscoverTag> parseGroup(dynamic group) {
      if (group is! Map) return const [];
      final content = group['content'];
      if (content is! List) return const [];
      final tags = <DiscoverTag>[];
      for (final item in content) {
        if (item is! Map) continue;
        final texts = item['texts'];
        if (texts is! List || texts.length < 2) continue;
        tags.add(DiscoverTag(
          id: texts[1].toString(),
          name: texts[0].toString(),
        ));
      }
      return tags;
    }

    return DiscoverTags(
      hotTags:
          rawList.isEmpty ? const [] : parseGroup(rawList.first),
      categories: [
        for (final group in rawList.skip(1))
          if (group is Map)
            DiscoverTagCategory(
              name: (group['header'] is Map
                      ? (group['header'] as Map)['title']
                      : '')
                  ?.toString() ??
                  '',
              tags: parseGroup(group),
            ),
      ],
    );
  }

  @override
  Future<DiscoverPlaylistPage> playlists(String tagId, int page) {
    return _listCache.getOrCreate('mg:playlists:$tagId:$page', () {
      return tagId.isEmpty ? _fetchRecommend(page) : _fetchTagList(tagId, page);
    });
  }

  /// 推荐歌单（LX 默认排序 = 推荐）。
  static Future<DiscoverPlaylistPage> _fetchRecommend(int page) {
    return retryRequest(
      maxTries: 3,
      attempt: (_) async {
        final body = await lxHttpGet(
          'https://app.c.nf.migu.cn/pc/bmw/page-data/'
          'playlist-square-recommend/v1.0?templateVersion=2&pageNo=$page',
          headers: _songListHeaders,
        );
        if (body is! Map || body['code'] != _successCode) return null;
        final data = body['data'];
        final contents = (data is Map) ? data['contents'] : null;
        return DiscoverPlaylistPage(
          playlists: filterList2(contents is List ? contents : const []),
          page: page,
          limit: _limitList,
          total: 99999,
        );
      },
    );
  }

  static Future<DiscoverPlaylistPage> _fetchTagList(String tagId, int page) {
    return retryRequest(
      maxTries: 3,
      attempt: (_) async {
        final body = await lxHttpGet(
          'https://app.c.nf.migu.cn/pc/v1.0/template/'
          'musiclistplaza-listbytag/release?pageNumber=$page'
          '&templateVersion=2&tagId=$tagId',
          headers: _songListHeaders,
        );
        if (body is! Map || body['code'] != _successCode) return null;
        final data = body['data'];
        if (data is! Map) return null;
        final contents = data['contents'];
        final playlists = contents is List
            ? filterList2(contents)
            : filterList(_contentItemList(data));
        return DiscoverPlaylistPage(
          playlists: playlists,
          page: page,
          limit: _limitList,
          total: 99999,
        );
      },
    );
  }

  static List<dynamic> _contentItemList(Map data) {
    final list = data['contentItemList'];
    if (list is! List || list.length < 2) return const [];
    final item = list[1];
    if (item is! Map) return const [];
    final items = item['itemList'];
    return items is List ? items : const [];
  }

  /// 解析嵌套歌单内容（`mg/songList.js` filterList2；独立出来便于单元测试）。
  static List<DiscoverPlaylist> filterList2(List<dynamic> listData) {
    final list = <DiscoverPlaylist>[];
    final ids = <String>{};
    void walk(List<dynamic> items) {
      for (final item in items) {
        if (item is! Map) continue;
        final contents = item['contents'];
        if (contents is List) {
          walk(contents);
          continue;
        }
        if (item['resType'] != '2021') continue;
        final id = item['resId']?.toString() ?? '';
        if (id.isEmpty || !ids.add(id)) continue;
        list.add(DiscoverPlaylist(
          id: id,
          name: (item['txt'] ?? '').toString(),
          coverUrl: _nonEmpty(item['img']?.toString()),
          playCount: 0,
          trackCount: 0,
          description: _nonEmpty(item['txt2']?.toString()),
        ));
      }
    }

    walk(listData);
    return list;
  }

  /// 解析扁平歌单内容（`mg/songList.js` filterList；独立出来便于单元测试）。
  static List<DiscoverPlaylist> filterList(List<dynamic> rawData) {
    final list = <DiscoverPlaylist>[];
    for (final item in rawData) {
      if (item is! Map) continue;
      final contentId = item['logEvent'] is Map
          ? (item['logEvent'] as Map)['contentId']
          : null;
      final playCount = item['barList'] is List && (item['barList'] as List).isNotEmpty
          ? ((item['barList'] as List)[0] is Map
              ? ((item['barList'] as List)[0] as Map)['title']
              : null)
          : null;
      list.add(DiscoverPlaylist(
        id: contentId?.toString() ?? '',
        name: (item['title'] ?? '').toString(),
        coverUrl: _nonEmpty(item['imageUrl']?.toString()),
        playCount: parseSourceCount(playCount) ?? 0,
        trackCount: 0,
      ));
    }
    return list;
  }

  @override
  Future<DiscoverPlaylistPage> searchPlaylists(String keyword, int page) {
    return _searchCache.getOrCreate('mg:playlist-search:$keyword:$page', () async {
      final time = DateTime.now().millisecondsSinceEpoch.toString();
      final sign = md5Hex(
        '$keyword$_signatureMd5'
        'yyapp2d16148780a1dcc7408e06336b98cfd50'
        '$_deviceId$time',
      );
      final body = await lxHttpGet(
        'https://jadeite.migu.cn/music_search/v3/search/searchAll'
        '?isCorrect=1&isCopyright=1'
        '&searchSwitch=%7B%22song%22%3A0%2C%22album%22%3A0%2C%22singer%22%3A0'
        '%2C%22tagSong%22%3A0%2C%22mvSong%22%3A0%2C%22bestShow%22%3A0'
        '%2C%22songlist%22%3A1%2C%22lyricSong%22%3A0%7D'
        '&pageSize=20&text=${Uri.encodeComponent(keyword)}&pageNo=$page'
        '&sort=0&sid=USS',
        headers: {
          'uiVersion': 'A_music_3.6.1',
          'deviceId': _deviceId,
          'timestamp': time,
          'sign': sign,
          'channel': '0146921',
          'User-Agent': _searchUa,
        },
      );
      if (body is! Map || body['code'] != _successCode) {
        throw StateError('mg 歌单搜索失败');
      }
      final resultData = body['songListResultData'];
      final items = (resultData is Map) ? resultData['result'] : null;
      return DiscoverPlaylistPage(
        playlists: filterSongListResult(
            items is List ? items : const []),
        page: page,
        limit: 20,
        total: (resultData is Map
                ? parseSourceCount(resultData['totalCount'])
                : null) ??
            0,
      );
    });
  }

  /// 解析歌单搜索结果（独立出来便于单元测试）。
  static List<DiscoverPlaylist> filterSongListResult(List<dynamic> raw) {
    final list = <DiscoverPlaylist>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final id = item['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      final playNum = int.tryParse(item['playNum']?.toString() ?? '');
      list.add(DiscoverPlaylist(
        id: id,
        name: (item['name'] ?? '').toString(),
        coverUrl: _nonEmpty(item['musicListPicUrl']?.toString()),
        author: (item['userName'] ?? '').toString(),
        playCount: playNum ?? 0,
        trackCount: parseSourceCount(item['musicNum']) ?? 0,
      ));
    }
    return list;
  }

  @override
  Future<DiscoverDetail> playlistDetail(String rawId, int page) {
    final id = _parsePlaylistId(rawId);
    if (id == null) throw StateError('mg 歌单 id 解析失败');
    return _detailCache.getOrCreate('mg:playlist-detail:$id', () async {
      final results = await Future.wait([
        _fetchDetailList(id),
        _fetchDetailInfo(id),
      ]);
      final listData = results[0] as ({List<SourceTrack> tracks, int total});
      final info = results[1] as ({
        String name,
        String? img,
        String? desc,
        String author,
        int playCount
      })?;
      return DiscoverDetail(
        info: DiscoverPlaylist(
          id: id,
          name: info?.name ?? '',
          coverUrl: info?.img,
          author: info?.author ?? '',
          playCount: info?.playCount ?? 0,
          trackCount: listData.total,
          description: info?.desc,
        ),
        tracks: [
          for (final track in listData.tracks) discoverTrackOf(track),
        ],
      );
    });
  }

  static String? _parsePlaylistId(String rawId) {
    if (RegExp(r'playlist[/?]').hasMatch(rawId)) {
      final match = RegExp(r'(?:playlistId|id)=(\d+)').firstMatch(rawId);
      return match?.group(1);
    }
    if (RegExp(r'\d').hasMatch(rawId) && !RegExp(r'[?&:/]').hasMatch(rawId)) {
      return rawId;
    }
    return null;
  }

  static Future<({List<SourceTrack> tracks, int total})> _fetchDetailList(
    String id,
  ) {
    return retryRequest(
      maxTries: 3,
      attempt: (_) async {
        final tracks = <SourceTrack>[];
        var total = 0;
        for (var page = 1; page <= _maxDetailPages; page++) {
          final body = await lxHttpGet(
            'https://app.c.nf.migu.cn/MIGUM3.0/resource/playlist/song/v2.0'
            '?pageNo=$page&pageSize=$_limitSong&playlistId=$id',
            headers: _songListHeaders,
          );
          if (body is! Map || body['code'] != _successCode) {
            // 首屏失败视为整次失败（重试）；后续页失败保留已取部分。
            if (page == 1) return null;
            break;
          }
          final data = body['data'];
          if (data is! Map) break;
          final songList = data['songList'];
          if (songList is List) {
            tracks.addAll(filterMusicInfoListV5(songList));
          }
          total = parseSourceCount(data['totalCount']) ?? tracks.length;
          if (tracks.length >= total) break;
        }
        return (tracks: tracks, total: total);
      },
    );
  }

  static Future<
      ({String name, String? img, String? desc, String author, int playCount})?>
      _fetchDetailInfo(String id) async {
    try {
      final body = await lxHttpGet(
        'https://c.musicapp.migu.cn/MIGUM3.0/resource/playlist/v2.0'
        '?playlistId=$id',
        headers: _songListHeaders,
      );
      if (body is! Map || body['code'] != _successCode) return null;
      final data = body['data'];
      if (data is! Map) return null;
      final imgItem = data['imgItem'];
      final opNumItem = data['opNumItem'];
      return (
        name: (data['title'] ?? '').toString(),
        img: imgItem is Map ? _nonEmpty(imgItem['img']?.toString()) : null,
        desc: _nonEmpty(data['summary']?.toString()),
        author: (data['ownerName'] ?? '').toString(),
        playCount: opNumItem is Map
            ? (parseSourceCount(opNumItem['playNum']) ?? 0)
            : 0,
      );
    } catch (_) {
      return null;
    }
  }

  // ————————————————————————— 热搜 —————————————————————————

  @override
  Future<List<String>> hotSearches() {
    return _hotSearchCache.getOrCreate('mg:hot-search', _fetchHotSearch);
  }

  static Future<List<String>> _fetchHotSearch() {
    return retryRequest(
      maxTries: 3,
      attempt: (_) async {
        final body = await lxHttpGet(
          'http://jadeite.migu.cn:7090/music_search/v3/search/hotword',
        );
        if (body is! Map || body['code'] != _successCode) return null;
        final data = body['data'];
        final hotwords = (data is Map) ? data['hotwords'] : null;
        if (hotwords is! List || hotwords.isEmpty) return null;
        final first = hotwords[0];
        final list = (first is Map) ? first['hotwordList'] : null;
        if (list is! List) return const [];
        return [
          for (final item in list)
            if (item is Map &&
                item['resourceType'] == 'song' &&
                (item['word']?.toString().isNotEmpty ?? false))
              item['word'].toString(),
        ];
      },
    );
  }

  static String? _nonEmpty(String? text) =>
      (text == null || text.isEmpty) ? null : text;
}
