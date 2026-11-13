/// 列表 M3U8 导出构建器：把列表行与下载记录合成为「位置 + Molia 键」。
///
/// M3U 天然有损（只保留标题 / 歌手 / 时长 / 键 / 位置）；raw payload 的
/// 全保真由可选的 `.molia.json` 备份承担。本模块只做纯装配：平台页地址与
/// 下载记录由调用方以函数注入，便于测试且不把 UI / 存储依赖带进来。
library;

import '../../data/local_identity.dart';
import '../../domain/models/download.dart';
import '../../domain/models/library.dart';
import 'playlist_file_codec.dart';

/// 一次 M3U8 导出的结果（文本 + 缺失文件计数）。
class PlaylistM3u8Export {
  const PlaylistM3u8Export({
    required this.text,
    required this.total,
    required this.missingFiles,
  });

  final String text;
  final int total;

  /// 引用了本机路径但文件已不在的数量：仍然写出路径，不静默丢条目。
  final int missingFiles;
}

/// M3U8 导出构建器。
class PlaylistExportBuilder {
  const PlaylistExportBuilder({
    required this.pageUrlOf,
    required this.downloadedRecordOf,
    required this.fileExists,
  });

  /// 平台页面地址（来自 `Track.platformPageUrl`；没有返回 null）。
  final String? Function(PlaylistTrack track) pageUrlOf;

  /// 该行的下载 / 导入记录（没有返回 null）。
  final DownloadedTrack? Function(PlaylistTrack track) downloadedRecordOf;

  /// 本机路径是否存在（缺失也照写，只计数）。
  final Future<bool> Function(String path) fileExists;

  Future<PlaylistM3u8Export> buildM3u8({
    required String name,
    required List<PlaylistTrack> tracks,
  }) async {
    var missing = 0;
    final entries = <PlaylistExportEntry>[];
    for (final track in tracks) {
      final record = downloadedRecordOf(track);
      final path = _localPathOf(track, record);
      final moliaKey = _moliaKeyOf(track);
      final String location;
      if (path != null && path.isNotEmpty) {
        // 本地 / 导入行始终写绝对路径，即使文件已不在（摘要计数，不换地址）。
        if (!await fileExists(path)) missing++;
        location = path;
      } else if (track.sourceKey == kLocalSourceKey) {
        // 没有记录也没有路径：稳定身份仍可用 molia 回退键；旧路径身份没有
        // 可写位置，计入缺失。
        missing++;
        location = moliaKey == null
            ? (legacyLocalPathOf(track.songId) ?? track.songId)
            : moliaTrackUri(moliaKey);
      } else {
        final pageUrl = pageUrlOf(track);
        location = pageUrl != null && pageUrl.isNotEmpty
            ? pageUrl
            : moliaTrackUri(moliaKey!);
      }
      entries.add(
        PlaylistExportEntry(
          title: track.title,
          artist: track.artist,
          durationMs: track.durationMs,
          moliaKey: moliaKey,
          location: location,
        ),
      );
    }
    return PlaylistM3u8Export(
      text: encodeM3u8Playlist(name: name, entries: entries),
      total: entries.length,
      missingFiles: missing,
    );
  }

  /// 本机路径：下载 / 导入记录优先；本地行回退到 raw 里记录的路径或旧
  /// `local:<绝对路径>` 身份。在线行没有本地路径返回 null。
  static String? _localPathOf(PlaylistTrack track, DownloadedTrack? record) {
    if (record?.hasAudio == true) return record!.filePath;
    if (track.sourceKey != kLocalSourceKey) return null;
    final rawPath = track.raw['path'];
    if (rawPath is String && rawPath.isNotEmpty) return rawPath;
    return legacyLocalPathOf(track.songId);
  }

  /// 导出键：在线曲目保留原音源键；本地导入使用稳定 `file:<uuid>` 身份
  /// （`local:<songId>`），旧路径身份没有稳定键时返回 null（不写 #MOLIA）。
  static String? _moliaKeyOf(PlaylistTrack track) {
    if (track.sourceKey != kLocalSourceKey) {
      return '${track.sourceKey}:${track.songId}';
    }
    if (isStableLocalKey(track.songId)) return 'local:${track.songId}';
    if (isLegacyLocalIdentity(track.songId)) return null;
    // 下载副本的领域 id 是原音源键（`wy:123`）：导出时回到在线键 + 路径。
    if (track.songId.contains(':')) return track.songId;
    return null;
  }
}
