/// 下载记录装配模块：部分状态 → [DownloadedTrack]（16 字段）的唯一装配点。
///
/// 为什么独立成模块：下载链路有四种装配形态——完整下载 / 分项更新 / 本地导入 /
/// 补发布——此前各自在下载编排里手装 16 个字段，任何新增字段都要改多处；
/// 「部分状态」的合并语义（音频下载合并先前分项、分项更新保留已有音频、
/// 补发布原样保留其余字段）也散在调用点。装配收进这里后，四种形态共用一份
/// 字段表与合并语义，服务不再感知字段。
///
/// 边界：只做字段装配——不落库（写库仍是 `DownloadsRepository`）、不写文件、
/// 不发通知；[clock] 可注入（下载时间是内容时间，与落库时刻分开）。
library;

import '../../domain/models/download.dart';
import '../../domain/models/track.dart';

/// 下载记录装配器（`DownloadService` 持有；四种形态各一个意图方法）。
class DownloadRecordAssembler {
  /// [clock] 是下载时间（`downloadedAt`）的来源；缺省墙上时钟。记录既有
  /// `downloadedAt` 的形态（分项更新 / 补发布）不重新取值。
  DownloadRecordAssembler({int Function()? clock})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int Function() _clock;

  /// 完整音频下载：音频路径 / 大小 / 音质必填；歌词 / 封面 / 公共副本
  /// 「本次产物优先，缺失回退上一条记录」——分项合并：先前单独下载的歌词 /
  /// 封面不被本次下载覆盖丢失，发布失败的旧副本定位也不丢。
  DownloadedTrack forAudioDownload({
    required Track track,
    required String quality,
    required String filePath,
    required int sizeBytes,
    String? lyricPath,
    String? coverPath,
    String? publicUri,
    DownloadedTrack? previous,
  }) {
    final draft = _RecordDraft.forTrack(track, downloadedAt: _clock())
      ..quality = quality
      ..filePath = filePath
      ..sizeBytes = sizeBytes
      ..lyricPath = lyricPath ?? previous?.lyricPath
      ..coverPath = coverPath ?? previous?.coverPath
      ..publicUri = publicUri ?? previous?.publicUri;
    return draft.build();
  }

  /// 分项（歌词 / 封面）更新：曲目快照 + 已有记录——保留已有音频与另一分项
  /// （本次写成功的那一项优先）；没有旧记录时得到一条只有歌词 / 封面的记录
  /// （`filePath` 可空）。
  DownloadedTrack forPartialDownload(
    Track track, {
    DownloadedTrack? existing,
    String? lyricPath,
    String? coverPath,
  }) {
    final draft = _RecordDraft.forTrack(
      track,
      downloadedAt: existing?.downloadedAt ?? _clock(),
    )
      ..quality = existing?.quality ?? ''
      ..filePath = existing?.filePath
      ..sizeBytes = existing?.sizeBytes ?? 0
      ..lyricPath = lyricPath ?? existing?.lyricPath
      ..coverPath = coverPath ?? existing?.coverPath
      ..publicUri = existing?.publicUri
      ..imported = existing?.imported ?? false;
    return draft.build();
  }

  /// 本地导入：就地引用用户文件（`imported`），只有文件元数据——没有网络
  /// 快照（raw 空、音质空），封面 / 分项 / 公共副本都为空。
  DownloadedTrack forLocalImport({
    required String filePath,
    required int sizeBytes,
    required String title,
    required String artist,
    required String album,
    int? durationMs,
  }) =>
      (_RecordDraft(
        originSourceKey: kLocalSourceKey,
        originSongId: filePath,
        title: title,
        artist: artist,
        album: album,
        durationMs: durationMs,
        filePath: filePath,
        sizeBytes: sizeBytes,
        imported: true,
        downloadedAt: _clock(),
      )).build();

  /// 补发布：只补公共副本定位，其余字段原样保留。
  DownloadedTrack republished(DownloadedTrack record, String publicUri) =>
      (_RecordDraft.of(record)..publicUri = publicUri).build();
}

/// 装配草稿：16 字段与 [DownloadedTrack] 同形，[build] 是唯一把字段写进
/// 记录的地方。
///
/// 模型新增字段时在这里补一处（字段 + [build]），四种形态自然共用；服务侧
/// 不感知任何字段。默认值取模型的缺省（如 `imported = false`、`raw = {}`），
/// 各形态只写自己关心的差异。
class _RecordDraft {
  _RecordDraft({
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
    required this.downloadedAt,
  });

  /// 曲目快照 → 字段（完整下载 / 分项更新的公共起点）。
  factory _RecordDraft.forTrack(Track track, {required int downloadedAt}) =>
      _RecordDraft(
        originSourceKey: track.id.sourceKey,
        originSongId: track.id.id,
        title: track.title,
        artist: track.artistLabel,
        album: track.album ?? '',
        coverUrl: track.artwork?.uri.toString(),
        durationMs: track.duration?.inMilliseconds,
        raw: Map<String, dynamic>.from(track.payload),
        downloadedAt: downloadedAt,
      );

  /// 已有记录 → 字段（补发布 / 分项更新的基底）。
  factory _RecordDraft.of(DownloadedTrack record) => _RecordDraft(
        originSourceKey: record.originSourceKey,
        originSongId: record.originSongId,
        title: record.title,
        artist: record.artist,
        album: record.album,
        coverUrl: record.coverUrl,
        durationMs: record.durationMs,
        raw: record.raw,
        quality: record.quality,
        filePath: record.filePath,
        sizeBytes: record.sizeBytes,
        lyricPath: record.lyricPath,
        coverPath: record.coverPath,
        publicUri: record.publicUri,
        imported: record.imported,
        downloadedAt: record.downloadedAt,
      );

  String originSourceKey;
  String originSongId;
  String title;
  String artist;
  String album;
  String? coverUrl;
  int? durationMs;
  Map<String, dynamic> raw;
  String quality;
  String? filePath;
  int sizeBytes;
  String? lyricPath;
  String? coverPath;
  String? publicUri;
  bool imported;
  int downloadedAt;

  DownloadedTrack build() => DownloadedTrack(
        originSourceKey: originSourceKey,
        originSongId: originSongId,
        title: title,
        artist: artist,
        album: album,
        coverUrl: coverUrl,
        durationMs: durationMs,
        raw: raw,
        quality: quality,
        filePath: filePath,
        sizeBytes: sizeBytes,
        lyricPath: lyricPath,
        coverPath: coverPath,
        publicUri: publicUri,
        imported: imported,
        downloadedAt: downloadedAt,
      );
}
