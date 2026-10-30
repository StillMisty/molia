/// 收藏页合集动作：把选中的行 / 当前视图翻译成一次类型化命令。
///
/// 为什么单独一层：页面原先在流程回调里按行变体拆播放队列、收藏 / 移除 /
/// 删除、排序重建与复制归一，还散着 `as HistoryCollectionRow` /
/// `as TrackCollectionRow` 强转——行形状不对就是运行时崩溃，本地删除则绕过
/// 类型化结果直接 `unawaited`，失败既没计数也没反馈。这里收成一份「行 →
/// 命令载荷 → 端口调用」，页面只留确认 / 提示 / 清选择与布局；播放与加入列表
/// 仍交给 TrackHandoff（洗牌、上下文名、批量 `addedAt` 只有一份实现）。
///
/// 编排本身不读 BuildContext，也不弹任何 UI：生产端口由页面按 context 组装，
/// 单测直接用假端口断言命令矩阵（含混合行变体与部分失败）。本模块不 import
/// Flutter / widgets：播放 / 加入列表的 context 适配在
/// `lib/widgets/collection_handoff.dart`，编排仍然只有 TrackHandoff 一份。
library;

import '../domain/models/download.dart';
import '../domain/models/library.dart';
import '../domain/models/track.dart';
import '../services/download/download_manager.dart';
import '../services/track_local_data_service.dart';
import 'collection_presenter.dart';
import 'library_outcome.dart';
import 'library_provider.dart';
import 'local_songs_collection.dart';

/// 收藏切换意图：由当前收藏状态推导，避免把「加 / 删」写成布尔开关。
enum CollectionFavoriteChange { add, remove }

/// 本地歌曲删除的来源：删除动作与确认文案都按它区分。
enum CollectionLocalDeleteKind {
  /// 下载副本：删记录 + 文件。
  download,

  /// 本地导入：只移出列表，不动用户原文件。
  imported,

  /// 缓存行：只清音频缓存。
  cached,
}

/// 一条本地歌曲的删除结果。
enum CollectionLocalDeleteStatus {
  /// 下载副本已删除（记录 + 文件）。
  deleted,

  /// 导入项已移出列表（原文件未动）。
  removed,

  /// 缓存行已清掉音频缓存。
  cleared,

  /// 缓存没清掉（正在写入 / 本来就没有），[CollectionLocalDeleteItem.skippedFiles]
  /// 区分原因（> 0 = 写入中跳过）。
  skipped,

  /// 删除抛错（异常收口在这里，不再逃进 `unawaited`）。
  failed,

  /// 能力不可用（未注入下载 / 本地数据服务）。
  unavailable,
}

/// 一条本地歌曲的删除结果明细。
final class CollectionLocalDeleteItem {
  const CollectionLocalDeleteItem({
    required this.song,
    required this.kind,
    required this.status,
    this.skippedFiles = 0,
    this.error,
  });

  final CollectionLocalSong song;
  final CollectionLocalDeleteKind kind;
  final CollectionLocalDeleteStatus status;

  /// 因正在写入被跳过的缓存文件数（只有缓存行可能 > 0）。
  final int skippedFiles;

  /// 失败原因（只用于日志 / 测试，页面统一说「操作失败」）。
  final Object? error;

  bool get isFailure => status == CollectionLocalDeleteStatus.failed;
}

/// 一次本地歌曲删除的汇总结果（页面按明细给反馈，按计数做断言）。
final class CollectionLocalDeleteOutcome {
  const CollectionLocalDeleteOutcome(this.items);

  final List<CollectionLocalDeleteItem> items;

  int get deleted => _count(CollectionLocalDeleteStatus.deleted);
  int get removed => _count(CollectionLocalDeleteStatus.removed);
  int get cleared => _count(CollectionLocalDeleteStatus.cleared);
  int get skipped => _count(CollectionLocalDeleteStatus.skipped);
  int get failed => _count(CollectionLocalDeleteStatus.failed);
  int get unavailable => _count(CollectionLocalDeleteStatus.unavailable);

