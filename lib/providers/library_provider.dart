/// 资料库状态：播放历史 / 我的列表 / 收藏 / `.lxmc` 导入 + 播放接线。
///
/// 职责：
/// - 内存缓存 history / playlists / 列表曲目 / 收藏键，仓库变更（[LibraryRepository.changes]）
///   时失效并重载（对齐「列表/历史查询结果在 provider 内做内存缓存」）；
/// - 把 [PlayHistoryEntry] / [PlaylistTrack] 还原为 [SourceTrack]（raw 原样带上）
///   并委托 [PlaybackProvider.playSourceTracks] 播放——播放时按需重新取链，
///   不持久化直链；
/// - 收藏切换（默认收藏列表）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/library_repository.dart';
import '../domain/models/library.dart';
import '../models/play_mode.dart';
import '../sources/raw_track.dart';
import '../sources/source_track.dart';
import 'playback_provider.dart';

class LibraryProvider extends ChangeNotifier {
  LibraryProvider({
    required LibraryRepository repository,
    required PlaybackProvider playbackProvider,
  })  : _repository = repository,
        _playback = playbackProvider {
    _subscription = _repository.changes.listen((_) => _onRepositoryChanged());
  }

  final LibraryRepository _repository;
  final PlaybackProvider _playback;
  StreamSubscription<void>? _subscription;

  List<PlayHistoryEntry> _history = const [];
  List<PlaylistInfo> _playlists = const [];
  final Map<int, List<PlaylistTrack>> _tracksByPlaylist = {};
  final Set<int> _loadingPlaylistIds = {};
  Set<String> _favoriteKeys = const {};

  bool _historyLoaded = false;
  bool _playlistsLoaded = false;
  bool _favoritesLoaded = false;
  bool _isHistoryLoading = false;
  bool _isPlaylistsLoading = false;

  bool _disposed = false;
  Future<void>? _pendingReload;

  List<PlayHistoryEntry> get history => _history;
  List<PlaylistInfo> get playlists => _playlists;

  /// 自建列表（不含默认收藏的内部保留行）。
  List<PlaylistInfo> get customPlaylists => [
        for (final playlist in _playlists)
          if (playlist.name != kFavoritesPlaylistName) playlist,
      ];

  bool get isHistoryLoading => _isHistoryLoading;
  bool get isPlaylistsLoading => _isPlaylistsLoading;

  bool isPlaylistLoading(int playlistId) =>
      _loadingPlaylistIds.contains(playlistId);

  List<PlaylistTrack>? cachedTracksOf(int playlistId) =>
      _tracksByPlaylist[playlistId];

  bool isFavorite(String sourceKey, String songId) =>
      _favoriteKeys.contains('$sourceKey:$songId');

  // -------------------------------------------------------------------------
  // 缓存刷新
  // -------------------------------------------------------------------------

  void _onRepositoryChanged() {
    if (_disposed) return;
    switch (_repository.lastChangeKind) {
      case LibraryChangeKind.history:
        // 只有历史变化：不清列表/收藏缓存；静默回载（不闪 loading）。
        _historyLoaded = false;
        _pendingReload = _reloadHistoryQuietly();
        unawaited(_pendingReload!);
      case LibraryChangeKind.favorites:
        // 收藏切换：收藏键已由 toggleFavorite 乐观更新；这里只做
        // 收藏列表曲目与计数的后台校准（旧列表保持可见，不闪 loading）。
        _pendingReload = _refreshFavoritesQuietly();
        unawaited(_pendingReload!);
      case LibraryChangeKind.playlistTracks:
        final playlistId = _repository.lastChangePlaylistId;
        _pendingReload = Future.wait([
          if (playlistId != null) _reloadPlaylistTracksQuietly(playlistId),
          _refreshPlaylistsQuietly(),
        ]);
        unawaited(_pendingReload!);
      case LibraryChangeKind.playlists:
      case LibraryChangeKind.import:
        _invalidateAll();
    }
  }

