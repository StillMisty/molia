/// 换源（跨音源找回同一首歌）的唯一状态机。
///
/// 职责：
/// - `begin`：按种子曲目「歌名 + 歌手」在可搜索音源并行检索
///   （逐源就绪即填充；单源失败不阻塞，可重试）；**保留种子源**，种子
///   曲目自身再按 URI 排除（同一渠道可能有其它版本 / 投稿）；
/// - 会话状态：分组候选 / 当前 tab / 选中项（不可变对象，UI 用 `Selector`）；
/// - `apply`：库内**原位替换**（列表/历史，经 [LibraryProvider]）与
///   **队列跟随**（经 [PlaybackProvider]，命中才跟随），两者解耦。
///
/// 与 LX 手动换源的差异：按源分组的原始结果不做严格过滤（人工挑选），
/// 严格匹配只用于自动换源（`AutoSourceSwapService`）。
library;

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../data/catalog/catalog_service.dart';
import '../domain/models/catalog.dart';
import '../domain/models/library.dart';
import '../domain/models/source.dart';
import '../domain/models/track.dart';
import '../domain/ports/source_registry.dart';
import '../services/source_swap/swap_query_planner.dart';
import 'library_provider.dart';
import 'playback_provider.dart';
import 'source_fan_out.dart';

final _logger = Logger('molia.source_swap_provider');

/// 换源写回位置。
enum SourceSwapPlacement {
  /// 收藏/自建列表内原位替换。
  playlist,

  /// 播放历史内原位替换。
  history,

  /// 仅替换播放队列（播放页入口，不落库）。
  queue,
}

/// 换源请求：种子曲目 + 写回位置。
class SourceSwapRequest {
  const SourceSwapRequest({
    required this.seed,
    required this.placement,
    this.playlistId,
    this.historyKey,
  });

  final Track seed;
  final SourceSwapPlacement placement;

  /// [SourceSwapPlacement.playlist] 时必填：目标列表（收藏/自建列表）。
  final int? playlistId;

  /// [SourceSwapPlacement.history] 时必填：历史行键。
  final TrackKey? historyKey;

  /// 种子在库内的键（与 `TrackId.id` 同规则）。
  TrackKey get seedKey => (sourceKey: seed.id.sourceKey, songId: seed.id.id);
}

/// 单个音源的候选分组。
class SourceSwapGroup {
  const SourceSwapGroup({
    required this.sourceKey,
    required this.displayName,
    required this.items,
  });

  final String sourceKey;
  final String displayName;
  final List<Track> items;
}

/// `apply` 结果（UI 据此提示/追问）。
enum SourceSwapApplyStatus {
  /// 已替换（库内与/或队列）。
  swapped,

  /// 目标已不在列表/历史/队列（数据已变化）。
  targetNotFound,

  /// 目标列表已存在所选曲目：确认后以 `removeDuplicate: true` 重试。
  duplicateConfirmationRequired,

  /// 库内写回失败（仓库抛错）：提示后保留弹层，队列不跟随。
  writeFailed,
}

class SourceSwapApplyResult {
  const SourceSwapApplyResult(this.status, {this.queueFollowed = false});

  final SourceSwapApplyStatus status;

  /// 播放队列是否跟随换源（库内换源时可能未命中，属正常）。
  final bool queueFollowed;
}

/// 换源成功后把曲目级本地数据（如自定义封面）带到新来源。
typedef SourceSwapTrackHook = Future<void> Function(Track seed, Track selected);

class SourceSwapProvider extends ChangeNotifier {
  SourceSwapProvider({
    required this._catalogService,
    required this._sourceRegistry,
    required this._swapQueryPlanner,
    required this._libraryProvider,
    required this._playbackProvider,
    this._onTrackSwapped,
  }) {
    // 查询代际 / 逐源状态 / 失败集合 / 选中项统一交给扇出会话；本类只保留
    // 换源请求、写回位置与分组展示。
    _searchSession = FanOutSearchSession<Track>(sources: _buildSearchSources)
      ..addListener(_notifyListeners);
  }

  /// 每个音源的候选上限（对齐 LX 弹窗的 25 条量级）。
  static const int perSourceLimit = 30;

  final CatalogService _catalogService;
  final SourceRegistry _sourceRegistry;
  final LibraryProvider _libraryProvider;
  final PlaybackProvider _playbackProvider;

