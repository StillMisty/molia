/// 单个「搜索类型 × 来源」的分页会话：关键词、归一化失败、分页控制器。
///
/// 从 `search_provider.dart` 抽出的唯一目的：跨来源聚合后，每个来源都要有
/// 自己的一份关键词 / 页码 / 失败，provider 只按来源 map 持有这些会话，
/// 不再把三种行形状塞进同一个泛型状态。
library;

import 'package:logging/logging.dart';

import '../domain/models/failure.dart';
import '../domain/models/track.dart';
import 'paged_list_controller.dart';

final _logger = Logger('molia.search_session');

/// 歌词搜索的一页：在通用 [PagedResult] 上带回本页命中的片段。
///
/// 片段必须随页身份一起被接受：只有控制器判定请求仍为当前会话后，才把
/// 这页的片段并入累计表；旧查询晚到的响应不能污染新查询的行。
class LyricPageResult extends PagedResult<Track> {
  const LyricPageResult({
    required this.snippets,
    required super.items,
    required super.hasMore,
    super.total,
  });

  /// 本页命中的片段（key = `TrackId.uri`，与行身份同一口径）。
  final Map<String, String> snippets;
}

/// 分页会话的只读面：provider 跨来源调度分页 / 重试时只读这些字段。
abstract interface class SearchSessionState {
  String get keyword;
  SourceFailure? get failure;
  int get page;
  int? get total;
  bool get hasMore;
  bool get isLoading;
  bool get isLoadingMore;
  bool get loadMoreFailed;

  void begin(String keyword);
  void reset();
  Future<void> loadFirstPage();
  Future<void> loadMore();
  void dispose();
}

/// 一个来源的分页会话（与结果类型无关）：关键词、失败、分页元数据。
///
/// 结果投影不放进会话：单曲 / 歌手 / 歌词的行形状不同（`SearchRow` /
/// `ArtistSummary` / 带片段的行），provider 仍按类型保留自己的投影；
/// 会话只保证「这个来源的关键词、页码、失败属于同一次搜索」。
class SearchSession<T> implements SearchSessionState {
  /// [failureLogLabel] 只用于失败日志前缀（保留各类会话 / 来源的可诊断文案）。
  SearchSession(this._pager, this._failureLogLabel);

  final PagedListController<T> _pager;

  final String _failureLogLabel;

  @override
  String keyword = '';

  /// 归一化失败（UI 的唯一错误出口）。
  @override
  SourceFailure? failure;

  /// 已接受页累计后的条目（provider 做类型化投影时读取）。
  List<T> get items => _pager.items;

  @override
  int get page => _pager.page;
  @override
  int? get total => _pager.total;
  @override
  bool get hasMore => _pager.hasMore;
  @override
  bool get isLoading => _pager.isLoading;
  @override
  bool get isLoadingMore => _pager.isLoadingMore;
  @override
  bool get loadMoreFailed => _pager.loadMoreFailed;

  /// 开始新关键词：先作废旧会话（关键词、失败与在途页），再记下新关键词。
  @override
  void begin(String keyword) {
    reset();
    this.keyword = keyword;
  }

  /// 清空会话：关键词与失败归空，分页器复位并使在途页过期。
  @override
  void reset() {
    keyword = '';
    failure = null;
    _pager.reset();
  }

  @override
  Future<void> loadFirstPage() async {
    await _pager.loadFirstPage();
    _syncFailure();
  }

  @override
  Future<void> loadMore() async {
    await _pager.loadMore();
    _syncFailure();
  }

  /// 失败归一化只在这一个出口：成功清失败，失败挂归一化对象。
  void _syncFailure() {
    final error = _pager.error;
    if (error == null) {
      failure = null;
      return;
    }
    _logger.fine('$_failureLogLabel: $error');
    failure = SourceFailure.from(error);
  }

  @override
  void dispose() => _pager.dispose();
}
