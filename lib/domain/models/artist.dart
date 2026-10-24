import 'equality.dart';
import 'track.dart';

/// 歌手页每页曲目条数（内置实现与 UI 分页共用同一口径）。
const int kArtistPageSize = 50;

/// 歌手搜索条目（搜索页「歌手」类型的一行）。
///
/// 内置平台（五个音乐平台 + B 站 UP）字段差异在
/// `lib/sources/builtin/*_artist.dart` 内归一化：
/// [id] 与曲目 payload 的歌手 id 同体系（kw/kg/wy 数字 id、tx singerMID、
/// mg 字符串 id、bili UP mid），可直接作为歌手页入口，无需映射表。
class ArtistSummary {
  /// 平台内歌手 id。
  final String id;

  final String name;

  /// 头像地址（平台未返回时为 null，UI 回退首字占位）。
  final String? avatarUrl;

  /// 歌曲数（平台未返回时为 null，行副标题不展示计数）。
  final int? songCount;

  const ArtistSummary({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.songCount,
  });

  @override
  bool operator ==(Object other) =>
      other is ArtistSummary &&
      other.id == id &&
      other.name == name &&
      other.avatarUrl == avatarUrl &&
      other.songCount == songCount;

  @override
  int get hashCode => Object.hash(id, name, avatarUrl, songCount);

  @override
  String toString() => 'ArtistSummary($id, $name)';
}

/// 歌手页数据（歌手信息 + 本页歌曲 + 分页）。
///
/// 与 `Album` 同构：曲目统一为领域 [Track]（payload 经 track_mapper 原样
/// 透传）；平台能力差异在此归一化——[description] 平台未提供时为空串
/// （UI 隐藏简介区），[hasMore] 平台无分页时为 false。
class ArtistDetail {
  /// 平台内歌手 id。
  final String id;

  final String name;

  /// 头像地址（平台未返回时为 null，UI 回退占位）。
  final String? avatarUrl;

  /// 歌手简介（平台未提供时为空串）。
  final String description;

  /// 本页曲目（按平台返回顺序）。
  final List<Track> tracks;

  /// 是否还有下一页（平台无分页时为 false）。
  final bool hasMore;

  const ArtistDetail({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.description = '',
    this.tracks = const [],
    this.hasMore = false,
  });

  @override
  bool operator ==(Object other) =>
      other is ArtistDetail &&
      other.id == id &&
      other.name == name &&
      other.avatarUrl == avatarUrl &&
      other.description == description &&
      deepEquals(other.tracks, tracks) &&
      other.hasMore == hasMore;

  @override
  int get hashCode => Object.hash(
        id,
        name,
        avatarUrl,
        description,
        deepHash(tracks),
        hasMore,
      );

  @override
  String toString() => 'ArtistDetail($id, $name, ${tracks.length} 首)';
}
