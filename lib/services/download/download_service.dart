/// 单曲下载服务：取链 → 下载音频（或缓存命中直接拷贝）→ 离线包
/// （歌词/封面，可单独下载）→ 音频标签嵌入 → 落库。
///
/// 设计要点：
/// - 目录隔离：写 `downloads/`（应用支持目录），与 `cache/audio_cache`
///   完全隔离——清缓存永不触碰下载，删下载是独立动作；
/// - **缓存优先**：所选音质的完整音频缓存（同名且无 `.part`）命中时直接
///   拷贝不触网；歌词经注入的解析器（组合根接 `LyricsService`：缓存 →
///   原生取词 → 跨平台回退）；封面经 [ArtworkCache] 命中直读、未命中取图
///   后回填缓存；
/// - **分项记录**：`downloads.filePath` 可空——记录可以只含歌词或只含封面
///   （`downloadLyrics` / `downloadCover`），音频下载可一次带全；
/// - **标签嵌入**：音频就绪后把标题/歌手/专辑/歌词/封面写进文件标签
///   （`audio_tag_writer.dart`，best-effort，失败保留 sidecar）；
/// - 半成品用 `.part` 后缀，完成时原子改名，落库在改名之后：
///   播放取链只认数据库记录，永远不会读到半成品；
/// - 进度 / 取消 / 失败：进度经 [notifyListeners] 节流广播；取消走 dio
///   `CancelToken`，半成品清理后抛 `cancelled` 失败（UI 静默）；
/// - 歌词/封面是 best-effort：失败不阻断音频下载，对应路径记为 null；
/// - 同一原曲只保留一条记录（下载前查重，重名文件自动 `(2)`、`(3)` 递增）。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../../data/catalog/catalog_service.dart';
import '../../data/downloads/audio_tag_writer.dart';
import '../../data/downloads/download_storage.dart';
import '../../data/downloads/downloads_repository.dart';
import '../../data/http/app_dio.dart';
import '../../domain/models/download.dart';
import '../../domain/models/failure.dart';
import '../../domain/models/track.dart';
import '../../managers/artwork_cache.dart';
import '../../models/lyrics_result.dart';
import '../../services/cache_service.dart';
import '../../sources/source_track.dart' show pickQualityFor;
import 'download_settings.dart';

/// 下载时取词结果（主歌词 + 可选翻译；罗马音/逐字不落盘）。
class DownloadLyrics {
  const DownloadLyrics({required this.lyric, this.translation});

  final String lyric;
  final String? translation;
}

/// 下载时原生取词（组合根注入：`LyricsService.getLyrics` 适配，缓存优先）。
typedef DownloadLyricsResolver = Future<DownloadLyrics?> Function(Track track);

/// 下载时封面 URL 解析（组合根注入：`SourceManager.fetchPic` 适配）。
typedef DownloadArtworkResolver = Future<String?> Function(Track track);

/// 单条下载任务的实时进度（UI 消费；值相等不重复通知）。
class DownloadProgress {
  const DownloadProgress({required this.receivedBytes, this.totalBytes});

  final int receivedBytes;

  /// 响应头 Content-Length；未知时为 null（进度不可量化）。
  final int? totalBytes;

  /// 0..1；总大小未知时为 null。
  double? get fraction {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    return (receivedBytes / total).clamp(0.0, 1.0);
  }

  /// 百分比 0..100；总大小未知时为 null。
  int? get percent {
    final value = fraction;
    return value == null ? null : (value * 100).round();
  }

  @override
  bool operator ==(Object other) =>
      other is DownloadProgress &&
      other.receivedBytes == receivedBytes &&
      other.totalBytes == totalBytes;

  @override
  int get hashCode => Object.hash(receivedBytes, totalBytes);

  @override
  String toString() => 'DownloadProgress($receivedBytes/$totalBytes)';
}

/// 本地下载服务（`ChangeNotifier`：UI 用 `Selector` 订阅状态）。
class DownloadService extends ChangeNotifier {
  DownloadService({
    required CatalogService catalog,
    required DownloadsRepository repository,
    required DownloadStorage storage,
    Dio? dio,
    DownloadLyricsResolver? lyricsResolver,
    DownloadArtworkResolver? artworkResolver,
    CacheService? cacheService,
    ArtworkCache? artworkCache,
    DownloadSettings? settings,
    String Function()? preferredQuality,
    int Function()? clock,
  })  : _catalog = catalog,
        _repository = repository,
        _storage = storage,
        _dio = dio ?? createAppDio(),
        _lyricsResolver = lyricsResolver,
        _artworkResolver = artworkResolver,
        _cacheService = cacheService,
        _artworkCache = artworkCache,
        _settings = settings,
        _preferredQuality = preferredQuality,
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final CatalogService _catalog;
  final DownloadsRepository _repository;
  final DownloadStorage _storage;
  final Dio _dio;
  final DownloadLyricsResolver? _lyricsResolver;
  final DownloadArtworkResolver? _artworkResolver;
  final CacheService? _cacheService;
  final ArtworkCache? _artworkCache;
  final DownloadSettings? _settings;
  final String Function()? _preferredQuality;
  final int Function() _clock;