  void _invalidateAll() {
    // 立即失效缓存并通知（同步），后台静默重载；不做事件去重——
    // 去重标志会在微任务未执行时吞掉后续变更，导致 UI 永久陈旧。
    // 静默重载不翻转 loading：后台校准不闪加载态（已有数据保持可见）。
    _historyLoaded = false;
    _playlistsLoaded = false;
    _favoritesLoaded = false;
    _tracksByPlaylist.clear();
    _notify();
    _pendingReload = Future.wait([
      _reloadHistoryQuietly(),
      _refreshPlaylistsQuietly(),
      _refreshFavoritesQuietly(),
    ]);
    unawaited(_pendingReload!);
  }

  /// 历史变化的后台校准：保持当前列表可见，不翻转 loading。
  Future<void> _reloadHistoryQuietly() async {
    try {
      _history = await _repository.listHistory();
      _historyLoaded = true;
    } catch (e) {
      debugPrint('[Library] 重载播放历史失败: $e');
    }
    _notify();
  }

  /// 收藏变化的后台校准：列表保持可见，不翻转 loading。
  Future<void> _refreshFavoritesQuietly() async {
    try {
      _favoriteKeys = await _repository.favoriteKeys();
      _favoritesLoaded = true;
    } catch (e) {
      debugPrint('[Library] 刷新收藏状态失败: $e');
    }
    final favoritesId = _favoritesPlaylistId;
    if (favoritesId != null && _tracksByPlaylist.containsKey(favoritesId)) {
      try {
        _tracksByPlaylist[favoritesId] =
            await _repository.listPlaylistTracks(favoritesId);
      } catch (e) {
        debugPrint('[Library] 刷新收藏列表失败: $e');
      }
    }
    await _refreshPlaylistsQuietly();
    _notify();
  }

  /// 列表集合/计数后台刷新（不清曲目缓存、不闪 loading）。
  Future<void> _refreshPlaylistsQuietly() async {
    try {
      _playlists = await _repository.listPlaylists();
      _playlistsLoaded = true;
    } catch (e) {
      debugPrint('[Library] 刷新列表失败: $e');
    }
    _notify();
  }

  /// 单个列表曲目的后台重载：已缓存时原地替换（滚动位置/列表实例稳定）。
  Future<void> _reloadPlaylistTracksQuietly(int playlistId) async {
    if (!_tracksByPlaylist.containsKey(playlistId)) return;
    try {
      _tracksByPlaylist[playlistId] =
          await _repository.listPlaylistTracks(playlistId);
      _notify();
    } catch (e) {
      debugPrint('[Library] 重载列表曲目失败: $e');
    }
  }

  int? get _favoritesPlaylistId {
    for (final playlist in _playlists) {
      if (playlist.name == kFavoritesPlaylistName) return playlist.id;
    }
    return null;
  }

  /// 仅供测试/调试：最近一次仓库变更触发的重载 Future（完成后为 null 不安全，
  /// 这里保留最近一次，供测试确定性等待）。
  @visibleForTesting
  Future<void>? get pendingReload => _pendingReload;

  Future<void> refreshHistory({bool force = false}) async {
    if (_historyLoaded && !force) return;
    _isHistoryLoading = true;
    _notify();
    try {
      _history = await _repository.listHistory();
      _historyLoaded = true;
    } catch (e) {
      // 查询失败保持旧缓存（首次为空列表），避免 UI 崩溃。
      debugPrint('[Library] 加载播放历史失败: $e');
    } finally {
      _isHistoryLoading = false;
      _notify();
    }
  }

  Future<void> refreshPlaylists({bool force = false}) async {
    if (_playlistsLoaded && !force) return;
    _isPlaylistsLoading = true;
    _notify();
    try {
      _playlists = await _repository.listPlaylists();
      _playlistsLoaded = true;
    } catch (e) {
      debugPrint('[Library] 加载列表失败: $e');
    } finally {
      _isPlaylistsLoading = false;
      _notify();
    }
  }

  Future<void> ensureFavoritesLoaded({bool force = false}) async {
    if (_favoritesLoaded && !force) return;
    try {
      _favoriteKeys = await _repository.favoriteKeys();
      _favoritesLoaded = true;
      _notify();
    } catch (e) {
      debugPrint('[Library] 加载收藏状态失败: $e');
    }
  }

