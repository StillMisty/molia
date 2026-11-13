/// 列表 M3U8 导出构建器：把列表行与下载记录合成为「位置 + Molia 键」。
///
/// M3U 天然有损（只保留标题 / 歌手 / 时长 / 键 / 位置）；raw payload 的
/// 全保真由可选的 `.molia.json` 备份承担。本模块只做纯装配：平台页地址与
/// 下载记录由调用方以函数注入，便于测试且不把 UI / 存储依赖带进来。
library;

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
      final path = record?.hasAudio == true ? record!.filePath : null;
      final moliaKey = _moliaKeyOf(track);
      final String location;
      if (path != null && path.isNotEmpty) {
        if (!await fileExists(path)) missing++;
        location = path;
      } else if (track.sourceKey == kLocalSourceKey) {
        // 本地身份存在但文件记录已丢失：仍写 Molia 回退地址并计入缺失，
        // 让导出摘要如实说明「这条在本机解析不到文件」。
        missing++;
        location = moliaTrackUri(moliaKey);
      } else {
        final pageUrl = pageUrlOf(track);
        location = pageUrl != null && pageUrl.isNotEmpty
            ? pageUrl
            : moliaTrackUri(moliaKey);
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

  /// 导出键：在线曲目保留原音源键；本地导入使用 #56 的稳定 `file:<uuid>`
  /// 身份（`local:<songId>`），不把绝对路径写进键里。
  static String _moliaKeyOf(PlaylistTrack track) =>
      '${track.sourceKey}:${track.songId}';
}