  /// 换源查询的唯一规划入口（关键词口径与候选来源，与自动换源共用）。
  final SwapQueryPlanner _swapQueryPlanner;

  /// 写回成功后的曲目级本地数据钩子（自定义封面跟随；失败不影响换源）。
  final SourceSwapTrackHook? _onTrackSwapped;

  /// 跨来源搜索的共享协议（查询代际 / 逐源状态 / 失败重试 / 选中失效）。
  late final FanOutSearchSession<Track> _searchSession;

  /// dispose 后仍有微任务（视图推迟 clear、异步搜索收尾）会回到这里：
  /// 统一在通知边界吞掉，避免「used after being disposed」。
  bool _disposed = false;

  SourceSwapRequest? _request;
  bool _noSources = false;
  String _activeSourceKey = '';

  bool get isSearching => _searchSession.isSearching;
  bool get hasSession => _request != null;
  Track? get seed => _request?.seed;
  SourceSwapPlacement? get placement => _request?.placement;

  /// 当前搜索关键词（begin 按策略生成默认值，之后可由搜索栏改写）。
  String get keyword => _searchSession.query;

  /// 没有任何可搜索音源（搜索前即可判定）。
  bool get noSources => _noSources;

  /// 按来源分组的候选（只保留有结果的来源，顺序跟随注册表）。
  List<SourceSwapGroup> get groups {
    final names = {
      for (final descriptor in _sourceRegistry.descriptors)
        descriptor.key: descriptor.displayName,
    };
    final groups = <SourceSwapGroup>[];
    for (final source in _searchSession.sources) {
      final items = _searchSession.resultsOf(source.key);
      if (items.isEmpty) continue;
      groups.add(
        SourceSwapGroup(
          sourceKey: source.key,
          displayName: names[source.key] ?? source.key,
          items: items,
        ),
      );
    }
    return groups;
  }

  Set<String> get failedSourceKeys => _searchSession.failedKeys;

  /// 可搜索且启用的音源（含种子源；种子曲目自身在 [_searchTrack] 过滤）。
  ///
  /// 来源标签也只消费这份列表；停用 / 非搜索脚本不在其中时，
  /// `lyricsProviderLabel` 会回退源 key（已知下限）。
  List<SourceDescriptor> get searchableSources =>
      _swapQueryPlanner.searchableSources;

  /// 失败音源的展示名（按注册表顺序；描述符已被移除时回退 key）。
  ///
  /// UI 要报出具体名字（如「哔哩哔哩」）：用户据此判断值不值得点重试。
  List<String> get failedSourceNames {
    final failed = _searchSession.failedKeys;
    if (failed.isEmpty) return const [];
    final descriptors = _sourceRegistry.descriptors;
    final names = <String>[
      for (final descriptor in descriptors)
        if (failed.contains(descriptor.key)) descriptor.displayName,
    ];
    final knownKeys = {for (final descriptor in descriptors) descriptor.key};
    names.addAll(failed.where((key) => !knownKeys.contains(key)));
    return names;
  }

  /// 已启用的渠道 key（含当前不可搜索的内置平台）。
  ///
  /// 歌词来源跟随渠道停用开关：六个音乐平台没有 LX 脚本时不在
  /// `descriptors` 里，但用户没有停用它们，歌词来源仍应保留。
  Set<String> get enabledChannelKeys => _sourceRegistry.enabledChannelKeys;

  /// 全部渠道按渠道管理顺序排列（含停用 / 不可搜索的内置平台）。
  ///
  /// 歌词换源的 chips 顺序用它，不能用只含可搜索源的 [searchableSources]。
  List<String> get orderedChannelKeys => _sourceRegistry.orderedChannelKeys;

  /// 空串 = 全部来源。
  String get activeSourceKey => _activeSourceKey;
  Track? get selected => _searchSession.selected;

  /// 当前筛选下的候选：全部 = 按分组顺序拼接，单源 = 该组候选。
  List<Track> get activeItems {
    if (_activeSourceKey.isEmpty) {
      return [for (final group in groups) ...group.items];
    }
    for (final group in groups) {
      if (group.sourceKey == _activeSourceKey) return group.items;
    }
    return const [];
  }

