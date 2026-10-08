import '../../domain/models/discover.dart';
import '../raw_track.dart';
import '../source_track.dart';

/// [SourceTrack] → 发现曲目（热榜 / 歌单详情，多平台共用）。
///
/// raw 原样保留，播放时仍可回传音源脚本；`songId` 与
/// [SourceTrack.id] 的取键优先级一致（[rawIdOf]，不含平台前缀）。
DiscoverTrack discoverTrackOf(SourceTrack track) {
  final rawId = rawIdOf(track.raw);
  return DiscoverTrack(
    sourceKey: track.sourceKey,
    songId: rawId.isNotEmpty ? rawId : '${track.title}-${track.artist}',
    title: track.title,
    artist: track.artist,
    album: track.album,
    coverUrl: track.coverUrl,
    durationMs: track.duration?.inMilliseconds,
    raw: track.raw,
  );
}
