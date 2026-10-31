/// 手动歌词换源的会话状态：来源搜索 → 选中 → 确认取词 → 写入手动缓存。
///
/// 搜索协议（查询代际、逐来源状态 / 结果、失败重试、选中失效）委托
/// [FanOutSearchSession]；本类只保留来源策略、可用性判定、最佳匹配、选中
/// 预览与「选中 → 确认 → 取词 → 写缓存」的结果类型。会话不碰 Navigator /
/// SnackBar：`select` 切选中态并拉预览，`applySelected` 返回
/// [LyricsSelectionOutcome]，由视图决定提示与 pop 的时机。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../models/lyric_line.dart';
import '../services/lyrics/lyric_provider.dart';
import '../services/lyrics/lyrics_match.dart';
import '../services/lyrics/lyrics_source_strategy.dart';
import 'fan_out_search_session.dart';
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

/// 每个提供者的搜索状态（扇出会话的逐源状态，保留旧名字给视图 / 测试）。
typedef ProviderSearchState = FanOutSourceStatus;

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

/// 选中结果的歌词预览状态。
enum LyricsPreviewStatus {
  loading,
  ready,

  /// 平台没有返回歌词，或返回的文本没有可展示行。
  empty,
  failed,
}

/// 选中结果的前几行歌词预览。
///
/// 预览文本的解析 / 截断 / 缓存都在会话内完成：视图只按 [status] 渲染，
/// 不再自己判断 LRC 或纯文本，避免和确认取词走两套解析口径。
class LyricsPreview {
  const LyricsPreview.loading()
    : status = LyricsPreviewStatus.loading,
      lines = const [];

  const LyricsPreview.ready(this.lines) : status = LyricsPreviewStatus.ready;

  const LyricsPreview.empty()
    : status = LyricsPreviewStatus.empty,
      lines = const [];

  const LyricsPreview.failed()
    : status = LyricsPreviewStatus.failed,
      lines = const [];

  final LyricsPreviewStatus status;

  /// 已截断的预览行（最多 [LyricsSourceSearchSession.previewLineLimit] 行）。
  final List<String> lines;
}

/// 预览缓存：成功时保留原始 payload，确认按钮直接复用，避免重复取词；
/// [payload] 为 null 表示这条缓存只记录「平台没有歌词」。
class _CachedLyricsPreview {
  const _CachedLyricsPreview(this.preview, this.payload);

  final LyricsPreview preview;
  final LyricsPayload? payload;
}

/// 手动歌词搜索会话：来源顺序 / 可用性、逐源结果、选中态与确认写缓存。
///
/// 搜索协议与通知节拍（立即通知查询 / 清空 / 选中，合并同轮来源完成）
/// 由 [FanOutSearchSession] 统一持有；本类只叠加歌词侧的状态与流程。
class LyricsSourceSearchSession extends ChangeNotifier {
  LyricsSourceSearchSession({
    required List<LyricsSourceStrategy> strategies,
    Set<String>? enabledChannelKeys,
    required this._lyricsProvider,
    required this._trackId,
    required this._trackTitle,
    required this._trackArtist,
    String? trackAlbum,
    Duration? trackDuration,
    List<String>? channelOrder,
  }) : // 公开参数名保持 trackAlbum / trackDuration，字段仍按本类惯例私有。
       // ignore: prefer_initializing_formals
       _trackAlbum = trackAlbum,
       // ignore: prefer_initializing_formals
       _trackDuration = trackDuration,
       _strategies = _orderedStrategies([
         for (final strategy in strategies)
           if (enabledChannelKeys == null ||
               !strategy.isChannel ||
               enabledChannelKeys.contains(strategy.channelKey))
             strategy,
       ], channelOrder) {
    // 查询代际 / 逐源状态 / 失败重试 / 选中失效统一交给扇出会话；本类只保留
    // 歌词来源策略、可用性原因与「确认 → 取词 → 写缓存」的歌词侧流程。
    _searchSession = FanOutSearchSession<LyricsSearchResult>(
      sources: () => [
        for (final strategy in _strategies)
          FanOutSource<LyricsSearchResult>(
            key: strategy.provider.name,
            isAvailable: () => strategy.unavailable?.call() == null,
            search: (query) => _searchProvider(strategy.provider, query),
            sourceKeyOf: (result) => result.provider.name,
          ),
      ],
    )..addListener(_notifyListeners);
  }

