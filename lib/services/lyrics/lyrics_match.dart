import '../song_match.dart';
import 'lyric_provider.dart';

/// 歌词搜索结果相似度匹配（LX `findMusic` 核心判定；实现见
/// `lib/services/song_match.dart`，与自动换源共用同一套判定）。
///
/// 与 LX 的差异：LX 在无候选命中时放弃该来源；这里回退到首个候选，
/// 保证命中时更准、未命中时至少不比第一个候选差。
SongMatch? pickBestSongMatch(
  List<SongMatch> candidates, {
  required String title,
  required String artist,
  String? album,
  Duration? duration,
}) {
  return pickBestSongMatchBy(
    candidates,
    target: SongMatchInfo(
      title: title,
      artist: artist,
      album: album,
      duration: duration,
    ),
    info: (match) => SongMatchInfo(
      title: match.title,
      artist: match.artist,
      album: match.album,
      duration: match.duration,
    ),
    requireStrictMatch: false,
  );
}
