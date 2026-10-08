import 'dart:convert';

import '../../domain/models/discover.dart';
import '../source_track.dart';
import '../source_search_result.dart';
import 'builtin_search.dart';
import 'crypto_utils.dart';
import 'discover_fetch.dart';
import 'discover_source.dart';
import 'discover_track_mapper.dart';
import 'kg_search.dart';

/// 酷狗音乐「发现」（移植自 lx-music-mobile `kg/leaderboard.js`、
/// `kg/songList.js`、`kg/hotSearch.js`）。
///
/// - 热榜：静态榜单表 + `mobilecdnbj/.../rank/song`；
/// - 歌单：标签（`getSpecial?is_smarty=1`）、推荐/标签歌单
///   （`getSpecial?is_ajax=1` + 推荐流）、详情（`special/single` 页面
///   `global.data` 歌单 → gateway 批量歌曲信息）、歌单搜索；
/// - 热搜词：`gateway.kugou.com/.../hot_tab`。
///
/// 网络结果缓存 5 分钟（统一走 `BuiltinSearch.transport.cached`）。
class KgDiscoverSource extends DiscoverSource {
  const KgDiscoverSource();

  static const int _limitList = 30;
  static const int _limitSong = 100;
  static const String _gatewayKey = 'OIlwieks28dk2k092lksi2UIkp';

  static final RegExp _listDataExp = RegExp(r'global\.data = (\[.+\]);');
  static final RegExp _listInfoExp = RegExp(
      r'global = {[\s\S]+?name: "(.+)"[\s\S]+?pic: "(.+)"[\s\S]+?};');

  @override
  String get sourceKey => 'kg';

  /// LX 静态榜单表（`kg/leaderboard.js`）。
  @override
  List<DiscoverLeaderboard> get leaderboards => boards;