  /// 按渠道管理的顺序重排来源。
  ///
  /// 顺序表来自渠道管理的 `orderedChannelKeys`；表里没有的渠道排在已知
  /// 渠道之后并保持声明顺序；非渠道来源（LRCLIB）
  /// 不参与渠道排序，统一放最后，避免夹在平台 chips 中间。
  static List<LyricsSourceStrategy> _orderedStrategies(
    List<LyricsSourceStrategy> strategies,
    List<String>? channelOrder,
  ) {
    if (strategies.length < 2) return List.unmodifiable(strategies);
    final orderByKey = <String, int>{};
    if (channelOrder != null) {
      for (var index = 0; index < channelOrder.length; index++) {
        orderByKey.putIfAbsent(channelOrder[index], () => index);
      }
    }
    final indexed = [
      for (var index = 0; index < strategies.length; index++)
        (index: index, strategy: strategies[index]),
    ];
    indexed.sort((a, b) {
      final aKey = _sortKey(a.strategy, a.index, orderByKey);
      final bKey = _sortKey(b.strategy, b.index, orderByKey);
      final bucket = aKey.$1.compareTo(bKey.$1);
      if (bucket != 0) return bucket;
      final withinBucket = aKey.$2.compareTo(bKey.$2);
      return withinBucket != 0 ? withinBucket : a.index.compareTo(b.index);
    });
    return List.unmodifiable([for (final entry in indexed) entry.strategy]);
  }

  /// (桶, 桶内序号)：0 = 顺序表里的渠道，1 = 其它渠道，2 = 非渠道来源。
  static (int, int) _sortKey(
    LyricsSourceStrategy strategy,
    int declarationIndex,
    Map<String, int> orderByKey,
  ) {
    if (!strategy.isChannel) return (2, declarationIndex);
    final order = orderByKey[strategy.channelKey];
    return order == null ? (1, declarationIndex) : (0, order);
  }

  /// 每个平台实际抓取的结果数；「全部」模式只预览前
  /// [allModePreviewLimit] 条，切到单源后展示完整列表。
  static const int _resultsPerProvider = 10;

  /// 「全部」模式每个来源的预览条数。
  static const int allModePreviewLimit = 3;

  /// 预览面板最多展示的歌词行数。
  static const int previewLineLimit = 3;

  /// 纯文本歌词里的元数据行（`[ti:...]` / `[ar:...]` 等），预览时跳过。
  static final RegExp _lyricMetadataLine = RegExp(r'^\[[a-zA-Z#]+:.*\]$');

  final List<LyricsSourceStrategy> _strategies;
  final LyricsProvider _lyricsProvider;
  final String _trackId;
  final String _trackTitle;
  final String _trackArtist;

  /// 种子曲目的专辑 / 时长：只参与最佳匹配，展示与写缓存不依赖它们。
  final String? _trackAlbum;
  final Duration? _trackDuration;

  /// 跨来源搜索的共享协议（查询代际 / 逐源状态 / 失败重试 / 选中失效）。
  late final FanOutSearchSession<LyricsSearchResult> _searchSession;

  bool _isFetchingLyric = false;
  bool _disposed = false;

  /// 当前预览只对 [_previewResult] 生效；选中项被搜索 / 重试清掉时，
  /// [preview] 读取会返回 null，不把旧歌词挂在新列表上。
  LyricsPreview? _preview;
  LyricsSearchResult? _previewResult;
  Future<void>? _previewFuture;

  /// 预览请求代际：快速连续点选时，旧请求晚到直接丢弃。
  int _previewGeneration = 0;

  /// 预览缓存按「provider + songId」：搜索重排 / 切筛选 / 再点回来都复用。
  final Map<String, _CachedLyricsPreview> _previewCache = {};