  bool get hasFailure => failed > 0;

  int _count(CollectionLocalDeleteStatus status) =>
      items.where((item) => item.status == status).length;
}

/// 换源种子：行变体归一后的产物，页面只把它交给换源页。
///
/// [playlistId] 与 [historyKey] 互斥地表达写回位置（列表 / 历史）。
final class CollectionSwapSeed {
  const CollectionSwapSeed({
    required this.track,
    this.playlistId,
    this.historyKey,
  });

  final Track track;
  final int? playlistId;
  final TrackKey? historyKey;
}

/// 资料库读写面：合集命令只碰这些成员。
///
/// 用窄端口而不是直接拿 [LibraryProvider]：命令矩阵可以在纯 Dart 单测里用假
/// 实现断言，不需要构造 provider / 仓库 / 数据库。
abstract interface class CollectionActionLibrary {
  Track trackFromPlaylistTrack(PlaylistTrack track);

  Track trackFromHistoryEntry(PlayHistoryEntry entry);

  bool isFavorite(String sourceKey, String songId);

  Future<LibraryMutationOutcome> addTracksToFavorites(
    List<PlaylistTrack> tracks,
  );

  Future<LibraryMutationOutcome> removeTracksFromFavorites(List<TrackKey> keys);

  Future<LibraryMutationOutcome> removeTracksFromPlaylist(
    int playlistId,
    List<PlaylistTrack> tracks,
  );

  Future<LibraryMutationOutcome> deleteHistoryEntries(
    List<PlayHistoryEntry> entries,
  );

  Future<LibraryMutationOutcome> clearHistory();

  Future<LibraryMutationOutcome> reorderPlaylistTracks(
    int playlistId,
    List<PlaylistTrack> ordered,
  );
}

/// [CollectionActionLibrary] 的生产实现：全部转发到资料库变更网关。
final class LibraryProviderCollectionActions
    implements CollectionActionLibrary {
  const LibraryProviderCollectionActions(this._provider);

  final LibraryProvider _provider;

  @override
  Track trackFromPlaylistTrack(PlaylistTrack track) =>
      _provider.trackFromPlaylistTrack(track);

  @override
  Track trackFromHistoryEntry(PlayHistoryEntry entry) =>
      _provider.trackFromHistoryEntry(entry);

  @override
  bool isFavorite(String sourceKey, String songId) =>
      _provider.isFavorite(sourceKey, songId);

  @override
  Future<LibraryMutationOutcome> addTracksToFavorites(
    List<PlaylistTrack> tracks,
  ) => _provider.addTracksToFavorites(tracks);

  @override
  Future<LibraryMutationOutcome> removeTracksFromFavorites(
    List<TrackKey> keys,
  ) => _provider.removeTracksFromFavorites(keys);

  @override
  Future<LibraryMutationOutcome> removeTracksFromPlaylist(
    int playlistId,
    List<PlaylistTrack> tracks,
  ) => _provider.removeTracksFromPlaylist(playlistId, tracks);

  @override
  Future<LibraryMutationOutcome> deleteHistoryEntries(
    List<PlayHistoryEntry> entries,
  ) => _provider.deleteHistoryEntries(entries);

  @override
  Future<LibraryMutationOutcome> clearHistory() => _provider.clearHistory();

  @override
  Future<LibraryMutationOutcome> reorderPlaylistTracks(
    int playlistId,
    List<PlaylistTrack> ordered,
  ) => _provider.reorderPlaylistTracks(playlistId, ordered);
}

/// 曲目交接端口：播放 / 加入列表都委托给 TrackHandoff。
///
/// 单独定义是为了让命令层可单测：假实现记录「交给播放的曲目 / 下标 / 洗牌 /
/// 上下文名」。生产实现需要 BuildContext，放在 widget 层
/// （`lib/widgets/collection_handoff.dart`），本模块保持 context-free。
abstract interface class CollectionHandoff {
  Future<void> play(
    List<Track> tracks, {
    required int startIndex,
    required bool shuffle,
    required String contextName,
  });

