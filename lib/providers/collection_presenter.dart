/// 收藏页合集的视图投影：合集身份、可见行、行动作构成与列规范只在这里推导。
///
/// 为什么单独一层：页面原先用四个布尔值 + 三份可见列表表达「当前合集」，
/// 标题、列表、多选栏、滚动键各自再判断一次；合集键 / 落库 id / 列规范
/// 的规则分散后必然出现「标题显示历史、滚动键却是收藏」这类错位。现在页面
/// 只拿一个类型化的 [CollectionView]，消费统一的 [CollectionRow] 行联合，
/// 不再按 [CollectionKind] 分支拼行或挑行动作。
library;

import '../domain/models/download.dart' show kLocalSourceKey;
import '../domain/models/library.dart';
import '../utils/collection_row_query.dart';
import 'library_collections.dart';
import 'local_songs_collection.dart';

/// 当前合集的四种形态（收藏 / 播放历史 / 本地歌曲 / 自建列表）。
enum CollectionKind { favorites, history, localSongs, custom }

/// 行内表格列档位（页面映射到 `TrackRowColumnSpec`，本层不依赖 widget）。
enum CollectionColumnLayout { standard, history }

/// 合集身份：与「行内容」无关的稳定部分（选中项、落库 id、展示名、键）。
class CollectionIdentity {
  const CollectionIdentity({
    required this.selectedId,
    required this.kind,
    required this.playlistId,
    required this.displayName,
  });

  /// 解析后的选集（哨兵或列表 id），用于持久化与弹层选中态。
  final int selectedId;

  final CollectionKind kind;

  /// 实际落库的列表 id：收藏 = 收藏列表 id；自建列表 = 自身 id；
  /// 历史 / 本地歌曲 = null。
  final int? playlistId;

  final String displayName;

  bool get isHistory => kind == CollectionKind.history;
  bool get isFavorites => kind == CollectionKind.favorites;
  bool get isLocalSongs => kind == CollectionKind.localSongs;
  bool get isCustom => kind == CollectionKind.custom;

  /// 当前合集的持久化键：收藏 / 历史 / 本地歌曲用固定键，自建列表按 id。
  ///
  /// 滚动偏移与合集顺序（弹层排序）共用同一套键。
  String get collectionKey => switch (kind) {
        CollectionKind.history => LibraryCollections.historyOrderKey,
        CollectionKind.localSongs => LibraryCollections.downloadsOrderKey,
        CollectionKind.favorites => LibraryCollections.favoritesOrderKey,
        CollectionKind.custom => playlistId == null
            ? LibraryCollections.favoritesOrderKey
            : LibraryCollections.playlistOrderKey(playlistId!),
      };

  /// 列规范：只有播放历史多一列「播放时间」。
  CollectionColumnLayout get columnLayout => kind == CollectionKind.history
      ? CollectionColumnLayout.history
      : CollectionColumnLayout.standard;
}

/// 合集可见行的统一联合：三种行（列表曲目 / 播放历史 / 本地歌曲）共用同一
/// 套展示字段与身份键，页面按变体取展示与动作载荷，不再拿三份平行列表。
///
/// 稳定 key 保留各合集原有的前缀（历史 `h:`、本地歌曲 `l:`），切换 / 删除 /
/// 导入后列表原地刷新、不整段重建的语义不变。
sealed class CollectionRow {
  const CollectionRow();

  /// 当前列表内的稳定行 key（同一列表内唯一）。
  String get key;

  String get title;
  String get artist;
  String get album;
  int? get durationMs;

  /// 行封面地址（下载 / 导入副本优先本地封面，缓存行用历史原图）。
  String? get artworkUrl;

  /// 收藏键（下载副本 = local 音源；缓存行 / 历史 / 曲目 = 原曲键）。
  ({String sourceKey, String songId}) get favoriteKey;

  /// 加入收藏 / 列表用的曲目快照（缓存行还原为原曲身份）。
  PlaylistTrack toPlaylistTrack({required int addedAt});
}

/// 列表曲目行（收藏 / 自建列表）。
final class TrackCollectionRow extends CollectionRow {
  const TrackCollectionRow(this.track);

  final PlaylistTrack track;

  @override
  String get key => '${track.sourceKey}:${track.songId}';

  @override
  String get title => track.title;

  @override
  String get artist => track.artist;

  @override
  String get album => track.album;

  @override
  int? get durationMs => track.durationMs;

  @override
  String? get artworkUrl => track.coverUrl;

  @override
  ({String sourceKey, String songId}) get favoriteKey =>
      (sourceKey: track.sourceKey, songId: track.songId);

  @override
  PlaylistTrack toPlaylistTrack({required int addedAt}) => track;
}

/// 播放历史行。
final class HistoryCollectionRow extends CollectionRow {
  const HistoryCollectionRow(this.entry);

  final PlayHistoryEntry entry;

  /// 行内「播放时间」列的毫秒时间戳。
  int get playedAt => entry.playedAt;