  final Logger _logger = Logger('molia.download_service');

  /// 已下载记录（键 = 原音源曲目键 `sourceKey:songId`）。
  Map<String, DownloadedTrack> _records = {};

  /// 进行中的下载（键同上）。
  final Map<String, DownloadProgress> _active = {};
  final Map<String, CancelToken> _tokens = {};

  /// 进行中任务对应的曲目（下载管理页展示用）。
  final Map<String, Track> _activeTracks = {};

  bool _supported = false;
  bool _initialized = false;

  /// 下载目录是否可用（Web 为 false，UI 隐藏下载入口）。
  bool get supported => _supported;

  /// 记录是否已加载（启动时 [init] 一次）。
  bool get initialized => _initialized;

  /// 全部下载（下载时间倒序）。
  List<DownloadedTrack> get downloads {
    final list = List<DownloadedTrack>.of(_records.values)
      ..sort((a, b) {
        final byTime = b.downloadedAt.compareTo(a.downloadedAt);
        return byTime != 0 ? byTime : b.key.compareTo(a.key);
      });
    return list;
  }

  /// 按原音源曲目键查询下载记录。
  DownloadedTrack? recordFor(String sourceKey, String songId) =>
      _records['$sourceKey:$songId'];

  /// 当前播放曲目的下载记录：本地曲目按自身 id 反查，在线曲目按原音源键。
  DownloadedTrack? recordForTrack(Track track) {
    if (track.id.sourceKey == kLocalSourceKey) return _records[track.id.id];
    return _records['${track.id.sourceKey}:${track.id.id}'];
  }

  /// 当前曲目的下载进度；未在下载返回 null。
  DownloadProgress? progressForTrack(Track track) {
    if (track.id.sourceKey == kLocalSourceKey) return null;
    return _active['${track.id.sourceKey}:${track.id.id}'];
  }

  /// 当前解析出的下载根目录（设置页展示；不可用返回 null）。
  Future<String?> rootPath() => _storage.downloadsRoot();

  /// 进行中的任务（曲目 + 进度）：下载管理页展示。
  List<(Track, DownloadProgress)> get activeTasks => [
        for (final entry in _active.entries)
          if (_activeTracks[entry.key] != null)
            (_activeTracks[entry.key]!, entry.value),
      ];

  /// 清扫崩溃遗留的半成品（`*.part`），返回删除数量。
  Future<int> cleanupIncompleteDownloads() async {
    final root = await _storage.downloadsRoot();
    if (root == null) return 0;
    var deleted = 0;
    try {
      final files = await _storage.listFiles(root);
      for (final path in files) {
        if (!path.endsWith(downloadPartSuffix)) continue;
        await _storage.deleteQuietly(path);
        deleted++;
      }
    } catch (e) {
      _logger.warning('半成品清扫失败: $e');
    }
    return deleted;
  }

  /// 无记录引用的孤儿文件（删除下载失败 / 手工拷贝残留），返回绝对路径。
  Future<List<String>> orphanFiles() async {
    final root = await _storage.downloadsRoot();
    if (root == null) return const [];
    final referenced = <String>{
      for (final record in _records.values) ...[
        if (record.filePath != null) record.filePath!,
        if (record.lyricPath != null) record.lyricPath!,
        if (record.translationLyricPath != null) record.translationLyricPath!,
        if (record.coverPath != null) record.coverPath!,
      ],
    };
    try {
      final files = await _storage.listFiles(root);
      return [
        for (final path in files)
          if (!path.endsWith(downloadPartSuffix) && !referenced.contains(path))
            path,
      ];
    } catch (e) {
      _logger.warning('孤儿文件扫描失败: $e');
      return const [];
    }
  }

  /// 删除全部孤儿文件，返回删除数量。
  Future<int> deleteOrphanFiles() async {
    final orphans = await orphanFiles();
    for (final path in orphans) {
      await _storage.deleteQuietly(path);
    }
    return orphans.length;
  }

