/// 跨来源扇出搜索的共享协议。
///
/// 换源（音频）与手动歌词换源都做同一件事：一条查询拆给多个来源并行搜、
/// 逐源出结果、单源失败隔离、只重试失败源。协议只保留这一份实现——查询
/// 代际、逐源状态 / 结果、失败集合、选中项与通知节拍；消费面只提供来源
/// 适配器，并把自己的展示映射（分组 / 行 / 最佳匹配）叠加在只读状态上。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

final _logger = Logger('molia.fan_out_search_session');

/// 参与扇出搜索的一个来源。
///
/// [key] 是会话内的稳定标识（内置平台 key / 歌词 provider 名）；顺序即
/// 展示顺序，完成顺序永远不参与排序。
///
/// [sourceKeyOf] 把一条结果映射回来源 key：某个来源的结果被替换 / 清空时，
/// 只有属于它的选中项需要失效（其它来源完成不能把用户的选择清掉）。
class FanOutSource<R> {
  const FanOutSource({
    required this.key,
    required this.search,
    this.isAvailable,
    required this.sourceKeyOf,
  });

  final String key;

  /// null = 恒可用；非 null 时每次搜索前求值（登录状态可能在会话期间变化）。
  final bool Function()? isAvailable;

  /// 单源搜索。返回空列表是成功，不是失败。
  final Future<List<R>> Function(String query) search;

  final String Function(R result) sourceKeyOf;

  bool get isAvailableNow => isAvailable?.call() ?? true;
}

/// 单个来源的搜索状态。
enum FanOutSourceStatus {
  idle,
  loading,
  loaded,
  error,

  /// 来源当前不可用（如未登录 B 站）：不发请求，只把原因留给消费面展示。
  unavailable,
}

/// 跨来源扇出搜索会话（[ChangeNotifier]）。
///
/// 通知策略：查询开始 / 清空 / 选中变化立即通知；来源完成合并同一轮事件
/// 循环内的通知（并行搜索几乎同时返回时只重建一次），不同时刻返回的来源
/// 仍逐条通知，保留「逐源出结果」的观感。
class FanOutSearchSession<R> extends ChangeNotifier {
  FanOutSearchSession({required List<FanOutSource<R>> Function() sources})
    : _sourceProvider = sources;

  /// 每次读取都重新求值：换源页的渠道启停 / 脚本增减会发生在会话存活期间，
  /// 缓存一份列表会让下一次搜索继续打向已停用的来源。
  final List<FanOutSource<R>> Function() _sourceProvider;

  final Map<String, FanOutSourceStatus> _statuses = {};
  final Map<String, List<R>> _results = {};
  final Set<String> _failedKeys = <String>{};

  String _query = '';

  /// 过期响应守卫：每次 [search] 自增；来源返回时代际不同即丢弃。
  int _generation = 0;

  /// 当前选中项及其来源：来源结果被替换时按来源失效，不影响其它来源。
  R? _selected;
  String? _selectedSourceKey;

  bool _disposed = false;

  /// 合并同一轮事件循环内的通知（见 [_scheduleNotify]）。
  bool _notifyPending = false;
  int _notifyEpoch = 0;

  /// 当前来源（按声明顺序）。
  List<FanOutSource<R>> get sources => _sourceProvider();

  /// 当前查询（已 trim；空串 = 未搜索 / 已清空）。
  String get query => _query;

  /// 有来源正在请求（消费面据此显示进度 / 禁用重试）。
  bool get isSearching =>
      _statuses.values.any((status) => status == FanOutSourceStatus.loading);

  FanOutSourceStatus statusOf(String key) =>
      _statuses[key] ?? FanOutSourceStatus.idle;

  /// 该来源的当前结果；未知来源返回空列表。
  List<R> resultsOf(String key) => _results[key] ?? const [];

  /// 当前查询下失败的来源。
  ///
  /// 维护独立集合而不是从状态推导：来源从注册表移除后仍需保留失败 key，
  /// 让 UI 能报出「哪个源失败了」，直到下一次搜索 / 重试清掉。
  Set<String> get failedKeys => Set.unmodifiable(_failedKeys);

  /// 全部结果：按来源声明顺序拼接，与完成顺序无关。
  List<R> get allResults {
    final results = <R>[];
    for (final source in sources) {
      results.addAll(resultsOf(source.key));
    }
    return results;
  }

  /// 当前选中项（未选中为 null）。
  R? get selected => _selected;