  @override
  String get key => 'h:${entry.sourceKey}:${entry.songId}';

  @override
  String get title => entry.title;

  @override
  String get artist => entry.artist;

  @override
  String get album => entry.album;

  @override
  int? get durationMs => entry.durationMs;

  @override
  String? get artworkUrl => entry.coverUrl;

  @override
  ({String sourceKey, String songId}) get favoriteKey =>
      (sourceKey: entry.sourceKey, songId: entry.songId);

  @override
  PlaylistTrack toPlaylistTrack({required int addedAt}) =>
      PlaylistTrack.fromHistoryEntry(entry, addedAt: addedAt);
}

/// 本地歌曲行（下载 / 导入副本，或命中完整音频缓存的曲目）。
final class LocalSongCollectionRow extends CollectionRow {
  const LocalSongCollectionRow(this.song);

  final CollectionLocalSong song;

  bool get isCached => song.isCached;
  bool get isImported => song.isImported;

  @override
  String get key => 'l:${song.key}';

  @override
  String get title => song.title;

  @override
  String get artist => song.artist;

  @override
  String get album => song.album;

  @override
  int? get durationMs => song.durationMs;

  @override
  String? get artworkUrl => song.artworkUri;

  @override
  ({String sourceKey, String songId}) get favoriteKey => song.favoriteKey;

  @override
  PlaylistTrack toPlaylistTrack({required int addedAt}) =>
      song.toPlaylistTrack(addedAt: addedAt);
}

/// 行动作种类：展示层（图标 / 文案）与流程回调由页面按种类接线，
/// 「这一行有哪些动作」由投影器决定。
enum CollectionRowActionKind {
  addToPlaylist,
  swapSource,
  removeFromPlaylist,
  removeFromFavorite,
  toggleFavorite,
  deleteHistoryEntry,
  deleteLocalSong,
}

/// 一条行动作的声明（不含图标 / 文案 / 回调）。
class CollectionRowActionSpec {
  const CollectionRowActionSpec(this.kind, {this.destructive = false});

  final CollectionRowActionKind kind;

  /// 移除类动作（触摸端套 error 配色、桌面端走 error 语义）。
  final bool destructive;

  @override
  bool operator ==(Object other) =>
      other is CollectionRowActionSpec &&
      other.kind == kind &&
      other.destructive == destructive;

  @override
  int get hashCode => Object.hash(kind, destructive);

  @override
  String toString() =>
      'CollectionRowActionSpec($kind, destructive: $destructive)';
}

/// 当前合集的只读视图（build 计算一次，头部 / 列表 / 多选共用）。
class CollectionView {
  const CollectionView({
    required this.identity,
    required this.tracks,
    required this.visibleRows,
    required this.hasItems,
  });

  final CollectionIdentity identity;

  CollectionKind get kind => identity.kind;
  int get selectedId => identity.selectedId;
  int? get playlistId => identity.playlistId;
  String get displayName => identity.displayName;
  String get collectionKey => identity.collectionKey;
  CollectionColumnLayout get columnLayout => identity.columnLayout;

  bool get isHistory => identity.isHistory;
  bool get isFavorites => identity.isFavorites;
  bool get isLocalSongs => identity.isLocalSongs;
  bool get isCustom => identity.isCustom;

  /// 全量曲目（历史 / 本地歌曲集合为空）；只用于空态与「调整顺序」入口判定。
  final List<PlaylistTrack> tracks;

  /// 搜索 + 排序后的可见行（可见顺序即播放队列顺序）；三种合集共用一条
  /// 有序列表，行本身携带展示字段与动作载荷。
  final List<CollectionRow> visibleRows;

  final bool hasItems;

  /// 当前合集可见行数（表格表头只在有可见行时显示）。
  int get visibleCount => visibleRows.length;
}

/// 合集投影器：解析选集、投影可见行 / 行动作并缓存排序结果。
///
/// 有状态只是为了复用排序（O(n log n) 与搜索词无关）；身份、过滤与动作构成
/// 都是纯函数，单元测试可以直接构造输入断言，不需要挂页面。
class CollectionPresenter {
  List<PlaylistTrack>? _sortedSource;
  List<PlaylistTrack> _sorted = const [];
  CollectionTrackSort? _sortedSort;

  /// 解析选集与合集身份（页面在加载曲目前就需要知道 kind / 落库 id）。
  CollectionIdentity identityFor({
    required int selectedId,
    required List<PlaylistInfo> playlists,
    required int? favoritesId,
    required String favoritesName,
    required String historyName,
    required String localSongsName,
  }) {
    final selected = LibraryCollections.resolveSelection(
      selected: selectedId,
      playlists: playlists,
      favoritesId: favoritesId,
    );
    final kind = switch (selected) {
      LibraryCollections.historySentinel => CollectionKind.history,
      LibraryCollections.downloadsSentinel => CollectionKind.localSongs,
      LibraryCollections.favoritesSentinel => CollectionKind.favorites,
      _ => CollectionKind.custom,
    };
    final playlistId = switch (kind) {
      CollectionKind.history || CollectionKind.localSongs => null,
      CollectionKind.favorites => favoritesId,
      CollectionKind.custom => selected,
    };
    final displayName = switch (kind) {
      CollectionKind.history => historyName,
      CollectionKind.localSongs => localSongsName,
      CollectionKind.favorites => favoritesName,
      CollectionKind.custom =>
        _playlistName(playlists, selected) ?? favoritesName,
    };
    return CollectionIdentity(
      selectedId: selected,
      kind: kind,
      playlistId: playlistId,
      displayName: displayName,
    );
  }

