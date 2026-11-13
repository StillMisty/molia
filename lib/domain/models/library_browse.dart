/// 专辑 / 歌手浏览索引与重复版本检测（纯 Dart，可在无 widget / 无数据库下测试）。
///
/// 输入是已读出的收藏 / 用户列表曲目 / 下载导入记录；这里只做去重、分组、
/// 排序与重复聚类，不做任何 I/O。历史不参与（太吵），只有音频缓存的在线曲目
/// 也不会出现在输入里。
library;

import 'download.dart';
import 'library.dart';

/// 聚合视图里的一行曲目（代表行会从多个来源补全空字段）。
class BrowseTrack {
  const BrowseTrack({
    required this.sourceKey,
    required this.songId,
    required this.title,
    this.artist = '',
    this.album = '',
    this.coverUrl,
    this.durationMs,
    this.raw = const {},
    this.addedAt = 0,
  });

  final String sourceKey;
  final String songId;
  final String title;
  final String artist;
  final String album;
  final String? coverUrl;
  final int? durationMs;
  final Map<String, dynamic> raw;
  final int addedAt;

  String get key => '$sourceKey:$songId';

  bool get hasCover => coverUrl != null && coverUrl!.isNotEmpty;

  /// 第一位非空歌手（按仓库规范分隔符 `, ` 拆分）；全空为空串。
  String get primaryArtist {
    for (final part in artist.split(', ')) {
      final name = part.trim();
      if (name.isNotEmpty) return name;
    }
    return '';
  }

  BrowseTrack mergedWith(BrowseTrack later) => BrowseTrack(
    sourceKey: sourceKey,
    songId: songId,
    title: title.isNotEmpty ? title : later.title,
    artist: artist.isNotEmpty ? artist : later.artist,
    album: album.isNotEmpty ? album : later.album,
    coverUrl: hasCover ? coverUrl : later.coverUrl,
    durationMs: durationMs ?? later.durationMs,
    raw: raw.isNotEmpty ? raw : later.raw,
    addedAt: addedAt != 0 ? addedAt : later.addedAt,
  );

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

  static BrowseTrack fromPlaylistTrack(PlaylistTrack track) => BrowseTrack(
    sourceKey: track.sourceKey,
    songId: track.songId,
    title: track.title,
    artist: track.artist,
    album: track.album,
    coverUrl: track.coverUrl,
    durationMs: track.durationMs,
    raw: track.raw,
    addedAt: track.addedAt,
  );

  static BrowseTrack fromDownload(DownloadedTrack record) => BrowseTrack(
    sourceKey: kLocalSourceKey,
    songId: record.localSongId,
    title: record.title,
    artist: record.artist,
    album: record.album,
    coverUrl: record.artworkUri?.toString(),
    durationMs: record.durationMs,
    raw: record.localPayload,
    addedAt: record.downloadedAt,
  );
}

class BrowsePlaylist {
  const BrowsePlaylist({required this.id, required this.tracks});

  final int id;
  final List<PlaylistTrack> tracks;
}

class BrowseSource {
  const BrowseSource({
    this.favorites = const [],
    this.playlists = const [],
    this.downloads = const [],
  });

  final List<PlaylistTrack> favorites;

  /// 用户列表（非收藏），按列表 id 升序；列表内按 `sortOrder`。
  final List<BrowsePlaylist> playlists;

  /// 下载 / 导入记录；缺失与无音频记录在构建时排除。
  final List<DownloadedTrack> downloads;
}

class AlbumGroup {
  const AlbumGroup({
    required this.album,
    required this.primaryArtist,
    required this.tracks,
    required this.sortKey,
  });

  /// 原始专辑名；空串表示未知专辑（UI 用 l10n 兜底）。
  final String album;
  final String primaryArtist;
  final List<BrowseTrack> tracks;

  /// 归一化排序键（未知专辑排在最后）。
  final String sortKey;

  bool get isUnknownAlbum => album.isEmpty;
}

class ArtistGroup {
  const ArtistGroup({
    required this.artist,
    required this.tracks,
    required this.sortKey,
  });

  /// 原始歌手名；空串表示未知歌手。
  final String artist;
  final List<BrowseTrack> tracks;
  final String sortKey;

  bool get isUnknownArtist => artist.isEmpty;
}

class LibraryBrowseIndex {
  const LibraryBrowseIndex({
    required this.tracks,
    required this.albums,
    required this.artists,
  });

  final List<BrowseTrack> tracks;
  final List<AlbumGroup> albums;
  final List<ArtistGroup> artists;
}

/// 归一化：去首尾空白、小写、折叠空白、去零宽字符。无拼音 / 变音折叠。
String normalizeBrowseText(String value) => value
    .replaceAll('\u200B', '')
    .replaceAll('\u200C', '')
    .replaceAll('\u200D', '')
    .replaceAll('\uFEFF', '')
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'\s+'), ' ');

/// 歌手标签拆分（仓库规范分隔符 `, `）；不拆 `/` 与 `&`。
List<String> splitArtistLabel(String label) {
  final result = <String>[];
  for (final part in label.split(', ')) {
    final name = part.trim();
    if (name.isNotEmpty && !result.contains(name)) result.add(name);
  }
  return result;
}

