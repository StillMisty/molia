/// 一种搜索类型（单曲 / 歌手 / 歌词）的分页分支。
///
/// 共享扇出会话 + 「条目 → UI 行」投影。三种搜索类型的行形状不同，类型
/// 参数只活在这里：provider 用 [kind] 索引控制面调度查询 / 分页 / 重试，
/// 按类型 getter 读分组。
library;

import '../domain/models/catalog.dart' show SearchKind;
import '../domain/models/source.dart';
import 'search_source_group.dart';
import 'source_fan_out.dart';

class SearchBranch<T, R> {
  SearchBranch({
    required this.kind,
    required this.session,
    required this._project,
  });

  final SearchKind kind;

  /// 该类型的跨来源扇出会话（每个来源一个分页执行体）。
  final FanOutSearchSession<T> session;

  final R Function(T item) _project;

  /// 按给定顺序把已开始的来源投影成只读分组；未开始来源不出现。
  List<SearchSourceGroup<R>> groups(Iterable<SourceDescriptor> descriptors) {
    final groups = <SearchSourceGroup<R>>[];
    for (final descriptor in descriptors) {
      final state = session.stateOf(descriptor.key);
      if (state == null) continue;
      groups.add(
        SearchSourceGroup<R>(
          source: descriptor,
          items: List<R>.unmodifiable([
            for (final item in state.items) _project(item),
          ]),
          failure: state.failure,
          isLoading: state.isLoading,
          hasMore: state.hasMore,
          isLoadingMore: state.isLoadingMore,
          loadMoreFailed: state.loadMoreFailed,
          total: state.total,
          page: state.page,
        ),
      );
    }
    return List.unmodifiable(groups);
  }
}
