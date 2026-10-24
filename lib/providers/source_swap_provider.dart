/// 换源（跨音源找回同一首歌）的唯一状态机。
///
/// 职责：
/// - `begin`：按种子曲目「歌名 + 歌手」在**其它**可搜索音源并行检索
///   （逐源就绪即填充；单源失败不阻塞，可重试）；
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
import 'library_provider.dart';
import 'playback_provider.dart';

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
  TrackKey get seedKey =>
      (sourceKey: seed.id.sourceKey, songId: seed.id.id);
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
  const SourceSwapApplyResult(
    this.status, {
    this.queueFollowed = false,
  });

  final SourceSwapApplyStatus status;

  /// 播放队列是否跟随换源（库内换源时可能未命中，属正常）。
  final bool queueFollowed;
}

class SourceSwapProvider extends ChangeNotifier {
  SourceSwapProvider({
    required CatalogService catalogService,
    required SourceRegistry sourceRegistry,
    required LibraryProvider libraryProvider,
    required PlaybackProvider playbackProvider,
  })  : _catalogService = catalogService,
        _sourceRegistry = sourceRegistry,
        _libraryProvider = libraryProvider,
        _playbackProvider = playbackProvider;

  /// 每个音源的候选上限（对齐 LX 弹窗的 25 条量级）。
  static const int perSourceLimit = 30;

  final CatalogService _catalogService;
  final SourceRegistry _sourceRegistry;
  final LibraryProvider _libraryProvider;
  final PlaybackProvider _playbackProvider;

  /// 会话 id：换源开始/清空时自增，过期搜索结果直接丢弃。
  int _sessionId = 0;

  SourceSwapRequest? _request;
  String _keyword = '';
  bool _isSearching = false;
  bool _noOtherSources = false;
  List<SourceSwapGroup> _groups = const [];
  final Set<String> _failedSourceKeys = <String>{};
  String _activeSourceKey = '';
  Track? _selected;

  bool get isSearching => _isSearching;
  bool get hasSession => _request != null;
  Track? get seed => _request?.seed;
  SourceSwapPlacement? get placement => _request?.placement;

  /// 没有任何「其它可搜索音源」（搜索前即可判定）。
  bool get noOtherSources => _noOtherSources;

  List<SourceSwapGroup> get groups => _groups;
  Set<String> get failedSourceKeys => Set.unmodifiable(_failedSourceKeys);
  String get activeSourceKey => _activeSourceKey;
  Track? get selected => _selected;

  /// 当前 tab 的候选（无该分组时为空）。
  List<Track> get activeItems {
    for (final group in _groups) {
      if (group.sourceKey == _activeSourceKey) return group.items;
    }
    return const [];
  }

  /// 开始换源会话：记录请求并立即发起跨源搜索。
  Future<void> begin(SourceSwapRequest request) async {
    final sessionId = ++_sessionId;
    _request = request;
    _groups = const [];
    _failedSourceKeys.clear();
    _activeSourceKey = '';
    _selected = null;
    _keyword = _buildKeyword(request.seed);

    final descriptors = _otherSearchableSources(request.seed);
    _noOtherSources = descriptors.isEmpty;
    _isSearching = !_noOtherSources;
    notifyListeners();
    if (descriptors.isEmpty) return;

    await Future.wait([
      for (final descriptor in descriptors)
        _searchSource(sessionId, descriptor),
    ]);
    if (sessionId != _sessionId) return;
    _isSearching = false;
    notifyListeners();
  }

  /// 重试失败音源（成功后清空失败集合）。
  Future<void> retryFailed() async {
    final request = _request;
    if (request == null || _failedSourceKeys.isEmpty || _isSearching) return;
    final sessionId = _sessionId;
    final descriptors = _otherSearchableSources(request.seed)
        .where((descriptor) => _failedSourceKeys.contains(descriptor.key))
        .toList();
    if (descriptors.isEmpty) return;
    _failedSourceKeys.clear();
    _isSearching = true;
    notifyListeners();
    await Future.wait([
      for (final descriptor in descriptors) _searchSource(sessionId, descriptor),
    ]);
    if (sessionId != _sessionId) return;
    _isSearching = false;
    notifyListeners();
  }

  /// 切换当前音源 tab。
  void selectSource(String sourceKey) {
    if (sourceKey == _activeSourceKey) return;
    _activeSourceKey = sourceKey;
    notifyListeners();
  }

  /// 选中候选（试听由 UI 层发起：选中与播放解耦，见弹层实现）。
  void select(Track track) {
    if (_selected == track) return;
    _selected = track;
    notifyListeners();
  }

