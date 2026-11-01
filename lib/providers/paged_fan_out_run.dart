/// 分页来源的执行体：把分页状态机接进跨来源扇出协议。
///
/// 搜索页每个「类型 × 来源」一份：分页 / 过期页 / 失败态由
/// [PagedListController] 持有，本类只把状态投影成协议快照并归一化失败，
/// 让分页来源与单发来源共用同一套通知与失败口径。
library;

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../domain/models/failure.dart';
import 'paged_list_controller.dart';
import 'source_fan_out.dart';

final _logger = Logger('molia.paged_fan_out_run');

class PagedFanOutRun<T> extends ValueNotifier<FanOutRunState<T>>
    implements FanOutRun<T> {
  PagedFanOutRun({
    required Future<PagedResult<T>> Function(int page) fetchPage,
    required this.failureLogLabel,
    String Function(T item)? keyOf,
    T Function(T existing, T incoming)? mergeDuplicate,
  }) : _pager = PagedListController<T>(
         fetchPage: fetchPage,
         keyOf: keyOf,
         mergeDuplicate: mergeDuplicate,
       ),
       super(FanOutRunState<T>()) {
    _pager.addListener(_sync);
    _sync();
  }

  /// 失败日志前缀（保留各搜索类型 / 来源的可诊断文案）。
  final String failureLogLabel;

  final PagedListController<T> _pager;

  Object? _failureCause;
  SourceFailure? _failure;

  @override
  FanOutRunState<T> get state => value;

  @override
  Future<void> loadFirstPage() => _pager.loadFirstPage();

  @override
  Future<void> loadMore() => _pager.loadMore();

  void _sync() {
    final state = _pager.state;
    value = FanOutRunState<T>(
      status: state.isLoading
          ? FanOutSourceStatus.loading
          : state.failed
          ? FanOutSourceStatus.error
          : state.page > 0
          ? FanOutSourceStatus.loaded
          : FanOutSourceStatus.idle,
      items: state.items,
      failure: state.failed ? _failureFor(state.error) : null,
      page: state.page,
      total: state.total,
      hasMore: state.hasMore,
      isLoadingMore: state.isLoadingMore,
      loadMoreFailed: state.loadMoreFailed,
    );
  }

  /// 归一化失败并只记一次日志：分页状态每次变化都会重建快照，同一个异常
  /// 不应反复写日志。
  SourceFailure? _failureFor(Object? error) {
    if (error == null) return null;
    if (!identical(error, _failureCause)) {
      _failureCause = error;
      _failure = SourceFailure.from(error);
      _logger.fine('$failureLogLabel: $error');
    }
    return _failure;
  }

  @override
  void dispose() {
    _pager.removeListener(_sync);
    _pager.dispose();
    super.dispose();
  }
}
