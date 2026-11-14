import '../../domain/models/track.dart';
import '../../sources/builtin/channel/channels.dart';
import '../../sources/raw_track.dart';
import '../../sources/source_track.dart';

/// `SourceTrack` ↔ 领域 `Track` 互转。
///
/// 不变量：`SourceTrack.raw` / `Track.payload` **原样透传**（同一引用），
/// 取链/歌词/封面请求依赖平台字段（songmid/hash/copyrightId...）。

/// `SourceTrack` → 领域 `Track`。
///
/// 歌手优先取 raw 的项目内部字段 [kRawArtistsField]（内置平台解析时增补，
/// 名字 + 平台内 id，供歌手页跳转）；缺省（脚本源 / 无 `_artists`）回退整串
/// `SourceTrack.artist`（无 id，UI 不展示歌手入口）。
Track trackFromSourceTrack(SourceTrack source) {
  final sourceArtists = artistsFromRaw(source.raw);
  return Track(
    // 与 `SourceTrack.songId` 同源（同一 getter，不是各写一份规则）。
    id: TrackId(source.sourceKey, source.songId),
    title: source.title,
    artists: sourceArtists.isEmpty
        ? [Artist(name: source.artist)]
        : [
            for (final artist in sourceArtists)
              Artist(name: artist.name, id: artist.id),
          ],
    album: source.album,
    duration: source.duration,
    artwork: _artworkFrom(source.coverUrl),
    origin: originFromWire(source.origin),
    qualities: [
      for (final quality in source.qualities)
        AudioQuality(
          type: quality.type,
          size: quality.size,
          hash: quality.hash,
          container: quality.container,
        ),
    ],
    payload: source.raw,
    // 平台网页地址 / 专辑 id 是渠道自述的一部分（渠道文件里声明），
    // 映射层不再维护按 key 的 switch。`Track.payload` 的契约仍是 UI 禁读：
    // 页面需要的派生数据在这里算一次并随 `Track` 传递。
    platformPageUrl: _channelOf(source)?.pageUrl?.call(source.raw),
    platformAlbumId: _channelOf(source)?.albumId?.call(source.raw),
  );
}

/// 内置渠道自述（脚本源 / any-listen / local 没有渠道声明）。
SongChannel? _channelOf(SourceTrack source) =>
    SongChannels.forKey(source.sourceKey);

/// 领域 `Track` → `SourceTrack`（供 `LocalPlaybackService` / `SourceManager` 使用）。
SourceTrack sourceTrackFromTrack(Track track) {
  return SourceTrack(
    sourceKey: track.id.sourceKey,
    origin: originToWire(track.origin),
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
          container: quality.container,
        ),
    ],
    // 原样回传（不重建 Map），保证取链时脚本收到原始字段。
    raw: track.payload,
  );
}

Artwork? _artworkFrom(String? coverUrl) {
  if (coverUrl == null || coverUrl.isEmpty) return null;
  final uri = Uri.tryParse(coverUrl);
  if (uri == null) return null;
  return Artwork(uri: uri);
}

/// 字符串来源 → 领域枚举（未知来源按脚本源处理，与本地播放语义一致）。
TrackOrigin originFromWire(String origin) {
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

/// 领域枚举 → 字符串来源（保持 any-listen 的 `'any_listen'` 约定）。
String originToWire(TrackOrigin origin) {
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
