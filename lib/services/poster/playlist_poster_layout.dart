/// 列表分享的纯布局 / 文案模型：不读文件、不读 provider、不含本机路径。
///
/// 分享内容只保留展示字符串与「第几张封面」的索引；封面字节由调用方按索引
/// 提供。这样测试可以断言分享模型里没有路径 / 账号 / 链接，渲染器也不负责
/// 决定哪些封面可用。
library;

/// 列表海报固定宽度（竖版，与年度海报同档）。
const int kPlaylistPosterWidth = 1440;

/// 列表海报高度上限；内容不足以撑满时仍输出完整画布。
const int kPlaylistPosterMaxHeight = 1920;

/// 文本分享最多列出的曲目数（更长的列表用「还有 N 首」收尾）。
const int kPlaylistShareTextTrackLimit = 500;

/// 海报里展示的曲目行数。
const int kPlaylistPosterTrackLimit = 5;

/// 3×3 封面马赛克的槽位数。
const int kPlaylistPosterMosaicSlots = 9;

/// 分享用曲目行（标题 / 歌手）。
class PlaylistShareTrack {
  const PlaylistShareTrack({required this.title, required this.artist});

  final String title;
  final String artist;

  /// 单行展示文本：`标题 · 歌手`（歌手空时只有标题）。
  String get label => artist.trim().isEmpty
      ? title.trim()
      : '${title.trim()} · ${artist.trim()}';
}

/// 列表分享内容模型。
class PlaylistShareContent {
  const PlaylistShareContent({
    required this.name,
    required this.description,
    required this.trackCountLabel,
    required this.tracks,
    required this.andMoreLabel,
    this.coverCount = 0,
  });

  final String name;
  final String description;

  /// 已本地化的「N 首」文案（模型不依赖 l10n）。
  final String trackCountLabel;

  /// 全部曲目（海报只取前 5，文本最多 500）。
  final List<PlaylistShareTrack> tracks;

  /// 已本地化的「还有 N 首」文案工厂。
  final String Function(int count) andMoreLabel;

  /// 可用的本机封面数量（马赛克只引用 0..coverCount-1）。
  final int coverCount;

  /// 海报展示的曲目（前 5）。
  List<PlaylistShareTrack> get posterTracks =>
      tracks.take(kPlaylistPosterTrackLimit).toList(growable: false);

  /// 海报「还有 N 首」计数（0 = 不显示）。
  int get posterExtraCount => tracks.length <= kPlaylistPosterTrackLimit
      ? 0
      : tracks.length - kPlaylistPosterTrackLimit;

  /// 9 个马赛克槽位：可用封面按顺序占位，其余为 null（中性占位）。
  ///
  /// 不重复使用同一张封面填满：1 张封面就是 1 张 + 8 个空槽。
  List<int?> get mosaicSlotIndices => [
    for (var index = 0; index < kPlaylistPosterMosaicSlots; index++)
      index < coverCount ? index : null,
  ];

  /// 纯文本分享：列表名、描述、曲目数与编号曲目（无链接 / 账号）。
  String toShareText() {
    final lines = <String>[name.trim()];
    final summary = description.trim();
    if (summary.isNotEmpty) lines.add(summary);
    lines.add(trackCountLabel);
    final visible = tracks.take(kPlaylistShareTextTrackLimit).toList();
    for (var index = 0; index < visible.length; index++) {
      lines.add('${index + 1}. ${visible[index].label}');
    }
    if (tracks.length > kPlaylistShareTextTrackLimit) {
      lines.add(andMoreLabel(tracks.length - kPlaylistShareTextTrackLimit));
    }
    return lines.join('\n');
  }
}
