/// 内置平台原生取图的派发入口（五平台：wy / tx / kg / kw / mg）。
///
/// 从 `SourceManager` 拆出：5 路 switch（曲目 raw 字段 → 各 `*_pic.dart` /
/// 歌曲详情接口）、结果归一化与 5 分钟 TTL 缓存（key `{track.id}:pic`）
/// 在这里只有一处实现；`SourceManager.fetchPic` 的脚本回退只调用 [fetch]。
///
/// 失败语义与迁移前逐条一致：
/// - 非内置平台 / 平台缺少拼图所需字段 → null；
/// - 取图链路抛错 → null（交由上层继续回退）；失败不进缓存
///   （下次调用会重试，见 `RequestCache` 的契约）。
library;

import '../../data/cache/request_cache.dart';
import '../source_track.dart';
import 'bili_track.dart';
import 'builtin_search.dart';
import 'kg_pic.dart';
import 'kw_pic.dart';
import 'mg_lyric.dart';
import 'wy_music_detail.dart';

class BuiltinPicDispatch {
  BuiltinPicDispatch({RequestCache? cache})
      : _cache = cache ??
            RequestCache(maxEntries: 128, ttl: const Duration(minutes: 5));

  /// 曲目原生取图缓存（key `{track.id}:pic`）。
  final RequestCache _cache;

  /// 内置平台原生封面回退（不支持 / 失败返回 null）。
  Future<String?> fetch(SourceTrack track) async {
    if (!BuiltinSearch.isBuiltin(track.sourceKey)) return null;
    try {
      return await _cache.getOrCreate<String?>(
          '${track.id}:pic', () => _fetchFor(track));
    } catch (_) {
      return null;
    }
  }

  /// 派发到各内置平台的原生取图实现。
  static Future<String?> _fetchFor(SourceTrack track) {
    final raw = track.raw;
    switch (track.sourceKey) {
      case 'wy':
        final songId = raw['songmid'] ?? raw['id'];
        if (songId == null) return Future.value(null);
        return WyMusicDetail.getList([songId]).then(
          (list) => list.isEmpty ? null : list.first.coverUrl,
        );
      case 'tx':
        final albumMid = (raw['albumMid'] ?? raw['albumId'])?.toString();
        if (albumMid != null && albumMid.isNotEmpty && albumMid != '空') {
          return Future.value(
            'https://y.gtimg.cn/music/photo_new/T002R500x500M000$albumMid.jpg',
          );
        }
        return Future.value(null);
      case 'kg':
        return KgPic.fetch(
          songmid: raw['songmid']?.toString() ?? '',
          audioId: raw['audioId']?.toString(),
          albumId: raw['albumId']?.toString(),
          hash: raw['hash']?.toString(),
          name: raw['name']?.toString(),
          singer: raw['singer']?.toString(),
        );
      case 'kw':
        return KwPic.fetch(raw['songmid']?.toString() ?? '');
      case 'mg':
        final img = raw['img']?.toString();
        if (img != null && img.isNotEmpty) return Future.value(img);
        final songId = raw['songmid']?.toString();
        if (songId == null || songId.isEmpty) return Future.value(null);
        return MgLyric.coverOf(songId);
      case 'bili':
        // 搜索 / 收藏夹自带封面：只做 `//` 补协议，不再发请求。
        return Future.value(
          biliCoverUrl(raw['pic'] ?? raw['cover'] ?? raw['img']),
        );
      default:
        return Future.value(null);
    }
  }
}