  /// 迁移旧位置（应用支持目录）的下载文件到当前下载根目录。
  ///
  /// 逐条记录搬运音频 / 歌词 / 翻译边车 / 封面（相对子目录保持不变），
  /// 更新记录后删除旧文件；单条失败不影响其余。返回 `(迁移数, 失败数)`。
  Future<(int, int)> migrateLegacyDownloads() async {
    final newRoot = await _storage.downloadsRoot();
    final legacyRoot = await _storage.legacyDownloadsRoot();
    if (newRoot == null || legacyRoot == null || newRoot == legacyRoot) {
      return (0, 0);
    }
    var moved = 0;
    var failed = 0;
    for (final record in List<DownloadedTrack>.of(_records.values)) {
      final audio = record.filePath;
      if (audio == null || !audio.startsWith(legacyRoot)) continue;
      try {
        final newAudio = _remapRoot(audio, legacyRoot, newRoot);
        await _copyIfNeeded(audio, newAudio);
        final lyric = record.lyricPath;
        final newLyric =
            lyric == null ? null : _remapRoot(lyric, legacyRoot, newRoot);
        if (lyric != null) await _copyIfNeeded(lyric, newLyric!);
        final translation = record.translationLyricPath;
        final newTranslation = translation == null
            ? null
            : _remapRoot(translation, legacyRoot, newRoot);
        if (translation != null) {
          await _copyIfNeeded(translation, newTranslation!);
        }
        final cover = record.coverPath;
        final newCover =
            cover == null ? null : _remapRoot(cover, legacyRoot, newRoot);
        if (cover != null) await _copyIfNeeded(cover, newCover!);

        final updated = DownloadedTrack(
          originSourceKey: record.originSourceKey,
          originSongId: record.originSongId,
          title: record.title,
          artist: record.artist,
          album: record.album,
          coverUrl: record.coverUrl,
          durationMs: record.durationMs,
          raw: record.raw,
          quality: record.quality,
          filePath: newAudio,
          sizeBytes: record.sizeBytes,
          lyricPath: newLyric,
          coverPath: newCover,
          downloadedAt: record.downloadedAt,
        );
        await _repository.insert(updated);
        _records[record.key] = updated;
        await _storage.deleteQuietly(audio);
        if (lyric != null) await _storage.deleteQuietly(lyric);
        if (translation != null) await _storage.deleteQuietly(translation);
        if (cover != null) await _storage.deleteQuietly(cover);
        moved++;
      } catch (e) {
        _logger.warning('迁移下载失败 ${record.key}: $e');
        failed++;
      }
    }
    if (moved > 0) notifyListeners();
    return (moved, failed);
  }

  /// 旧根 → 新根的路径重映射（保留相对子目录，如 `lyrics/`、`covers/`）。
  static String _remapRoot(String path, String from, String to) =>
      to + path.substring(from.length);

  Future<void> _copyIfNeeded(String from, String to) async {
    if (from == to) return;
    if (await _storage.fileExists(to)) return;
    await _storage.copyFile(from, to);
  }

  /// 批量下载（队列全量）：顺序执行，跳过已下载与不支持项。
  ///
  /// 不做断点续传（平台直链多为一次性签名地址，续传价值低）；
  /// 单项失败不影响后续，返回 `(下载数, 失败数)`。
  Future<(int, int)> downloadBatch(Iterable<Track> tracks) async {
    var done = 0;
    var failed = 0;
    for (final track in tracks) {
      if (recordForTrack(track)?.hasAudio ?? false) continue;
      if (track.id.sourceKey == kLocalSourceKey) continue;
      try {
        await download(track);
        done++;
      } on SourceFailure catch (failure) {
        if (failure.kind != FailureKind.cancelled) failed++;
      } catch (_) {
        failed++;
      }
    }
    return (done, failed);
  }

  /// 指定音质是否命中完整音频缓存（下载弹层的「本地缓存」标记）。
  Future<bool> audioCacheHit(Track track, String quality) async =>
      await _completeAudioCachePath(track, quality) != null;

  /// 缺省下载音质：偏好音质 × 曲目可用音质（下载弹层的预选项）。
  String defaultQualityFor(Track track) => _pickQuality(track);

  /// 加载已有下载记录并探测存储可用性（启动时调用一次）。
  Future<void> init() async {
    try {
      _supported = await _storage.downloadsRoot() != null;
      // Web（存储不可用）不触碰数据库：本机下载整体关闭。
      if (_supported) {
        final records = await _repository.listAll();
        _records = {for (final record in records) record.key: record};
        // 崩溃遗留的半成品（.part）清扫：不阻断启动，失败仅记日志。
        final cleaned = await cleanupIncompleteDownloads();
        if (cleaned > 0) _logger.info('清理未完成的下载文件 $cleaned 个');
      }
    } catch (e) {
      _logger.warning('下载初始化失败: $e');
    }
    _initialized = true;
    notifyListeners();
  }