  /// 开始换源会话：记录请求并立即发起跨源搜索。
  Future<void> begin(SourceSwapRequest request) async {
    _request = request;
    // 默认「全部」：视图自己按 groups 分组展示，不能自动落到第一个返回的源
    // （完成顺序不稳定，用户会看到筛选凭空跳走）。
    _activeSourceKey = '';
    // 手动换源保留种子源（同渠道可能有其它版本），因此不传排除集合。
    final plan = _swapQueryPlanner.plan(request.seed);
    _noSources = plan.sources.isEmpty;
    await _searchSession.search(plan.keyword);
  }

  /// 用新关键词重搜。
  ///
  /// 空串 = 清空会话（保留请求本身，便于搜索栏重新输入）。当前筛选源仍
  /// 可搜索时保留筛选，否则回到「全部」；旧搜索的在途结果由扇出会话的
  /// 查询代际丢弃。
  Future<void> search(String keyword) async {
    // 页面关闭后仍可能有排队回调（清空 / 提交）；没有会话就不该起搜索。
    if (_request == null) return;
    final normalized = keyword.trim();
    final descriptors = searchableSources;
    _noSources = descriptors.isEmpty;
    if (normalized.isEmpty) {
      _activeSourceKey = '';
    } else if (_activeSourceKey.isNotEmpty &&
        !descriptors.any((descriptor) => descriptor.key == _activeSourceKey)) {
      _activeSourceKey = '';
    }
    await _searchSession.search(normalized);
  }

  /// 重试失败音源（成功后清空失败集合）。
  Future<void> retryFailed() async {
    if (_request == null) return;
    await _searchSession.retryFailed();
  }

  /// 切换来源筛选；空串 = 全部。
  void selectSource(String sourceKey) {
    if (sourceKey == _activeSourceKey) return;
    _activeSourceKey = sourceKey;
    // 走扇出会话的通知节拍：作废排队中的合并通知，避免筛选切换后重建两次。
    _searchSession.notifyNow();
  }

  /// 选中候选（试听由 UI 层发起：选中与播放解耦，见弹层实现）。
  void select(Track track) {
    _searchSession.select(track);
  }

