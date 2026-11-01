/// 跨来源搜索的共享协议。
///
/// 一条查询拆给多个来源并行执行、逐源出结果、单源失败隔离、只重试失败源。
/// 查询代际、逐源状态 / 失败、选中项失效与通知节拍只在这里实现；消费面
/// 提供来源适配器与执行体，并把自己的展示映射叠加在只读状态上。
///
/// 执行体分两种：单发（换源 / 手动歌词换源，一次查询一次结果）与分页
/// （搜索页每个「类型 × 来源」都有独立页码）。两者共用同一轮查询的生命
/// 周期：会话统一开轮、作废旧执行体、合并通知，分页细节留在执行体。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../domain/models/failure.dart';

final _logger = Logger('molia.source_fan_out');

/// 单个来源在一轮查询里的只读状态快照。
@immutable
class FanOutRunState<T> {
  const FanOutRunState({
    this.status = FanOutSourceStatus.idle,
    this.items = const [],
    this.failure,
    this.page = 0,
    this.total,
    this.hasMore = false,
    this.isLoadingMore = false,
    this.loadMoreFailed = false,
  });

  final FanOutSourceStatus status;

  /// 已接受页累计后的条目（单发来源是本次查询的全部结果）。
  final List<T> items;

  /// 首屏归一化失败。追加页失败只体现在 [loadMoreFailed]，不清空已加载条目。
  final SourceFailure? failure;

  /// 已成功加载到第几页（单发来源成功一次即第 1 页）。
  final int page;

  final int? total;
  final bool hasMore;
  final bool isLoadingMore;
  final bool loadMoreFailed;

  bool get isLoading => status == FanOutSourceStatus.loading;
}

