/// `.lxmc`（LX Music 收藏夹导出）解码结果模型（纯 Dart，供条件实现共用）。
library;

/// 解码后的单首曲目（尚未落库，playlistId / addedAt / sortOrder 由仓库补齐）。
class LxmcDecodedTrack {
  final String sourceKey;
  final String songId;
  final String title;
  final String artist;
  final String album;
  final String? coverUrl;
  final int? durationMs;

  /// 取链参数：`.lxmc` 中 `meta` 的原样副本（含 qualitys/_qualitys）。
  final Map<String, dynamic> raw;

  const LxmcDecodedTrack({
    required this.sourceKey,
    required this.songId,
    required this.title,
    this.artist = '',
    this.album = '',
    this.coverUrl,
    this.durationMs,
    this.raw = const {},
  });
}

/// 解码后的收藏夹（名称已清洗，如 `list__name_love` → `love`）。
class LxmcDecodedPlaylist {
  final String name;
  final List<LxmcDecodedTrack> tracks;

  /// 被跳过的非法条目数（缺 source / 标题 / 平台 id 等）。
  final int skipped;

  const LxmcDecodedPlaylist({
    required this.name,
    required this.tracks,
    this.skipped = 0,
  });
}

/// `.lxmc` 解码失败。[reason] 为机器可读原因，UI 据此选择本地化文案。
class LxmcDecodeException implements Exception {
  final String reason;

  const LxmcDecodeException(this.reason);

  @override
  String toString() => 'LxmcDecodeException($reason)';
}
