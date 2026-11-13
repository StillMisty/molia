/// 本地下载领域模型（纯 Dart，无 Flutter / drift 依赖）。
///
/// 下载是**不参与缓存 LRU 淘汰的持久副本**：行内保存原音源曲目键
/// （`originSourceKey`/`originSongId`）+ 自包含元数据快照 + 原音源 raw
/// 取链参数，供「本地歌曲」列表还原为本地曲目（`sourceKey = kLocalSourceKey`）
/// 与加入歌单（歌单表存快照，无需改表）。
library;

import 'library.dart';
import 'track.dart';

/// 本地下载音源 key（`TrackId.sourceKey` / `SourceTrack.sourceKey`）。
///
/// 约定：本地曲目的 payload 携带 `path`（音频文件路径）与可选的
/// `lyricPath`/`coverPath`；`songId` 固定为 `{原音源key}:{原曲目id}`，
/// 保证与下载记录一一对应、跨设备同步时可按该 key 过滤。
const String kLocalSourceKey = 'local';

/// 翻译歌词边车文件路径约定：`xxx.lrc` → `xxx.t.lrc`。
///
/// 歌词主文件存 `downloads/lyrics/`，翻译（如有）写同名边车文件；
/// 删除下载时按同一约定派生，不需要额外的数据库列。
String? translationLyricPathOf(String? lyricPath) {
  if (lyricPath == null || lyricPath.isEmpty) return null;
  final dot = lyricPath.lastIndexOf('.');
  if (dot <= 0) return '$lyricPath.t.lrc';
  return '${lyricPath.substring(0, dot)}.t.lrc';
}

/// 一条本地下载记录（`downloads` 表的领域形态）。
class DownloadedTrack {
  /// 原音源 key（wy / kw / 脚本 key / any_listen）。
  final String originSourceKey;

  /// 原音源曲目 id。
  final String originSongId;

  final String title;
  final String artist;
  final String album;

  /// 原音源封面 URL（本地封面缺失时的回退展示；不落网络请求也可用）。
  final String? coverUrl;
  final int? durationMs;

  /// 原音源 payload（取链参数）；本地曲目 payload 由此派生。
  final Map<String, dynamic> raw;

  /// 实际下载音质（LX 音质标识，如 `320k` / `flac`）。
  final String quality;

  /// 音频文件绝对路径；**可空**：记录可以只含歌词或只含封面（分项下载）。
  final String? filePath;

  final int sizeBytes;

  /// 歌词文件路径（`downloads/lyrics/`，长期存储；无歌词为 null）。
  final String? lyricPath;

  /// 封面文件路径（`downloads/covers/`；无封面为 null）。
  final String? coverPath;

  /// 公共 Downloads 副本的 content URI（Android MediaStore；未发布 / 其余
  /// 平台为 null）。仅用于删除下载时回收公共副本——播放取链只认 [filePath]。
  final String? publicUri;

  /// 本地导入（就地引用）：`filePath` 指向用户自己的文件，不复制副本，
  /// 删除记录时**不删除原文件**；`originSourceKey` 固定 `local`、
  /// `originSongId` 为稳定本地 id（[localKey]，`file:<uuid>`）。
  final bool imported;

  /// 本地导入的稳定身份（`file:<uuid>`；下载副本为 null）。
  ///
  /// 路径只属于 [filePath]，移动 / 重定位不改身份；收藏 / 列表 / 历史 /
  /// 会话 / 统计 / 自定义封面都引用它。
  final String? localKey;

  /// 文件修改时间（毫秒；扫描增量判定用，null = 尚未探测）。
  final int? mtimeMs;

  /// 确认文件不见的时间（毫秒；null = 可用）。
  final int? missingAt;

  final int downloadedAt;

  const DownloadedTrack({
    required this.originSourceKey,
    required this.originSongId,
    required this.title,
    this.artist = '',
    this.album = '',
    this.coverUrl,
    this.durationMs,
    this.raw = const {},
    this.quality = '',
    this.filePath,
    this.sizeBytes = 0,
    this.lyricPath,
    this.coverPath,
    this.publicUri,
    this.imported = false,
    this.localKey,
    this.mtimeMs,
    this.missingAt,
    required this.downloadedAt,
  });

  /// 翻译歌词边车文件路径（约定见 [translationLyricPathOf]）。
  String? get translationLyricPath => translationLyricPathOf(lyricPath);

  /// 是否已有音频文件（分项记录可能只有歌词 / 封面）。
  bool get hasAudio => filePath != null && filePath!.isNotEmpty;

  /// 是否已有歌词文件。
  bool get hasLyrics => lyricPath != null && lyricPath!.isNotEmpty;

  /// 是否已有封面文件。
  bool get hasCover => coverPath != null && coverPath!.isNotEmpty;

  /// 是否已发布公共 Downloads 副本（Android；其余平台恒为 false）。
  bool get hasPublicCopy => publicUri != null && publicUri!.isNotEmpty;