  /// 列表曲目：命中缓存直接返回，否则查询并缓存。
  Future<List<PlaylistTrack>> tracksOf(int playlistId) async {
    final cached = _tracksByPlaylist[playlistId];
    if (cached != null) return cached;
    return loadPlaylistTracks(playlistId);
  }

  Future<List<PlaylistTrack>> loadPlaylistTracks(
    int playlistId, {
    bool force = false,
  }) async {
    if (!force) {
      final cached = _tracksByPlaylist[playlistId];
      if (cached != null) return cached;
    }
    if (_loadingPlaylistIds.add(playlistId)) _notify();
    try {
      final tracks = await _repository.listPlaylistTracks(playlistId);
      _tracksByPlaylist[playlistId] = tracks;
      return tracks;
    } catch (e) {
      debugPrint('[Library] 加载列表曲目失败: $e');
      return _tracksByPlaylist[playlistId] ?? const [];
    } finally {
      _loadingPlaylistIds.remove(playlistId);
      _notify();
    }
  }

  // -------------------------------------------------------------------------
  // 播放接线（raw 原样 → SourceTrack → PlaybackProvider；按需重新取链）
  // -------------------------------------------------------------------------

  /// 播放音乐历史（[entries] 的可见顺序即播放队列顺序；[index] 为起始下标）。
  ///
  /// [mode] 非空时先切换播放模式（「播放全部」→顺序、「随机播放」→随机）。
  Future<void> playHistory(
    List<PlayHistoryEntry> entries,
    int index, {
    String? contextName,
    PlayMode? mode,
  }) async {
    if (entries.isEmpty) return;
    if (mode != null) {
      await _playback.setPlayMode(mode);
    }
    final tracks = [for (final entry in entries) _fromHistory(entry)];
    await _playback.playSourceTracks(
      tracks,
      index.clamp(0, tracks.length - 1),
      contextName: contextName,
    );
  }

  /// 播放指定列表（曲目来自缓存/仓库）。
  Future<void> playPlaylist(
    int playlistId,
    int index, {
    String? contextName,
  }) async {
    final tracks = [
      for (final track in await tracksOf(playlistId)) _fromPlaylistTrack(track),
    ];
    if (tracks.isEmpty) return;
    await _playback.playSourceTracks(
      tracks,
      index.clamp(0, tracks.length - 1),
      contextName: contextName,
    );
  }

  /// 按给定曲目顺序播放（收藏页搜索/排序后的可见顺序即播放队列顺序）。
  ///
  /// [mode] 非空时先切换播放模式（「播放全部」→顺序、「随机播放」→随机），
  /// 保证按钮语义与后续自动切歌行为一致；单曲点击不传 [mode]，尊重用户
  /// 当前模式。
  Future<void> playPlaylistTracks(
    List<PlaylistTrack> tracks,
    int index, {
    String? contextName,
    PlayMode? mode,
  }) async {
    if (tracks.isEmpty) return;
    if (mode != null) {
      await _playback.setPlayMode(mode);
    }
    await _playback.playSourceTracks(
      [for (final track in tracks) _fromPlaylistTrack(track)],
      index.clamp(0, tracks.length - 1),
      contextName: contextName,
    );
  }

  // -------------------------------------------------------------------------
  // 变更操作（仓库写 → changes 流触发缓存失效）
  // -------------------------------------------------------------------------

  Future<void> deleteHistoryEntry(PlayHistoryEntry entry) async {
    // 乐观更新本地缓存（列表即时移除，不等待变更流回载）。
    _history = [
      for (final item in _history)
        if (!(item.sourceKey == entry.sourceKey && item.songId == entry.songId))
          item,
    ];
    _notify();
    await _repository.deleteHistoryEntry(entry.sourceKey, entry.songId);
  }

  Future<void> clearHistory() async {
    // 乐观清空本地缓存（UI 立即显示空态，不等待变更流回载）。
    _history = const [];
    _historyLoaded = true;
    _notify();
    await _repository.clearHistory();
  }

  Future<bool> removeTrackFromPlaylist(PlaylistTrack track) async {
    final removed = await _repository.removeTrackFromPlaylist(
      track.playlistId,
      track.sourceKey,
      track.songId,
    );
    return removed > 0;
  }