  /// 下载 [track] 的音频（原音源曲目）；完成后自动落库。
  ///
  /// [quality] 为下载弹层选定的音质（LX 标识）；缺省用偏好音质。
  /// [includeLyrics] / [includeCover] 控制是否同时下载离线歌词 / 封面。
  ///
  /// 失败抛 [SourceFailure]（kind / l10nKey 供 UI 映射文案）：
  /// - `unsupported`：平台不支持 / 本地曲目 / 非 http(s) 直链；
  /// - `cancelled`：用户取消（UI 可静默）；
  /// - `network` / `unknown`：下载失败，已清理半成品。
  Future<void> download(
    Track track, {
    String? quality,
    bool includeLyrics = true,
    bool includeCover = true,
  }) async {
    _guardDownloadable(track);
    final root = await _requireRoot();
    final key = '${track.id.sourceKey}:${track.id.id}';
    if (_records[key]?.hasAudio ?? false) {
      throw const SourceFailure(
        kind: FailureKind.unsupported,
        message: '该曲目已下载',
        l10nKey: 'downloadAlreadyExists',
      );
    }
    if (_active.containsKey(key)) return; // 重复请求：忽略

    final resolvedQuality = quality ?? _pickQuality(track);
    _active[key] = const DownloadProgress(receivedBytes: 0);
    _activeTracks[key] = track;
    final cancelToken = CancelToken();
    _tokens[key] = cancelToken;
    notifyListeners();

    String? partPath;
    String? filePath;
    String? lyricPath;
    String? coverPath;
    DownloadLyrics? lyrics;
    _ResolvedCover? cover;
    late final String base;
    try {
      // 1) 缓存优先：完整缓存文件直接拷贝，不触网。
      final cached = await _completeAudioCachePath(track, resolvedQuality);
      if (cached != null) {
        _logger.info('音频缓存命中，直接拷贝: $cached');
        final extension = _extensionForQuality(resolvedQuality);
        base = await _uniqueBaseName(root, _baseNameFor(track), extension);
        filePath = p.join(root, '$base.$extension');
        partPath = '$filePath$downloadPartSuffix';
        await _storage.copyFile(cached, partPath);
        await _storage.rename(partPath, filePath);
        partPath = null;
        _updateProgress(key, await _storage.fileSize(filePath), null);
      } else {
        // 2) 网络下载（扩展名优先取 URL 后缀，回退音质推断）。
        final stream = await _catalog.resolve(
          track,
          quality:
              resolvedQuality.isEmpty ? null : AudioQuality(type: resolvedQuality),
        );
        final url = stream.uri;
        if (url.scheme != 'http' && url.scheme != 'https') {
          throw const SourceFailure(
            kind: FailureKind.unsupported,
            message: '取到的播放地址不是网络直链',
            l10nKey: 'downloadUnsupported',
          );
        }
        final extension = extensionFor(url, resolvedQuality);
        base = await _uniqueBaseName(root, _baseNameFor(track), extension);
        filePath = p.join(root, '$base.$extension');
        partPath = '$filePath$downloadPartSuffix';
        final response = await _dio.get<ResponseBody>(
          url.toString(),
          options: Options(
            responseType: ResponseType.stream,
            headers: stream.headers,
          ),
          cancelToken: cancelToken,
        );
        final status = response.statusCode ?? 0;
        if (status < 200 || status >= 300) {
          throw SourceFailure(
            kind: FailureKind.network,
            message: 'HTTP $status',
            l10nKey: 'downloadFailed',
            retryable: true,
          );
        }
        final total = int.tryParse(
          response.headers.value(Headers.contentLengthHeader) ?? '',
        );
        await _storage.writeStream(
          partPath,
          streamBody(response).stream,
          total: total,
          onProgress: (received, expected) =>
              _updateProgress(key, received, expected),
        );
        _throwIfCancelled(cancelToken);
        await _storage.rename(partPath, filePath);
        partPath = null;
      }

      final size = await _storage.fileSize(filePath);
      _throwIfCancelled(cancelToken);

      // 3) 离线歌词 / 封面（best-effort，失败不阻断音频下载）。
      if (includeLyrics) {
        lyrics = await _resolveLyrics(track);
        if (lyrics != null) {
          lyricPath = await _writeLyricsFile(root, base, lyrics);
        }
      }
      if (includeCover) {
        cover = await _resolveCover(track);
        if (cover != null) {
          coverPath = await _writeCoverFile(root, base, cover);
        }
      }
      _throwIfCancelled(cancelToken);

      // 4) 标签嵌入（best-effort：失败保留 sidecar；可在下载设置关闭）。
      if (_settings?.embedTags ?? true) {
        await embedDownloadTags(
          storage: _storage,
          filePath: filePath,
          title: track.title,
          artist: _artistLabel(track),
          album: track.album ?? '',
          lyrics: lyrics?.lyric,
          coverBytes: cover?.bytes,
          coverMimeType: cover?.mimeType ?? 'image/jpeg',
        );
      }

      final previous = _records[key];
      final record = DownloadedTrack(
        originSourceKey: track.id.sourceKey,
        originSongId: track.id.id,
        title: track.title,
        artist: _artistLabel(track),
        album: track.album ?? '',
        coverUrl: track.artwork?.uri.toString(),
        durationMs: track.duration?.inMilliseconds,
        raw: Map<String, dynamic>.from(track.payload),
        quality: resolvedQuality,
        filePath: filePath,
        sizeBytes: size,
        // 分项合并：先前单独下载的歌词 / 封面不被本次下载覆盖丢失。
        lyricPath: lyricPath ?? previous?.lyricPath,
        coverPath: coverPath ?? previous?.coverPath,
        downloadedAt: _clock(),
      );
      await _repository.insert(record);
      _records[key] = record;
      _logger.info('下载完成: $key -> $filePath (${record.sizeLabel})');
    } catch (e) {
      await _cleanupFailedDownload(
        partPath: partPath,
        filePath: filePath,
        lyricPath: lyricPath,
        coverPath: coverPath,
      );
      if ((e is DioException && CancelToken.isCancel(e)) ||
          cancelToken.isCancelled) {
        throw const SourceFailure(
          kind: FailureKind.cancelled,
          message: '下载已取消',
          l10nKey: 'downloadCancelled',
        );
      }
      if (e is SourceFailure) rethrow;
      throw SourceFailure.from(e);
    } finally {
      _active.remove(key);
      _tokens.remove(key);
      _activeTracks.remove(key);
      _lastProgressNotified.remove(key);
      notifyListeners();
    }
  }

