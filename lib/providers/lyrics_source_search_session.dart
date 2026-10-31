/// 手动歌词换源的会话状态：来源搜索 → 选中 → 确认取词 → 写入手动缓存。
///
/// 持有逐来源状态、查询代际、可用性判定、最佳匹配与「选中 → 确认 → 取词 →
/// 写缓存」的结果类型。会话不碰 Navigator / SnackBar：`select` 只切选中态，
/// `applySelected` 返回 [LyricsSelectionOutcome]，由视图决定提示与 pop 的时机。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../services/lyrics/lyric_provider.dart';
import '../services/lyrics/lyrics_match.dart';
import '../services/lyrics/lyrics_source_strategy.dart';
import 'lyrics_provider.dart';

final _logger = Logger('molia.lyrics_source_search_session');

/// 一条平台搜索结果（平台匹配项 + 取词实现）。
class LyricsSearchResult {
  const LyricsSearchResult({required this.match, required this.provider});

  final SongMatch match;
  final LyricProvider provider;
}

/// 手动选择成功后由宿主页 pop 回调用方的数据。
class LyricsSearchSelection {
  const LyricsSearchSelection({required this.lyrics, required this.provider});

  final String lyrics;
  final String provider;
}

/// 每个提供者的搜索状态。
enum ProviderSearchState {
  idle,
  loading,
  loaded,
  error,

  /// 来源当前不可用（如未登录 B 站）：不发请求，只提示「怎么办」。
  unavailable,
}

enum LyricsSearchEntryType { header, result }

/// 逐平台分组列表的一行；视图直接按 [type] 渲染。
class LyricsSearchEntry {
  const LyricsSearchEntry.header(this.strategy)
    : type = LyricsSearchEntryType.header,
      result = null;

  const LyricsSearchEntry.result(this.result)
    : type = LyricsSearchEntryType.result,
      strategy = null;

  final LyricsSearchEntryType type;
  final LyricsSourceStrategy? strategy;
  final LyricsSearchResult? result;
}

/// `select` 的结果：视图据此提示 / pop，不把导航与文案塞进会话。
sealed class LyricsSelectionOutcome {
  const LyricsSelectionOutcome();
}

final class LyricsSelectionSuccess extends LyricsSelectionOutcome {
  const LyricsSelectionSuccess(this.selection);

  final LyricsSearchSelection selection;
}

/// 平台没有可用的歌词文本（payload 为空或规范化后为空）。
final class LyricsSelectionNotFound extends LyricsSelectionOutcome {
  const LyricsSelectionNotFound();
}

/// 取词或写缓存抛错；[error] 只用于日志 / 测试，视图展示通用失败文案。
final class LyricsSelectionFailed extends LyricsSelectionOutcome {
  const LyricsSelectionFailed(this.error);

  final Object error;
}

/// 已有一次取词在途（并发点击）：视图不做任何提示。
final class LyricsSelectionBusy extends LyricsSelectionOutcome {
  const LyricsSelectionBusy();
}

/// 尚未选中任何结果：底部确认按钮理论上是禁用的，走到这里只 no-op。
final class LyricsSelectionNone extends LyricsSelectionOutcome {
  const LyricsSelectionNone();
}

/// 手动歌词搜索会话：来源顺序 / 可用性、逐源结果、选中态与确认写缓存。
///
/// 通知只在**可见状态**变化时发出：搜索开始、清空、选中态切换立即通知；
/// 并行来源几乎同时返回时合并成一次重建（[scheduleMicrotask]），不同时刻
/// 返回的来源仍逐条通知，保留「逐源出结果」的观感。
class LyricsSourceSearchSession extends ChangeNotifier {
  LyricsSourceSearchSession({
    required List<LyricsSourceStrategy> strategies,
    Set<String>? enabledChannelKeys,
    required this._lyricsProvider,
    required this._trackId,
    required this._trackTitle,
    required this._trackArtist,
  }) : _strategies = List.unmodifiable([
         for (final strategy in strategies)
           if (enabledChannelKeys == null ||
               !strategy.isChannel ||
               enabledChannelKeys.contains(strategy.channelKey))
             strategy,
       ]) {
    for (final strategy in _strategies) {
      _providerStates[strategy.provider.name] = ProviderSearchState.idle;
      _providerResults[strategy.provider.name] = const [];
    }
  }

  /// 与 LX 手动换源一致：每个平台最多展示 3 条。
  static const int _resultsPerProvider = 3;

  final List<LyricsSourceStrategy> _strategies;
  final LyricsProvider _lyricsProvider;
  final String _trackId;
  final String _trackTitle;
  final String _trackArtist;

  final Map<String, ProviderSearchState> _providerStates = {};
  final Map<String, List<LyricsSearchResult>> _providerResults = {};