  void _notifyListeners() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _searchSession
      ..removeListener(_notifyListeners)
      ..dispose();
    super.dispose();
  }

  /// 清空会话（弹层关闭时调用；过期在途结果被扇出会话的查询代际丢弃）。
  void clear() {
    _request = null;
    _noSources = false;
    _activeSourceKey = '';
    _searchSession.clear();
  }

  /// 应用换源：库内原位替换（列表/历史）+ 队列跟随。
  ///
  /// [removeDuplicate]：目标列表已存在所选曲目时，确认后传 true
  /// （事务内删重复行并把旧行替换为新曲目）。
  ///
  /// 仓库写失败在边界收口成 [SourceSwapApplyStatus.writeFailed]：队列保持
  /// 原样（不跟随），弹层据此提示后可重试，不再把异常抛给调用方。
  Future<SourceSwapApplyResult> apply({bool removeDuplicate = false}) async {
    final request = _request;
    final selected = _searchSession.selected;
    if (request == null || selected == null) {
      return const SourceSwapApplyResult(SourceSwapApplyStatus.targetNotFound);
    }
    final seedKey = request.seedKey;
    final selectedKey = (
      sourceKey: selected.id.sourceKey,
      songId: selected.id.id,
    );
    // 写回行的时间字段（加入 / 播放历史）用同一次取时；历史侧真正的内容
    // 时间仍由仓库沿用旧行（见 LibraryWriteEngine.replaceHistoryEntry）。
    final now = DateTime.now().millisecondsSinceEpoch;

    switch (request.placement) {
      case SourceSwapPlacement.playlist:
        final playlistId = request.playlistId;
        if (playlistId == null) {
          return const SourceSwapApplyResult(
            SourceSwapApplyStatus.targetNotFound,
          );
        }
        final bool applied;
        try {
          if (!removeDuplicate &&
              await _libraryProvider.playlistContains(
                playlistId,
                selectedKey,
              )) {
            return const SourceSwapApplyResult(
              SourceSwapApplyStatus.duplicateConfirmationRequired,
            );
          }
          applied = await _libraryProvider.replacePlaylistTrack(
            playlistId,
            seedKey,
            PlaylistTrack.fromTrack(
              selected,
              playlistId: playlistId,
              addedAt: now,
            ),
          );
        } catch (e) {
          debugPrint('[SourceSwap] 换源写回列表失败: $e');
          return const SourceSwapApplyResult(SourceSwapApplyStatus.writeFailed);
        }
        if (!applied) {
          return const SourceSwapApplyResult(
            SourceSwapApplyStatus.targetNotFound,
          );
        }
        break; // 库内替换成功：继续队列跟随。
      case SourceSwapPlacement.history:
        final historyKey = request.historyKey;
        if (historyKey == null) {
          return const SourceSwapApplyResult(
            SourceSwapApplyStatus.targetNotFound,
          );
        }
        final bool applied;
        try {
          applied = await _libraryProvider.replaceHistoryEntry(
            historyKey,
            PlayHistoryEntry.fromTrack(selected, playedAt: now),
          );
        } catch (e) {
          debugPrint('[SourceSwap] 换源写回历史失败: $e');
          return const SourceSwapApplyResult(SourceSwapApplyStatus.writeFailed);
        }
        if (!applied) {
          return const SourceSwapApplyResult(
            SourceSwapApplyStatus.targetNotFound,
          );
        }
        break; // 同上：继续队列跟随。
      case SourceSwapPlacement.queue:
        final followed = await _playbackProvider.replaceQueueTrack(
          request.seed,
          selected,
        );
        if (followed) {
          await _notifyTrackSwapped(request.seed, selected);
          return const SourceSwapApplyResult(
            SourceSwapApplyStatus.swapped,
            queueFollowed: true,
          );
        }
        // 试听已把所选曲目接入播放（单曲试听队列已不含旧曲目）：视为已生效，
        // 否则仅队列入口的「试听 → 确认」会必然报「目标不在队列」。
        if (_playbackProvider.snapshot.current?.id == selected.id) {
          await _notifyTrackSwapped(request.seed, selected);
          return const SourceSwapApplyResult(
            SourceSwapApplyStatus.swapped,
            queueFollowed: true,
          );
        }
        return const SourceSwapApplyResult(
          SourceSwapApplyStatus.targetNotFound,
        );
    }

    // 队列跟随是尽力而为：库内已经写成功，播放队列替换失败不应把整次换源
    // 变成异常（页面会误以为需要重试）；只记录并报告「未跟随」。
    var followed = false;
    try {
      followed = await _playbackProvider.replaceQueueTrack(
        request.seed,
        selected,
      );
    } catch (e) {
      debugPrint('[SourceSwap] 换源后队列跟随失败: $e');
    }
    await _notifyTrackSwapped(request.seed, selected);
    return SourceSwapApplyResult(
      SourceSwapApplyStatus.swapped,
      queueFollowed: followed,
    );
  }

  /// 换源成功后的本地数据跟随：失败只记日志，不把已完成的换源变成异常。
  Future<void> _notifyTrackSwapped(Track seed, Track selected) async {
    try {
      await _onTrackSwapped?.call(seed, selected);
    } catch (e) {
      _logger.warning('换源后同步本地数据失败: $e');
    }
  }

  /// 当前可搜索来源 → 扇出会话适配器。
  ///
  /// 每次搜索都经 planner 重新求值：渠道启停 / 脚本增减会在 provider 存活
  /// 期间发生，适配器闭包拿到的是本轮查询对应的描述符。
  List<FanOutSource<Track>> _buildSearchSources() => [
    for (final descriptor in _swapQueryPlanner.searchableSources)
      FanOutSource<Track>(
        key: descriptor.key,
        search: (query) => _searchTrack(descriptor, query),
        // 结果自己的来源 key 用于「来源结果被替换时失效选中项」。
        sourceKeyOf: (track) => track.id.sourceKey,
      ),
  ];

  /// 单源搜索：种子自身按 URI 排除，同源重复结果只留一条。
  Future<List<Track>> _searchTrack(
    SourceDescriptor descriptor,
    String query,
  ) async {
    final page = await _catalogService.search(
      descriptor.key,
      SearchQuery(keyword: query, limit: perSourceLimit),
    );
    final seedUri = _request?.seed.id.uri;
    final seen = <String>{};
    return [
      for (final track in page.items)
        if (track.id.uri != seedUri && seen.add(track.id.uri)) track,
    ];
  }
}