  Future<bool> addToLibrary(
    List<PlaylistTrack> tracks, {
    required bool includeFavorites,
    required bool includeHistory,
  });
}

/// 本地数据删除端口（下载记录 + 音频缓存）。
abstract interface class CollectionLocalData {
  /// 下载 / 导入能力是否可用（未注入下载服务 = 不可用）。
  bool get available;

  Future<void> deleteDownload(DownloadedTrack record);

  /// 清音频缓存；null = 本地数据服务不可用。
  Future<LocalCacheClearResult?> clearCachedAudio(Track track);
}

/// [CollectionLocalData] 的生产实现：转发下载 / 本地数据服务。
final class ProviderCollectionLocalData implements CollectionLocalData {
  const ProviderCollectionLocalData({this._downloads, this._localData});

  final DownloadManager? _downloads;
  final TrackLocalDataService? _localData;

  @override
  bool get available => _downloads != null;

  @override
  Future<void> deleteDownload(DownloadedTrack record) async {
    final downloads = _downloads;
    if (downloads == null) {
      throw StateError('下载服务不可用');
    }
    await downloads.delete(record);
  }

  @override
  Future<LocalCacheClearResult?> clearCachedAudio(Track track) {
    final localData = _localData;
    if (localData == null) return Future.value();
    return localData.clear(track, LocalCachePart.audio);
  }
}

