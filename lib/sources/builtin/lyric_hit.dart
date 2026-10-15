/// 歌词搜索的命中项与一页结果（对齐 `ArtistSearchPage` 形状）。
///
/// 失败语义：平台业务拒绝 / 传输失败**抛 SourceFailure**（不静默吞成空
/// 结果——与单曲搜索的 `SourceSearchResult.failed` 区分：歌词结果行没有
/// 「部分失败」语义，UI 直接进错误态可重试）。
library;

import '../source_track.dart';

/// 歌词搜索命中项：曲目 + 命中的歌词片段（平台未返回时为 null）。
class SourceLyricHit {
  final SourceTrack track;
  final String? snippet;

  const SourceLyricHit({required this.track, this.snippet});

  @override
  bool operator ==(Object other) =>
      other is SourceLyricHit &&
      other.track == track &&
      other.snippet == snippet;

  @override
  int get hashCode => Object.hash(track, snippet);

  @override
  String toString() => 'SourceLyricHit(${track.id}, $snippet)';
}

/// 歌词搜索的一页结果。
class LyricSearchPage {
  final List<SourceLyricHit> hits;

  /// 是否还有下一页（平台无总数时按「本页取满」近似）。
  final bool hasMore;

  /// 平台返回的结果总数（部分平台不返回时为 null）。
  final int? total;

  const LyricSearchPage({
    required this.hits,
    this.hasMore = false,
    this.total,
  });

  static const LyricSearchPage empty = LyricSearchPage(hits: []);
}