  /// 单独下载歌词（缓存优先）；无歌词抛 `downloadNoLyrics`。
  Future<void> downloadLyrics(Track track) async {
    _guardDownloadable(track);
    final root = await _requireRoot();
    final lyrics = await _resolveLyrics(track);
    if (lyrics == null || lyrics.lyric.trim().isEmpty) {
      throw const SourceFailure(
        kind: FailureKind.unsupported,
        message: '未找到歌词',
        l10nKey: 'downloadNoLyrics',
      );
    }
    final base = await _partBaseName(
      track,
      existingPath: recordForTrack(track)?.lyricPath,
      subdir: downloadsLyricsDirName,
      extension: 'lrc',
    );
    final path = await _writeLyricsFile(root, base, lyrics);
    if (path == null) {
      throw const SourceFailure(
        kind: FailureKind.unknown,
        message: '歌词写入失败',
        l10nKey: 'downloadFailed',
      );
    }
    await _upsertPart(track, lyricPath: path);
    notifyListeners();
    unawaited(_embedTagsFromFiles(track));
  }

  /// 单独下载封面（缓存优先）；无封面抛 `downloadNoArtwork`。
  Future<void> downloadCover(Track track) async {
    _guardDownloadable(track);
    final root = await _requireRoot();
    final cover = await _resolveCover(track);
    if (cover == null) {
      throw const SourceFailure(
        kind: FailureKind.unsupported,
        message: '没有封面',
        l10nKey: 'downloadNoArtwork',
      );
    }
    final extension = _imageExtension(cover.url ?? '');
    final base = await _partBaseName(
      track,
      existingPath: recordForTrack(track)?.coverPath,
      subdir: downloadsCoversDirName,
      extension: extension,
    );
    final path = await _writeCoverFile(root, base, cover);
    if (path == null) {
      throw const SourceFailure(
        kind: FailureKind.unknown,
        message: '封面写入失败',
        l10nKey: 'downloadFailed',
      );
    }
    await _upsertPart(track, coverPath: path);
    notifyListeners();
    unawaited(_embedTagsFromFiles(track));
  }

  /// 取消下载（无进行中任务时空操作）。
  void cancel(String sourceKey, String songId) =>
      _tokens['$sourceKey:$songId']?.cancel();

  /// 取消当前曲目的下载（UI 入口）。
  void cancelTrack(Track track) {
    if (track.id.sourceKey == kLocalSourceKey) return;
    cancel(track.id.sourceKey, track.id.id);
  }

  /// 删除下载：先删数据库记录（避免残留半删记录），再删音频 / 歌词 / 封面文件。
  Future<void> delete(DownloadedTrack record) async {
    await _repository.delete(record.originSourceKey, record.originSongId);
    _records.remove(record.key);
    final audio = record.filePath;
    if (audio != null) await _storage.deleteQuietly(audio);
    final lyric = record.lyricPath;
    if (lyric != null) {
      await _storage.deleteQuietly(lyric);
      final translation = record.translationLyricPath;
      if (translation != null) await _storage.deleteQuietly(translation);
    }
    final cover = record.coverPath;
    if (cover != null) await _storage.deleteQuietly(cover);
    notifyListeners();
  }

  /// 播放取链优先命中本地副本：原音源曲目已有下载且文件存在时返回 file URI。
  ///
  /// 本地曲目（`sourceKey = local`）返回 null——由 `local` 音源自身解析；
  /// 只有歌词 / 封面的分项记录（无音频）同样返回 null。
  Future<Uri?> localUriFor(Track track) async {
    if (track.id.sourceKey == kLocalSourceKey) return null;
    final record = _records['${track.id.sourceKey}:${track.id.id}'];
    final path = record?.filePath;
    if (record == null || path == null || path.isEmpty) return null;
    if (!await _storage.fileExists(path)) return null;
    return Uri.file(path);
  }

  /// 本地曲目的离线歌词（读 `downloads/lyrics/`，不触网）；无歌词返回 null。
  Future<LyricsResult?> localLyricsFor(Track track) async {
    if (track.id.sourceKey != kLocalSourceKey) return null;
    final lyricPath = track.payload['lyricPath'];
    if (lyricPath is! String || lyricPath.isEmpty) return null;
    final lyric = await _storage.readString(lyricPath);
    if (lyric == null || lyric.trim().isEmpty) return null;
    String? translation;
    final translationPath = track.payload['translationLyricPath'];
    if (translationPath is String && translationPath.isNotEmpty) {
      final text = await _storage.readString(translationPath);
      if (text != null && text.trim().isNotEmpty) translation = text;
    }
    return LyricsResult(
      lyric: lyric,
      translation: translation,
      provider: kLocalSourceKey,
    );
  }

