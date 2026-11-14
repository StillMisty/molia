/// 汽水音乐专辑（`GET https://www.qishui.com/share/album?album_id=` 分享页 SSR）。
///
/// 汽水没有匿名的专辑详情 API；分享页的 `_ROUTER_DATA.album_page` 一次给出
/// 专辑元信息与完整曲目表（实测 23 首专辑仍完整），因此无分页。
/// 曲目实体的字段与搜索响应一致，解析复用 [QsTrack]。
library;

import '../../data/mapping/track_mapper.dart';
import '../../domain/models/album.dart';
import 'album_utils.dart';
import 'qs_api.dart';
import 'qs_track.dart';

class QsAlbum {
  QsAlbum._();

  static Future<Album> fetch(
    String albumId, {
    int page = 1,
    int limit = kAlbumPageSize,
  }) async {
    final loader = await QsApi.shareLoaderData('/share/album', {
      'album_id': albumId,
    });
    return parse(loader['album_page'], albumId: albumId);
  }

  /// 分享页 `album_page` → 领域专辑（供单测复用）。
  ///
  /// `hasMore` 恒为 false：平台没有第二页可取；页面若被平台截断，只能展示
  /// 截断后的曲目，不伪造分页。
  static Album parse(Object? page, {required String albumId}) {
    if (page is! Map) throw albumPlatformFailure('qs', '专辑数据结构不符');
    final info = page['albumInfo'];
    if (info is! Map) throw albumPlatformFailure('qs', '专辑数据结构不符');

    final id = info['id']?.toString() ?? albumId;
    final name = info['name']?.toString() ?? '';
    final cover = QsTrack.imageUrlOf(info['url_cover']);
    final tracks = [
      for (final track in QsTrack.parseList(
        page['trackList'],
        albumName: name,
        albumId: id,
        cover: cover,
      ))
        trackFromSourceTrack(track),
    ];

    return Album(
      id: id,
      name: name,
      artist: QsTrack.joinArtists(info['artists']),
      coverUrl: cover,
      year: _yearOf(info['release_date']),
      tracks: tracks,
      hasMore: false,
    );
  }

  /// `release_date` 是秒级时间戳；归一成毫秒后交给共享年份解析。
  static int? _yearOf(Object? releaseDate) {
    if (releaseDate is num) {
      final seconds = releaseDate.toInt();
      if (seconds > 0) {
        return albumYearOf(seconds * 1000);
      }
    }
    return null;
  }
}