  /// 清空会话（弹层关闭时调用；过期在途结果被会话 id 守卫丢弃）。
  void clear() {
    _sessionId++;
    _request = null;
    _keyword = '';
    _isSearching = false;
    _noOtherSources = false;
    _groups = const [];
    _failedSourceKeys.clear();
    _activeSourceKey = '';
    _selected = null;
    notifyListeners();
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
    final selected = _selected;
    if (request == null || selected == null) {
      return const SourceSwapApplyResult(SourceSwapApplyStatus.targetNotFound);
    }
    final seedKey = request.seedKey;
    final selectedKey =
        (sourceKey: selected.id.sourceKey, songId: selected.id.id);

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
            _toPlaylistTrack(playlistId, selected),
          );
        } catch (e) {
          debugPrint('[SourceSwap] 换源写回列表失败: $e');
          return const SourceSwapApplyResult(
            SourceSwapApplyStatus.writeFailed,
          );
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
            _toHistoryEntry(selected),
          );
        } catch (e) {
          debugPrint('[SourceSwap] 换源写回历史失败: $e');
          return const SourceSwapApplyResult(
            SourceSwapApplyStatus.writeFailed,
          );
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
          return const SourceSwapApplyResult(
            SourceSwapApplyStatus.swapped,
            queueFollowed: true,
          );
        }
        // 试听已把所选曲目接入播放（单曲试听队列已不含旧曲目）：视为已生效，
        // 否则仅队列入口的「试听 → 确认」会必然报「目标不在队列」。
        if (_playbackProvider.snapshot.current?.id == selected.id) {
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
    return SourceSwapApplyResult(
      SourceSwapApplyStatus.swapped,
      queueFollowed: followed,
    );
  }

  List<SourceDescriptor> _otherSearchableSources(Track seed) => [
        for (final descriptor in _sourceRegistry.descriptors)
          if (descriptor.enabled &&
              descriptor.capabilities.search &&
              descriptor.key != seed.id.sourceKey)
            descriptor,
      ];

  /// 搜索关键词：歌名 + 歌手（空段过滤），对齐 LX 的 `name + singer`。
  static String _buildKeyword(Track seed) => [
        seed.title,
        ...seed.artists.map((artist) => artist.name),
      ].map((value) => value.trim()).where((value) => value.isNotEmpty).join(' ');

  /// 单源搜索：结果就绪即并入分组（渐进渲染）；失败记入 [failedSourceKeys]。
  Future<void> _searchSource(int sessionId, SourceDescriptor descriptor) async {
    try {
      final page = await _catalogService.search(
        descriptor.key,
        SearchQuery(keyword: _keyword, limit: perSourceLimit),
      );
      if (sessionId != _sessionId) return;
      final seedUri = _request?.seed.id.uri;
      final seen = <String>{};
      final items = <Track>[
        for (final track in page.items)
          if (track.id.uri != seedUri && seen.add(track.id.uri)) track,
      ];
      if (items.isEmpty) return;
      _groups = [
        ..._groups,
        SourceSwapGroup(
          sourceKey: descriptor.key,
          displayName: descriptor.displayName,
          items: items,
        ),
      ];
      if (_activeSourceKey.isEmpty) _activeSourceKey = descriptor.key;
      notifyListeners();
    } catch (e) {
      if (sessionId != _sessionId) return;
      _logger.fine('换源搜索失败 ${descriptor.key}: $e');
      _failedSourceKeys.add(descriptor.key);
      notifyListeners();
    }
  }

  PlaylistTrack _toPlaylistTrack(int playlistId, Track track) {
    return PlaylistTrack(
      playlistId: playlistId,
      sourceKey: track.id.sourceKey,
      songId: track.id.id,
      title: track.title,
      artist: track.artistLabel,
      album: track.album ?? '',
      coverUrl: track.artwork?.uri.toString(),
      durationMs: track.duration?.inMilliseconds,
      // payload 原样透传（取链依赖平台字段）；浅拷贝避免与领域对象共享引用。
      raw: Map<String, dynamic>.from(track.payload),
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  PlayHistoryEntry _toHistoryEntry(Track track) {
    return PlayHistoryEntry(
      sourceKey: track.id.sourceKey,
      songId: track.id.id,
      title: track.title,
      artist: track.artistLabel,
      album: track.album ?? '',
      coverUrl: track.artwork?.uri.toString(),
      durationMs: track.duration?.inMilliseconds,
      raw: Map<String, dynamic>.from(track.payload),
      playedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }
}
