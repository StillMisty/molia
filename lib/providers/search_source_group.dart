/// 跨音源聚合搜索的只读分组投影：一个来源在当前搜索类型下的已加载结果。
///
/// provider 不把三种行形状混进同一个泛型列表；UI 按来源分组渲染时，只读
/// 这一份不可变快照。分页 / 失败 / 加载态都来自该来源自己的分页执行体，
/// 因此一个平台失败或到底不会影响其它平台。
library;

import '../domain/models/failure.dart';
import '../domain/models/source.dart';

class SearchSourceGroup<T> {
  const SearchSourceGroup({
    required this.source,
    required this.items,
    this.failure,
    this.isLoading = false,
    this.hasMore = false,
    this.isLoadingMore = false,
    this.loadMoreFailed = false,
    this.total,
    this.page = 0,
  });

  /// 该分组对应的渠道描述（顺序 / 展示名 / 能力位来自同一份 registry 快照）。
  final SourceDescriptor source;

  final List<T> items;

  /// 首屏归一化失败。首屏失败时该来源没有新页；追加页失败只体现在
  /// [loadMoreFailed]，[items] 保留已加载的行。
  final SourceFailure? failure;

  /// 首屏加载中。
  final bool isLoading;

  final bool hasMore;
  final bool isLoadingMore;
  final bool loadMoreFailed;

  /// 平台返回的总数（部分平台 / 脚本不返回则为 null）。
  final int? total;

  /// 已成功加载到第几页（0 = 尚未加载成功）。
  final int page;

  bool get isEmpty => page > 0 && items.isEmpty && failure == null;
}
