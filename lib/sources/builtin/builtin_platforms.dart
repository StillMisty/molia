/// 内置平台的唯一注册表：平台键 / 显示名 / 各能力族适配器的声明处。
///
/// 之前同一份「五平台 × 六能力族」矩阵散落在
/// `album_source` / `artist_source` / `comment_source` / `lyric_search` /
/// `builtin_search` / `discover_source` 的 `supportedKeys` 与五路 switch 里，
/// 每加一个平台要改七处，且 `SourceManager.capabilitiesFor` 无法与路由门
/// 保持同一事实。现在只在这里新增/删除平台条目；各 facade 只做参数校验与
/// 错误语义转换。
///
/// 能力族保持类型化，刻意不做 `Object` 通用适配器：
/// - 搜索失败语义是 `SourceSearchResult.failed`（由平台 runner 产出）；
/// - 歌词搜索 / 专辑 / 歌手 / 评论失败抛 `SourceFailure`；
/// - 发现返回自己的 `DiscoverSource` 类型。
/// 混成一个通用返回值会把上述差异抹平。
library;

import '../../domain/models/album.dart';
import '../../domain/models/artist.dart';
import '../../domain/models/comment.dart';
import '../source_search_result.dart';
import 'artist_source.dart';
import 'discover_source.dart';
import 'kg_album.dart';
import 'kg_artist.dart';
import 'kg_comment.dart';
import 'kg_discover.dart';
import 'kg_lyric_search.dart';
import 'kg_search.dart';
import 'kw_album.dart';
import 'kw_artist.dart';
import 'kw_comment.dart';
import 'kw_discover.dart';
import 'kw_lyric_search.dart';
import 'kw_search.dart';
import 'lyric_hit.dart';
import 'mg_album.dart';
import 'mg_artist.dart';
import 'mg_comment.dart';
import 'mg_discover.dart';
import 'mg_lyric_search.dart';
import 'mg_search.dart';
import 'tx_album.dart';
import 'tx_artist.dart';
import 'tx_comment.dart';
import 'tx_discover.dart';
import 'tx_lyric_search.dart';
import 'tx_search.dart';
import 'wy_album.dart';
import 'wy_artist.dart';
import 'wy_comment.dart';
import 'wy_discover.dart';
import 'wy_lyric_search.dart';
import 'wy_search.dart';

/// 单曲搜索适配器（结果含分页信息；平台失败由 runner 归一为 failed）。
typedef BuiltinSearchAdapter = Future<SourceSearchResult> Function(
  String keyword, {
  int page,
  int limit,
});

/// 按歌词搜歌适配器（失败抛 `SourceFailure`，不静默吞成空结果）。
typedef BuiltinLyricSearchAdapter = Future<LyricSearchPage> Function(
  String keyword, {
  int page,
  int limit,
});

/// 评论取数适配器（[id] 已由 facade 从 raw 中按平台字段解析）。
typedef BuiltinCommentFetch = Future<CommentPage> Function(
  String id, {
  required CommentKind kind,
  int page,
  int limit,
});

/// 评论适配器：平台 raw 字段名随平台不同，和取数实现放在同一条目里，
/// 避免 facade 再维护一份平台字段表。
class BuiltinCommentAdapter {
  /// 从 `SourceTrack.raw` 取评论目标 id 的候选键（按顺序取第一个非空值）。
  final List<String> rawIdKeys;

  final BuiltinCommentFetch fetch;

  const BuiltinCommentAdapter({
    required this.rawIdKeys,
    required this.fetch,
  });
}

/// 专辑取数适配器。
typedef BuiltinAlbumAdapter = Future<Album> Function(
  String albumId, {
  int page,
  int limit,
});

/// 歌手搜索适配器。
typedef BuiltinArtistSearch = Future<ArtistSearchPage> Function(
  String keyword, {
  int page,
  int limit,
});

/// 歌手详情取数适配器。
typedef BuiltinArtistFetch = Future<ArtistDetail> Function(
  String artistId, {
  int page,
  int limit,
});