  static const List<DiscoverLeaderboard> boards = [
    DiscoverLeaderboard(id: 'kg__8888', name: 'TOP500', bangid: '8888'),
    DiscoverLeaderboard(id: 'kg__6666', name: '飙升榜', bangid: '6666'),
    DiscoverLeaderboard(id: 'kg__59703', name: '蜂鸟流行音乐榜', bangid: '59703'),
    DiscoverLeaderboard(id: 'kg__52144', name: '抖音热歌榜', bangid: '52144'),
    DiscoverLeaderboard(id: 'kg__52767', name: '快手热歌榜', bangid: '52767'),
    DiscoverLeaderboard(id: 'kg__24971', name: 'DJ热歌榜', bangid: '24971'),
    DiscoverLeaderboard(id: 'kg__23784', name: '网络红歌榜', bangid: '23784'),
    DiscoverLeaderboard(id: 'kg__44412', name: '说唱先锋榜', bangid: '44412'),
    DiscoverLeaderboard(id: 'kg__31308', name: '内地榜', bangid: '31308'),
    DiscoverLeaderboard(id: 'kg__33160', name: '电音榜', bangid: '33160'),
    DiscoverLeaderboard(id: 'kg__31313', name: '香港地区榜', bangid: '31313'),
    DiscoverLeaderboard(id: 'kg__51341', name: '民谣榜', bangid: '51341'),
    DiscoverLeaderboard(id: 'kg__54848', name: '台湾地区榜', bangid: '54848'),
    DiscoverLeaderboard(id: 'kg__31310', name: '欧美榜', bangid: '31310'),
    DiscoverLeaderboard(id: 'kg__33162', name: 'ACG新歌榜', bangid: '33162'),
    DiscoverLeaderboard(id: 'kg__31311', name: '韩国榜', bangid: '31311'),
    DiscoverLeaderboard(id: 'kg__31312', name: '日本榜', bangid: '31312'),
    DiscoverLeaderboard(id: 'kg__49225', name: '80后热歌榜', bangid: '49225'),
    DiscoverLeaderboard(id: 'kg__49223', name: '90后热歌榜', bangid: '49223'),
    DiscoverLeaderboard(id: 'kg__49224', name: '00后热歌榜', bangid: '49224'),
    DiscoverLeaderboard(id: 'kg__33165', name: '粤语金曲榜', bangid: '33165'),
    DiscoverLeaderboard(id: 'kg__33166', name: '欧美金曲榜', bangid: '33166'),
    DiscoverLeaderboard(id: 'kg__33163', name: '影视金曲榜', bangid: '33163'),
    DiscoverLeaderboard(id: 'kg__51340', name: '伤感榜', bangid: '51340'),
    DiscoverLeaderboard(id: 'kg__35811', name: '会员专享榜', bangid: '35811'),
    DiscoverLeaderboard(id: 'kg__37361', name: '雷达榜', bangid: '37361'),
    DiscoverLeaderboard(id: 'kg__21101', name: '分享榜', bangid: '21101'),
    DiscoverLeaderboard(id: 'kg__46910', name: '综艺新歌榜', bangid: '46910'),
    DiscoverLeaderboard(id: 'kg__30972', name: '酷狗音乐人原创榜', bangid: '30972'),
    DiscoverLeaderboard(id: 'kg__60170', name: '闽南语榜', bangid: '60170'),
    DiscoverLeaderboard(id: 'kg__65234', name: '儿歌榜', bangid: '65234'),
    DiscoverLeaderboard(id: 'kg__4681', name: '美国BillBoard榜', bangid: '4681'),
    DiscoverLeaderboard(
        id: 'kg__25028', name: 'Beatport电子舞曲榜', bangid: '25028'),
    DiscoverLeaderboard(id: 'kg__4680', name: '英国单曲榜', bangid: '4680'),
    DiscoverLeaderboard(id: 'kg__38623', name: '韩国Melon音乐榜', bangid: '38623'),
    DiscoverLeaderboard(id: 'kg__42807', name: 'joox本地热歌榜', bangid: '42807'),
    DiscoverLeaderboard(id: 'kg__36107', name: '小语种热歌榜', bangid: '36107'),
    DiscoverLeaderboard(id: 'kg__4673', name: '日本公信榜', bangid: '4673'),
    DiscoverLeaderboard(
        id: 'kg__46868', name: '日本SPACE SHOWER榜', bangid: '46868'),
    DiscoverLeaderboard(id: 'kg__42808', name: 'KKBOX风云榜', bangid: '42808'),
    DiscoverLeaderboard(id: 'kg__60171', name: '越南语榜', bangid: '60171'),
    DiscoverLeaderboard(id: 'kg__60172', name: '泰语榜', bangid: '60172'),
    DiscoverLeaderboard(id: 'kg__59895', name: 'R&B榜', bangid: '59895'),
    DiscoverLeaderboard(id: 'kg__59896', name: '摇滚榜', bangid: '59896'),
    DiscoverLeaderboard(id: 'kg__59897', name: '爵士榜', bangid: '59897'),
    DiscoverLeaderboard(id: 'kg__59898', name: '乡村音乐榜', bangid: '59898'),
    DiscoverLeaderboard(id: 'kg__59900', name: '纯音乐榜', bangid: '59900'),
    DiscoverLeaderboard(id: 'kg__59899', name: '古典榜', bangid: '59899'),
    DiscoverLeaderboard(id: 'kg__22603', name: '5sing音乐榜', bangid: '22603'),
    DiscoverLeaderboard(id: 'kg__21335', name: '繁星音乐榜', bangid: '21335'),
    DiscoverLeaderboard(id: 'kg__33161', name: '古风新歌榜', bangid: '33161'),
  ];

  // ————————————————————————— 热榜 —————————————————————————

  @override
  Future<List<DiscoverTrack>> leaderboardTracks(String bangid) {
    return BuiltinSearch.transport.cached(
      'kg:leaderboard:$bangid',
      () => _fetchLeaderboard(bangid),
    );
  }