  String _query = '';

  /// 过期响应守卫：每次 [search] 自增；来源返回时 token 不同即丢弃。
  int _searchToken = 0;

  /// 当前选中的结果：只表达「选中」，取词由 [applySelected] 显式触发。
  LyricsSearchResult? _selected;

  bool _isFetchingLyric = false;
  bool _disposed = false;

  /// 合并同一轮事件循环内的通知（见 [_scheduleNotify]）。
  bool _notifyPending = false;
  int _notifyEpoch = 0;

  /// 本次会话的来源（已按同源置顶 / 渠道开关过滤）。
  List<LyricsSourceStrategy> get strategies => _strategies;

  /// 当前查询（已 trim；空串 = 未搜索 / 已清空）。
  String get query => _query;

  bool get isFetchingLyric => _isFetchingLyric;

  /// 当前选中项（未选中为 null）；视图据此画勾选与底栏摘要。
  LyricsSearchResult? get selected => _selected;

  bool isSelected(LyricsSearchResult result) => identical(_selected, result);

  bool get isAnyProviderLoading => _providerStates.values.any(
    (state) => state == ProviderSearchState.loading,
  );

  /// 当前查询下搜索失败的来源（retry 只重搜这些，不重搜成功源）。
  List<LyricsSourceStrategy> get failedStrategies => [
    for (final strategy in _strategies)
      if (stateOf(strategy.provider.name) == ProviderSearchState.error)
        strategy,
  ];

  List<LyricsSearchResult> get allResults {
    final results = <LyricsSearchResult>[];
    for (final strategy in _strategies) {
      results.addAll(_providerResults[strategy.provider.name] ?? const []);
    }
    return results;
  }

  /// 当前不可用的来源原因（去重、保持声明顺序）。
  ///
  /// 无结果时要在空态里补一句「怎么办」（如未登录 B 站）；有结果时
  /// 分组头自己会显示提示，不重复。
  List<LyricsSourceUnavailable> get unavailableReasons {
    final reasons = <LyricsSourceUnavailable>[];
    for (final strategy in _strategies) {
      final reason = unavailableReasonOf(strategy);
      if (reason != null && !reasons.contains(reason)) reasons.add(reason);
    }
    return reasons;
  }

  /// 来源的可用性在**每次读取时**求值（登录 / 退出会发生在页面打开之后）。
  LyricsSourceUnavailable? unavailableReasonOf(LyricsSourceStrategy strategy) =>
      strategy.unavailable?.call();

  ProviderSearchState stateOf(String providerName) =>
      _providerStates[providerName] ?? ProviderSearchState.idle;

  List<LyricsSearchResult> resultsOf(String providerName) =>
      _providerResults[providerName] ?? const [];

  /// 按来源筛选的列表行。
  ///
  /// [channelKey] 为空串 / null = 全部：只列**有结果**的来源（header + 结果），
  /// 没有结果的空分组不占版面；单源时只列该来源结果，header 与加载占位由
  /// 视图的状态区承担。
  List<LyricsSearchEntry> entriesFor(String? channelKey) {
    final key = channelKey ?? '';
    final all = key.isEmpty;
    final entries = <LyricsSearchEntry>[];
    for (final strategy in _strategies) {
      if (!all && strategy.channelKey != key) continue;
      final results = resultsOf(strategy.provider.name);
      if (results.isEmpty) continue;
      if (all) entries.add(LyricsSearchEntry.header(strategy));
      for (final result in results) {
        entries.add(LyricsSearchEntry.result(result));
      }
    }
    return entries;
  }

  /// 兼容旧读取：等价于「全部」筛选。
  List<LyricsSearchEntry> get entries => entriesFor(null);

  /// 该提供者分组内与当前曲目最相近的结果（时长 / 歌名 / 歌手相似度）。
  LyricsSearchResult? bestMatchOf(LyricProvider provider) {
    final results = resultsOf(provider.name);
    if (results.isEmpty) return null;
    final best = pickBestSongMatch(
      [for (final result in results) result.match],
      title: _trackTitle,
      artist: _trackArtist,
    );
    if (best == null) return null;
    for (final result in results) {
      if (identical(result.match, best)) return result;
    }
    return null;
  }

