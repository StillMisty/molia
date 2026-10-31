/// 分页曲目集合：控制器（页实体捕获 + 分页状态）与共享列表体的唯一实现。
///
/// 专辑 / 歌手 / 发现详情三页的头部数据与曲目列表来自同一次响应。实体捕获
/// 收在 [PagedTrackCollection]，正文骨架收在 [PagedTrackCollectionBody]，
/// 页面只保留头部、行与播放动作；分页口径与列表态只有这一份实现。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../providers/paged_list_controller.dart';
import '../utils/responsive.dart';
import 'detail_page/detail_page_chrome.dart';
import 'paged_list_auto_load.dart';
import 'track_row.dart';
import 'track_table_header.dart';

/// 一页曲目响应：曲目列表 + 该响应携带的页实体（专辑 / 歌手 / 发现详情）。
///
/// 实体与曲目必须同页返回：头部展示的名称 / 封面 / 总数随分页响应更新，
/// 拆成两次请求会让头部与列表短暂来自不同页。
@immutable
class PagedTrackPage<T, R> {
  const PagedTrackPage({
    required this.entity,
    required this.items,
    required this.hasMore,
    this.total,
  });

  final T entity;
  final List<R> items;
  final bool hasMore;

  /// 平台声明的结果总数（没有时为 null，由列表按已加载项处理）。
  final int? total;
}

/// 按页取曲目响应（缓存 / 错误边界在注入方的 service）。
typedef PagedTrackPageLoader<T, R> = Future<PagedTrackPage<T, R>> Function(
  int page,
);

/// 曲目分页集合：在 [PagedListController] 上补「页实体」捕获。
///
/// 列表状态仍由 [PagedListController] 负责（在途请求过期丢弃、跨页去重、
/// 首屏 / 加载更多的失败语义）；本类只把成功响应的实体记下来，让头部与列表
/// 读同一份快照。[reset] 同时作废列表与实体的在途响应。
class PagedTrackCollection<T, R> extends ValueNotifier<PagedListState<R>> {
  PagedTrackCollection({
    required this._loadPage,
    required String Function(R item) keyOf,
  }) : super(const PagedListState(hasMore: true)) {
    _inner = PagedListController<R>(fetchPage: _fetchPage, keyOf: keyOf)
      ..addListener(_forward);
  }

  final PagedTrackPageLoader<T, R> _loadPage;
  late final PagedListController<R> _inner;

  /// 最近一次成功响应携带的实体（[reset] 清空）。
  T? _entity;

  /// 包装层的代际：重置 / 销毁后，旧响应连实体也不得回写。
  /// [PagedListController] 只保证列表状态不被旧响应覆盖；实体捕获的过期
  /// 判定必须和它同步，否则会出现「列表是新页、头部是旧页」。
  int _generation = 0;

  /// 当前分页状态（与 [PagedListController.state] 同一个不可变值）。
  PagedListState<R> get state => value;

  List<R> get items => value.items;

  /// 最近一次成功响应的页实体；首屏成功前 / [reset] 后为 null。
  T? get entity => _entity;

  Future<PagedResult<R>> _fetchPage(int page) async {
    final generation = _generation;
    final result = await _loadPage(page);
    if (generation == _generation) _entity = result.entity;
    return PagedResult<R>(
      items: result.items,
      hasMore: result.hasMore,
      total: result.total,
    );
  }

  void _forward() => value = _inner.value;

  Future<void> loadFirstPage() => _inner.loadFirstPage();

  Future<void> loadMore() => _inner.loadMore();

  /// 作废在途请求并清空列表与实体（切换筛选条件时调用）。
  void reset() {
    _generation++;
    _entity = null;
    _inner.reset();
  }

  @override
  void dispose() {
    // 在途请求的实体也不得在销毁后回写。
    _generation++;
    _inner
      ..removeListener(_forward)
      ..dispose();
    super.dispose();
  }
}

/// 分页曲目列表的共享正文：加载 / 首屏失败 / 空态 / 列表 / 底部重试。
///
/// 三个详情页只有头部、行与文案不同；滚动容器、固定行高、可选钉住表头与
/// 页脚的组合方式收在这里。宿主只给 [state] 与回调，行高与表头列宽的口径
/// 也随之同源。
class PagedTrackCollectionBody<R> extends StatefulWidget {
  const PagedTrackCollectionBody({
    super.key,
    required this.state,
    required this.headerBuilder,
    required this.rowBuilder,
    required this.onRetry,
    required this.onLoadMore,
    required this.emptyText,
    required this.failureText,
    required this.retryText,
    this.emptyIcon = Icons.music_note_rounded,
    this.tableColumns = false,
    this.pinnedTableHeader = false,
  });

  final PagedListState<R> state;

  /// 头部构建：需要列表状态（已加载数量），且实体可能只在列表态存在。
  final Widget Function(BuildContext context, PagedListState<R> state)
  headerBuilder;