  static Future<List<DiscoverTrack>> _fetchLeaderboard(String bangid) {
    return retryRequest(
      maxTries: 4,
      attempt: (_) async {
        final body = await lxHttpGet(
          'http://mobilecdnbj.kugou.com/api/v3/rank/song?version=9108'
          '&ranktype=1&plat=0&pagesize=$_limitSong&area_code=1&page=1'
          '&rankid=$bangid&with_res_tag=0&show_portrait_mv=1',
        );
        if (body is! Map || body['errcode'] != 0) return null;
        final data = body['data'];
        final rawList = (data is Map) ? data['info'] : null;
        if (rawList is! List) return null;
        return [
          for (final item in rawList)
            if (filterDataItem(item) case final track?) discoverTrackOf(track),
        ];
      },
    );
  }

  /// 解析榜单曲目（`kg/leaderboard.js` filterData；独立出来便于单元测试）。
  static SourceTrack? filterDataItem(dynamic rawItem) {
    if (rawItem is! Map) return null;
    final types = <String, Map<String, dynamic>>{};
    KgSearch.addKgQuality(types, '128k',
        size: rawItem['filesize'], hash: rawItem['hash']);
    KgSearch.addKgQuality(types, '320k',
        size: rawItem['320filesize'], hash: rawItem['320hash']);
    KgSearch.addKgQuality(types, 'flac',
        size: rawItem['sqfilesize'], hash: rawItem['sqhash']);
    KgSearch.addKgQuality(types, 'flac24bit',
        size: rawItem['filesize_high'], hash: rawItem['hash_high']);

    final singers = rawItem['authors'];
    final singerNames = <String>[];
    if (singers is List) {
      for (final singer in singers) {
        final name = (singer is Map ? singer['author_name'] : null)?.toString();
        if (name != null && name.isNotEmpty) {
          singerNames.add(decodeName(name));
        }
      }
    }
    final singer = singerNames.join('、');
    final duration =
        int.tryParse(rawItem['duration']?.toString() ?? '') ?? 0;
    return KgSearch.buildTrack(
      songId: rawItem['audio_id']?.toString() ?? '',
      name: decodeName(rawItem['songname']?.toString()),
      artist: singer,
      album: decodeName(rawItem['remark']?.toString()),
      albumId: rawItem['album_id']?.toString() ?? '',
      hash: rawItem['hash']?.toString() ?? '',
      intervalText: formatPlayTime(duration),
      duration: duration > 0 ? Duration(seconds: duration) : null,
      types: types,
    );
  }

  // ————————————————————————— 歌单 —————————————————————————

  @override
  Future<DiscoverTags> tags() {
    return BuiltinSearch.transport.cached('kg:tags', () async {
      final body = await lxHttpGet(
        'http://www2.kugou.kugou.com/yueku/v9/special/getSpecial?is_smarty=1&',
      );
      if (body is! Map || body['status'] != 1) {
        throw StateError('kg 标签获取失败');
      }
      final data = body['data'];
      if (data is! Map) throw StateError('kg 标签解析失败');
      return DiscoverTags(
        hotTags: filterInfoHotTag(data['hotTag']),
        categories: filterTagInfo(data['tagids']),
      );
    });
  }

  /// 解析热门标签（独立出来便于单元测试）。
  static List<DiscoverTag> filterInfoHotTag(dynamic rawData) {
    if (rawData is! Map || rawData['status'] != 1) return const [];
    final data = rawData['data'];
    if (data is! Map) return const [];
    final result = <DiscoverTag>[];
    for (final key in data.keys) {
      final tag = data[key];
      if (tag is! Map) continue;
      final id = tag['special_id']?.toString() ?? '';
      final name = tag['special_name']?.toString() ?? '';
      if (id.isEmpty || name.isEmpty) continue;
      result.add(DiscoverTag(id: id, name: name));
    }
    return result;
  }

  /// 解析标签目录（独立出来便于单元测试）。
  static List<DiscoverTagCategory> filterTagInfo(dynamic rawData) {
    if (rawData is! Map) return const [];
    final result = <DiscoverTagCategory>[];
    for (final name in rawData.keys) {
      final group = rawData[name];
      if (group is! Map) continue;
      final items = group['data'];
      result.add(DiscoverTagCategory(
        name: name.toString(),
        tags: [
          for (final tag in (items is List ? items : const []))
            if (tag is Map)
              DiscoverTag(
                id: (tag['id'] ?? '').toString(),
                name: (tag['name'] ?? '').toString(),
              ),
        ],
      ));
    }
    return result;
  }

