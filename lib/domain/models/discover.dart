/// 发现（热榜 / 歌单 / 热搜）领域模型（纯 Dart，无 Flutter / HTTP 依赖）。
///
/// 设计对齐资料库模型：曲目只携带**元数据 + 取链参数 raw**，
/// 播放时由 provider 还原为音源曲目并按需取链。
library;

/// 排行榜（网易云静态榜单表；`bangid` 为 weapi 请求参数）。
class DiscoverLeaderboard {
  /// 展示/路由用 id（LX 约定 `wy__<bangid>`）。
  final String id;
  final String name;
  final String bangid;

  const DiscoverLeaderboard({
    required this.id,
    required this.name,
    required this.bangid,
  });
}

/// 歌单概要（列表/搜索/详情头部的公共信息）。
class DiscoverPlaylist {
  final String id;
  final String name;
  final String? coverUrl;
  final String author;
  final int playCount;
  final int trackCount;
  final String? description;

  /// 创建时间（`Y-M-D`，平台返回时才有）。
  final String? createdAt;

  const DiscoverPlaylist({
    required this.id,
    required this.name,
    this.coverUrl,
    this.author = '',
    this.playCount = 0,
    this.trackCount = 0,
    this.description,
    this.createdAt,
  });

  /// 平台风格播放量文案（`x.x万` / `x.x亿`，与 LX `formatPlayCount` 一致）。
  String get playCountText => formatDiscoverPlayCount(playCount);
}

/// 歌单分页结果。
class DiscoverPlaylistPage {
  final List<DiscoverPlaylist> playlists;
  final int page;
  final int limit;
  final int total;

  const DiscoverPlaylistPage({
    required this.playlists,
    required this.page,
    required this.limit,
    this.total = 0,
  });

  bool get hasMore => page * limit < total;
}

/// 发现曲目（与 `PlaylistTrack` 同构：raw 原样回传音源脚本）。
class DiscoverTrack {
  final String sourceKey;
  final String songId;
  final String title;
  final String artist;
  final String album;
  final String? coverUrl;
  final int? durationMs;
  final Map<String, dynamic> raw;

  const DiscoverTrack({
    required this.sourceKey,
    required this.songId,
    required this.title,
    this.artist = '',
    this.album = '',
    this.coverUrl,
    this.durationMs,
    this.raw = const {},
  });

  String get key => '$sourceKey:$songId';
}

/// 详情页数据（榜单或歌单：头部信息 + 曲目）。
class DiscoverDetail {
  final DiscoverPlaylist info;
  final List<DiscoverTrack> tracks;

  const DiscoverDetail({required this.info, required this.tracks});
}

/// 歌单标签。
class DiscoverTag {
  final String id;
  final String name;

  const DiscoverTag({required this.id, required this.name});
}

/// 标签分类（网易云 catalogue 的 categories + sub）。
class DiscoverTagCategory {
  final String name;
  final List<DiscoverTag> tags;

  const DiscoverTagCategory({required this.name, required this.tags});
}

/// 某平台的歌单标签集合：热门标签 + 分类目录（对齐 LX `getTags()` 返回）。
class DiscoverTags {
  /// 热门标签（用于「歌单」tab 顶部 chips）。
  final List<DiscoverTag> hotTags;

  /// 分类目录（用于「全部标签」弹层）。
  final List<DiscoverTagCategory> categories;

  const DiscoverTags({
    this.hotTags = const [],
    this.categories = const [],
  });

  bool get isEmpty => hotTags.isEmpty && categories.isEmpty;
}

/// 平台风格播放量格式化（移植自 LX `formatPlayCount`）。
String formatDiscoverPlayCount(num count) {
  if (count > 100000000) {
    return '${(count ~/ 10000000) / 10}亿';
  }
  if (count > 10000) {
    return '${(count ~/ 1000) / 10}万';
  }
  return '$count';
}
