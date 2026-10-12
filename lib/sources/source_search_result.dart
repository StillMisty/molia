import '../domain/models/failure.dart';
import 'source_track.dart';

/// 音源搜索结果（携带分页信息）。
///
/// [tracks] 为当前页的曲目；[hasMore] 表示是否可能还有下一页；
/// [total] 为平台返回的结果总数（部分平台仅在首页返回，可能为空）。
///
/// [failure] 非空表示这次搜索**失败**（请求异常或平台业务拒绝），与「平台
/// 正常返回但没有结果」（tracks 为空、failure 为空）是两回事——内置检索
/// runner 是唯一区分点（`builtin_search_runner.dart`）。
class SourceSearchResult {
  final List<SourceTrack> tracks;
  final bool hasMore;
  final int? total;

  /// 失败语义（延迟消费：UI 收口前仍只读 tracks，失败由后续版本展示）。
  final SourceFailure? failure;

  const SourceSearchResult({
    required this.tracks,
    this.hasMore = false,
    this.total,
    this.failure,
  });

  static const SourceSearchResult empty = SourceSearchResult(tracks: []);

  /// 失败结果（无曲目、带归一化失败）。
  factory SourceSearchResult.failed(SourceFailure failure) =>
      SourceSearchResult(tracks: const [], failure: failure);

  /// 依据平台返回的 [total] / [isEnd] / 本页曲目数推断是否还有下一页。
  ///
  /// 优先级：明确的 [isEnd] > 总数 [total] > 本页是否装满 [tracks.length >= limit]。
  /// LX 脚本扩展搜索的返回格式是社区约定，无明确分页信息时只能近似判断。
  factory SourceSearchResult.fromPage({
    required List<SourceTrack> tracks,
    required int page,
    required int limit,
    int? total,
    bool? isEnd,
  }) {
    bool hasMore;
    if (isEnd != null) {
      hasMore = !isEnd;
    } else if (total != null) {
      hasMore = page * limit < total;
    } else {
      hasMore = tracks.length >= limit;
    }
    return SourceSearchResult(tracks: tracks, total: total, hasMore: hasMore);
  }
}

/// 把平台返回的计数（可能是 int / num / String）转为 int；无法解析返回 null。
int? parseSourceCount(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

/// 把平台/脚本返回的布尔字段（bool 或 0/1）转为 bool；无法解析返回 null。
bool? parseSourceBool(dynamic value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    switch (value.trim().toLowerCase()) {
      case 'true':
      case '1':
        return true;
      case 'false':
      case '0':
        return false;
    }
  }
  return null;
}