  /// 搜索。空查询 = 清空并回到初始态；查询变化立即作废在途响应与选中项。
  Future<void> search(String query) async {
    if (_disposed) return;
    final normalized = query.trim();
    final generation = ++_generation;

    _selected = null;
    _selectedSourceKey = null;
    _statuses.clear();
    _results.clear();
    _failedKeys.clear();

    if (normalized.isEmpty) {
      _query = '';
      _notifyNow();
      return;
    }

    _query = normalized;
    final targets = <FanOutSource<R>>[];
    for (final source in sources) {
      _results[source.key] = const [];
      if (source.isAvailableNow) {
        _statuses[source.key] = FanOutSourceStatus.loading;
        targets.add(source);
      } else {
        // 不可用来源不发请求，但保留状态让消费面挂出「怎么办」。
        _statuses[source.key] = FanOutSourceStatus.unavailable;
      }
    }
    _notifyNow();

    await Future.wait([
      for (final source in targets)
        _searchSource(source, normalized, generation),
    ]);
  }

  /// 只重搜当前查询下失败的来源；不改变查询，也不重搜已成功的来源。
  ///
  /// 一轮搜索进行中不重试：两轮响应会同时写同一来源的状态，失败集合也会
  /// 互相覆盖；消费面的重试按钮同样在这期间禁用。
  Future<void> retryFailed() async {
    if (_disposed || _query.isEmpty || isSearching || _failedKeys.isEmpty) {
      return;
    }

    final targets = [
      for (final source in sources)
        if (_failedKeys.contains(source.key)) source,
    ];
    if (targets.isEmpty) {
      // 失败来源已从注册表移除：清空失败集合并通知，让 UI 撤掉旧提示。
      _failedKeys.clear();
      _notifyNow();
      return;
    }

    _failedKeys.clear();
    for (final source in targets) {
      _replaceResults(source.key, const []);
      _statuses[source.key] = FanOutSourceStatus.loading;
    }
    _notifyNow();

    final generation = _generation;
    await Future.wait([
      for (final source in targets) _searchSource(source, _query, generation),
    ]);
  }

  /// 选中一条结果（只切选中态）；null = 取消选中。
  void select(R? result) {
    if (_disposed || identical(_selected, result)) return;
    _selected = result;
    _selectedSourceKey = result == null ? null : _ownerKeyOf(result);
    _notifyNow();
  }

  /// 清空查询、逐源状态 / 结果与选中项；来源列表保持不变。
  void clear() {
    if (_disposed) return;
    _generation++;
    _query = '';
    _statuses.clear();
    _results.clear();
    _failedKeys.clear();
    _selected = null;
    _selectedSourceKey = null;
    _notifyNow();
  }

  /// 立即通知并作废已排队的合并通知。
  ///
  /// 消费面自己的状态（换源筛选 / 取词中）变化也走这里：若直接
  /// `notifyListeners()`，紧跟着的合并通知会让界面再重建一次。
  void notifyNow() => _notifyNow();

  Future<void> _searchSource(
    FanOutSource<R> source,
    String query,
    int generation,
  ) async {
    try {
      final results = await source.search(query);
      if (_disposed || generation != _generation) return;
      _replaceResults(source.key, results);
      _statuses[source.key] = FanOutSourceStatus.loaded;
      _failedKeys.remove(source.key);
      _scheduleNotify();
    } catch (e) {
      if (_disposed || generation != _generation) return;
      _logger.warning('来源 ${source.key} 搜索失败: $e');
      _replaceResults(source.key, const []);
      _statuses[source.key] = FanOutSourceStatus.error;
      _failedKeys.add(source.key);
      _scheduleNotify();
    }
  }

  /// 替换某来源的结果；该来源的选中项同时失效。
  void _replaceResults(String key, List<R> results) {
    if (_selectedSourceKey == key) {
      _selected = null;
      _selectedSourceKey = null;
    }
    _results[key] = results.isEmpty ? const [] : List<R>.unmodifiable(results);
  }

  /// 结果属于哪个来源。优先匹配声明 key；来源已移除时回退第一个适配器的
  /// 映射，保证这条选中项在对应来源下次返回时仍会被清掉。
  String? _ownerKeyOf(R result) {
    final sources = this.sources;
    for (final source in sources) {
      if (source.sourceKeyOf(result) == source.key) return source.key;
    }
    return sources.isEmpty ? null : sources.first.sourceKeyOf(result);
  }

  /// 立即通知：搜索开始 / 清空 / 选中态切换这类整屏可见的变化。
  void _notifyNow() {
    if (_disposed) return;
    // 让已排队的合并通知过期，避免紧接着再重建一次。
    _notifyEpoch++;
    _notifyPending = false;
    notifyListeners();
  }

  /// 合并同一轮事件循环内的来源完成（并行搜索几乎同时返回）为一次重建；
  /// 不同时间返回的来源仍各自通知，保留逐源填充结果的观感。
  void _scheduleNotify() {
    if (_disposed || _notifyPending) return;
    _notifyPending = true;
    final epoch = _notifyEpoch;
    scheduleMicrotask(() {
      if (_disposed || epoch != _notifyEpoch) return;
      _notifyPending = false;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _statuses.clear();
    _results.clear();
    _failedKeys.clear();
    _selected = null;
    _selectedSourceKey = null;
    super.dispose();
  }
}