/// 歌手族适配器：搜索与详情总是成对出现。
class BuiltinArtistAdapter {
  final BuiltinArtistSearch search;
  final BuiltinArtistFetch fetch;

  const BuiltinArtistAdapter({
    required this.search,
    required this.fetch,
  });
}

/// 一个内置平台的完整声明：所有能力位都从这里的适配器是否存在推导。
class BuiltinPlatform {
  final String key;
  final String displayName;

  /// 搜索渠道候选的展示序（保持拆分前的 kw→kg→tx→wy→mg）。
  /// 发现页与默认渠道顺序使用 [BuiltinPlatforms.keys] 的规范顺序。
  final int searchRank;

  final BuiltinSearchAdapter? search;
  final BuiltinLyricSearchAdapter? lyricSearch;
  final BuiltinCommentAdapter? comments;
  final BuiltinAlbumAdapter? album;
  final BuiltinArtistAdapter? artist;
  final DiscoverSource? discover;

  const BuiltinPlatform({
    required this.key,
    required this.displayName,
    required this.searchRank,
    this.search,
    this.lyricSearch,
    this.comments,
    this.album,
    this.artist,
    this.discover,
  });
}

/// 内置平台注册表。
class BuiltinPlatforms {
  BuiltinPlatforms._();

  /// 规范平台顺序：wy 在前（默认平台），与发现页/渠道默认顺序一致。
  static final Map<String, BuiltinPlatform> byKey =
      Map.unmodifiable(<String, BuiltinPlatform>{
    'wy': BuiltinPlatform(
      key: 'wy',
      displayName: '网易音乐',
      searchRank: 3,
      search: WySearch.searchWithMeta,
      lyricSearch: WyLyricSearch.search,
      comments: BuiltinCommentAdapter(
        rawIdKeys: const ['songmid', 'id'],
        fetch: WyComment.fetch,
      ),
      album: WyAlbum.fetch,
      artist: BuiltinArtistAdapter(
        search: WyArtist.search,
        fetch: WyArtist.fetch,
      ),
      discover: const WyDiscoverSource(),
    ),
    'tx': BuiltinPlatform(
      key: 'tx',
      displayName: 'QQ音乐',
      searchRank: 2,
      search: TxSearch.searchWithMeta,
      lyricSearch: TxLyricSearch.search,
      comments: BuiltinCommentAdapter(
        rawIdKeys: const ['songId'],
        fetch: TxComment.fetch,
      ),
      album: TxAlbum.fetch,
      artist: BuiltinArtistAdapter(
        search: TxArtist.search,
        fetch: TxArtist.fetch,
      ),
      discover: const TxDiscoverSource(),
    ),
    'kg': BuiltinPlatform(
      key: 'kg',
      displayName: '酷狗音乐',
      searchRank: 1,
      search: KgSearch.searchWithMeta,
      lyricSearch: KgLyricSearch.search,
      comments: BuiltinCommentAdapter(
        rawIdKeys: const ['hash'],
        fetch: KgComment.fetch,
      ),
      album: KgAlbum.fetch,
      artist: BuiltinArtistAdapter(
        search: KgArtist.search,
        fetch: KgArtist.fetch,
      ),
      discover: const KgDiscoverSource(),
    ),
    'kw': BuiltinPlatform(
      key: 'kw',
      displayName: '酷我音乐',
      searchRank: 0,
      search: KwSearch.searchWithMeta,
      lyricSearch: KwLyricSearch.search,
      comments: BuiltinCommentAdapter(
        rawIdKeys: const ['songmid'],
        fetch: KwComment.fetch,
      ),
      album: KwAlbum.fetch,
      artist: BuiltinArtistAdapter(
        search: KwArtist.search,
        fetch: KwArtist.fetch,
      ),
      discover: const KwDiscoverSource(),
    ),
    'mg': BuiltinPlatform(
      key: 'mg',
      displayName: '咪咕音乐',
      searchRank: 4,
      search: MgSearch.searchWithMeta,
      lyricSearch: MgLyricSearch.search,
      comments: BuiltinCommentAdapter(
        rawIdKeys: const ['songmid', 'copyrightId'],
        fetch: MgComment.fetch,
      ),
      album: MgAlbum.fetch,
      artist: BuiltinArtistAdapter(
        search: MgArtist.search,
        fetch: MgArtist.fetch,
      ),
      discover: const MgDiscoverSource(),
    ),
  });