/// 收藏 ∪ 用户列表 ∪ 下载 / 导入，按 `sourceKey:songId` 去重。
///
/// 代表行优先级：收藏 → 下载 / 导入 → 自建列表（列表 id、sortOrder 稳定）。
/// 后面的候选只补空字段，不覆盖已有值。
LibraryBrowseIndex buildBrowseIndex(BrowseSource source) {
  final ordered = <BrowseTrack>[];
  for (final track in source.favorites) {
    ordered.add(BrowseTrack.fromPlaylistTrack(track));
  }
  for (final record in source.downloads) {
    if (!record.hasAudio || record.isMissing) continue;
    ordered.add(BrowseTrack.fromDownload(record));
  }
  final playlists = [...source.playlists]..sort((a, b) => a.id.compareTo(b.id));
  for (final playlist in playlists) {
    final tracks = [...playlist.tracks]
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    for (final track in tracks) {
      ordered.add(BrowseTrack.fromPlaylistTrack(track));
    }
  }

  final byKey = <String, int>{};
  final merged = <BrowseTrack>[];
  for (final track in ordered) {
    final index = byKey[track.key];
    if (index == null) {
      byKey[track.key] = merged.length;
      merged.add(track);
    } else {
      merged[index] = merged[index].mergedWith(track);
    }
  }

  return LibraryBrowseIndex(
    tracks: List.unmodifiable(merged),
    albums: List.unmodifiable(_buildAlbums(merged)),
    artists: List.unmodifiable(_buildArtists(merged)),
  );
}

List<AlbumGroup> _buildAlbums(List<BrowseTrack> tracks) {
  final buckets = <String, _AlbumBucket>{};
  for (final track in tracks) {
    final artist = track.primaryArtist;
    final album = track.album.trim();
    final artistKey = normalizeBrowseText(artist);
    // 未知专辑按主歌手分桶，避免整库一个大桶；双未知合成一个桶。
    final key = album.isEmpty
        ? 'unknown|$artistKey'
        : 'album|${normalizeBrowseText(album)}|$artistKey';
    final bucket = buckets.putIfAbsent(
      key,
      () => _AlbumBucket(album: album, primaryArtist: artist),
    );
    bucket.tracks.add(track);
  }
  final groups = [
    for (final bucket in buckets.values)
      AlbumGroup(
        album: bucket.album,
        primaryArtist: bucket.primaryArtist,
        tracks: List.unmodifiable(bucket.tracks),
        sortKey: bucket.album.isEmpty
            ? '\u{10FFFF}${normalizeBrowseText(bucket.primaryArtist)}'
            : '${normalizeBrowseText(bucket.album)}\u0000'
                  '${normalizeBrowseText(bucket.primaryArtist)}',
      ),
  ]..sort((a, b) => a.sortKey.compareTo(b.sortKey));
  return groups;
}

class _AlbumBucket {
  _AlbumBucket({required this.album, required this.primaryArtist});

  final String album;
  final String primaryArtist;
  final List<BrowseTrack> tracks = [];
}

List<ArtistGroup> _buildArtists(List<BrowseTrack> tracks) {
  final buckets = <String, _ArtistBucket>{};
  for (final track in tracks) {
    final names = splitArtistLabel(track.artist);
    if (names.isEmpty) {
      buckets
          .putIfAbsent('\u{10FFFF}', () => _ArtistBucket(artist: ''))
          .tracks
          .add(track);
      continue;
    }
    for (final name in names) {
      final key = normalizeBrowseText(name);
      buckets
          .putIfAbsent(key, () => _ArtistBucket(artist: name))
          .tracks
          .add(track);
    }
  }
  final groups = [
    for (final entry in buckets.entries)
      ArtistGroup(
        artist: entry.value.artist,
        tracks: List.unmodifiable(entry.value.tracks),
        sortKey: entry.key,
      ),
  ]..sort((a, b) => a.sortKey.compareTo(b.sortKey));
  return groups;
}

class _ArtistBucket {
  _ArtistBucket({required this.artist});

  final String artist;
  final List<BrowseTrack> tracks = [];
}

/// 一个重复版本组：代表行 + 全部版本（代表行在首位）。
class DuplicateGroup {
  const DuplicateGroup({required this.representative, required this.versions});

  final BrowseTrack representative;
  final List<BrowseTrack> versions;

  bool get hasMultipleVersions => versions.length > 1;
}

/// 重复检测：标题 + 主歌手归一化相同，且双方时长差 ≤ 3000ms。
///
/// 任一侧没有时长就不合并（宁可漏，不误合并 live / remaster / cover）。
/// 检测只影响展示，不删除 / 合并任何记录。
List<DuplicateGroup> groupDuplicates(List<BrowseTrack> tracks) {
  final clusters = <String, List<_DurationCluster>>{};
  final order = <_DurationCluster>[];
  for (final track in tracks) {
    final title = normalizeBrowseText(track.title);
    final artist = normalizeBrowseText(track.primaryArtist);
    final key = '$title\u0000$artist';
    final duration = track.durationMs;
    final groups = clusters.putIfAbsent(key, () => []);
    _DurationCluster? target;
    if (duration != null) {
      for (final cluster in groups) {
        final existing = cluster.durationMs;
        if (existing == null) continue;
        if ((existing - duration).abs() <= 3000) {
          target = cluster;
          break;
        }
      }
    }
    if (target == null) {
      target = _DurationCluster(duration);
      groups.add(target);
      order.add(target);
    }
    target.tracks.add(track);
  }
  return [
    for (final cluster in order)
      if (cluster.tracks.isNotEmpty)
        DuplicateGroup(
          representative: cluster.tracks.first,
          versions: List.unmodifiable(cluster.tracks),
        ),
  ];
}

class _DurationCluster {
  _DurationCluster(this.durationMs);

  final int? durationMs;
  final List<BrowseTrack> tracks = [];
}

/// 版本计数（按代表行 key）；只有多版本才出现。
Map<String, int> duplicateVersionCounts(List<DuplicateGroup> groups) => {
  for (final group in groups)
    if (group.hasMultipleVersions)
      group.representative.key: group.versions.length,
};
