import 'equality.dart';

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