  /// 行构建：`count` 用于首末行圆角；`tableColumns` 与列表行高 / 表头同源。
  final Widget Function(
    BuildContext context,
    int index,
    int count,
    bool tableColumns,
  )
  rowBuilder;

  /// 首屏失败重试。
  final VoidCallback onRetry;

  /// 触底自动取页 / 页脚重试。
  final VoidCallback onLoadMore;

  final String emptyText;
  final String failureText;
  final String retryText;

  /// 空态图标：默认单曲音符，宿主按页面语义覆盖（专辑 / 歌手 / 歌单）。
  final IconData emptyIcon;

  /// 宽屏表格列（行版式与行高都按档取；判据由宿主从 DesktopLayout 解析）。
  final bool tableColumns;

  /// 表格档是否把列标题钉在视口顶部（发现详情页）。
  final bool pinnedTableHeader;

  @override
  State<PagedTrackCollectionBody<R>> createState() =>
      _PagedTrackCollectionBodyState<R>();
}

class _PagedTrackCollectionBodyState<R>
    extends State<PagedTrackCollectionBody<R>> {
  /// 曲目区滚动控制器（常显滚动条，支持手拖定位）。
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    if (state.isLoading) {
      return const DetailPageLoading();
    }
    if (state.failed) {
      return DetailPageFailure(
        message: widget.failureText,
        retryLabel: widget.retryText,
        onRetry: widget.onRetry,
      );
    }
    if (state.isEmpty) {
      return DetailPageEmpty(
        icon: widget.emptyIcon,
        message: widget.emptyText,
      );
    }

    final items = state.items;
    final cardList = M3ETheme.of(context).listTheme.cardList;
    final horizontalPadding = context.horizontalPadding;
    final tableColumns = widget.tableColumns;
    return Scrollbar(
      controller: _scrollController,
      thumbVisibility: true,
      interactive: true,
      child: PagedListAutoLoad(
        hasMore: state.hasMore,
        failed: state.failed,
        isLoadingMore: state.isLoadingMore,
        loadMoreFailed: state.loadMoreFailed,
        onLoadMore: widget.onLoadMore,
        child: CustomScrollView(
          controller: _scrollController,
          slivers: [
            SliverToBoxAdapter(child: widget.headerBuilder(context, state)),
            // 表头钉在滚动视口顶部（封面头部滚走后列标题仍在），与行内
            // 列同宽同左缘；表面色遮挡滚过其下的行。
            if (tableColumns && widget.pinnedTableHeader)
              SliverPersistentHeader(
                pinned: true,
                delegate: _PinnedTableHeaderDelegate(
                  extent: TrackTableHeader.extentOf(context),
                  background: Theme.of(context).colorScheme.surface,
                  horizontalPadding: horizontalPadding,
                ),
              ),
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
              sliver: SliverFixedExtentList.builder(
                // 行高 + 行距：固定 extent，长列表滚动条拖动一次定位。
                itemExtent:
                    (tableColumns
                        ? TrackRow.extentOf(context, tableColumns: true)
                        : TrackRow.extent) +
                    cardList.gap,
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final isLast = index == items.length - 1;
                  return Column(
                    children: [
                      widget.rowBuilder(
                        context,
                        index,
                        items.length,
                        tableColumns,
                      ),
                      if (!isLast) SizedBox(height: cardList.gap),
                    ],
                  );
                },
              ),
            ),
            if (state.isLoadingMore || state.loadMoreFailed)
              SliverToBoxAdapter(
                child: PagedListFooter(
                  isLoadingMore: state.isLoadingMore,
                  loadMoreFailed: state.loadMoreFailed,
                  onRetry: widget.onLoadMore,
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 16)),
          ],
        ),
      ),
    );
  }
}

/// 钉住的表格表头：列标题固定在滚动视口顶部，封面头部滚走后行内列仍有
/// 标题可对照；[ColoredBox] 用页面表面色遮挡滚过其下的行。
///
/// extent 由 [TrackTableHeader.extentOf] 按主题 + 系统文字缩放算出，不写死
/// 行高（大字号下不裁切）。子组件在 [build] 内按可比较的字段构造：
/// widget 实例比较恒不相等，起不到去重作用。
class _PinnedTableHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _PinnedTableHeaderDelegate({
    required this.extent,
    required this.background,
    required this.horizontalPadding,
  });

  final double extent;
  final Color background;

  /// 列表横向页边距（与行列表同值）：表头列缘据此与行内列对齐。
  final double horizontalPadding;

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => ColoredBox(
    color: background,
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: const TrackTableHeader(),
    ),
  );

  @override
  bool shouldRebuild(covariant _PinnedTableHeaderDelegate oldDelegate) =>
      oldDelegate.extent != extent ||
      oldDelegate.background != background ||
      oldDelegate.horizontalPadding != horizontalPadding;
}