  /// 当前来源筛选（空串 = 全部）：只影响展示，不重搜、不清选中。
  ///
  /// 由会话持有而不是视图 State：与音频换源（`SourceSwapProvider`）的
  /// `activeSourceKey` 保持同一归属层，视图重建 / 切 tab 都不会丢筛选。
  String _activeSourceKey = '';

  /// 本次会话的来源（已按渠道开关过滤，并按渠道管理顺序排列）。
  List<LyricsSourceStrategy> get strategies => _strategies;

  /// 当前查询（已 trim；空串 = 未搜索 / 已清空）。
  String get query => _searchSession.query;

  /// 当前来源筛选（空串 = 全部）。
  String get activeSourceKey => _activeSourceKey;

  bool get isFetchingLyric => _isFetchingLyric;

  /// 当前选中项（未选中为 null）；视图据此画勾选与确认按钮可用态。
  LyricsSearchResult? get selected => _searchSession.selected;

  bool isSelected(LyricsSearchResult result) =>
      identical(_searchSession.selected, result);

  bool get isAnyProviderLoading => _searchSession.isSearching;

  /// 当前查询下搜索失败的来源（retry 只重搜这些，不重搜成功源）。
  List<LyricsSourceStrategy> get failedStrategies => [
    for (final strategy in _strategies)
      if (stateOf(strategy.provider.name) == ProviderSearchState.error)
        strategy,
  ];

  /// 全部结果：按来源声明顺序拼接；组内已把最佳匹配排到第一。
  List<LyricsSearchResult> get allResults => [
    for (final strategy in _strategies) ...resultsOf(strategy.provider.name),
  ];

  /// 选中结果的预览；没有选中、或选中项已被新查询清掉时为 null。
  ///
  /// 预览只跟随当前选中项，不在列表里按 provider 名称认领，避免快速切换
  /// 时把上一条的歌词显示在新选中行下面。
  LyricsPreview? get preview {
    final selected = this.selected;
    if (selected == null || !identical(_previewResult, selected)) return null;
    return _preview;
  }

  /// 选中项在当前筛选下是否真的有可见行。
  ///
  /// 「全部」模式还要受预览条数限制：用户在单源里选中第 5 条再切回全部，
  /// 这一行不在前 3 条里，确认按钮不能可用。
  bool get isSelectedVisible {
    final selected = this.selected;
    return selected != null && isResultVisible(selected);
  }

  bool isResultVisible(LyricsSearchResult result) {
    final results = resultsOf(result.provider.name);
    final index = results.indexWhere(
      (candidate) => identical(candidate, result),
    );
    if (index < 0) return false;
    if (_activeSourceKey.isEmpty) return index < allModePreviewLimit;
    return _strategies.any(
      (strategy) =>
          strategy.channelKey == _activeSourceKey &&
          strategy.provider.name == result.provider.name,
    );
  }

  /// 当前筛选下是否有可见结果（底栏只在此时出现）。
  bool get hasVisibleResults =>
      entries.any((entry) => entry.type == LyricsSearchEntryType.result);

  /// 当前筛选下唯一要标记「最佳匹配」的结果。
  ///
  /// 全部模式只标记一个全局最佳；单源模式只标记该来源最佳，避免列表里
  /// 同时出现多个「最佳匹配」徽章。
  LyricsSearchResult? get bestMatchForDisplay {
    if (_activeSourceKey.isEmpty) return _pickBestResult(allResults);
    for (final strategy in _strategies) {
      if (strategy.channelKey == _activeSourceKey) {
        return bestMatchOf(strategy.provider);
      }
    }
    return null;
  }

  bool isBestMatch(LyricsSearchResult result) =>
      identical(bestMatchForDisplay, result);

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
      _searchSession.statusOf(providerName);

