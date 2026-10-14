/// 单曲下载服务：取链 → 下载音频 → 离线包（歌词/封面）→ 落库。
///
/// 设计要点：
/// - 目录隔离：写 `downloads/`（应用支持目录），与 `cache/audio_cache`
///   完全隔离——清缓存永不触碰下载，删下载是独立动作；
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
import '../../data/downloads/download_storage.dart';
import '../../data/downloads/downloads_repository.dart';
import '../../data/http/app_dio.dart';
import '../../domain/models/download.dart';
import '../../domain/models/failure.dart';
import '../../domain/models/track.dart';
import '../../managers/artwork_cache.dart';
import '../../models/lyrics_result.dart';
import '../../sources/source_track.dart' show pickQualityFor;

/// 下载时取词结果（主歌词 + 可选翻译；罗马音/逐字不落盘）。
class DownloadLyrics {
  const DownloadLyrics({required this.lyric, this.translation});

  final String lyric;
  final String? translation;
}

/// 下载时原生取词（组合根注入：`SourceManager.fetchLyric` 适配）。
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
    String Function()? preferredQuality,
    int Function()? clock,
  })  : _catalog = catalog,
        _repository = repository,
        _storage = storage,
        _dio = dio ?? createAppDio(),
        _lyricsResolver = lyricsResolver,
        _artworkResolver = artworkResolver,
        _preferredQuality = preferredQuality,
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final CatalogService _catalog;
  final DownloadsRepository _repository;
  final DownloadStorage _storage;
  final Dio _dio;
  final DownloadLyricsResolver? _lyricsResolver;
  final DownloadArtworkResolver? _artworkResolver;
  final String Function()? _preferredQuality;
  final int Function() _clock;

  final Logger _logger = Logger('molia.download_service');

  /// 已下载记录（键 = 原音源曲目键 `sourceKey:songId`）。
  Map<String, DownloadedTrack> _records = {};

  /// 进行中的下载（键同上）。
  final Map<String, DownloadProgress> _active = {};
  final Map<String, CancelToken> _tokens = {};

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

  /// 加载已有下载记录并探测存储可用性（启动时调用一次）。
  Future<void> init() async {
    try {
      _supported = await _storage.downloadsRoot() != null;
      // Web（存储不可用）不触碰数据库：本机下载整体关闭。
      if (_supported) {
        final records = await _repository.listAll();
        _records = {for (final record in records) record.key: record};
      }
    } catch (e) {
      _logger.warning('下载初始化失败: $e');
    }
    _initialized = true;
    notifyListeners();
  }

  /// 下载 [track]（原音源曲目）；完成后自动落库。
  ///
  /// 失败抛 [SourceFailure]（kind / l10nKey 供 UI 映射文案）：
  /// - `unsupported`：平台不支持 / 本地曲目 / 非 http(s) 直链；
  /// - `cancelled`：用户取消（UI 可静默）；
  /// - `network` / `unknown`：下载失败，已清理半成品。
  Future<void> download(Track track) async {
    if (track.id.sourceKey == kLocalSourceKey) {
      throw const SourceFailure(
        kind: FailureKind.unsupported,
        message: '本地曲目无需下载',
        l10nKey: 'downloadLocalTrack',
      );
    }
    final root = await _storage.downloadsRoot();
    if (root == null) {
      throw const SourceFailure(
        kind: FailureKind.unsupported,
        message: '当前平台不支持下载',
        l10nKey: 'downloadUnsupported',
      );
    }
    final key = '${track.id.sourceKey}:${track.id.id}';
    if (_records.containsKey(key)) {
      throw const SourceFailure(
        kind: FailureKind.unsupported,
        message: '该曲目已下载',
        l10nKey: 'downloadAlreadyExists',
      );
    }
    if (_active.containsKey(key)) return; // 重复请求：忽略

    _active[key] = const DownloadProgress(receivedBytes: 0);
    final cancelToken = CancelToken();
    _tokens[key] = cancelToken;
    notifyListeners();

    String? partPath;
    String? filePath;
    String? lyricPath;
    String? coverPath;
    try {
      final quality = _pickQuality(track);
      final stream = await _catalog.resolve(
        track,
        quality: quality.isEmpty ? null : AudioQuality(type: quality),
      );
      final url = stream.uri;
      if (url.scheme != 'http' && url.scheme != 'https') {
        throw const SourceFailure(
          kind: FailureKind.unsupported,
          message: '取到的播放地址不是网络直链',
          l10nKey: 'downloadUnsupported',
        );
      }

      final extension = extensionFor(url, quality);
      final base = await _uniqueBaseName(root, baseNameFor(track), extension);
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

      final size = await _storage.fileSize(filePath);
      _throwIfCancelled(cancelToken);

      // Phase 2：离线歌词 / 封面（best-effort，失败不阻断音频下载）。
      lyricPath = await _tryWriteLyrics(root, base, track);
      coverPath = await _tryWriteCover(root, base, track);
      _throwIfCancelled(cancelToken);

      final record = DownloadedTrack(
        originSourceKey: track.id.sourceKey,
        originSongId: track.id.id,
        title: track.title,
        artist: track.artists
            .map((artist) => artist.name)
            .where((name) => name.isNotEmpty)
            .join(', '),
        album: track.album ?? '',
        coverUrl: track.artwork?.uri.toString(),
        durationMs: track.duration?.inMilliseconds,
        raw: Map<String, dynamic>.from(track.payload),
        quality: quality,
        filePath: filePath,
        sizeBytes: size,
        lyricPath: lyricPath,
        coverPath: coverPath,
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
      _lastProgressNotified.remove(key);
      notifyListeners();
    }
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
    await _storage.deleteQuietly(record.filePath);
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
  /// 本地曲目（`sourceKey = local`）返回 null——由 `local` 音源自身解析。
  Future<Uri?> localUriFor(Track track) async {
    if (track.id.sourceKey == kLocalSourceKey) return null;
    final record = _records['${track.id.sourceKey}:${track.id.id}'];
    if (record == null) return null;
    if (!await _storage.fileExists(record.filePath)) return null;
    return Uri.file(record.filePath);
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

  /// 唯一文件名基名：磁盘上已有同名音频（或记录占用）时追加 ` (2)`、` (3)`。
  Future<String> _uniqueBaseName(
    String root,
    String desiredBase,
    String extension,
  ) async {
    final used = <String>{
      for (final record in _records.values)
        p.basenameWithoutExtension(record.filePath).toLowerCase(),
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

  /// `{歌手} - {歌名}`；无歌手只用歌名；非法字符替换、空白折叠、限长。
  @visibleForTesting
  static String baseNameFor(Track track) {
    final artist = track.artists
        .map((artist) => artist.name)
        .where((name) => name.isNotEmpty)
        .join(', ');
    final raw = artist.isEmpty ? track.title : '$artist - ${track.title}';
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

  // 内部：离线包（歌词 / 封面）

  Future<String?> _tryWriteLyrics(String root, String base, Track track) async {
    final resolver = _lyricsResolver;
    if (resolver == null) return null;
    String? path;
    try {
      final lyrics = await resolver(track);
      if (lyrics == null || lyrics.lyric.trim().isEmpty) return null;
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
      // 歌词是增强项：失败清理半成品并继续（对应路径记 null）。
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

  /// 封面大小上限：超过按无封面处理（避免异常大图占用磁盘）。
  static const int _maxCoverBytes = 8 * 1024 * 1024;

  Future<String?> _tryWriteCover(String root, String base, Track track) async {
    final resolver = _artworkResolver;
    if (resolver == null) return null;
    String? path;
    try {
      final url = await resolver(track);
      if (url == null || url.isEmpty) return null;
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
      path = p.join(root, downloadsCoversDirName, '$base.${_imageExtension(url)}');
      await _storage.writeBytes(path, chunks);
      return path;
    } catch (e) {
      // 封面是增强项：失败清理半成品并继续（对应路径记 null）。
      _logger.warning('下载封面失败: $e');
      if (path != null) await _storage.deleteQuietly(path);
      return null;
    }
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
}