  /// 规范键顺序（发现页 / 默认渠道顺序）。
  static final List<String> keys = List.unmodifiable(byKey.keys);

  /// 规范键集合（只读；不要另行声明平台矩阵）。
  static final Set<String> keySet = Set.unmodifiable(byKey.keys);

  /// 平台展示名（键顺序同 [keys]）。
  static final Map<String, String> displayNames = Map.unmodifiable(
    <String, String>{
      for (final platform in byKey.values) platform.key: platform.displayName,
    },
  );

  /// 搜索渠道候选顺序：保持拆分前 kw→kg→tx→wy→mg 的既有展示顺序。
  static final List<BuiltinPlatform> searchCandidates = List.unmodifiable(
    byKey.values.toList()..sort((a, b) => a.searchRank.compareTo(b.searchRank)),
  );

  /// 某能力族的非空适配器表：`byKey` 是唯一事实来源，六族键表都从这里推导，
  /// 选择器为 null 的平台不进表。
  static Map<String, T> _adaptersOf<T extends Object>(
    T? Function(BuiltinPlatform platform) select,
  ) {
    final adapters = <String, T>{};
    for (final platform in byKey.values) {
      final adapter = select(platform);
      if (adapter != null) adapters[platform.key] = adapter;
    }
    return Map.unmodifiable(adapters);
  }

  static final Map<String, BuiltinSearchAdapter> searchAdapters =
      _adaptersOf((platform) => platform.search);

  static final Map<String, BuiltinLyricSearchAdapter> lyricSearchAdapters =
      _adaptersOf((platform) => platform.lyricSearch);

  static final Map<String, BuiltinCommentAdapter> commentAdapters =
      _adaptersOf((platform) => platform.comments);

  static final Map<String, BuiltinAlbumAdapter> albumAdapters =
      _adaptersOf((platform) => platform.album);

  static final Map<String, BuiltinArtistAdapter> artistAdapters =
      _adaptersOf((platform) => platform.artist);

  static final Map<String, DiscoverSource> discoverSources =
      _adaptersOf((platform) => platform.discover);

  static final Set<String> searchKeys = Set.unmodifiable(searchAdapters.keys);
  static final Set<String> lyricSearchKeys =
      Set.unmodifiable(lyricSearchAdapters.keys);
  static final Set<String> commentKeys = Set.unmodifiable(commentAdapters.keys);
  static final Set<String> albumKeys = Set.unmodifiable(albumAdapters.keys);
  static final Set<String> artistKeys = Set.unmodifiable(artistAdapters.keys);
  static final Set<String> discoverKeys =
      Set.unmodifiable(discoverSources.keys);

  static bool isSupported(String key) => byKey.containsKey(key);

  static BuiltinPlatform? maybeOf(String key) => byKey[key];

  static String displayName(String key) => byKey[key]?.displayName ?? key;

  static BuiltinSearchAdapter? searchFor(String key) => byKey[key]?.search;

  static BuiltinLyricSearchAdapter? lyricSearchFor(String key) =>
      byKey[key]?.lyricSearch;

  static BuiltinCommentAdapter? commentsFor(String key) => byKey[key]?.comments;

  static BuiltinAlbumAdapter? albumFor(String key) => byKey[key]?.album;

  static BuiltinArtistAdapter? artistFor(String key) => byKey[key]?.artist;

  static DiscoverSource? discoverFor(String key) => byKey[key]?.discover;
}
