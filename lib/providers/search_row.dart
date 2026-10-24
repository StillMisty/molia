import '../domain/models/track.dart';

/// 搜索结果行（不可变）：展示、收藏、播放共用的唯一形状。
///
/// 只暴露领域 [Track]：音源侧的 `SourceTrack`（含 raw payload）留在
/// [SearchProvider] 内部，不跨 provider 边界；UI 不再解码
/// `Map<String, dynamic>` 的私有键。
class SearchRow {
  const SearchRow({required this.track, this.lyricSnippet});

  /// 领域曲目：标题 / 歌手 / 封面 / 时长 / 收藏 / 播放身份都从这里取。
  final Track track;

  /// 按歌词搜歌的命中片段（仅歌词类型）；null 时行副标题回退歌手名。
  final String? lyricSnippet;

  TrackId get id => track.id;

  String get title => track.title;

  String get albumName => track.album ?? '';

  String? get coverUrl => track.artwork?.uri.toString();

  Duration? get duration => track.duration;

  /// 首位歌手名（搜索行副标题的兜底口径；全空返回空串）。
  String get primaryArtistName => track.primaryArtistName;

  /// 全部歌手名（表格歌手列口径，`、` 连接；全空返回空串）。
  String get artistNames => [
        for (final artist in track.artists)
          if (artist.name.isNotEmpty) artist.name,
      ].join('、');

  @override
  bool operator ==(Object other) =>
      other is SearchRow &&
      other.track == track &&
      other.lyricSnippet == lyricSnippet;

  @override
  int get hashCode => Object.hash(track, lyricSnippet);

  @override
  String toString() => 'SearchRow($id)';
}