/// 合集动作编排：视图 / 行 → 命令 → 端口。
///
/// 页面每次点按现建一个实例（端口按当时 context 组装），方法都返回类型化
/// 结果；确认框、snackbar、触感以外的选择清空仍由页面决定。
final class CollectionActions {
  CollectionActions({
    required this._library,
    required this._handoff,
    this._localData,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final CollectionActionLibrary _library;
  final CollectionHandoff _handoff;
  final CollectionLocalData? _localData;
  final DateTime Function() _clock;

  /// 本地歌曲删除能力（页面据此决定是否弹确认，保持「服务缺席不弹框」）。
  bool get localDataAvailable => _localData?.available ?? false;

  int get _addedAt => _clock().millisecondsSinceEpoch;

  /// 从 [startIndex] 起播可见行：可见顺序即队列顺序，洗牌与上下文名交给
  /// TrackHandoff。历史行还原成历史曲目、本地歌曲行还原成 `local` 源快照。
  Future<void> play(
    CollectionView view, {
    int startIndex = 0,
    bool shuffle = false,
  }) {
    final rows = view.visibleRows;
    if (rows.isEmpty) return Future.value();
    final addedAt = _addedAt;
    final tracks = [
      for (final row in rows)
        switch (row) {
          TrackCollectionRow(:final track) => _library.trackFromPlaylistTrack(
            track,
          ),
          HistoryCollectionRow(:final entry) => _library.trackFromHistoryEntry(
            entry,
          ),
          LocalSongCollectionRow(:final song) =>
            _library.trackFromPlaylistTrack(
              song.toPlaylistTrack(addedAt: addedAt),
            ),
        },
    ];
    return _handoff.play(
      tracks,
      startIndex: startIndex,
      shuffle: shuffle,
      contextName: view.displayName,
    );
  }

  /// 当前选中的行「点收藏」会做什么：全部已收藏 → 取消，否则 → 收藏。
  ///
  /// 空选择按「收藏」处理（入口只在有选择时出现，空集合不可达）。
  CollectionFavoriteChange favoriteChange(Iterable<CollectionRow> rows) {
    final selected = List<CollectionRow>.of(rows);
    if (selected.isEmpty) return CollectionFavoriteChange.add;
    final allFavorited = selected.every(
      (row) => _library.isFavorite(
        row.favoriteKey.sourceKey,
        row.favoriteKey.songId,
      ),
    );
    return allFavorited
        ? CollectionFavoriteChange.remove
        : CollectionFavoriteChange.add;
  }

  /// 批量收藏 / 取消收藏：三种行都用行联合的曲目快照 / 收藏键。
  Future<LibraryMutationOutcome> setFavorite(
    Iterable<CollectionRow> rows, {
    required CollectionFavoriteChange change,
  }) {
    final selected = List<CollectionRow>.of(rows);
    if (selected.isEmpty) {
      return Future.value(const LibraryMutationOutcome.unchanged());
    }
    final addedAt = _addedAt;
    return switch (change) {
      CollectionFavoriteChange.add => _library.addTracksToFavorites([
        for (final row in selected) row.toPlaylistTrack(addedAt: addedAt),
      ]),
      CollectionFavoriteChange.remove => _library.removeTracksFromFavorites([
        for (final row in selected) row.favoriteKey,
      ]),
    };
  }

  /// 单行收藏开关（本地歌曲行动作）：按此刻收藏状态决定加 / 删。
  Future<LibraryMutationOutcome> toggleFavorite(Iterable<CollectionRow> rows) {
    final selected = List<CollectionRow>.of(rows);
    return setFavorite(selected, change: favoriteChange(selected));
  }

  /// 从当前自建列表移除选中行（只取列表曲目行，其余变体显式忽略）。
  Future<LibraryMutationOutcome> removeFromPlaylist(
    CollectionView view,
    Iterable<CollectionRow> rows,
  ) {
    final playlistId = view.playlistId;
    final tracks = [
      for (final row in rows)
        if (row case TrackCollectionRow(:final track)) track,
    ];
    if (playlistId == null || tracks.isEmpty) {
      return Future.value(const LibraryMutationOutcome.unchanged());
    }
    return _library.removeTracksFromPlaylist(playlistId, tracks);
  }

  /// 删除选中的播放历史（只取历史行，其余变体显式忽略）。
  Future<LibraryMutationOutcome> deleteHistory(Iterable<CollectionRow> rows) {
    final entries = [
      for (final row in rows)
        if (row case HistoryCollectionRow(:final entry)) entry,
    ];
    if (entries.isEmpty) {
      return Future.value(const LibraryMutationOutcome.unchanged());
    }
    return _library.deleteHistoryEntries(entries);
  }

  /// 清空播放历史（「清空历史」确认弹窗的写入面）。
  Future<LibraryMutationOutcome> clearHistory() => _library.clearHistory();

  /// 选中行里的本地歌曲（删除确认的输入，按可见顺序）。
  List<CollectionLocalSong> localSongsOf(Iterable<CollectionRow> rows) => [
    for (final row in rows)
      if (row case LocalSongCollectionRow(:final song)) song,
  ];

  /// 删除本地歌曲：下载副本删记录 + 文件、导入项只移出列表、缓存行清缓存。
  ///
  /// 逐条处理并收口异常：一条失败不阻断其余，结果按明细返回给页面。
  Future<CollectionLocalDeleteOutcome> deleteLocalSongs(
    Iterable<CollectionLocalSong> songs,
  ) async {
    final items = <CollectionLocalDeleteItem>[];
    for (final song in songs) {
      items.add(await _deleteLocalSong(song));
    }
    return CollectionLocalDeleteOutcome(items);
  }

  /// 拖动排序落位：M3E 宿主给的是「直接移动」语义（曲目落在目标下标）。
  ///
  /// 用当前可见的有序列表整体重建（与页面原实现同一口径），写回由资料库网关
  /// 事务重写 `sortOrder`；本地缓存顺序也由网关按同一列表回写。
  Future<LibraryMutationOutcome> reorder(
    CollectionView view,
    int from,
    int to,
  ) {
    final playlistId = view.playlistId;
    final tracks = [
      for (final row in view.visibleRows)
        if (row case TrackCollectionRow(:final track)) track,
    ];
    if (playlistId == null ||
        from == to ||
        from < 0 ||
        to < 0 ||
        from >= tracks.length ||
        to >= tracks.length) {
      return Future.value(const LibraryMutationOutcome.unchanged());
    }
    final reordered = List<PlaylistTrack>.of(tracks);
    reordered.insert(to, reordered.removeAt(from));
    return _library.reorderPlaylistTracks(playlistId, reordered);
  }

  /// 复制选中行到资料库目标（我的收藏 / 播放历史 / 自建列表）。
  ///
  /// 三种行先统一成 [PlaylistTrack]（历史行同批共用一个 `addedAt`），目标选择
  /// 与写入反馈仍走 TrackHandoff → Add-to-library flow。返回是否真正选择目标
  /// 并写入（取消为 false）。
  Future<bool> copyToLibrary(
    CollectionView view,
    Iterable<CollectionRow> rows,
  ) {
    final addedAt = _addedAt;
    final tracks = [
      for (final row in rows) row.toPlaylistTrack(addedAt: addedAt),
    ];
    if (tracks.isEmpty) return Future.value(false);
    return _handoff.addToLibrary(
      tracks,
      includeFavorites: !view.isFavorites,
      includeHistory: !view.isHistory,
    );
  }

  /// 一行的动作载荷：行变体归一 + 具体命令选择都在这里，页面只接线。
  CollectionRowCommands rowCommands(CollectionView view, CollectionRow row) =>
      switch (row) {
        TrackCollectionRow(:final track) => TrackCollectionRowCommands(
          this,
          view,
          row,
          track,
        ),
        HistoryCollectionRow(:final entry) => HistoryCollectionRowCommands(
          this,
          view,
          row,
          entry,
        ),
        LocalSongCollectionRow(:final song) => LocalSongCollectionRowCommands(
          this,
          view,
          row,
          song,
        ),
      };

  Future<CollectionLocalDeleteItem> _deleteLocalSong(
    CollectionLocalSong song,
  ) async {
    switch (song) {
      case CollectionLocalSong(record: final record?) when record.imported:
        return _deleteDownload(
          song,
          record,
          kind: CollectionLocalDeleteKind.imported,
          success: CollectionLocalDeleteStatus.removed,
        );
      case CollectionLocalSong(record: final record?):
        return _deleteDownload(
          song,
          record,
          kind: CollectionLocalDeleteKind.download,
          success: CollectionLocalDeleteStatus.deleted,
        );
      case CollectionLocalSong(history: final entry?):
        return _clearCachedAudio(song, entry);
      case CollectionLocalSong():
        // 两个载荷都为空不是合法行形状；按能力不可用处理，不抛到页面。
        return CollectionLocalDeleteItem(
          song: song,
          kind: CollectionLocalDeleteKind.cached,
          status: CollectionLocalDeleteStatus.unavailable,
        );
    }
  }

  Future<CollectionLocalDeleteItem> _deleteDownload(
    CollectionLocalSong song,
    DownloadedTrack record, {
    required CollectionLocalDeleteKind kind,
    required CollectionLocalDeleteStatus success,
  }) async {
    final localData = _localData;
    if (localData == null || !localData.available) {
      return CollectionLocalDeleteItem(
        song: song,
        kind: kind,
        status: CollectionLocalDeleteStatus.unavailable,
      );
    }
    try {
      await localData.deleteDownload(record);
      return CollectionLocalDeleteItem(song: song, kind: kind, status: success);
    } catch (error) {
      return CollectionLocalDeleteItem(
        song: song,
        kind: kind,
        status: CollectionLocalDeleteStatus.failed,
        error: error,
      );
    }
  }

  Future<CollectionLocalDeleteItem> _clearCachedAudio(
    CollectionLocalSong song,
    PlayHistoryEntry entry,
  ) async {
    final localData = _localData;
    if (localData == null) {
      return CollectionLocalDeleteItem(
        song: song,
        kind: CollectionLocalDeleteKind.cached,
        status: CollectionLocalDeleteStatus.unavailable,
      );
    }
    try {
      final result = await localData.clearCachedAudio(
        _library.trackFromHistoryEntry(entry),
      );
      if (result == null) {
        return CollectionLocalDeleteItem(
          song: song,
          kind: CollectionLocalDeleteKind.cached,
          status: CollectionLocalDeleteStatus.unavailable,
        );
      }
      return CollectionLocalDeleteItem(
        song: song,
        kind: CollectionLocalDeleteKind.cached,
        status: result.cleared
            ? CollectionLocalDeleteStatus.cleared
            : CollectionLocalDeleteStatus.skipped,
        skippedFiles: result.skipped,
      );
    } catch (error) {
      return CollectionLocalDeleteItem(
        song: song,
        kind: CollectionLocalDeleteKind.cached,
        status: CollectionLocalDeleteStatus.failed,
        error: error,
      );
    }
  }
}

/// 一行的动作载荷（行联合归一后的结果）。
///
/// 页面把它接成 `CollectionRowActionWiring`：流程回调返回类型化结果，页面负责
/// 提示 / 清选择；确认类动作（本地删除）只给输入，不在这里执行。
sealed class CollectionRowCommands {
  CollectionRowCommands(
    CollectionActions actions,
    CollectionView view,
    this.row,
  ) : _actions = actions,
      _view = view;

  final CollectionActions _actions;
  final CollectionView _view;

  /// 该行对应的行联合成员。
  final CollectionRow row;

  /// 加入列表：所有行变体共用同一目标选择流程。
  Future<bool> copy() => _actions.copyToLibrary(_view, [row]);

  /// 换源种子；本地歌曲行没有在线音源可换。
  CollectionSwapSeed? get swap => null;

  Future<LibraryMutationOutcome> Function()? get removeFromPlaylist => null;

  Future<LibraryMutationOutcome> Function()? get removeFromFavorites => null;

  Future<LibraryMutationOutcome> Function()? get toggleFavorite => null;

  Future<LibraryMutationOutcome> Function()? get deleteHistory => null;

  /// 本地歌曲行的删除输入（确认与删除流程由页面编排）。
  CollectionLocalSong? get localSong => null;

  /// 收藏开关 / 删除文案所需的行状态（仅本地歌曲行有意义）。
  bool get isFavorite => false;

  bool get localSongCached => false;

  bool get localSongImported => false;
}

final class TrackCollectionRowCommands extends CollectionRowCommands {
  TrackCollectionRowCommands(super.actions, super.view, super.row, this.track);

  final PlaylistTrack track;

  @override
  Future<LibraryMutationOutcome> Function()? get removeFromPlaylist {
    if (_view.playlistId == null) return null;
    return () => _actions.removeFromPlaylist(_view, [row]);
  }

  @override
  Future<LibraryMutationOutcome> Function()? get removeFromFavorites =>
      () =>
          _actions.setFavorite([row], change: CollectionFavoriteChange.remove);

  @override
  CollectionSwapSeed? get swap => CollectionSwapSeed(
    track: _actions._library.trackFromPlaylistTrack(track),
    playlistId: _view.playlistId,
  );
}

final class HistoryCollectionRowCommands extends CollectionRowCommands {
  HistoryCollectionRowCommands(
    super.actions,
    super.view,
    super.row,
    this.entry,
  );

  final PlayHistoryEntry entry;

  @override
  Future<LibraryMutationOutcome> Function()? get deleteHistory =>
      () => _actions.deleteHistory([row]);

  @override
  CollectionSwapSeed? get swap => CollectionSwapSeed(
    track: _actions._library.trackFromHistoryEntry(entry),
    historyKey: (sourceKey: entry.sourceKey, songId: entry.songId),
  );
}

final class LocalSongCollectionRowCommands extends CollectionRowCommands {
  LocalSongCollectionRowCommands(
    super.actions,
    super.view,
    super.row,
    this.song,
  );

  final CollectionLocalSong song;

  @override
  Future<LibraryMutationOutcome> Function()? get toggleFavorite =>
      () => _actions.toggleFavorite([row]);

  @override
  CollectionLocalSong? get localSong => song;

  @override
  bool get isFavorite => _actions._library.isFavorite(
    song.favoriteKey.sourceKey,
    song.favoriteKey.songId,
  );

  @override
  bool get localSongCached => song.isCached;

  @override
  bool get localSongImported => song.isImported;
}
