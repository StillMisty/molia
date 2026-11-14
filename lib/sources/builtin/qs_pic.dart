/// 汽水音乐封面：搜索 / 歌单 / 专辑响应自带专辑封面，缺封面时按 track_id
/// 取 H5 详情（`seo_track.coverURL`）。
library;

import 'qs_api.dart';
import 'qs_track.dart';

class QsPic {
  QsPic._();

  static Future<String?> fetch(Map<String, dynamic> raw) async {
    final direct = coverOf(raw);
    if (direct != null) return direct;
    final trackId = raw['track_id']?.toString() ?? raw['id']?.toString() ?? '';
    if (trackId.isEmpty) return null;
    final response = await QsApi.getJson(
      '/luna/h5/seo_track',
      query: {'track_id': trackId},
    );
    if (response is! Map) return null;
    final track = response['seo_track'];
    if (track is! Map) return null;
    return QsTrack.imageUrlOf(track['coverURL']);
  }

  /// 实体内已带封面：分享页详情用 `coverURL`，搜索 / 歌单用 `album.url_cover`。
  static String? coverOf(Map<String, dynamic> raw) {
    final direct = QsTrack.imageUrlOf(raw['coverURL'] ?? raw['cover']);
    if (direct != null) return direct;
    final album = raw['album'];
    if (album is! Map) return null;
    return QsTrack.imageUrlOf(album['url_cover'] ?? album['url_player_bg']);
  }
}
