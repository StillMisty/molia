import 'equality.dart';
import 'track.dart';

/// 专辑每页曲目条数（内置实现与 UI 分页共用同一口径）。
const int kAlbumPageSize = 50;

/// 领域层统一专辑模型（不可变 + 值相等，UI 只读）。
///
/// 五平台（wy/tx/kg/kw/mg）字段差异在 `lib/sources/builtin/*_album.dart`
/// 内归一化：曲目统一为领域 [Track]（payload 原样透传），年份从平台发布
/// 时间派生（无法解析时为 null，UI 不展示年份）。
class Album {
  /// 平台内专辑 id（wy 数字 id / tx albumMid / kg/kw/mg albumId）。
  final String id;

  final String name;

  /// 专辑歌手（平台多歌手时以 `、` 连接）。
  final String artist;

  /// 封面地址（平台未返回时为 null，UI 回退占位图）。
  final String? coverUrl;

  /// 发行年份（平台未返回 / 解析失败时为 null）。
  final int? year;

  /// 本页曲目（按平台返回顺序）。
  final List<Track> tracks;

  /// 是否还有下一页（平台无分页时为 false）。
  final bool hasMore;

  const Album({
    required this.id,
    required this.name,
    this.artist = '',
    this.coverUrl,
    this.year,
    this.tracks = const [],
    this.hasMore = false,
  });

  @override
  bool operator ==(Object other) =>
      other is Album &&
      other.id == id &&
      other.name == name &&
      other.artist == artist &&
      other.coverUrl == coverUrl &&
      other.year == year &&
      deepEquals(other.tracks, tracks) &&
      other.hasMore == hasMore;

  @override
  int get hashCode => Object.hash(
        id,
        name,
        artist,
        coverUrl,
        year,
        deepHash(tracks),
        hasMore,
      );

  @override
  String toString() => 'Album($id, $name, ${tracks.length} 首)';
}
