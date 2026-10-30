/// 内置平台「曲目 raw → 原生封面」适配器集合。
///
/// 与 `builtin_lyric_adapters.dart` 同一思路：原先字段派发在
/// `BuiltinPicDispatch._fetchFor` 的六路 switch 里，能力位只能按
/// 「是不是内置平台」笼统为真。现在每个实现登记进 [BuiltinPlatforms]，
/// `capabilities.artwork` 与派发读取同一条目。
///
/// 适配器只挑选 raw 字段（或直接复用搜索响应里的封面），失败返回 null；
/// 缓存与异常归一仍由 `BuiltinPicDispatch` 负责。
library;

import 'bili_track.dart';
import 'builtin_cover_urls.dart';
import 'kg_pic.dart';
import 'kw_pic.dart';
import 'mg_lyric.dart';
import 'wy_music_detail.dart';

/// 网易云：歌曲详情 `al.picUrl`。
Future<String?> wyBuiltinPic(Map<String, dynamic> raw) async {
  final songId = raw['songmid'] ?? raw['id'];
  if (songId == null) return null;
  final list = await WyMusicDetail.getList([songId]);
  return list.isEmpty ? null : list.first.coverUrl;
}

/// QQ 音乐：按专辑 mid 拼静态封面 URL（不发请求）。
Future<String?> txBuiltinPic(Map<String, dynamic> raw) {
  final albumMid = (raw['albumMid'] ?? raw['albumId'])?.toString();
  if (albumMid == null || albumMid.isEmpty || albumMid == '空') {
    return Future.value(null);
  }
  return Future.value(
    'https://y.gtimg.cn/music/photo_new/T002R500x500M000$albumMid.jpg',
  );
}

/// 酷狗：响应内已带封面（`Image` / `sizable_cover`）时直接复用；
/// 否则 `get_res_privilege` 按 hash / album_id 取图。
Future<String?> kgBuiltinPic(Map<String, dynamic> raw) {
  final fromRaw = kgCoverUrlOf(raw);
  if (fromRaw != null) return Future.value(fromRaw);
  return KgPic.fetch(
    songmid: raw['songmid']?.toString() ?? '',
    audioId: (raw['audioId'] ?? raw['albumAudioId'])?.toString(),
    albumId: raw['albumId']?.toString(),
    hash: raw['hash']?.toString(),
    name: raw['name']?.toString(),
    singer: raw['singer']?.toString(),
  );
}

/// 酷我：响应内已带封面时直接复用；否则 pic.web 接口返回纯文本 URL。
Future<String?> kwBuiltinPic(Map<String, dynamic> raw) {
  final fromRaw = kwCoverUrlOf(raw);
  if (fromRaw != null) return Future.value(fromRaw);
  return KwPic.fetch(raw['songmid']?.toString() ?? '');
}

/// 咪咕：搜索响应自带 `img`，否则走资源信息封面。
Future<String?> mgBuiltinPic(Map<String, dynamic> raw) {
  final img = raw['img']?.toString();
  if (img != null && img.isNotEmpty) return Future.value(img);
  final songId = raw['songmid']?.toString();
  if (songId == null || songId.isEmpty) return Future.value(null);
  return MgLyric.coverOf(songId);
}

/// B 站：搜索 / 收藏夹自带封面，只做 `//` 补协议，不再发请求。
Future<String?> biliBuiltinPic(Map<String, dynamic> raw) => Future.value(
      biliCoverUrl(raw['pic'] ?? raw['cover'] ?? raw['img']),
    );
