/// 本地下载曲目的离线歌词读取（`downloads/lyrics/`）。
///
/// **为什么独立于 `DownloadService`**：下载服务与歌词服务互为依赖——
/// 下载动作要在线取词（`DownloadService.lyricsResolver`），本地曲目取词要读
/// 下载离线歌词（`LyricsService.trackLyricLoader`）。把「读离线歌词」这条边
/// 从服务实例解耦成「存储 + 曲目」的纯函数后，组合根可以按
/// 歌词服务 → 下载服务 的构造顺序装配，两条依赖都是普通参数，
/// 不需要任何前向引用 / late 绑定（公开 API 不变：
/// `DownloadService.localLyricsFor` 仍是对外入口，内部转发到本函数）。
library;

import '../../domain/models/download.dart';
import '../../domain/models/track.dart';
import '../../models/lyrics_result.dart';
import 'download_storage.dart';

/// 读取 [track]（`local` 音源曲目）的离线歌词与可选翻译；无歌词返回 null。
///
/// 音频 / 歌词 / 封面路径由下载时写进 `payload`（`lyricPath` /
/// `translationLyricPath`），这里只读文件，不触网。
Future<LyricsResult?> readDownloadedLyrics(
  DownloadStorage storage,
  Track track,
) async {
  if (track.id.sourceKey != kLocalSourceKey) return null;
  final lyricPath = track.payload['lyricPath'];
  if (lyricPath is! String || lyricPath.isEmpty) return null;
  final lyric = await storage.readString(lyricPath);
  if (lyric == null || lyric.trim().isEmpty) return null;
  String? translation;
  final translationPath = track.payload['translationLyricPath'];
  if (translationPath is String && translationPath.isNotEmpty) {
    final text = await storage.readString(translationPath);
    if (text != null && text.trim().isNotEmpty) translation = text;
  }
  return LyricsResult(
    lyric: lyric,
    translation: translation,
    provider: kLocalSourceKey,
  );
}