/// 单个来源在一轮查询里的执行体。
///
/// 会话只驱动 [loadFirstPage] / [loadMore] 并读 [state]；取数、失败归一与
/// 分页细节留在执行体，因此单发与分页共用同一份查询代际与通知协议。
abstract interface class FanOutRun<T>
    implements ValueListenable<FanOutRunState<T>> {
  FanOutRunState<T> get state;

  /// 执行首屏（一轮查询开始时由会话调用一次）。
  Future<void> loadFirstPage();

  /// 下一页；没有分页的来源不做任何事。
  Future<void> loadMore();

  void dispose();
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

/// 参与扇出搜索的一个来源。
///
/// [key] 是会话内的稳定标识（内置平台 key / 歌词 provider 名）；顺序即
/// 展示顺序，完成顺序永远不参与排序。
class FanOutSource<R> {
  /// 单发来源：一次查询一次结果（换源 / 手动歌词换源）。
  ///
  /// [sourceKeyOf] 把一条结果映射回来源 key：某个来源的结果被替换 / 清空时，
  /// 只有属于它的选中项需要失效（其它来源完成不能把用户的选择清掉）。
  const FanOutSource({
    required this.key,
    required this._search,
    this.isAvailable,
    required this._sourceKeyOf,
  }) : _openRun = null;

  /// 分页来源：一次查询开一个分页执行体（搜索页每个「类型 × 来源」一份）。
  const FanOutSource.paged({
    required this.key,
    required this._openRun,
    this.isAvailable,
  }) : _search = null,
       _sourceKeyOf = null;

  final String key;

  /// null = 恒可用；非 null 时每次搜索前求值（登录状态可能在会话期间变化）。
  final bool Function()? isAvailable;

  final Future<List<R>> Function(String query)? _search;
  final FanOutRun<R> Function(String query)? _openRun;
  final String Function(R result)? _sourceKeyOf;

  bool get isAvailableNow => isAvailable?.call() ?? true;

  /// 结果属于哪个来源；没有映射（分页来源）返回 null。
  String? ownerKeyOf(R result) => _sourceKeyOf?.call(result);

  FanOutRun<R> open(String query) =>
      _openRun?.call(query) ??
      SingleShotFanOutRun<R>(key: key, search: () => _search!(query));
}

/// 搜索页需要的扇出控制面（不含结果类型）。
///
/// 三种搜索分支的行形状不同，provider 只经这一份接口调度查询 / 分页 /
/// 重试；类型化结果由 `SearchBranch` 的投影读取。
abstract interface class FanOutSearchControl {
  /// 当前查询（已 trim；空串 = 未搜索 / 已清空）。
  String get query;

  Future<void> search(String query);

  /// 给当前查询下缺失的来源补开执行体（注册表晚到的来源 / 过滤切回）。
  Future<void> ensureSources();

  /// 注册表移除来源时丢弃它的执行体与状态。
  void retainSources(Set<String> keys);

  /// 该来源是否正在加载首屏。
  bool isLoading(String sourceKey);

  Future<void> loadMore(String sourceKey);

  /// 重试单个来源：追加页失败重试下一页，首屏失败重开首屏。
  Future<void> retry(String sourceKey);

  /// 只重试当前查询下失败的来源。
  ///
  /// [onlyKeys] 非 null 时只在给定来源内重试（搜索页的过滤视图）；null 时
  /// 重试全部失败来源（一轮搜索进行中不启动），失败来源已从注册表移除则
  /// 清空失败集合。
  Future<void> retryFailed({Set<String>? onlyKeys});

  void clear();

  void addListener(VoidCallback listener);

  void removeListener(VoidCallback listener);

  void dispose();
}

/// 单个来源的执行体记录：适配器、执行体与它所属的查询代际。
final class _SourceRun<R> {
  _SourceRun({
    required this.source,
    required this.run,
    required this.generation,
  });

  final FanOutSource<R> source;
  final FanOutRun<R> run;
  final int generation;
  VoidCallback? onChanged;

  void dispose() {
    final listener = onChanged;
    if (listener != null) run.removeListener(listener);
    run.dispose();
  }
}

/// 跨来源扇出搜索会话（[ChangeNotifier]）。
///
/// 通知策略：查询开始 / 清空 / 选中变化立即通知；来源完成合并同一轮事件
/// 循环内的通知（并行搜索几乎同时返回时只重建一次），不同时刻返回的来源
/// 仍逐条通知，保留「逐源出结果」的观感。
class FanOutSearchSession<R> extends ChangeNotifier
    implements FanOutSearchControl {
  FanOutSearchSession({required List<FanOutSource<R>> Function() sources})
    : _sourceProvider = sources;

  /// 每次读取都重新求值：换源页的渠道启停 / 脚本增减会发生在会话存活期间，
  /// 缓存一份列表会让下一次搜索继续打向已停用的来源。
  final List<FanOutSource<R>> Function() _sourceProvider;

  final Map<String, _SourceRun<R>> _runs = {};
  final Set<String> _failedKeys = <String>{};
  final Set<String> _unavailableKeys = <String>{};

  String _query = '';

  /// 过期响应守卫：每次 [search] 自增；执行体返回时代际不同即丢弃。
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

  @override
  String get query => _query;

  /// 有来源正在请求（消费面据此显示进度 / 禁用重试）。
  bool get isSearching =>
      _runs.values.any((entry) => entry.run.state.isLoading);

  FanOutSourceStatus statusOf(String key) {
    if (_unavailableKeys.contains(key)) return FanOutSourceStatus.unavailable;
    return _runs[key]?.run.state.status ?? FanOutSourceStatus.idle;
  }

  /// 该来源当前状态快照；没有执行体（未参与本轮 / 已移除）返回 null。
  FanOutRunState<R>? stateOf(String key) => _runs[key]?.run.state;

  /// 该来源的当前结果；未知来源返回空列表。
  List<R> resultsOf(String key) => _runs[key]?.run.state.items ?? const [];

  /// 当前查询下失败的来源（首屏失败或追加页失败）。
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
  @override
  Future<void> search(String query) async {
    if (_disposed) return;
    final normalized = query.trim();
    final generation = ++_generation;

    _selected = null;
    _selectedSourceKey = null;
    _failedKeys.clear();
    _unavailableKeys.clear();
    _disposeRuns();

    if (normalized.isEmpty) {
      _query = '';
      _notifyNow();
      return;
    }

    _query = normalized;
    final pending = <Future<void>>[];
    for (final source in sources) {
      final entry = _open(source, generation);
      if (entry != null) pending.add(_loadFirstPage(entry));
    }
    // 执行体已同步进入 loading：先发一次通知让消费面的分组标题出现 spinner。
    _notifyNow();
    await Future.wait(pending);
  }

  /// 当前查询下补齐缺失来源的执行体（不重发已有来源的请求）。
  @override
  Future<void> ensureSources() async {
    if (_disposed || _query.isEmpty) return;
    final pending = <Future<void>>[];
    for (final source in sources) {
      if (_runs.containsKey(source.key)) continue;
      final entry = _open(source, _generation);
      if (entry != null) pending.add(_loadFirstPage(entry));
    }
    if (pending.isEmpty) return;
    _notifyNow();
    await Future.wait(pending);
  }

  @override
  void retainSources(Set<String> keys) {
    if (_disposed) return;
    final removed = [
      for (final key in _runs.keys)
        if (!keys.contains(key)) key,
    ];
    for (final key in removed) {
      _runs.remove(key)?.dispose();
      _failedKeys.remove(key);
    }
    _unavailableKeys.removeWhere((key) => !keys.contains(key));
    final selectedSource = _selectedSourceKey;
    if (selectedSource != null && !keys.contains(selectedSource)) {
      _selected = null;
      _selectedSourceKey = null;
    }
  }

  @override
  bool isLoading(String sourceKey) =>
      _runs[sourceKey]?.run.state.isLoading ?? false;

  @override
  Future<void> loadMore(String sourceKey) async {
    final entry = _runs[sourceKey];
    if (entry == null || _query.isEmpty) return;
    final pending = _loadMore(entry);
    // 状态机先同步置 loadingMore：立即通知让分页页脚出现进度。
    _notifyNow();
    await pending;
  }

  @override
  Future<void> retry(String sourceKey) async {
    final entry = _runs[sourceKey];
    if (entry == null || _query.isEmpty) return;
    final pending = entry.run.state.loadMoreFailed
        ? _retryLoadMore(entry)
        : _retryFirstPage(entry);
    if (pending == null) return;
    _notifyNow();
    await pending;
  }

  /// 只重搜当前查询下失败的来源；不改变查询，也不重搜已成功的来源。
  ///
  /// 整轮重试（[onlyKeys] 为 null）在一轮搜索进行中不启动：两轮响应会同时
  /// 写同一来源的状态，失败集合也会互相覆盖。
  @override
  Future<void> retryFailed({Set<String>? onlyKeys}) async {
    if (_disposed || _query.isEmpty || _failedKeys.isEmpty) {
      return;
    }
    // 整轮重试（换源 / 歌词换源）在一轮搜索进行中不启动：两轮响应会同时
    // 写同一来源的状态；搜索页按来源重试，只碰已失败、未在途的来源。
    if (onlyKeys == null && isSearching) return;

    final targets = [
      for (final source in sources)
        if (_failedKeys.contains(source.key) &&
            (onlyKeys == null || onlyKeys.contains(source.key)))
          source,
    ];
    if (targets.isEmpty) {
      if (onlyKeys != null) return;
      // 失败来源已从注册表移除：清空失败集合并通知，让 UI 撤掉旧提示。
      _failedKeys.clear();
      _notifyNow();
      return;
    }

    final pending = <Future<void>>[];
    if (onlyKeys == null) {
      // 换源 / 歌词换源：失败集合整轮重算；已从注册表移除的失败源就此清掉。
      _failedKeys.clear();
    } else {
      _failedKeys.removeAll([for (final source in targets) source.key]);
    }
    for (final source in targets) {
      final entry = _runs[source.key];
      if (entry == null) continue;
      final future = entry.run.state.loadMoreFailed
          ? _retryLoadMore(entry)
          : _retryFirstPage(entry);
      if (future != null) pending.add(future);
    }
    if (pending.isEmpty) return;
    _notifyNow();
    await Future.wait(pending);
  }

  /// 选中一条结果（只切选中态）；null = 取消选中。
  void select(R? result) {
    if (_disposed || identical(_selected, result)) return;
    _selected = result;
    _selectedSourceKey = result == null ? null : _ownerKeyOf(result);
    _notifyNow();
  }

  /// 清空查询、逐源状态 / 结果与选中项；来源列表保持不变。
  @override
  void clear() {
    if (_disposed) return;
    _generation++;
    _query = '';
    _disposeRuns();
    _failedKeys.clear();
    _unavailableKeys.clear();
    _selected = null;
    _selectedSourceKey = null;
    _notifyNow();
  }

  /// 立即通知并作废已排队的合并通知。
  ///
  /// 消费面自己的状态（换源筛选 / 取词中）变化也走这里：若直接
  /// `notifyListeners()`，紧跟着的合并通知会让界面再重建一次。
  void notifyNow() => _notifyNow();

  /// 开一个来源的执行体；不可用来源只记状态、不发请求。
  ///
  /// [force] 用于重试：失败来源即使暂时不可用也要再试一次（登录状态可能
  /// 刚恢复），与其它来源的可用性判定解耦。
  _SourceRun<R>? _open(
    FanOutSource<R> source,
    int generation, {
    bool force = false,
  }) {
    _unavailableKeys.remove(source.key);
    if (!force && !source.isAvailableNow) {
      _unavailableKeys.add(source.key);
      return null;
    }
    final entry = _SourceRun<R>(
      source: source,
      run: source.open(_query),
      generation: generation,
    );
    entry.onChanged = () => _onRunChanged(entry);
    entry.run.addListener(entry.onChanged!);
    _runs[source.key] = entry;
    return entry;
  }

  Future<void> _loadFirstPage(_SourceRun<R> entry) async {
    await entry.run.loadFirstPage();
    if (_disposed || entry.generation != _generation) return;
    _refreshFailure(entry);
    _scheduleNotify();
  }

  Future<void>? _retryFirstPage(_SourceRun<R> entry) {
    if (entry.run.state.status != FanOutSourceStatus.error) return null;
    final source = _sourceFor(entry.source.key) ?? entry.source;
    final key = entry.source.key;
    _invalidateSelectionFor(key);
    _failedKeys.remove(key);
    _runs.remove(key);
    entry.dispose();
    final replacement = _open(source, _generation, force: true);
    if (replacement == null) return null;
    return _loadFirstPage(replacement);
  }

  Future<void>? _retryLoadMore(_SourceRun<R> entry) {
    _failedKeys.remove(entry.source.key);
    return _loadMore(entry);
  }

  Future<void> _loadMore(_SourceRun<R> entry) async {
    await entry.run.loadMore();
    if (_disposed || entry.generation != _generation) return;
    _refreshFailure(entry);
  }

  FanOutSource<R>? _sourceFor(String key) {
    for (final source in sources) {
      if (source.key == key) return source;
    }
    return _runs[key]?.source;
  }

  void _onRunChanged(_SourceRun<R> entry) {
    if (_disposed || entry.generation != _generation) return;
    _refreshFailure(entry);
    _scheduleNotify();
  }

  /// 首屏失败与追加页失败都算「该来源失败」，只重试这些来源。
  void _refreshFailure(_SourceRun<R> entry) {
    final state = entry.run.state;
    final failed =
        state.status == FanOutSourceStatus.error || state.loadMoreFailed;
    if (failed) {
      _failedKeys.add(entry.source.key);
    } else {
      _failedKeys.remove(entry.source.key);
    }
  }

  void _invalidateSelectionFor(String key) {
    if (_selectedSourceKey != key) return;
    _selected = null;
    _selectedSourceKey = null;
  }

  /// 结果属于哪个来源。优先匹配声明 key；来源已移除时回退同一条结果在
  /// 现有适配器里的映射，保证这条选中项在对应来源下次返回时仍会被清掉。
  String? _ownerKeyOf(R result) {
    final declared = sources;
    final candidates = [
      ...declared,
      for (final entry in _runs.values)
        if (!declared.any((source) => source.key == entry.source.key))
          entry.source,
    ];
    for (final source in candidates) {
      if (source.ownerKeyOf(result) == source.key) return source.key;
    }
    for (final source in candidates) {
      final owner = source.ownerKeyOf(result);
      if (owner != null) return owner;
    }
    return null;
  }

  void _disposeRuns() {
    for (final entry in _runs.values) {
      entry.dispose();
    }
    _runs.clear();
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
    _generation++;
    _disposeRuns();
    _failedKeys.clear();
    _unavailableKeys.clear();
    _selected = null;
    _selectedSourceKey = null;
    super.dispose();
  }
}

/// 单发来源的执行体：一次查询一次结果。
///
/// 查询结果与失败都以 [FanOutRunState] 发布，换源 / 手动歌词换源的视图
/// 只读这一份状态。
class SingleShotFanOutRun<R> extends ValueNotifier<FanOutRunState<R>>
    implements FanOutRun<R> {
  SingleShotFanOutRun({required this.key, required this._search})
    : super(FanOutRunState<R>());

  final String key;
  final Future<List<R>> Function() _search;

  int _generation = 0;
  bool _disposed = false;

  @override
  FanOutRunState<R> get state => value;

  @override
  Future<void> loadFirstPage() async {
    final generation = ++_generation;
    value = FanOutRunState<R>(status: FanOutSourceStatus.loading);
    try {
      final items = await _search();
      if (_disposed || generation != _generation) return;
      value = FanOutRunState<R>(
        status: FanOutSourceStatus.loaded,
        items: List<R>.unmodifiable(items),
        page: 1,
      );
    } catch (e) {
      if (_disposed || generation != _generation) return;
      _logger.warning('来源 $key 搜索失败: $e');
      value = FanOutRunState<R>(
        status: FanOutSourceStatus.error,
        failure: SourceFailure.from(e),
      );
    }
  }

  @override
  Future<void> loadMore() async {}

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
