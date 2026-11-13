/// 列表分享的数据来源：内容模型 + 本机封面字节读取。
///
/// 页面只负责把「封面路径从哪里来」注入进来；路径解析、去重与文件读取都在
/// 本模块，分享模型（`PlaylistShareContent`）仍只含展示字符串。
library;

import 'dart:io';
import 'dart:typed_data';

import '../../domain/models/library.dart';
import '../poster/playlist_poster_layout.dart';

class PlaylistShareSource {
  const PlaylistShareSource({
    required this.playlist,
    required this.tracks,
    required this.playlistCoverPathOf,
    required this.downloadedCoverPathOf,
    required this.customCoverPathOf,
  });

  final PlaylistInfo playlist;
  final List<PlaylistTrack> tracks;

  /// 列表封面键 → 本机文件路径。
  final String? Function(String key) playlistCoverPathOf;

  /// 列表行 → 下载 / 导入记录的封面路径。
  final String? Function(PlaylistTrack track) downloadedCoverPathOf;

  /// 列表行 → 曲目自定义封面路径。
  final String? Function(PlaylistTrack track) customCoverPathOf;

  /// 本机可用的封面文件（列表封面优先，其次各曲目；最多 9 张）。
  List<String> localCoverPaths() {
    final paths = <String>[];
    final key = playlist.effectiveCoverKey;
    final playlistPath = key == null ? null : playlistCoverPathOf(key);
    if (playlistPath != null && playlistPath.isNotEmpty) {
      paths.add(playlistPath);
    }
    for (final track in tracks) {
      if (paths.length >= 9) break;
      final path = downloadedCoverPathOf(track) ?? customCoverPathOf(track);
      if (path != null && path.isNotEmpty && !paths.contains(path)) {
        paths.add(path);
      }
    }
    return paths;
  }

  PlaylistShareContent buildContent({
    required String displayName,
    required String trackCountLabel,
    required String Function(int count) andMoreLabel,
  }) => PlaylistShareContent(
    name: displayName,
    description: playlist.description,
    trackCountLabel: trackCountLabel,
    andMoreLabel: andMoreLabel,
    coverCount: localCoverPaths().length,
    tracks: [
      for (final track in tracks)
        PlaylistShareTrack(title: track.title, artist: track.artist),
    ],
  );

  /// 读取封面字节；单张失败只留空槽，不影响整张海报。
  Future<List<Uint8List?>> loadCovers() async {
    final bytes = <Uint8List?>[];
    for (final path in localCoverPaths()) {
      try {
        final file = File(path);
        if (!await file.exists()) continue;
        final data = await file.readAsBytes();
        if (data.isNotEmpty) bytes.add(data);
      } catch (_) {
        // 读不到的一张只留空槽。
      }
    }
    return bytes;
  }
}