  /// 某来源的结果（展示顺序）：最佳匹配排到组内第一，保证「全部」模式
  /// 的前 3 条预览里一定能看到它。
  List<LyricsSearchResult> resultsOf(String providerName) {
    final results = _searchSession.resultsOf(providerName);
    if (results.length < 2) return results;
    final best = _pickBestResult(results);
    if (best == null) return results;
    final index = results.indexWhere((result) => identical(result, best));
    if (index <= 0) return results;
    return List.unmodifiable([
      results[index],
      ...results.take(index),
      ...results.skip(index + 1),
    ]);
  }

  /// 按来源筛选的列表行。
  ///
  /// [channelKey] 省略 / null = 用会话当前筛选 [activeSourceKey]（空串 =
  /// 全部）：列出**有结果或有不可用原因**的来源（header + 结果）——未登录
  /// B 站没有结果，但 header 要挂「怎么办」提示。显式传 key 时只列该来源
  /// 结果（不再重复分组头）；header 与空态提示由视图承担。
  ///
  /// 「全部」模式每组只出前 [allModePreviewLimit] 条；单源模式出完整结果。
  List<LyricsSearchEntry> entriesFor([String? channelKey]) {
    final key = channelKey ?? _activeSourceKey;
    final all = key.isEmpty;
    final entries = <LyricsSearchEntry>[];
    for (final strategy in _strategies) {
      if (!all && strategy.channelKey != key) continue;
      final results = resultsOf(strategy.provider.name);
      if (!all) {
        for (final result in results) {
          entries.add(LyricsSearchEntry.result(result));
        }
        continue;
      }
      final unavailable = unavailableReasonOf(strategy);
      if (results.isEmpty && unavailable == null) continue;
      entries.add(LyricsSearchEntry.header(strategy));
      for (final result in results.take(allModePreviewLimit)) {
        entries.add(LyricsSearchEntry.result(result));
      }
    }
    return entries;
  }

  /// 当前筛选下的列表行。
  List<LyricsSearchEntry> get entries => entriesFor();

  /// 切换来源筛选；空串 = 全部。
  ///
  /// 只影响展示，不重搜、不清选中；筛选在会话内跨搜索 / 选中保留。重复
  /// 选择同一来源不通知，避免无意义重建。
  void selectSource(String key) {
    if (key == _activeSourceKey) return;
    _activeSourceKey = key;
    // 走扇出会话的通知节拍：作废排队中的合并通知，避免筛选切换后重建两次。
    _searchSession.notifyNow();
  }

  /// 该提供者分组内与当前曲目最相近的结果（时长 / 歌名 / 歌手 / 专辑）。
  ///
  /// 直接对扇出会话的原始结果挑选；[resultsOf] 再用同一判定重排，避免
  /// 「最佳」语义藏在展示排序里。
  LyricsSearchResult? bestMatchOf(LyricProvider provider) =>
      _pickBestResult(_searchSession.resultsOf(provider.name));

  /// 某来源在当前筛选下实际渲染的行数：全部模式封顶预览条数，单源模式
  /// 是完整结果。视图的卡片圆角与行位置都消费它。
  int displayedCountOf(String providerName) {
    final count = _searchSession.resultsOf(providerName).length;
    if (_activeSourceKey.isEmpty && count > allModePreviewLimit) {
      return allModePreviewLimit;
    }
    return count;
  }

  /// 某来源在当前筛选下是否还有未展示的结果（全部模式超过预览条数）。
  bool hasMoreOf(LyricsSourceStrategy strategy) =>
      _activeSourceKey.isEmpty &&
      _searchSession.resultsOf(strategy.provider.name).length >
          allModePreviewLimit;

