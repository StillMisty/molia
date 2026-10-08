import '../source_search_result.dart';
import '../source_track.dart';

/// 解析 LX 脚本扩展搜索的返回数据（社区约定，字段兼容性尽力而为）。
///
/// 从 `SourceManager` 拆出的纯函数（无宿主状态）：优先识别
/// isEnd / hasMore / total，兼容 `{ data: { list: [...], total: n } }`
/// 之类的两层结构；无法识别的条目跳过。
SourceSearchResult parseLxSearchResult(
  String sourceKey,
  dynamic data, {
  int page = 1,
  int limit = 20,
}) {
  List<dynamic> rawList;
  int? total;
  bool? isEnd;

  if (data is List) {
    rawList = data;
  } else if (data is Map) {
    final candidate = data['list'] ??
        data['data'] ??
        data['songs'] ??
        data['result'] ??
        data['results'];
    if (candidate is List) {
      rawList = candidate;
    } else if (candidate is Map) {
      // 兼容 { data: { list: [...], total: n } } 之类的两层结构
      final nested = candidate['list'] ??
          candidate['data'] ??
          candidate['songs'] ??
          candidate['result'] ??
          candidate['results'];
      rawList = nested is List ? nested : const [];
      total = parseSourceCount(candidate['total'] ??
          candidate['totalCount'] ??
          candidate['total_count']);
      isEnd = parseSourceBool(candidate['isEnd'] ??
          candidate['is_end'] ??
          candidate['end'] ??
          candidate['noMore']);
    } else {
      rawList = const [];
    }

    total ??= parseSourceCount(
        data['total'] ?? data['totalCount'] ?? data['total_count']);
    isEnd ??= parseSourceBool(data['isEnd'] ??
        data['is_end'] ??
        data['end'] ??
        data['noMore']);
    if (isEnd == null) {
      // hasMore 语义与 isEnd 相反
      final hasMore = parseSourceBool(data['hasMore'] ?? data['has_more']);
      if (hasMore != null) isEnd = !hasMore;
    }
  } else {
    rawList = const [];
  }

  final tracks = <SourceTrack>[];
  for (final item in rawList) {
    if (item is! Map) continue;
    final title =
        (item['name'] ?? item['title'] ?? item['songName'])?.toString() ?? '';
    if (title.trim().isEmpty) continue;

    final artist = (item['singer'] ??
            item['artist'] ??
            item['artists'] ??
            item['singerName'])
        ?.toString() ??
        '';
    final album =
        (item['albumName'] ?? item['album'] ?? item['album_name'])
                ?.toString() ??
            '';
    final cover =
        (item['img'] ?? item['pic'] ?? item['cover'] ?? item['picUrl'])
            ?.toString();
    final interval = item['interval'] ?? item['duration'];
    Duration? duration;
    if (interval is String && interval.contains(':')) {
      final parts = interval.split(':');
      if (parts.length >= 2) {
        final m = int.tryParse(parts[0]) ?? 0;
        final s = int.tryParse(parts[1].split('.').first) ?? 0;
        duration = Duration(minutes: m, seconds: s);
      }
    } else if (interval is num) {
      duration = Duration(seconds: interval.toInt());
    }

    final raw = item.map((key, value) => MapEntry(key.toString(), value));
    final rawSource = raw['source']?.toString();
    tracks.add(SourceTrack(
      sourceKey: sourceKey,
      origin: 'lx',
      title: title,
      artist: artist,
      album: album,
      coverUrl: (cover?.isNotEmpty ?? false) ? cover : null,
      duration: duration,
      raw: rawSource == null ? {...raw, 'source': sourceKey} : raw,
    ));
  }
  return SourceSearchResult.fromPage(
    tracks: tracks,
    page: page,
    limit: limit,
    total: total,
    isEnd: isEnd,
  );
}