  /// 批量移除列表曲目（返回实际移除数）。
  Future<int> removeTracksFromPlaylist(
    int playlistId,
    List<PlaylistTrack> tracks,
  ) {
    return _repository.removeTracksFromPlaylist(playlistId, [
      for (final track in tracks)
        (sourceKey: track.sourceKey, songId: track.songId),
    ]);
  }

  /// 批量复制曲目到目标列表（跳过重复；返回实际新增数）。
  Future<int> addTracksToPlaylist(
    int playlistId,
    List<PlaylistTrack> tracks,
  ) {
    return _repository.addTracksToPlaylist(playlistId, tracks);
  }

  /// 批量把播放历史复制到目标列表（历史条目转列表曲目）。
  Future<int> addHistoryEntriesToPlaylist(
    int playlistId,
    List<PlayHistoryEntry> entries,
  ) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return _repository.addTracksToPlaylist(playlistId, [
      for (final entry in entries)
        PlaylistTrack(
          playlistId: playlistId,
          sourceKey: entry.sourceKey,
          songId: entry.songId,
          title: entry.title,
          artist: entry.artist,
          album: entry.album,
          coverUrl: entry.coverUrl,
          durationMs: entry.durationMs,
          raw: entry.raw,
          addedAt: now,
        ),
    ]);
  }

  /// 新建列表（收藏页合集弹层 / 「加入列表」弹层使用）。
  Future<int> createPlaylist(String name) => _repository.createPlaylist(name);

  /// 把外部曲目导入同名本地列表（重复导入幂等）。
  ///
  /// 返回 `(playlistId, 本次新增数, 曲目总数)`；曲目为空时不落库。
  Future<({int playlistId, int added, int total})> importTracksAsPlaylist({
    required String name,
    required List<PlaylistTrack> tracks,
  }) async {
    final result = await _repository.importTracks(name, tracks);
    if (result.playlistId > 0 && result.added > 0) {
      await refreshPlaylists(force: true);
    }
    return result;
  }

  /// 批量把列表曲目加入播放历史（最近播放置顶）；返回写入条数。
  Future<int> addTracksToHistory(List<PlaylistTrack> tracks) {
    final now = DateTime.now().millisecondsSinceEpoch;
    var offset = 0;
    return _repository.addHistoryEntries([
      for (final track in tracks)
        PlayHistoryEntry(
          sourceKey: track.sourceKey,
          songId: track.songId,
          title: track.title,
          artist: track.artist,
          album: track.album,
          coverUrl: track.coverUrl,
          durationMs: track.durationMs,
          raw: track.raw,
          playedAt: now + offset++,
        ),
    ]);
  }

  /// 批量把历史条目重新置顶（「加入列表 → 播放历史」）。
  Future<int> addHistoryEntriesToHistory(List<PlayHistoryEntry> entries) {
    final now = DateTime.now().millisecondsSinceEpoch;
    var offset = 0;
    return _repository.addHistoryEntries([
      for (final entry in entries) entry.copyWith(playedAt: now + offset++),
    ]);
  }

  /// 批量把播放历史收藏进默认收藏列表（返回新增数）。
  Future<int> addHistoryEntriesToFavorites(List<PlayHistoryEntry> entries) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return addTracksToFavorites([
      for (final entry in entries)
        PlaylistTrack(
          playlistId: 0,
          sourceKey: entry.sourceKey,
          songId: entry.songId,
          title: entry.title,
          artist: entry.artist,
          album: entry.album,
          coverUrl: entry.coverUrl,
          durationMs: entry.durationMs,
          raw: entry.raw,
          addedAt: now,
        ),
    ]);
  }

  /// 按给定顺序重排列表曲目（`sortOrder` 事务重写）。
  Future<void> reorderPlaylistTracks(
    int playlistId,
    List<PlaylistTrack> ordered,
  ) async {
    await _repository.reorderPlaylistTracks(playlistId, [
      for (final track in ordered)
        (sourceKey: track.sourceKey, songId: track.songId),
    ]);
    // 本地缓存按同一顺序立即回写：重排落位后列表不闪回旧序；
    // changes 流的静默重载随后用数据库真实顺序二次校准。
    final cached = _tracksByPlaylist[playlistId];
    if (cached != null && cached.length == ordered.length) {
      _tracksByPlaylist[playlistId] = List.of(ordered);
      _notify();
    }
  }

  /// 批量收藏（跳过已收藏；返回新增数），收藏键缓存同步校准。
  Future<int> addTracksToFavorites(List<PlaylistTrack> tracks) async {
    final added = await _repository.addFavorites(tracks);
    if (added > 0) {
      final keys = Set<String>.from(_favoriteKeys);
      for (final track in tracks) {
        keys.add('${track.sourceKey}:${track.songId}');
      }
      _favoriteKeys = keys;
      _favoritesLoaded = true;
      _notify();
    }
    return added;
  }

  /// 批量取消收藏（返回移除数），收藏键缓存同步校准。
  Future<int> removeTracksFromFavorites(List<TrackKey> keys) async {
    final removed = await _repository.removeFavorites(keys);
    if (removed > 0) {
      final dropped = {
        for (final key in keys) '${key.sourceKey}:${key.songId}',
      };
      _favoriteKeys = {
        for (final key in _favoriteKeys)
          if (!dropped.contains(key)) key,
      };
      _favoritesLoaded = true;
      _notify();
    }
    return removed;
  }

  /// 批量删除历史记录（乐观更新本地缓存）。
  Future<int> deleteHistoryEntries(List<PlayHistoryEntry> entries) async {
    if (entries.isEmpty) return 0;
    final keys = {
      for (final entry in entries) '${entry.sourceKey}:${entry.songId}',
    };
    _history = [
      for (final item in _history)
        if (!keys.contains('${item.sourceKey}:${item.songId}')) item,
    ];
    _notify();
    return _repository.deleteHistoryEntries([
      for (final entry in entries)
        (sourceKey: entry.sourceKey, songId: entry.songId),
    ]);
  }

  Future<void> deletePlaylist(int playlistId) =>
      _repository.deletePlaylist(playlistId);

  Future<void> renamePlaylist(int playlistId, String name) =>
      _repository.renamePlaylist(playlistId, name);

  /// 收藏/取消收藏（当前播放曲目 / 搜索结果 / 列表曲目通用入口）。
  Future<bool> toggleFavorite({
    required String sourceKey,
    required String songId,
    required String title,
    String artist = '',
    String album = '',
    String? coverUrl,
    int? durationMs,
    Map<String, dynamic> raw = const {},
  }) async {
    final favorite = await _repository.toggleFavorite(
      sourceKey: sourceKey,
      songId: songId,
      title: title,
      artist: artist,
      album: album,
      coverUrl: coverUrl,
      durationMs: durationMs,
      raw: raw,
    );
    // 立即更新本地键集合，UI 无需等待 changes 流的下一次重载。
    final keys = Set<String>.from(_favoriteKeys);
    final key = '$sourceKey:$songId';
    if (favorite) {
      keys.add(key);
    } else {
      keys.remove(key);
    }
    _favoriteKeys = keys;
    _favoritesLoaded = true;
    _notify();
    return favorite;
  }

  Future<bool> toggleFavoriteSourceTrack(SourceTrack track) => toggleFavorite(
        sourceKey: track.sourceKey,
        songId: _songIdOfSourceTrack(track),
        title: track.title,
        artist: track.artist,
        album: track.album,
        coverUrl: track.coverUrl,
        durationMs: track.duration?.inMilliseconds,
        raw: track.raw,
      );

  /// 把音源曲目加入指定列表（发现页/搜索等入口使用；重复加入返回 false）。
  Future<bool> addSourceTrackToPlaylist(int playlistId, SourceTrack track) {
    return _repository.addTrackToPlaylist(
      playlistId,
      PlaylistTrack(
        playlistId: playlistId,
        sourceKey: track.sourceKey,
        songId: _songIdOfSourceTrack(track),
        title: track.title,
        artist: track.artist,
        album: track.album,
        coverUrl: track.coverUrl,
        durationMs: track.duration?.inMilliseconds,
        raw: track.raw,
        addedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  /// 搜索结果项收藏切换（item map 由 SearchProvider 生成，含 `_sourceTrack`）。
  /// 无法识别来源曲目时返回 null（调用方忽略）。
  Future<bool?> toggleFavoriteSearchItem(Map<String, dynamic> item) async {
    final sourceTrack = item['_sourceTrack'];
    if (sourceTrack is! SourceTrack) return null;
    return toggleFavoriteSourceTrack(sourceTrack);
  }

  /// 搜索结果项是否已收藏。
  bool isFavoriteSearchItem(Map<String, dynamic> item) {
    final sourceTrack = item['_sourceTrack'];
    if (sourceTrack is! SourceTrack) return false;
    return isFavorite(sourceTrack.sourceKey, _songIdOfSourceTrack(sourceTrack));
  }

  Future<bool> toggleFavoritePlaylistTrack(PlaylistTrack track) => toggleFavorite(
        sourceKey: track.sourceKey,
        songId: track.songId,
        title: track.title,
        artist: track.artist,
        album: track.album,
        coverUrl: track.coverUrl,
        durationMs: track.durationMs,
        raw: track.raw,
      );

  Future<bool> toggleFavoriteHistoryEntry(PlayHistoryEntry entry) =>
      toggleFavorite(
        sourceKey: entry.sourceKey,
        songId: entry.songId,
        title: entry.title,
        artist: entry.artist,
        album: entry.album,
        coverUrl: entry.coverUrl,
        durationMs: entry.durationMs,
        raw: entry.raw,
      );

  /// 导入 `.lxmc` 收藏夹；失败抛 [LxmcDecodeException]（由 UI 转 l10n 提示）。
  Future<LxmcImportResult> importLxmcBytes(
    Uint8List bytes, {
    String? fileName,
  }) async {
    final result =
        await _repository.importLxmcBytes(bytes, fileName: fileName);
    await Future.wait([
      refreshHistory(force: true),
      refreshPlaylists(force: true),
      ensureFavoritesLoaded(force: true),
    ]);
    return result;
  }

  // -------------------------------------------------------------------------
  // 模型转换
  // -------------------------------------------------------------------------

  SourceTrack _fromHistory(PlayHistoryEntry entry) => _toSourceTrack(
        sourceKey: entry.sourceKey,
        title: entry.title,
        artist: entry.artist,
        album: entry.album,
        coverUrl: entry.coverUrl,
        durationMs: entry.durationMs,
        raw: entry.raw,
      );

  SourceTrack _fromPlaylistTrack(PlaylistTrack track) => _toSourceTrack(
        sourceKey: track.sourceKey,
        title: track.title,
        artist: track.artist,
        album: track.album,
        coverUrl: track.coverUrl,
        durationMs: track.durationMs,
        raw: track.raw,
      );

  SourceTrack _toSourceTrack({
    required String sourceKey,
    required String title,
    required String artist,
    required String album,
    required String? coverUrl,
    required int? durationMs,
    required Map<String, dynamic> raw,
  }) {
    return SourceTrack(
      sourceKey: sourceKey,
      origin: 'lx',
      title: title,
      artist: artist,
      album: album,
      coverUrl: (coverUrl?.isNotEmpty ?? false) ? coverUrl : null,
      duration: (durationMs != null && durationMs > 0)
          ? Duration(milliseconds: durationMs)
          : null,
      qualities: qualitiesFromRaw(raw),
      // raw 原样（含 qualitys/_qualitys），取链时脚本依赖平台字段；
      // 仅补齐平台规范 id 别名（见 [withCanonicalId]）。
      raw: withCanonicalId(sourceKey: sourceKey, raw: raw),
    );
  }

  /// 与 `SourceTrack.id` / `TrackId.id` 一致的平台 id 提取规则（兜底标题-歌手）。
  static String _songIdOfSourceTrack(SourceTrack track) {
    final key = rawIdOf(track.raw);
    return key.isNotEmpty ? key : '${track.title}-${track.artist}';
  }

  /// dispose 后不再向已销毁的监听器发通知（仓库变更流是异步的，存在竞态）。
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    super.dispose();
  }
}