  /// 在一组结果里按种子曲目的歌名 / 歌手 / 专辑 / 时长挑最佳。
  LyricsSearchResult? _pickBestResult(List<LyricsSearchResult> results) {
    if (results.isEmpty) return null;
    final best = pickBestSongMatch(
      [for (final result in results) result.match],
      title: _trackTitle,
      artist: _trackArtist,
      album: _trackAlbum,
      duration: _trackDuration,
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
  /// 「怎么办」。旧查询的在途响应由扇出会话的查询代际丢弃。
  Future<void> search(String query) async {
    // 取词在途时不换查询：applySelected 已经捕获旧选中项，结果不能和
    // 界面上刚出现的新查询 / 新候选错位。
    if (_isFetchingLyric || _disposed) return;
    // 新查询会清掉选中项：旧预览立刻失效，晚到的预览结果也按代际丢弃。
    _invalidatePreview();
    await _searchSession.search(query);
  }

  /// 重试当前查询下失败的来源（不重搜成功源，不改变查询与筛选）。
  ///
  /// 取词在途时 no-op：一次确认只做一件事，避免重试把正在写入的歌词
  /// 与候选状态搅在一起。
  Future<void> retryFailed() async {
    if (_isFetchingLyric) return;
    await _searchSession.retryFailed();
  }

  /// 单源搜索：结果包上取词实现（同一 provider 的 match + fetch 成对）。
  Future<List<LyricsSearchResult>> _searchProvider(
    LyricProvider provider,
    String query,
  ) async {
    final matches = await provider.searchMultiple(
      query,
      '',
      limit: _resultsPerProvider,
    );
    return [
      for (final match in matches)
        LyricsSearchResult(match: match, provider: provider),
    ];
  }

  /// 选中一条候选：切选中态并拉取预览（不写缓存）。
  ///
  /// 取词写缓存仍是确认按钮的显式动作：用户可以先比较来源 / 切换筛选，
  /// 再决定用哪一条，避免点错一次就写缓存一次。
  void select(LyricsSearchResult result) {
    // 确认后正在取词：锁住选中，否则 applySelected 写入的和界面显示的不一致。
    if (_isFetchingLyric || _disposed) return;

    final alreadySelected = identical(_searchSession.selected, result);
    if (alreadySelected) {
      // 同一行重复点击：已经在加载 / 成功 / 确实没有歌词时不再发请求；
      // 失败时允许再点一次重试。
      final status = _previewStatusFor(result);
      if (status != null && status != LyricsPreviewStatus.failed) return;
    }

    // 先把预览置为 loading / 命中缓存，再切选中：选中通知一次就把预览带出去。
    final previewFuture = _beginPreview(result);
    if (alreadySelected) {
      _notifyPreviewChanged();
    } else {
      _searchSession.select(result);
    }
    if (previewFuture != null) unawaited(previewFuture);
  }

  /// 预览失败后的显式重试；忽略缓存。
  void retryPreview() {
    final result = _searchSession.selected;
    if (result == null || _isFetchingLyric || _disposed) return;
    if (_previewStatusFor(result) == LyricsPreviewStatus.loading) return;
    final future = _beginPreview(result, force: true);
    _notifyPreviewChanged();
    if (future != null) unawaited(future);
  }

  /// 对当前选中项取词 → 规范化 → 写手动缓存。
  ///
  /// 预览已经拿到的 payload 直接复用；预览仍在途就等它结束；预览失败 /
  /// 为空时按约定重新取词一次，保证确认动作不依赖预览成功。
  Future<LyricsSelectionOutcome> applySelected() async {
    final result = _searchSession.selected;
    if (result == null) return const LyricsSelectionNone();
    if (_isFetchingLyric) return const LyricsSelectionBusy();

    _isFetchingLyric = true;
    _searchSession.notifyNow();

    try {
      var payload = _readyPayloadFor(result);
      if (payload == null &&
          _previewStatusFor(result) == LyricsPreviewStatus.loading) {
        final pendingPreview = _previewFuture;
        if (pendingPreview != null) await pendingPreview;
        payload = _readyPayloadFor(result);
      }
      payload ??= await result.provider.fetchForMatch(result.match);
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
      if (!_disposed) _searchSession.notifyNow();
    }
  }

  LyricsPreviewStatus? _previewStatusFor(LyricsSearchResult result) {
    if (!identical(_previewResult, result)) return null;
    return _preview?.status;
  }

  /// 准备当前选中项的预览：命中缓存直接出结果，否则置 loading 并起请求。
  ///
  /// 返回可等待的请求；缓存命中返回 null，视图 / 确认流程据此判断是否在途。
  Future<void>? _beginPreview(LyricsSearchResult result, {bool force = false}) {
    _previewGeneration++;
    _previewResult = result;
    _previewFuture = null;

    final cached = force ? null : _previewCache[_previewKey(result)];
    if (cached != null) {
      _preview = cached.preview;
      return null;
    }

    _preview = const LyricsPreview.loading();
    final generation = _previewGeneration;
    // 放到微任务：调用方（select）要先完成选中态切换，首个通知才能同时
    // 带上「已选中 + 预览加载中」；同步抛错的 provider 也不会抢在选中前
    // 通知一次空预览。
    final future = Future<void>.microtask(
      () => _fetchPreview(result, generation),
    );
    _previewFuture = future;
    return future;
  }

  Future<void> _fetchPreview(LyricsSearchResult result, int generation) async {
    // 排队微任务期间可能已经 dispose / 换选中：不再发无意义的取词请求。
    if (_disposed || generation != _previewGeneration) return;
    try {
      final payload = await result.provider.fetchForMatch(result.match);
      if (!_isCurrentPreview(result, generation)) return;
      final normalizedLyric = payload == null
          ? ''
          : result.provider.normalizeLyric(payload.lyric);
      final lines = _previewLines(normalizedLyric);
      if (payload == null || normalizedLyric.isEmpty || lines.isEmpty) {
        _previewCache[_previewKey(result)] = const _CachedLyricsPreview(
          LyricsPreview.empty(),
          null,
        );
        _preview = const LyricsPreview.empty();
        return;
      }
      final preview = LyricsPreview.ready(List.unmodifiable(lines));
      _previewCache[_previewKey(result)] = _CachedLyricsPreview(
        preview,
        payload,
      );
      _preview = preview;
    } catch (e) {
      if (!_isCurrentPreview(result, generation)) return;
      _logger.fine('Provider ${result.provider.name} preview error: $e');
      _preview = const LyricsPreview.failed();
    } finally {
      if (_isCurrentPreview(result, generation)) {
        _previewFuture = null;
        _notifyPreviewChanged();
      }
    }
  }

  /// 预览缓存命中且成功时返回可取词的 payload。
  LyricsPayload? _readyPayloadFor(LyricsSearchResult result) {
    if (!identical(_previewResult, result)) return null;
    if (_preview?.status != LyricsPreviewStatus.ready) return null;
    return _previewCache[_previewKey(result)]?.payload;
  }

  bool _isCurrentPreview(LyricsSearchResult result, int generation) =>
      !_disposed &&
      generation == _previewGeneration &&
      identical(_previewResult, result) &&
      identical(_searchSession.selected, result);

  static String _previewKey(LyricsSearchResult result) =>
      '${result.provider.name}\u0000${result.match.songId}';

  /// 预览只取前 [previewLineLimit] 行：LRC 走统一 parseLyrics，纯文本按行
  /// 过滤空行与 `[ti:...]` 等元数据行，两种格式都先经 provider 规范化。
  static List<String> _previewLines(String normalizedLyric) {
    final lines = hasLyricTimestamps(normalizedLyric)
        ? [for (final line in parseLyrics(normalizedLyric)) line.text]
        : [
            for (final line in normalizedLyric.split('\n'))
              if (_isPreviewTextLine(line)) line.trim(),
          ];
    return List.unmodifiable(lines.take(previewLineLimit));
  }

  static bool _isPreviewTextLine(String line) {
    final trimmed = line.trim();
    return trimmed.isNotEmpty && !_lyricMetadataLine.hasMatch(trimmed);
  }

  void _invalidatePreview() {
    _previewGeneration++;
    _preview = null;
    _previewResult = null;
    _previewFuture = null;
  }

  void _notifyPreviewChanged() {
    if (_disposed) return;
    _searchSession.notifyNow();
  }

  void _notifyListeners() => notifyListeners();

  @override
  void dispose() {
    _disposed = true;
    _invalidatePreview();
    _previewCache.clear();
    _searchSession
      ..removeListener(_notifyListeners)
      ..dispose();
    super.dispose();
  }
}
