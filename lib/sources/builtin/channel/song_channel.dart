/// 一个内置歌曲渠道的自述：身份 + 能力实现 + 平台展示事实
/// （曲目页地址 / 专辑 id）。
///
/// 渠道能做什么**只由它自己声明的适配器是否存在**推导：没有 `album` 就没有
/// 专辑能力，没有 `resolve` 就只能靠脚本取链。能力位（`SourceCapabilities`）
/// 由 `SourceProfiles` 从这份自述派生，UI 只消费派生结果，不认平台 key。
///
/// 能力族保持类型化，刻意不做 `Object` 通用适配器：
/// - 搜索失败语义是 `SourceSearchResult.failed`（由平台 runner 产出）；
/// - 歌词搜索 / 专辑 / 歌手 / 评论失败抛 `SourceFailure`；
/// - 发现返回自己的 `DiscoverSource` 类型。
/// 混成一个通用返回值会把上述差异抹平。
///
/// 新增渠道 = 在本目录加一个 `{key}_channel.dart` 声明条目 + 在
/// `channels.dart` 的 `all` 里登记一行；注册表与各 facade 不需要再改。
library;

import '../../../domain/models/album.dart';
import '../../../domain/models/artist.dart';
import '../../../domain/models/comment.dart';
import '../../../domain/ports/music_source.dart' show PlayableStream;
import '../../source_search_result.dart';
import '../artist_source.dart';
import '../discover_source.dart';
import '../lyric_hit.dart';
import '../lyric_result.dart';

/// 单曲搜索适配器（结果含分页信息；平台失败由 runner 归一为 failed）。
typedef SongChannelSearch = Future<SourceSearchResult> Function(
  String keyword, {
  int page,
  int limit,
});

/// 原生取链适配器：渠道自己就能从 raw 解析可播流（无需 LX 脚本）。
///
/// 返回 [PlayableStream] 而不是 URL：B 站直链必须带 Referer / UA，headers
/// 必须一路透传到播放器与缓存写入。
typedef SongChannelResolve = Future<PlayableStream> Function(
  Map<String, dynamic> raw, {
  String? quality,
});

/// 按歌词搜歌适配器（失败抛 `SourceFailure`，不静默吞成空结果）。
typedef SongChannelLyricSearch = Future<LyricSearchPage> Function(
  String keyword, {
  int page,
  int limit,
});

/// 原生取词适配器：曲目 raw → 统一歌词结果（无字段 / 失败返回 null）。
///
/// 能力位 `SourceCapabilities.lyrics` 只认这个适配器（或脚本声明的 lyric
/// action），与渠道是否内置无关。
typedef SongChannelLyric = Future<BuiltinLyricResult?> Function(
  Map<String, dynamic> raw,
);

/// 原生取图适配器：曲目 raw → 封面 URL（无字段 / 失败返回 null）。
typedef SongChannelPic = Future<String?> Function(Map<String, dynamic> raw);

/// 评论取数适配器（[id] 已由 facade 从 raw 中按渠道字段解析）。
typedef SongChannelCommentFetch = Future<CommentPage> Function(
  String id, {
  required CommentKind kind,
  int page,
  int limit,
});

/// 评论适配器：渠道 raw 字段名随渠道不同，和取数实现放在同一条目里，
/// 避免 facade 再维护一份渠道字段表。
class SongChannelComments {
  /// 从 `SourceTrack.raw` 取评论目标 id 的候选键（按顺序取第一个非空值）。
  final List<String> rawIdKeys;

  final SongChannelCommentFetch fetch;

  const SongChannelComments({required this.rawIdKeys, required this.fetch});
}

/// 专辑取数适配器。
typedef SongChannelAlbum = Future<Album> Function(
  String albumId, {
  int page,
  int limit,
});

/// 歌手搜索适配器。
typedef SongChannelArtistSearch = Future<ArtistSearchPage> Function(
  String keyword, {
  int page,
  int limit,
});

/// 歌手详情取数适配器。
typedef SongChannelArtistFetch = Future<ArtistDetail> Function(
  String artistId, {
  int page,
  int limit,
});

/// 歌手族适配器：搜索与详情总是成对出现。
class SongChannelArtist {
  final SongChannelArtistSearch search;
  final SongChannelArtistFetch fetch;

  const SongChannelArtist({required this.search, required this.fetch});
}

/// 一个内置渠道的完整声明。
///
/// 字段即能力：适配器为 null 表示渠道没有这项能力，UI 据此隐藏入口。
class SongChannel {
  /// 渠道键（`wy` / `tx` / `kg` / `kw` / `mg` / `bili` / `qs`）。
  ///
  /// 与 LX 脚本声明的 key 同一命名空间：脚本可给同名内置渠道补充
  /// 取链 / 取词 / 取图，但不会生成第二个同 key 的源。
  final String key;

  final String displayName;

  final SongChannelSearch? search;
  final SongChannelResolve? resolve;
  final SongChannelLyricSearch? lyricSearch;
  final SongChannelLyric? lyric;
  final SongChannelPic? pic;
  final SongChannelComments? comments;
  final SongChannelAlbum? album;
  final SongChannelArtist? artist;
  final DiscoverSource? discover;

  /// 曲目在平台上的网页地址（分享 / 「在平台打开」）；没有网页时返回 null。
  ///
  /// 平台事实放在渠道自述里：`track_mapper` 不再维护按 key 的 switch。
  final String? Function(Map<String, dynamic> raw)? pageUrl;

  /// 曲目所属专辑 id（专辑页入口）；平台没有专辑概念时为 null。
  final String? Function(Map<String, dynamic> raw)? albumId;

  const SongChannel({
    required this.key,
    required this.displayName,
    this.search,
    this.resolve,
    this.lyricSearch,
    this.lyric,
    this.pic,
    this.comments,
    this.album,
    this.artist,
    this.discover,
    this.pageUrl,
    this.albumId,
  });

  @override
  String toString() => 'SongChannel($key)';
}