  @override
  Future<DiscoverPlaylistPage> playlists(String tagId, int page) {
    return BuiltinSearch.transport.cached('kg:playlists:$tagId:$page', () async {
      final list = await _fetchSongList(tagId, page);
      final info = tagId.isEmpty ? null : await _fetchListInfo(tagId);
      final total = parseSourceCount(info?['total']) ?? list.length;
      final limit = parseSourceCount(info?['pagesize']) ?? _limitList;
      return DiscoverPlaylistPage(
        playlists: [
          for (final item in list)
            if (filterListItem(item) case final playlist?) playlist,
        ],
        page: page,
        limit: limit,
        total: total,
      );
    });
  }

  static Future<List<dynamic>> _fetchSongList(String tagId, int page) {
    return retryRequest(
      maxTries: 3,
      attempt: (_) async {
        // LX 默认排序 = 推荐（t=5）。
        final body = await lxHttpGet(
          'http://www2.kugou.kugou.com/yueku/v9/special/getSpecial'
          '?is_ajax=1&cdn=cdn&t=5&c=$tagId&p=$page',
        );
        if (body is! Map || body['status'] != 1) return null;
        final list = body['special_db'];
        if (list is! List) return null;
        return list;
      },
    );
  }

  static Future<Map<String, dynamic>?> _fetchListInfo(String tagId) async {
    try {
      final body = await lxHttpGet(
        'http://www2.kugou.kugou.com/yueku/v9/special/getSpecial'
        '?is_smarty=1&cdn=cdn&t=5&c=$tagId',
      );
      if (body is! Map || body['status'] != 1) return null;
      final params = (body['data'] is Map) ? (body['data'] as Map)['params'] : null;
      return params is Map ? params.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  /// 解析歌单概要（独立出来便于单元测试）。
  static DiscoverPlaylist? filterListItem(dynamic item) {
    if (item is! Map) return null;
    final id = item['specialid']?.toString() ?? '';
    if (id.isEmpty) return null;
    final img = (item['img'] ?? item['imgurl'])?.toString();
    return DiscoverPlaylist(
      id: 'id_$id',
      name: (item['specialname'] ?? '').toString(),
      coverUrl: (img == null || img.isEmpty) ? null : img,
      author: (item['nickname'] ?? '').toString(),
      playCount: parseSourceCount(item['total_play_count'] ?? item['play_count']) ?? 0,
      trackCount: parseSourceCount(item['songcount']) ?? 0,
      description: (item['intro']?.toString().isNotEmpty ?? false)
          ? item['intro'].toString()
          : null,
    );
  }

  @override
  Future<DiscoverPlaylistPage> searchPlaylists(String keyword, int page) {
    return BuiltinSearch.transport.cached('kg:playlist-search:$keyword:$page', () async {
      final body = await lxHttpGet(
        'http://msearchretry.kugou.com/api/v3/search/special'
        '?keyword=${Uri.encodeComponent(keyword)}&page=$page&pagesize=20'
        '&showtype=10&filter=0&version=7910&sver=2',
      );
      if (body is! Map || body['errcode'] != 0) {
        throw StateError('kg 歌单搜索失败');
      }
      final data = body['data'];
      final items = (data is Map) ? data['info'] : null;
      return DiscoverPlaylistPage(
        playlists: [
          for (final item in (items is List ? items : const []))
            if (filterSearchItem(item) case final playlist?) playlist,
        ],
        page: page,
        limit: 20,
        total: (data is Map ? parseSourceCount(data['total']) : null) ?? 0,
      );
    });
  }

  /// 解析歌单搜索结果（独立出来便于单元测试）。
  static DiscoverPlaylist? filterSearchItem(dynamic item) {
    if (item is! Map) return null;
    final id = item['specialid']?.toString() ?? '';
    if (id.isEmpty) return null;
    final img = item['imgurl']?.toString();
    return DiscoverPlaylist(
      id: 'id_$id',
      name: (item['specialname'] ?? '').toString(),
      coverUrl: (img == null || img.isEmpty) ? null : img,
      author: (item['nickname'] ?? '').toString(),
      playCount: parseSourceCount(item['playcount']) ?? 0,
      trackCount: parseSourceCount(item['songcount']) ?? 0,
      description: (item['intro']?.toString().isNotEmpty ?? false)
          ? item['intro'].toString()
          : null,
    );
  }

  @override
  Future<DiscoverDetail> playlistDetail(String rawId, int page) {
    final id = _parseSpecialId(rawId);
    if (id == null) throw StateError('kg 歌单 id 解析失败');
    return BuiltinSearch.transport.cached('kg:playlist-detail:$id', () {
      return _fetchDetailBySpecialId(id);
    });
  }

  /// 从 `id_123` / `special/single/123-5-9999.html` / 纯数字中提取 specialid。
  static String? _parseSpecialId(String rawId) {
    if (rawId.startsWith('id_')) return rawId.substring(3);
    final match = RegExp(r'/(\d+)-5-9999\.html').firstMatch(rawId) ??
        RegExp(r'special/single/(\d+)').firstMatch(rawId);
    if (match != null) return match.group(1);
    if (RegExp(r'^\d+$').hasMatch(rawId)) return rawId;
    return null;
  }

  static Future<DiscoverDetail> _fetchDetailBySpecialId(String id) {
    return retryRequest(
      maxTries: 3,
      attempt: (_) async {
        final html = await lxHttpGetText(
          'http://www2.kugou.kugou.com/yueku/v9/special/single/$id-5-9999.html',
        );
        final dataMatch = _listDataExp.firstMatch(html);
        if (dataMatch == null) return null;
        final rawList = jsonDecode(dataMatch.group(1)!) as List;
        final hashes = <Map<String, dynamic>>[
          for (final item in rawList)
            if (item is Map && item['hash'] != null)
              {'hash': item['hash'].toString()},
        ];
        final tracks = await _fetchMusicInfos(hashes);
        final infoMatch = _listInfoExp.firstMatch(html);
        return DiscoverDetail(
          info: DiscoverPlaylist(
            id: 'id_$id',
            name: infoMatch?.group(1) ?? '',
            coverUrl: infoMatch?.group(2),
            author: '',
            playCount: 0,
            trackCount: tracks.length,
            description: _parseHtmlDesc(html),
          ),
          tracks: [
            for (final track in tracks) discoverTrackOf(track),
          ],
        );
      },
    );
  }

  static String? _parseHtmlDesc(String html) {
    const prefix =
        '<div class="pc_specail_text pc_singer_tab_content" id="specailIntroduceWrap">';
    final start = html.indexOf(prefix);
    if (start < 0) return null;
    final after = html.substring(start + prefix.length);
    final end = after.indexOf('</div>');
    if (end < 0) return null;
    return decodeName(after.substring(0, end));
  }

  /// 通过 gateway 批量补充歌曲信息（hash → 曲目；每批 100）。
  ///
  /// 全部批次为空（且有待取 hash）视为失败并重试；最后一次尝试允许空结果。
  static Future<List<SourceTrack>> _fetchMusicInfos(
    List<Map<String, dynamic>> hashes,
  ) {
    const maxTries = 3;
    return retryRequest(
      maxTries: maxTries,
      attempt: (tryNum) async {
        final tracks = <SourceTrack>[];
        for (var i = 0; i < hashes.length; i += _limitSong) {
          final chunk = hashes.sublist(
            i,
            (i + _limitSong) > hashes.length ? hashes.length : i + _limitSong,
          );
          final body = await lxHttpPost(
            'http://gateway.kugou.com/v2/album_audio/audio',
            headers: {
              'KG-THash': '13a3164',
              'KG-RC': '1',
              'KG-Fake': '0',
              'KG-RF': '00869891',
              'User-Agent':
                  'Android712-AndroidPhone-11451-376-0-FeeCacheUpdate-wifi',
              'x-router': 'kmr.service.kugou.com',
            },
            body: {
              'area_code': '1',
              'show_privilege': 1,
              'show_album_info': '1',
              'is_publish': '',
              'appid': 1005,
              'clientver': 11451,
              'mid': '1',
              'dfid': '-',
              'clienttime': DateTime.now().millisecondsSinceEpoch,
              'key': _gatewayKey,
              'fields':
                  'album_info,author_name,audio_info,ori_audio_name,base,songname',
              'data': chunk,
            },
          );
          if (body is! Map || body['status'] != 1) continue;
          final data = body['data'];
          if (data is! List) continue;
          for (final group in data) {
            if (group is! List || group.isEmpty) continue;
            final track = filterData2Item(group[0]);
            if (track != null) tracks.add(track);
          }
        }
        if (tracks.isEmpty && hashes.isNotEmpty && tryNum < maxTries - 1) {
          return null;
        }
        return tracks;
      },
    );
  }

  /// 解析 gateway 歌曲信息（`kg/songList.js` filterData2；便于单元测试）。
  static SourceTrack? filterData2Item(dynamic item) {
    if (item is! Map) return null;
    final audio = item['audio_info'];
    final album = item['album_info'];
    if (audio is! Map) return null;

    final types = <String, Map<String, dynamic>>{};
    KgSearch.addKgQuality(types, '128k',
        size: audio['filesize'], hash: audio['hash']);
    KgSearch.addKgQuality(types, '320k',
        size: audio['filesize_320'], hash: audio['hash_320']);
    KgSearch.addKgQuality(types, 'flac',
        size: audio['filesize_flac'], hash: audio['hash_flac']);
    KgSearch.addKgQuality(types, 'flac24bit',
        size: audio['filesize_high'], hash: audio['hash_high']);

    final name = decodeName(item['songname']?.toString());
    final singer = decodeName(item['author_name']?.toString());
    final albumName =
        decodeName(album is Map ? album['album_name']?.toString() : '');
    final durationMs =
        int.tryParse(audio['timelength']?.toString() ?? '') ?? 0;

    return KgSearch.buildTrack(
      songId: audio['audio_id']?.toString() ?? '',
      name: name,
      artist: singer,
      album: albumName,
      albumId: album is Map ? album['album_id']?.toString() ?? '' : '',
      hash: audio['hash']?.toString() ?? '',
      intervalText: durationMs > 0
          ? formatPlayTime((durationMs / 1000).floor())
          : null,
      duration: durationMs > 0 ? Duration(milliseconds: durationMs) : null,
      types: types,
    );
  }

  // ————————————————————————— 热搜 —————————————————————————

  @override
  Future<List<String>> hotSearches() {
    return BuiltinSearch.transport.cached('kg:hot-search', _fetchHotSearch);
  }

  static Future<List<String>> _fetchHotSearch() {
    return retryRequest(
      maxTries: 3,
      attempt: (_) async {
        final body = await lxHttpGet(
          'http://gateway.kugou.com/api/v3/search/hot_tab'
          '?signature=ee44edb9d7155821412d220bcaf509dd&appid=1005'
          '&clientver=10026&plat=0',
          headers: {
            'dfid': '1ssiv93oVqMp27cirf2CvoF1',
            'mid': '156798703528610303473757548878786007104',
            'clienttime': '1584257267',
            'x-router': 'msearch.kugou.com',
            'user-agent':
                'Android9-AndroidPhone-10020-130-0-searchrecommendprotocol-wifi',
            'kg-rc': '1',
          },
        );
        if (body is! Map || body['errcode'] != 0) return null;
        final data = body['data'];
        final rawList = (data is Map) ? data['list'] : null;
        if (rawList is! List) return null;
        final words = <String>[];
        for (final item in rawList) {
          if (item is! Map) continue;
          final keywords = item['keywords'];
          if (keywords is! List) continue;
          for (final keyword in keywords) {
            if (keyword is Map && keyword['keyword'] != null) {
              words.add(decodeName(keyword['keyword'].toString()));
            }
          }
        }
        return words;
      },
    );
  }
}