  // 内部：守卫与记录

  void _guardDownloadable(Track track) {
    if (track.id.sourceKey == kLocalSourceKey) {
      throw const SourceFailure(
        kind: FailureKind.unsupported,
        message: '本地曲目无需下载',
        l10nKey: 'downloadLocalTrack',
      );
    }
  }

  Future<String> _requireRoot() async {
    final root = await _storage.downloadsRoot();
    if (root == null) {
      throw const SourceFailure(
        kind: FailureKind.unsupported,
        message: '当前平台不支持下载',
        l10nKey: 'downloadUnsupported',
      );
    }
    return root;
  }

  /// 分项写入后的记录更新（保留既有音频 / 另一分项字段）。
  Future<void> _upsertPart(
    Track track, {
    String? lyricPath,
    String? coverPath,
  }) async {
    final key = '${track.id.sourceKey}:${track.id.id}';
    final existing = _records[key];
    final record = DownloadedTrack(
      originSourceKey: track.id.sourceKey,
      originSongId: track.id.id,
      title: track.title,
      artist: _artistLabel(track),
      album: track.album ?? '',
      coverUrl: track.artwork?.uri.toString(),
      durationMs: track.duration?.inMilliseconds,
      raw: Map<String, dynamic>.from(track.payload),
      quality: existing?.quality ?? '',
      filePath: existing?.filePath,
      sizeBytes: existing?.sizeBytes ?? 0,
      lyricPath: lyricPath ?? existing?.lyricPath,
      coverPath: coverPath ?? existing?.coverPath,
      downloadedAt: existing?.downloadedAt ?? _clock(),
    );
    await _repository.insert(record);
    _records[key] = record;
  }

  /// 已有音频时把（sidecar 里的）歌词 / 封面补写进标签。
  Future<void> _embedTagsFromFiles(Track track) async {
    if (!(_settings?.embedTags ?? true)) return;
    final record = recordForTrack(track);
    final audioPath = record?.filePath;
    if (record == null || audioPath == null) return;
    String? lyrics;
    final lyricPath = record.lyricPath;
    if (lyricPath != null) lyrics = await _storage.readString(lyricPath);
    Uint8List? coverBytes;
    final coverPath = record.coverPath;
    if (coverPath != null) coverBytes = await _storage.readBytes(coverPath);
    await embedDownloadTags(
      storage: _storage,
      filePath: audioPath,
      title: record.title,
      artist: record.artist,
      album: record.album,
      lyrics: lyrics,
      coverBytes: coverBytes,
      coverMimeType: _mimeTypeForPath(coverPath ?? ''),
    );
  }

  // 内部：缓存优先取数

  /// 完整音频缓存路径：命中返回路径，未命中 / 仍在写入（`.part`）返回 null。
  Future<String?> _completeAudioCachePath(Track track, String quality) async {
    final cache = _cacheService;
    if (cache == null) return null;
    final dir = await cache.audioCacheDirPath();
    if (dir == null) return null;
    final name = CacheService.audioCacheKey(
      sourceKey: track.id.sourceKey,
      songId: track.id.id,
      quality: quality,
    );
    final path = p.join(dir, name);
    if (!await _storage.fileExists(path)) return null;
    if (await _storage.fileExists('$path$downloadPartSuffix')) return null;
    return path;
  }

  Future<DownloadLyrics?> _resolveLyrics(Track track) async {
    final resolver = _lyricsResolver;
    if (resolver == null) return null;
    try {
      final lyrics = await resolver(track);
      if (lyrics == null || lyrics.lyric.trim().isEmpty) return null;
      return lyrics;
    } catch (e) {
      _logger.warning('取词失败: $e');
      return null;
    }
  }

  /// 封面字节：曲目主图 + 降级链先查缓存，未命中再取图并回填缓存。
  Future<_ResolvedCover?> _resolveCover(Track track) async {
    final artwork = track.artwork;
    final urls = <String>[
      if (artwork != null && artwork.uri.toString().isNotEmpty)
        artwork.uri.toString(),
      if (artwork != null)
        for (final fallback in artwork.fallbacks)
          if (fallback.toString().isNotEmpty) fallback.toString(),
    ];
    final cache = _artworkCache;
    if (cache != null) {
      for (final url in urls) {
        final bytes = await cache.bytesOf(url);
        if (bytes != null && bytes.isNotEmpty) {
          return _ResolvedCover(
            bytes: bytes,
            url: url,
            mimeType: _mimeTypeForPath(url),
          );
        }
      }
    }
    final resolver = _artworkResolver;
    if (resolver == null) return null;
    String? url;
    try {
      url = await resolver(track);
    } catch (e) {
      _logger.warning('取图失败: $e');
      return null;
    }
    final effective = (url == null || url.isEmpty) ? null : url;
    if (effective == null) {
      // 没有新图可取：回退到曲目自带的封面地址（可能仍是网络图）。
      if (urls.isEmpty) return null;
      return _downloadCoverBytes(urls.first);
    }
    return _downloadCoverBytes(effective);
  }

