/// 设备本地缓存索引行：本机确认存在完整音频缓存的曲目快照。
///
/// 它不是资料库真值：只由缓存完成事件 / 手动核对本地缓存写入，不参与同步；
/// 展示前仍要实时扫描缓存目录，索引行存在不代表缓存现在仍在。`raw` 与播放
/// 历史同形态（文本 / Map），缓存被清后回退在线取链时仍能原样回传脚本参数。
library;

import 'library.dart';

/// 一条缓存完成记录。
class LocalCacheIndexEntry {
  const LocalCacheIndexEntry({
    required this.sourceKey,
    required this.songId,
    required this.title,
    this.artist = '',
    this.album = '',
    this.coverUrl,
    this.durationMs,
    this.raw = const {},
    required this.cachedAt,
  });

  /// 播放历史条目 → 索引候选（仅用于「核对本地缓存」的元数据来源）。
  factory LocalCacheIndexEntry.fromHistoryEntry(PlayHistoryEntry entry) =>
      LocalCacheIndexEntry(
        sourceKey: entry.sourceKey,
        songId: entry.songId,
        title: entry.title,
        artist: entry.artist,
        album: entry.album,
        coverUrl: entry.coverUrl,
        durationMs: entry.durationMs,
        raw: entry.raw,
        cachedAt: entry.playedAt,
      );

  final String sourceKey;
  final String songId;
  final String title;
  final String artist;
  final String album;
  final String? coverUrl;
  final int? durationMs;
  final Map<String, dynamic> raw;

  /// 缓存完成时间（毫秒；排序与上限裁剪的依据）。
  final int cachedAt;

  String get key => '$sourceKey:$songId';

  /// 还原成列表 / 收藏 / 播放使用的曲目行（缓存行保留原曲身份）。
  PlaylistTrack toPlaylistTrack({int playlistId = 0, required int addedAt}) =>
      PlaylistTrack(
        playlistId: playlistId,
        sourceKey: sourceKey,
        songId: songId,
        title: title,
        artist: artist,
        album: album,
        coverUrl: coverUrl,
        durationMs: durationMs,
        raw: raw,
        addedAt: addedAt,
      );
}