  /// 投影当前合集的可见行：只对生效的合集做过滤 / 排序（其余列表给空，
  /// 避免无谓遍历；页面也据此判断空态与加载态）。
  CollectionView viewFor({
    required CollectionIdentity identity,
    required List<PlaylistTrack> tracks,
    required List<PlayHistoryEntry> history,
    required List<CollectionLocalSong> localSongs,
    required String query,
    required CollectionTrackSort sort,
  }) {
    final visibleRows = switch (identity.kind) {
      CollectionKind.history => [
          for (final entry in filterRowsByQuery(
            history,
            query: query,
            fields: (entry) => (title: entry.title, artist: entry.artist),
          ))
            HistoryCollectionRow(entry),
        ],
      CollectionKind.localSongs => [
          for (final song in filterRowsByQuery(
            localSongs,
            query: query,
            fields: (song) => (title: song.title, artist: song.artist),
          ))
            LocalSongCollectionRow(song),
        ],
      CollectionKind.favorites || CollectionKind.custom => [
          for (final track in _filterAndSortTracks(
            tracks,
            query: query,
            sort: sort,
          ))
            TrackCollectionRow(track),
        ],
    };
    final hasItems = switch (identity.kind) {
      CollectionKind.history => history.isNotEmpty,
      CollectionKind.localSongs => localSongs.isNotEmpty,
      CollectionKind.favorites || CollectionKind.custom => tracks.isNotEmpty,
    };
    return CollectionView(
      identity: identity,
      tracks: identity.isHistory || identity.isLocalSongs
          ? const <PlaylistTrack>[]
          : tracks,
      visibleRows: visibleRows,
      hasItems: hasItems,
    );
  }

  /// 一行应有哪些行动作（顺序 / 是否移除类在这里定；图标 / 文案 / 流程由
  /// 页面按种类接线）。页面不再按 [CollectionKind] 挑动作集合。
  List<CollectionRowActionSpec> rowActionsFor(
    CollectionRow row,
    CollectionIdentity identity,
  ) {
    switch (row) {
      case TrackCollectionRow(:final track):
        return [
          const CollectionRowActionSpec(CollectionRowActionKind.addToPlaylist),
          if (identity.playlistId != null && track.sourceKey != kLocalSourceKey)
            const CollectionRowActionSpec(CollectionRowActionKind.swapSource),
          if (identity.isCustom && identity.playlistId != null)
            const CollectionRowActionSpec(
              CollectionRowActionKind.removeFromPlaylist,
              destructive: true,
            )
          else if (identity.isFavorites)
            const CollectionRowActionSpec(
              CollectionRowActionKind.removeFromFavorite,
              destructive: true,
            ),
        ];
      case HistoryCollectionRow(:final entry):
        return [
          const CollectionRowActionSpec(CollectionRowActionKind.addToPlaylist),
          if (entry.sourceKey != kLocalSourceKey)
            const CollectionRowActionSpec(CollectionRowActionKind.swapSource),
          const CollectionRowActionSpec(
            CollectionRowActionKind.deleteHistoryEntry,
            destructive: true,
          ),
        ];
      case LocalSongCollectionRow():
        return const [
          CollectionRowActionSpec(CollectionRowActionKind.addToPlaylist),
          CollectionRowActionSpec(CollectionRowActionKind.toggleFavorite),
          CollectionRowActionSpec(
            CollectionRowActionKind.deleteLocalSong,
            destructive: true,
          ),
        ];
    }
  }

  /// 排序结果记忆化：键 = 源列表身份 + 排序口径。
  ///
  /// 搜索只对已排序列表做一次 O(n) 过滤，按键不重排。
  List<PlaylistTrack> _filterAndSortTracks(
    List<PlaylistTrack> tracks, {
    required String query,
    required CollectionTrackSort sort,
  }) {
    if (!identical(tracks, _sortedSource) || sort != _sortedSort) {
      _sorted = sortCollectionTracks(tracks, sort);
      _sortedSource = tracks;
      _sortedSort = sort;
    }
    return filterRowsByQuery(
      _sorted,
      query: query,
      fields: (track) => (title: track.title, artist: track.artist),
    );
  }

  static String? _playlistName(List<PlaylistInfo> playlists, int id) {
    for (final playlist in playlists) {
      if (playlist.id == id) return playlist.name;
    }
    return null;
  }
}
