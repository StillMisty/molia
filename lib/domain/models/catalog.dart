import 'equality.dart';
import 'track.dart';

/// 搜索类型（搜索页「单曲 / 歌手 / 歌词」分段）。
///
/// 各类型的可取性与分页相互独立：能力位在 `SourceCapabilities`
/// （song 恒有；artist / lyricSearch 按平台），UI 按能力位显隐分段。
enum SearchKind { song, artist, lyric }

/// 按歌词搜歌的命中项（曲目 + 命中的歌词片段；平台未返回片段时为 null）。
class LyricHit {
  final Track track;
  final String? snippet;

  const LyricHit({required this.track, this.snippet});

  @override
  bool operator ==(Object other) =>
      other is LyricHit && other.track == track && other.snippet == snippet;

  @override
  int get hashCode => Object.hash(track, snippet);

  @override
  String toString() => 'LyricHit(${track.id}, $snippet)';
}

/// 搜索请求（page 从 1 开始）。
class SearchQuery {
  final String keyword;
  final int page;
  final int limit;

  const SearchQuery({required this.keyword, this.page = 1, this.limit = 30});

  @override
  bool operator ==(Object other) =>
      other is SearchQuery &&
      other.keyword == keyword &&
      other.page == page &&
      other.limit == limit;

  @override
  int get hashCode => Object.hash(keyword, page, limit);
}

/// 统一搜索结果（items/hasMore/total），承接现有 `SourceSearchResult` 语义。
class SearchResult<T> {
  final List<T> items;
  final bool hasMore;
  final int? total;

  const SearchResult({required this.items, this.hasMore = false, this.total});

  static SearchResult<T> empty<T>() => SearchResult<T>(items: const []);

  @override
  bool operator ==(Object other) =>
      other is SearchResult<T> &&
      deepEquals(other.items, items) &&
      other.hasMore == hasMore &&
      other.total == total;

  @override
  int get hashCode => Object.hash(deepHash(items), hasMore, total);
}
