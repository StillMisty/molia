/// 收藏页合集的视图投影：合集身份、可见行与列规范只在这里推导。
///
/// 为什么单独一层：页面原先用四个布尔值 + 三份可见列表表达「当前合集」，
/// 标题、列表、多选栏、滚动键各自再判断一次；合集键 / 落库 id / 列规范
/// 的规则分散后必然出现「标题显示历史、滚动键却是收藏」这类错位。现在页面
/// 只拿一个类型化的 [CollectionView]，按 [CollectionKind] 分支渲染。
library;

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

/// 当前合集的只读视图（build 计算一次，头部 / 列表 / 多选共用）。
class CollectionView {
  const CollectionView({
    required this.identity,
    required this.tracks,
    required this.visible,
    required this.visibleHistory,
    required this.visibleLocalSongs,
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

  /// 全量曲目（历史 / 本地歌曲集合为空）。
  final List<PlaylistTrack> tracks;

  /// 搜索 + 排序后的可见曲目（可见顺序即播放队列顺序）。
  final List<PlaylistTrack> visible;

  /// 搜索过滤后的历史条目。
  final List<PlayHistoryEntry> visibleHistory;

  /// 搜索过滤后的本地歌曲（下载 / 导入副本 + 缓存行）。
  final List<CollectionLocalSong> visibleLocalSongs;

  final bool hasItems;

  /// 当前合集可见行数（表格表头只在有可见行时显示）。
  int get visibleCount => switch (kind) {
        CollectionKind.history => visibleHistory.length,
        CollectionKind.localSongs => visibleLocalSongs.length,
        CollectionKind.favorites || CollectionKind.custom => visible.length,
      };
}

/// 合集投影器：解析选集、投影可见行并缓存排序结果。
///
/// 有状态只是为了复用排序（O(n log n) 与搜索词无关）；身份与过滤都是纯
/// 函数，单元测试可以直接构造输入断言，不需要挂页面。
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

  /// 投影当前合集：只对生效的合集做过滤 / 排序（其余列表给空，避免无谓
  /// 遍历；页面也据此判断空态与加载态）。
  CollectionView viewFor({
    required CollectionIdentity identity,
    required List<PlaylistTrack> tracks,
    required List<PlayHistoryEntry> history,
    required List<CollectionLocalSong> localSongs,
    required String query,
    required CollectionTrackSort sort,
  }) {
    final isHistory = identity.kind == CollectionKind.history;
    final isLocalSongs = identity.kind == CollectionKind.localSongs;
    final visible = isHistory || isLocalSongs
        ? const <PlaylistTrack>[]
        : _filterAndSortTracks(tracks, query: query, sort: sort);
    final visibleHistory = isHistory
        ? filterRowsByQuery(
            history,
            query: query,
            fields: (entry) => (title: entry.title, artist: entry.artist),
          )
        : const <PlayHistoryEntry>[];
    final visibleLocalSongs = isLocalSongs
        ? filterRowsByQuery(
            localSongs,
            query: query,
            fields: (song) => (title: song.title, artist: song.artist),
          )
        : const <CollectionLocalSong>[];
    final hasItems = switch (identity.kind) {
      CollectionKind.history => history.isNotEmpty,
      CollectionKind.localSongs => localSongs.isNotEmpty,
      CollectionKind.favorites || CollectionKind.custom => tracks.isNotEmpty,
    };
    return CollectionView(
      identity: identity,
      tracks: isHistory || isLocalSongs ? const <PlaylistTrack>[] : tracks,
      visible: visible,
      visibleHistory: visibleHistory,
      visibleLocalSongs: visibleLocalSongs,
      hasItems: hasItems,
    );
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
