/// 播放兼容 map 的读取工具（`currentTrack` / 队列项等统一形状）。
library;

/// 取兼容 map 的首张封面 URL。
///
/// `album.images` 可能为空列表（曲目无封面）或字段缺失；
/// 不要写成 `images?[0]?['url']`——空列表上取下标会抛 RangeError。
String? trackMapImageUrl(Map<String, dynamic>? track) {
  final album = track?['album'];
  if (album is! Map) return null;
  final images = album['images'];
  if (images is! List || images.isEmpty) return null;
  final first = images.first;
  if (first is! Map) return null;
  final url = first['url'];
  return (url is String && url.isNotEmpty) ? url : null;
}

/// 取兼容 map 的第一位歌手名（`artists` 可能为空列表或缺字段）。
String? trackMapFirstArtistName(Map<String, dynamic>? track) {
  final artists = track?['artists'];
  if (artists is! List || artists.isEmpty) return null;
  final first = artists.first;
  if (first is! Map) return null;
  final name = first['name'];
  return (name is String && name.isNotEmpty) ? name : null;
}
