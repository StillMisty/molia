import 'dart:convert';

import '../../data/mapping/track_mapper.dart';
import '../../domain/models/album.dart';
import '../../domain/models/track.dart';
import '../source_search_result.dart';
import 'album_utils.dart';
import 'builtin_search.dart';
import 'builtin_transport.dart';
import 'tx_search.dart';

/// QQ 音乐专辑（模块 `music.musichallAlbum.AlbumSongList`）。
///
/// 接口：`GET https://u.y.qq.com/cgi-bin/musicu.fcg?data={...}`，模块
/// `music.musichallAlbum.AlbumSongList` + `albumMid` + `begin/num` 分页
/// （开发环境已抓到真实响应，见 test/fixtures/albums/tx.json）。
///
/// 响应 `albumSonglist.data.songList[].songInfo` 与搜索条目同构，解析复用
/// [TxSearch.parseSongItem]（取链字段 / 音质约定完全一致）。
/// 注：LX 无 tx 专辑实现；`music.musichall.AlbumInter` 等旧模块在本环境返回
/// 500003（860100001），此模块为本环境实测可用端点，仍需真机复验。
class TxAlbum {
  TxAlbum._();

  static const String _url = 'https://u.y.qq.com/cgi-bin/musicu.fcg';
  static const String _module = 'music.musichallAlbum.AlbumSongList';
  static const Map<String, String> _headers = {
    'User-Agent': 'QQMusic 14090508(android 12)',
  };

  static Future<Album> fetch(
    String albumMid, {
    int page = 1,
    int limit = kAlbumPageSize,
  }) async {
    final payload = <String, dynamic>{
      'comm': {'ct': 24, 'cv': 10000},
      'albumSonglist': {
        'module': _module,
        'method': 'GetAlbumSongList',
        'param': {
          'albumMid': albumMid,
          'albumID': 0,
          'begin': limit * (page - 1),
          'num': limit,
          'order': 2,
        },
      },
    };
    final url = '$_url?g_tk=5381&format=json&inCharset=utf8&outCharset=utf-8'
        '&data=${Uri.encodeComponent(jsonEncode(payload))}';
    final body = await lxHttpGet(
      url,
      headers: _headers,
      retries: BuiltinTransport.defaultRetries,
      retryIf: _isInvalid,
    );
    return parse(body, albumMid: albumMid, page: page, limit: limit);
  }

  static bool _isInvalid(dynamic response) {
    if (response is! Map) return true;
    final section = response['albumSonglist'];
    return response['code'] != 0 || (section is Map && section['code'] != 0);
  }

  /// 专辑响应 → 领域模型（供单测复用）。
  static Album parse(
    dynamic body, {
    required String albumMid,
    int page = 1,
    int limit = kAlbumPageSize,
  }) {
    if (body is! Map || body['code'] != 0) {
      throw albumPlatformFailure(
        'tx',
        '获取专辑失败（code=${body is Map ? body['code'] : '非 JSON'}）',
      );
    }
    final section = body['albumSonglist'];
    if (section is! Map || section['code'] != 0) {
      throw albumPlatformFailure(
        'tx',
        '获取专辑失败（subcode=${section is Map ? section['subcode'] : '无'}）',
      );
    }
    final data = section['data'];
    if (data is! Map) throw albumPlatformFailure('tx', '专辑数据结构不符');

    final rawList = data['songList'] is List ? data['songList'] as List : const [];
    final tracks = <Track>[];
    Map<String, dynamic>? firstInfo;
    for (final item in rawList) {
      final info = item is Map ? item['songInfo'] : null;
      if (info is! Map) continue;
      final typed = Map<String, dynamic>.from(info);
      firstInfo ??= typed;
      final track = TxSearch.parseSongItem(typed);
      if (track != null) tracks.add(trackFromSourceTrack(track));
    }

    // 专辑元信息取首条歌曲内嵌的 album / singer（平台随曲目返回）。
    final album = firstInfo?['album'];
    final mid = (data['albumMid'] ?? (album is Map ? album['mid'] : null) ??
            albumMid)
        .toString();
    final total = parseSourceCount(data['totalNum']);
    return Album(
      id: mid,
      name: album is Map ? album['name']?.toString() ?? '' : '',
      artist: firstInfo == null ? '' : _joinSingers(firstInfo['singer']),
      coverUrl: _coverOf(mid),
      year: albumYearOf(
        firstInfo?['time_public'] ??
            (album is Map ? album['time_public'] : null),
      ),
      tracks: tracks,
      hasMore: albumHasMore(page: page, limit: limit, total: total),
    );
  }

  /// 专辑封面（与搜索 / 取图同一拼装约定）。
  static String? _coverOf(String albumMid) {
    if (albumMid.isEmpty || albumMid == '空') return null;
    return 'https://y.gtimg.cn/music/photo_new/T002R500x500M000$albumMid.jpg';
  }

  static String _joinSingers(Object? singers) {
    if (singers is! List) return '';
    final names = <String>[];
    for (final singer in singers) {
      final name = singer is Map ? singer['name']?.toString() : null;
      if (name != null && name.isNotEmpty) names.add(name);
    }
    return names.join('、');
  }
}