  /// 封面大小上限：超过按无封面处理（避免异常大图占用磁盘）。
  static const int _maxCoverBytes = 8 * 1024 * 1024;

  Future<_ResolvedCover?> _downloadCoverBytes(String url) async {
    try {
      final response = await _dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          // 与封面显示同一套请求头（浏览器 UA + 平台 Referer）。
          headers: ArtworkCache.headersFor(url),
        ),
      );
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 300) return null;
      final chunks = <int>[];
      var total = 0;
      await for (final chunk in streamBody(response).stream) {
        total += chunk.length;
        if (total > _maxCoverBytes) return null;
        chunks.addAll(chunk);
      }
      if (chunks.isEmpty) return null;
      final bytes = Uint8List.fromList(chunks);
      // 回填封面缓存：后续展示 / 再次下载直接命中。
      unawaited(_artworkCache?.putBytes(url, bytes));
      return _ResolvedCover(
        bytes: bytes,
        url: url,
        mimeType: _mimeTypeForPath(url),
      );
    } catch (e) {
      _logger.warning('封面下载失败: $e');
      return null;
    }
  }

  // 内部：下载流程

  void _throwIfCancelled(CancelToken token) {
    if (token.isCancelled) {
      throw const SourceFailure(
        kind: FailureKind.cancelled,
        message: '下载已取消',
        l10nKey: 'downloadCancelled',
      );
    }
  }

  /// 进度节流：每累计 32KB 或任务收尾时通知一次（避免逐分片刷 UI）。
  static const int _progressNotifyStep = 32 * 1024;
  final Map<String, int> _lastProgressNotified = {};

  void _updateProgress(String key, int received, int? total) {
    final last = _lastProgressNotified[key] ?? 0;
    if (received - last < _progressNotifyStep &&
        (total == null || received < total)) {
      return;
    }
    _lastProgressNotified[key] = received;
    final progress = DownloadProgress(
      receivedBytes: received,
      totalBytes: total,
    );
    if (_active[key] == progress) return;
    _active[key] = progress;
    notifyListeners();
  }

  Future<void> _cleanupFailedDownload({
    String? partPath,
    String? filePath,
    String? lyricPath,
    String? coverPath,
  }) async {
    if (partPath != null) await _storage.deleteQuietly(partPath);
    if (filePath != null) await _storage.deleteQuietly(filePath);
    if (lyricPath != null) {
      await _storage.deleteQuietly(lyricPath);
      final translation = translationLyricPathOf(lyricPath);
      if (translation != null) await _storage.deleteQuietly(translation);
    }
    if (coverPath != null) await _storage.deleteQuietly(coverPath);
  }

  String _pickQuality(Track track) {
    final preferred = _preferredQuality?.call() ?? '320k';
    final types = [
      for (final quality in track.qualities)
        if (quality.type.isNotEmpty) quality.type,
    ];
    return pickQualityFor(types, preferred);
  }

  /// 音频扩展名：缓存命中无法从 URL 推断时按音质映射（flac/wav/ape/其余 mp3）。
  static String _extensionForQuality(String quality) {
    switch (quality) {
      case 'flac24bit':
      case 'flac':
        return 'flac';
      case 'wav':
        return 'wav';
      case 'ape':
        return 'ape';
      default:
        return 'mp3';
    }
  }

  /// 唯一文件名基名：磁盘上已有同名音频（或记录占用）时追加 ` (2)`、` (3)`。
  Future<String> _uniqueBaseName(
    String root,
    String desiredBase,
    String extension,
  ) async {
    final used = <String>{
      for (final record in _records.values)
        if (record.filePath != null)
          p.basenameWithoutExtension(record.filePath!).toLowerCase(),
    };
    var candidate = desiredBase;
    var index = 2;
    while (true) {
      final lower = candidate.toLowerCase();
      if (!used.contains(lower) &&
          !await _storage.fileExists(
            p.join(root, '$candidate.$extension'),
          )) {
        return candidate;
      }
      if (index > 999) {
        return '$desiredBase (${DateTime.now().millisecondsSinceEpoch})';
      }
      candidate = '$desiredBase ($index)';
      index++;
    }
  }

  /// 分项文件基名：已有音频 → 跟随音频基名（同目录 sidecar 约定）；
  /// 已有同分项文件 → 复用；否则按曲目名在目标子目录内查重。
  Future<String> _partBaseName(
    Track track, {
    required String? existingPath,
    required String subdir,
    required String extension,
  }) async {
    final record = recordForTrack(track);
    final audioPath = record?.filePath;
    if (audioPath != null && audioPath.isNotEmpty) {
      return p.basenameWithoutExtension(audioPath);
    }
    final existing = existingPath;
    if (existing != null && existing.isNotEmpty) {
      return p.basenameWithoutExtension(existing);
    }
    final root = await _requireRoot();
    final desired = _baseNameFor(track);
    var candidate = desired;
    var index = 2;
    while (await _storage.fileExists(
      p.join(root, subdir, '$candidate.$extension'),
    )) {
      if (index > 999) return '$desired (${DateTime.now().millisecondsSinceEpoch})';
      candidate = '$desired ($index)';
      index++;
    }
    return candidate;
  }

  /// 写入歌词主文件 + 翻译边车；失败返回 null（best-effort）。
  Future<String?> _writeLyricsFile(
    String root,
    String base,
    DownloadLyrics lyrics,
  ) async {
    String? path;
    try {
      path = p.join(root, downloadsLyricsDirName, '$base.lrc');
      await _storage.writeString(path, lyrics.lyric);
      final translation = lyrics.translation;
      if (translation != null && translation.trim().isNotEmpty) {
        final translationPath = translationLyricPathOf(path);
        if (translationPath != null) {
          await _storage.writeString(translationPath, translation);
        }
      }
      return path;
    } catch (e) {
      _logger.warning('下载歌词失败: $e');
      if (path != null) {
        await _storage.deleteQuietly(path);
        final translationPath = translationLyricPathOf(path);
        if (translationPath != null) {
          await _storage.deleteQuietly(translationPath);
        }
      }
      return null;
    }
  }

  /// 写入封面文件；失败返回 null（best-effort）。
  Future<String?> _writeCoverFile(
    String root,
    String base,
    _ResolvedCover cover,
  ) async {
    String? path;
    try {
      path = p.join(
        root,
        downloadsCoversDirName,
        '$base.${_imageExtension(cover.url ?? '')}',
      );
      await _storage.writeBytes(path, cover.bytes);
      return path;
    } catch (e) {
      _logger.warning('下载封面失败: $e');
      if (path != null) await _storage.deleteQuietly(path);
      return null;
    }
  }

  /// 文件名基名：按下载设置模板（默认 `{artist} - {title}`）生成并清洗。
  String _baseNameFor(Track track) {
    final template = _settings?.filenameTemplate ?? kDefaultFilenameTemplate;
    final raw = DownloadSettings.applyTemplate(template, {
      'artist': _artistLabel(track),
      'title': track.title,
      'album': track.album ?? '',
    });
    return sanitizeFileName(raw);
  }

  static String _artistLabel(Track track) => track.artists
      .map((artist) => artist.name)
      .where((name) => name.isNotEmpty)
      .join(', ');

  /// `{歌手} - {歌名}`；无歌手只用歌名；非法字符替换、空白折叠、限长。
  @visibleForTesting
  static String baseNameFor(Track track) {
    final raw = _artistLabel(track).isEmpty
        ? track.title
        : '${_artistLabel(track)} - ${track.title}';
    return sanitizeFileName(raw);
  }

  static final RegExp _illegalFileNameChars = RegExp(r'[\\/:*?"<>|\x00-\x1f]');
  static final RegExp _whitespaceRun = RegExp(r'\s+');

  /// 文件系统非法字符替换为 `_`，空白折叠，空名回退 `unknown`，限长 120。
  @visibleForTesting
  static String sanitizeFileName(String name) {
    final replaced = name.replaceAll(_illegalFileNameChars, '_');
    final collapsed = replaced.replaceAll(_whitespaceRun, ' ').trim();
    if (collapsed.isEmpty) return 'unknown';
    const maxLength = 120;
    if (collapsed.length <= maxLength) return collapsed;
    // 按 rune 截断，避免切断代理对。
    return String.fromCharCodes(collapsed.runes.take(maxLength)).trim();
  }

  /// 扩展名：URL 路径里的音频后缀优先，否则按音质推断（默认 mp3）。
  @visibleForTesting
  static String extensionFor(Uri url, String quality) {
    const audioExtensions = {
      'mp3', 'flac', 'm4a', 'aac', 'ogg', 'oga', 'opus',
      'wav', 'ape', 'wma', 'mka', 'mp4',
    };
    final ext = p.extension(url.path).toLowerCase().replaceFirst('.', '');
    if (audioExtensions.contains(ext)) return ext == 'oga' ? 'ogg' : ext;
    return _extensionForQuality(quality);
  }

  static String _imageExtension(String url) {
    const imageExtensions = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'};
    final ext = p
        .extension(Uri.tryParse(url)?.path ?? '')
        .toLowerCase()
        .replaceFirst('.', '');
    if (imageExtensions.contains(ext)) return ext == 'jpeg' ? 'jpg' : ext;
    return 'jpg';
  }

  static String _mimeTypeForPath(String path) {
    final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
    return switch (ext) {
      'png' => 'image/png',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'bmp' => 'image/bmp',
      _ => 'image/jpeg',
    };
  }
}

/// 已解析的封面字节（下载链路内部使用）。
class _ResolvedCover {
  const _ResolvedCover({
    required this.bytes,
    required this.url,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String? url;
  final String mimeType;
}