  /// 搜索（空查询 = 清空并回到初始提示）。
  ///
  /// 不可用来源（未登录 B 站）不发请求：状态置 unavailable，分组头直接显示
  /// 「怎么办」。旧查询的在途响应由 [_searchToken] 丢弃。
  Future<void> search(String query) async {
    final normalized = query.trim();
    final token = ++_searchToken;
    // 新查询的候选全部换掉：旧选中项可能已不在结果里，必须同步清掉。
    _selected = null;

    if (normalized.isEmpty) {
      _query = '';
      for (final strategy in _strategies) {
        final providerName = strategy.provider.name;
        _providerStates[providerName] = ProviderSearchState.idle;
        _providerResults[providerName] = const [];
      }
      _notifyNow();
      return;
    }

    final searchable = <LyricProvider>[];
    _query = normalized;
    for (final strategy in _strategies) {
      final providerName = strategy.provider.name;
      _providerResults[providerName] = const [];
      if (unavailableReasonOf(strategy) == null) {
        _providerStates[providerName] = ProviderSearchState.loading;
        searchable.add(strategy.provider);
      } else {
        _providerStates[providerName] = ProviderSearchState.unavailable;
      }
    }
    _notifyNow();

    await Future.wait(
      searchable.map(
        (provider) => _searchProvider(provider, normalized, token),
      ),
    );
  }

  /// 重试当前查询下失败的来源（不重搜成功源，不改变查询与筛选）。
  ///
  /// 取词在途时 no-op：一次确认只做一件事，避免重试把正在写入的歌词
  /// 与候选状态搅在一起。
  Future<void> retryFailed() async {
    if (_isFetchingLyric || _query.isEmpty) return;
    final failed = failedStrategies;
    if (failed.isEmpty) return;

    final token = _searchToken;
    for (final strategy in failed) {
      final providerName = strategy.provider.name;
      _clearSelectionIfProvider(providerName);
      _providerStates[providerName] = ProviderSearchState.loading;
      _providerResults[providerName] = const [];
    }
    _notifyNow();

    await Future.wait([
      for (final strategy in failed)
        _searchProvider(strategy.provider, _query, token),
    ]);
  }

  Future<void> _searchProvider(
    LyricProvider provider,
    String query,
    int token,
  ) async {
    try {
      final matches = await provider.searchMultiple(
        query,
        '',
        limit: _resultsPerProvider,
      );

      if (token != _searchToken) return;

      _clearSelectionIfProvider(provider.name);
      _providerResults[provider.name] = [
        for (final match in matches)
          LyricsSearchResult(match: match, provider: provider),
      ];
      _providerStates[provider.name] = ProviderSearchState.loaded;
      _scheduleNotify();
    } catch (e) {
      _logger.fine('Provider ${provider.name} search error: $e');

      if (token != _searchToken) return;

      _clearSelectionIfProvider(provider.name);
      _providerStates[provider.name] = ProviderSearchState.error;
      _providerResults[provider.name] = const [];
      _scheduleNotify();
    }
  }

  /// 该来源的结果被替换 / 清空时，属于它的选中项不能再留着。
  void _clearSelectionIfProvider(String providerName) {
    if (_selected?.provider.name == providerName) _selected = null;
  }

  /// 选中一条候选（只切选中态，不取词）。
  ///
  /// 取词是确认按钮的显式动作：用户可以先比较来源 / 切换筛选，再决定
  /// 用哪一条，避免点错一次就发一次请求并写缓存。
  void select(LyricsSearchResult result) {
    if (identical(_selected, result)) return;
    _selected = result;
    _notifyNow();
  }

  /// 对当前选中项取词 → 规范化 → 写手动缓存。
  ///
  /// 不 pop 路由、不提示；视图根据返回的 [LyricsSelectionOutcome] 处理。
  Future<LyricsSelectionOutcome> applySelected() async {
    final result = _selected;
    if (result == null) return const LyricsSelectionNone();
    if (_isFetchingLyric) return const LyricsSelectionBusy();

    _isFetchingLyric = true;
    _notifyNow();

    try {
      final payload = await result.provider.fetchForMatch(result.match);
      final rawLyric = payload?.lyric;
      if (rawLyric != null) {
        final normalizedLyric = result.provider.normalizeLyric(rawLyric);

        if (normalizedLyric.isNotEmpty) {
          await _lyricsProvider.saveManual(
            trackId: _trackId,
            lyric: normalizedLyric,
            providerName: result.provider.name,
            translation: normalizeOptionalLyric(
              result.provider,
              payload?.translation,
            ),
            roma: normalizeOptionalLyric(result.provider, payload?.roma),
            lxlyric: normalizeOptionalLyric(result.provider, payload?.lxlyric),
          );
          _logger.fine(
            '手动获取的歌词已缓存，曲目ID：$_trackId，'
            '提供者：${result.provider.name}',
          );
          return LyricsSelectionSuccess(
            LyricsSearchSelection(
              lyrics: normalizedLyric,
              provider: result.provider.name,
            ),
          );
        }
      }

      return const LyricsSelectionNotFound();
    } catch (e) {
      _logger.fine('Provider ${result.provider.name} fetch lyric error: $e');
      return LyricsSelectionFailed(e);
    } finally {
      _isFetchingLyric = false;
      _notifyNow();
    }
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
    super.dispose();
  }
}
