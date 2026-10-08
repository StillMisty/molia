import '../../domain/models/track.dart';
import '../../sources/raw_track.dart';
import '../../sources/source_track.dart';

/// 旧 `SourceTrack` ↔ 领域 `Track` 互转（阶段 1–3 兼容层）。
///
/// 不变量：`SourceTrack.raw` / `Track.payload` **原样透传**（同一引用），
/// 取链/歌词/封面请求依赖平台字段（songmid/hash/copyrightId...）。

/// `SourceTrack` → 领域 `Track`。
Track trackFromSourceTrack(SourceTrack source) {
  return Track(
    id: TrackId(source.sourceKey, _rawId(source)),
    title: source.title,
    artists: [Artist(name: source.artist)],
    album: source.album,
    duration: source.duration,
    artwork: _artworkFrom(source.coverUrl),
    origin: originFromLegacy(source.origin),
    qualities: [
      for (final quality in source.qualities)
        AudioQuality(
          type: quality.type,
          size: quality.size,
          hash: quality.hash,
        ),
    ],
    payload: source.raw,
  );
}

/// 领域 `Track` → `SourceTrack`（供 `LocalPlaybackService` / `SourceManager` 使用）。
SourceTrack sourceTrackFromTrack(Track track) {
  return SourceTrack(
    sourceKey: track.id.sourceKey,
    origin: originToLegacy(track.origin),
    title: track.title,
    artist: track.artists.map((artist) => artist.name).join('/'),
    album: track.album ?? '',
    coverUrl: track.artwork?.uri.toString(),
    duration: track.duration,
    qualities: [
      for (final quality in track.qualities)
        SourceQuality(
          type: quality.type,
          size: quality.size,
          hash: quality.hash,
        ),
    ],
    // 原样回传（不重建 Map），保证取链时脚本收到原始字段。
    raw: track.payload,
  );
}

/// 与 `SourceTrack.id` 完全一致的平台内 id 提取规则（兜底为标题-歌手）。
String _rawId(SourceTrack source) {
  final key = rawIdOf(source.raw);
  return key.isNotEmpty ? key : '${source.title}-${source.artist}';
}

Artwork? _artworkFrom(String? coverUrl) {
  if (coverUrl == null || coverUrl.isEmpty) return null;
  final uri = Uri.tryParse(coverUrl);
  if (uri == null) return null;
  return Artwork(uri: uri);
}

/// 旧字符串来源 → 领域枚举（未知来源按脚本源处理，与本地播放语义一致）。
TrackOrigin originFromLegacy(String origin) {
  switch (origin) {
    case 'builtin':
      return TrackOrigin.builtin;
    case 'lx':
      return TrackOrigin.lx;
    case 'any_listen':
    case 'anyListen':
      return TrackOrigin.anyListen;
    case 'localFile':
    case 'local_file':
    case 'local':
      return TrackOrigin.localFile;
    default:
      return TrackOrigin.lx;
  }
}

/// 领域枚举 → 旧字符串来源（保持 any-listen 的 `'any_listen'` 约定）。
String originToLegacy(TrackOrigin origin) {
  switch (origin) {
    case TrackOrigin.builtin:
      return 'builtin';
    case TrackOrigin.lx:
      return 'lx';
    case TrackOrigin.anyListen:
      return 'any_listen';
    case TrackOrigin.localFile:
      return 'localFile';
  }
}