  /// 下载记录键 = 原音源曲目键（`downloads` 表唯一约束同构）。
  ///
  /// 导入记录的键是 `local:<localKey>`（唯一约束仍按 `originSongId` 走），
  /// 但**领域身份**是 [localSongId] 返回的 `localKey`——两者刻意不同。
  String get key => '$originSourceKey:$originSongId';

  /// 本地曲目的 `TrackId.id`。
  ///
  /// 导入 = 稳定 `localKey`（`file:<uuid>`）；下载副本沿用原音源键
  /// （`<原音源>:<原曲目id>`，带一层 `local:` 前缀），两者都不含路径。
  String get localSongId {
    final stable = localKey;
    if (imported && stable != null && stable.isNotEmpty) return stable;
    return key;
  }

  /// 是否确认文件不见（缺文件状态）。
  bool get isMissing => missingAt != null;

  /// 复制并替换可变字段（重定位 / 扫描 / 探测 / 改标题）。
  DownloadedTrack copyWith({
    String? originSongId,
    String? title,
    String? artist,
    String? album,
    String? coverUrl,
    int? durationMs,
    String? quality,
    String? filePath,
    int? sizeBytes,
    String? lyricPath,
    String? coverPath,
    String? publicUri,
    String? localKey,
    int? mtimeMs,
    int? missingAt,
    bool clearMissingAt = false,
  }) => DownloadedTrack(
    originSourceKey: originSourceKey,
    originSongId: originSongId ?? this.originSongId,
    title: title ?? this.title,
    artist: artist ?? this.artist,
    album: album ?? this.album,
    coverUrl: coverUrl ?? this.coverUrl,
    durationMs: durationMs ?? this.durationMs,
    raw: raw,
    quality: quality ?? this.quality,
    filePath: filePath ?? this.filePath,
    sizeBytes: sizeBytes ?? this.sizeBytes,
    lyricPath: lyricPath ?? this.lyricPath,
    coverPath: coverPath ?? this.coverPath,
    publicUri: publicUri ?? this.publicUri,
    imported: imported,
    localKey: localKey ?? this.localKey,
    mtimeMs: mtimeMs ?? this.mtimeMs,
    missingAt: clearMissingAt ? null : (missingAt ?? this.missingAt),
    downloadedAt: downloadedAt,
  );

  /// 本地曲目 payload（含路径的 raw；UI 禁读，只走音源链路）。
  Map<String, dynamic> get localPayload => {
    if (hasAudio) 'path': filePath,
    // rawIdOf 取键优先级含 songId：本地曲目 id 稳定为 `{origin}:{id}`。
    'songId': localSongId,
    if (lyricPath != null) 'lyricPath': lyricPath,
    if (translationLyricPath != null)
      'translationLyricPath': translationLyricPath,
    if (coverPath != null) 'coverPath': coverPath,
  };

  /// 展示/播放用封面：本地文件优先，回退原音源 URL。
  Uri? get artworkUri {
    final local = coverPath;
    if (local != null && local.isNotEmpty) return Uri.file(local);
    final remote = coverUrl;
    if (remote == null || remote.isEmpty) return null;
    return Uri.tryParse(remote);
  }

  /// 还原本地领域曲目（origin = localFile，自动换源显式跳过该来源）；
  /// 记录只有歌词 / 封面（无音频）时返回 null。
  Track? get localTrack {
    final path = filePath;
    if (path == null || path.isEmpty) return null;
    return Track(
      id: TrackId(kLocalSourceKey, localSongId),
      title: title,
      artists: artist.isEmpty ? const [] : [Artist(name: artist)],
      album: (album.isEmpty) ? null : album,
      duration: (durationMs != null && durationMs! > 0)
          ? Duration(milliseconds: durationMs!)
          : null,
      artwork: artworkUri == null ? null : Artwork(uri: artworkUri!),
      origin: TrackOrigin.localFile,
      qualities: quality.isEmpty ? const [] : [AudioQuality(type: quality)],
      payload: localPayload,
    );
  }

  /// 还原为歌单/收藏快照（`playlist_tracks` 自包含，无需改表）。
  PlaylistTrack toPlaylistTrack({int playlistId = 0, required int addedAt}) =>
      PlaylistTrack(
        playlistId: playlistId,
        sourceKey: kLocalSourceKey,
        songId: localSongId,
        title: title,
        artist: artist,
        album: album,
        coverUrl: artworkUri?.toString(),
        durationMs: durationMs,
        raw: localPayload,
        addedAt: addedAt,
      );

  /// 展示用大小文案（1 位小数 MB / 整数 KB / B）。
  String get sizeLabel {
    if (sizeBytes >= 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (sizeBytes >= 1024) return '${(sizeBytes / 1024).toStringAsFixed(0)} KB';
    return '$sizeBytes B';
  }

  @override
  String toString() => 'DownloadedTrack($key, $filePath)';
}
