/// 单曲下载服务：取链 → 下载音频（或缓存命中直接拷贝）→ 离线包
/// （歌词/封面，可单独下载）→ 音频标签嵌入 → 落库 → 公共目录发布。
///
/// 设计要点：
/// - 目录隔离：写 `downloads/`（应用支持目录），与 `cache/audio_cache`
///   完全隔离——清缓存永不触碰下载，删下载是独立动作；
/// - **缓存优先**：所选音质的完整音频缓存（同名且无 `.part`）命中时直接
///   拷贝不触网；歌词经注入的解析器（组合根接 `LyricsService`：缓存 →
///   原生取词 → 跨平台回退）；封面经 [ArtworkCache] 命中直读、未命中取图
///   后回填缓存；
/// - **公共目录发布**（Android）：音频就绪后 best-effort 拷进 MediaStore
///   Downloads（[DownloadsPublisher]），content URI 落库供删除时回收；
///   **公共副本不参与播放取链**——播放只认应用目录里的 `filePath`；
/// - **分项记录**：`downloads.filePath` 可空——记录可以只含歌词或只含封面
///   （`downloadLyrics` / `downloadCover`），音频下载可一次带全；
/// - **标签嵌入**：音频就绪后把标题/歌手/专辑/歌词/封面写进文件标签
///   （`audio_tag_writer.dart`，best-effort，失败保留 sidecar）；
/// - 半成品用 `.part` 后缀，完成时原子改名，落库在改名之后：
///   播放取链只认数据库记录，永远不会读到半成品；
/// - 进度 / 取消 / 失败：进度经 [notifyListeners] 节流广播；取消走 dio
///   `CancelToken`，半成品清理后抛 `cancelled` 失败（UI 静默）；
/// - 歌词/封面是 best-effort：失败不阻断音频下载，对应路径记为 null；
/// - 同一原曲只保留一条记录（下载前查重，重名文件自动 `(2)`、`(3)` 递增）；
/// - **系统通知**（Android）：音频下载任务经 [DownloadNotifications] 起一条
///   前台服务（dataSync）进度通知，后台也能继续下载；批量下载整批共享一条
///   「N/N」通知（批内单任务通知被抑制）。通知是纯附加面：通道缺失 / 权限未授予 /
///   原生失败一律 no-op 只记日志，下载本身与既有语义完全不变；歌词/封面这类
///   秒级分项动作不发通知（无进度可言，闪一下反而吵）。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../../data/catalog/catalog_service.dart';
import '../../data/downloads/audio_tag_reader.dart';
import '../../data/downloads/audio_tag_writer.dart';
import '../../data/downloads/download_notifications.dart';
import '../../data/downloads/download_storage.dart';
import '../../data/downloads/downloads_publisher.dart';
import '../../data/downloads/downloads_repository.dart';
import '../../data/downloads/local_lyrics.dart';
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

/// 完整音频缓存命中（「缓存 = 已下载」识别与离线取链共用）。
class AudioCacheHit {
  const AudioCacheHit({
    required this.quality,
    required this.path,
    required this.sizeBytes,
  });

  /// 命中缓存的音质（LX 标识；未知为 `auto`）。
  final String quality;

  /// 缓存文件绝对路径（完整、无 `.part`）。
  final String path;

  final int sizeBytes;

  @override
  bool operator ==(Object other) =>
      other is AudioCacheHit &&
      other.quality == quality &&
      other.path == path &&
      other.sizeBytes == sizeBytes;

  @override
  int get hashCode => Object.hash(quality, path, sizeBytes);

  @override
  String toString() => 'AudioCacheHit($quality, $path, $sizeBytes)';
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
    DownloadsPublisher? publisher,
    DownloadNotifications? notifications,
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
        _publisher = publisher ?? const NoopDownloadsPublisher(),
        _notifications = notifications ?? createDownloadNotifications(),
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

  /// 公共 Downloads 发布器（组合根注入 `createDownloadsPublisher()`；
  /// 未注入 / 非 Android 时为空实现，发布整体 no-op）。
  final DownloadsPublisher _publisher;

  /// 系统下载通知端口（组合根注入 `createDownloadNotifications()`；
  /// 未注入 / 非 Android 时为空实现，通知整体 no-op）。
  final DownloadNotifications _notifications;

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

  /// 下载目录是否可用（无文件系统 / 目录解析失败时为 false，UI 隐藏下载
  /// 入口）。
  bool get supported => _supported;

  /// 是否支持发布公共 Downloads 副本（仅 Android；UI 据此显隐发布设置 /
  /// 补发布入口）。
  bool get publisherSupported => _publisher.supported;

  /// 是否支持系统下载通知（仅 Android；UI 据此显隐「下载通知」开关）。
  bool get notificationsSupported => _notifications.supported;

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
      // 本地导入是就地引用：文件在用户目录，不属于下载根迁移范围。
      if (record.imported) continue;
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
          publicUri: record.publicUri,
          imported: record.imported,
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
  ///
  /// 通知（Android）：整批共享一条「N/N」通知（曲目位置按入参序号），批内单任务
  /// 通知被抑制——顺序下载时逐条通知会闪成一串，一条批量通知更接近用户直觉。
  Future<(int, int)> downloadBatch(Iterable<Track> tracks) async {
    // 物化入参只为「批量位置」计数（顺序与跳过判定完全不变）。
    final items = tracks.toList();
    var done = 0;
    var failed = 0;
    // 已有批量在进行（并发调用）时不抢占通知：服务端只有一个批量 id。
    final batch = _notificationsOn && items.isNotEmpty && _batch == null
        ? _BatchNotificationContext(total: items.length)
        : null;
    if (batch != null) _batch = batch;
    try {
      for (var index = 0; index < items.length; index++) {
        final track = items[index];
        if (recordForTrack(track)?.hasAudio ?? false) continue;
        if (track.id.sourceKey == kLocalSourceKey) continue;
        if (batch != null) {
          batch.index = index + 1;
          batch.activeKey = '${track.id.sourceKey}:${track.id.id}';
          _notifyBatchItem(batch, track);
        }
        try {
          await download(track);
          done++;
        } on SourceFailure catch (failure) {
          if (failure.kind != FailureKind.cancelled) failed++;
        } catch (_) {
          failed++;
        }
      }
    } finally {
      if (batch != null) {
        _stopBatchNotification();
        _batch = null;
      }
    }
    return (done, failed);
  }

  /// 指定音质是否命中完整音频缓存（下载弹层的「本地缓存」标记）。
  Future<bool> audioCacheHit(Track track, String quality) async =>
      await _completeAudioCachePath(track, quality) != null;

  /// 完整音频缓存命中（「缓存 = 已下载」识别）：按 [qualities]（缺省 =
  /// 偏好音质 × 曲目可用音质）顺序探测，返回首个完整缓存（无 `.part`）。
  ///
  /// 与 [recordForTrack] 的区别：这里只认文件系统里的缓存副本，不产生下载
  /// 记录；缓存可被 LRU / 清理移除，调用方必须允许状态回退。
  Future<AudioCacheHit?> audioCacheFor(
    Track track, {
    Iterable<String>? qualities,
  }) async {
    if (track.id.sourceKey == kLocalSourceKey) return null;
    for (final quality in qualities ?? _audioCacheQualityCandidates(track)) {
      final path = await _completeAudioCachePath(track, quality);
      if (path == null) continue;
      final size = await _storage.fileSize(path);
      if (size <= 0) continue;
      return AudioCacheHit(quality: quality, path: path, sizeBytes: size);
    }
    return null;
  }

  /// 缓存探测的音质顺序：偏好音质在前，再按曲目可用音质去重保序。
  List<String> _audioCacheQualityCandidates(Track track) {
    final result = <String>[];
    final preferred = _pickQuality(track);
    if (preferred.isNotEmpty) result.add(preferred);
    for (final quality in track.qualities) {
      final type = quality.type;
      if (type.isNotEmpty && !result.contains(type)) result.add(type);
    }
    return result;
  }

  /// 缺省下载音质：偏好音质 × 曲目可用音质（下载弹层的预选项）。
  String defaultQualityFor(Track track) => _pickQuality(track);

  /// 加载已有下载记录并探测存储可用性（启动时调用一次）。
  Future<void> init() async {
    try {
      _supported = await _storage.downloadsRoot() != null;
      // 存储不可用时不触碰数据库：本机下载整体关闭。
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
    _startTaskNotification(key, track);

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
          quality: resolvedQuality.isEmpty
              ? null
              : AudioQuality(type: resolvedQuality),
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
          artist: track.artistLabel,
          album: track.album ?? '',
          lyrics: lyrics?.lyric,
          coverBytes: cover?.bytes,
          coverMimeType: cover?.mimeType ?? 'image/jpeg',
        );
      }

      final previous = _records[key];
      // 5) 公共目录发布（best-effort）：Android 拷进 MediaStore Downloads，
      //    用户在文件管理器 / 其它播放器里可见；失败只记日志，不影响下载。
      final publicUri = await _publishPublicCopy(
        filePath,
        p.basename(filePath),
      );
      final record = DownloadedTrack(
        originSourceKey: track.id.sourceKey,
        originSongId: track.id.id,
        title: track.title,
        artist: track.artistLabel,
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
        publicUri: publicUri ?? previous?.publicUri,
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
      _stopTaskNotification(key);
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

  /// 删除下载：先删数据库记录（避免残留半删记录），再删音频 / 歌词 / 封面文件
  /// 与公共 Downloads 副本（发布副本随下载一起回收；失败只记日志）。
  ///
  /// 本地导入（`imported`）是就地引用：只移除记录，**不动用户原文件**。
  Future<void> delete(DownloadedTrack record) async {
    await _repository.delete(record.originSourceKey, record.originSongId);
    _records.remove(record.key);
    if (!record.imported) {
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
      final publicUri = record.publicUri;
      if (publicUri != null && publicUri.isNotEmpty) {
        await _removePublicCopy(publicUri);
      }
    }
    notifyListeners();
  }

  /// 导入本地音频文件（就地引用：不复制、不移动，删除记录不动原文件）。
  ///
  /// 记录的原音源键 = `local:<绝对路径>`（同路径重复导入幂等：刷新元数据并
  /// 按导入时间置顶）；标题/歌手/专辑读文件标签（mp3 / flac，见
  /// `audio_tag_reader.dart`），其余格式按 `歌手 - 歌名` 文件名兜底。
  ///
  /// 返回 `(导入数, 跳过数)`：路径为空 / 文件不存在 / 非音频后缀 /
  /// 存储不可用计入跳过。
  Future<(int, int)> importLocalFiles(Iterable<String> paths) async {
    var imported = 0;
    var skipped = 0;
    if (!_supported) return (0, paths.length);
    for (final rawPath in paths) {
      final path = p.normalize(rawPath.trim());
      // 后缀不带点（`audioExtensions` 约定）；标签解析要带点的原始后缀。
      final extension = p.extension(path).toLowerCase();
      final extensionName = extension.replaceFirst('.', '');
      if (path.isEmpty || !audioExtensions.contains(extensionName)) {
        skipped++;
        continue;
      }
      final size = await _storage.fileSize(path);
      if (size <= 0) {
        skipped++;
        continue;
      }
      final head =
          await _storage.readHead(path, kAudioTagReadLimit) ?? Uint8List(0);
      final tags = readAudioTags(head, extension: extension, fileSize: size);
      final fallback = splitFileNameMetadata(p.basenameWithoutExtension(path));
      final record = DownloadedTrack(
        originSourceKey: kLocalSourceKey,
        originSongId: path,
        title: tags.title ?? fallback.title,
        artist: tags.artist ?? fallback.artist,
        album: tags.album ?? '',
        durationMs: tags.durationMs,
        quality: '',
        filePath: path,
        sizeBytes: size,
        imported: true,
        downloadedAt: _clock(),
      );
      await _repository.insert(record);
      _records[record.key] = record;
      imported++;
    }
    if (imported > 0) notifyListeners();
    return (imported, skipped);
  }

  /// 补发布：把已有音频但还没有公共副本的记录发布到公共 Downloads。
  ///
  /// 用于旧版本留下的下载（v4 之前）或发布失败的记录；返回
  /// `(发布数, 失败数)`。平台不支持（非 Android）时返回 `(0, 0)`。
  Future<(int, int)> publishMissingPublicCopies() async {
    if (!_publisher.supported) return (0, 0);
    var published = 0;
    var failed = 0;
    for (final record in List<DownloadedTrack>.of(_records.values)) {
      // 本地导入是就地引用：不发布到公共 Downloads（文件本来就在用户目录）。
      if (record.imported) continue;
      final audio = record.filePath;
      if (audio == null || audio.isEmpty) continue;
      if (record.hasPublicCopy) continue;
      if (!await _storage.fileExists(audio)) {
        _logger.warning('补发布跳过（文件缺失）: $audio');
        failed++;
        continue;
      }
      final uri = await _publishPublicCopy(audio, p.basename(audio));
      if (uri == null) {
        failed++;
        continue;
      }
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
        filePath: record.filePath,
        sizeBytes: record.sizeBytes,
        lyricPath: record.lyricPath,
        coverPath: record.coverPath,
        publicUri: uri,
        imported: record.imported,
        downloadedAt: record.downloadedAt,
      );
      await _repository.insert(updated);
      _records[record.key] = updated;
      published++;
    }
    if (published > 0) notifyListeners();
    return (published, failed);
  }

  /// 播放取链优先命中本地副本：下载记录 → 完整缓存（缓存 = 已下载）。
  ///
  /// 本地曲目（`sourceKey = local`）返回 null——由 `local` 音源自身解析；
  /// 只有歌词 / 封面的分项记录（无音频）返回 null。[quality] 为本次播放
  /// 实际选择的音质（精确命中优先，未命中回退其它已缓存音质），缓存命中时
  /// 直接返回 `file://`，离线可播、不再取链。
  Future<Uri?> localUriFor(Track track, {String? quality}) async {
    if (track.id.sourceKey == kLocalSourceKey) return null;
    final record = _records['${track.id.sourceKey}:${track.id.id}'];
    final path = record?.filePath;
    if (path != null && path.isNotEmpty && await _storage.fileExists(path)) {
      return Uri.file(path);
    }
    final cached = await audioCacheFor(
      track,
      qualities: <String>[
        if (quality != null && quality.isNotEmpty) quality,
        ..._audioCacheQualityCandidates(track),
      ],
    );
    return cached == null ? null : Uri.file(cached.path);
  }

  /// 本地曲目的离线歌词（读 `downloads/lyrics/`，不触网）；无歌词返回 null。
  ///
  /// 实现见 [readDownloadedLyrics]：同一份读取逻辑也供组合根的歌词服务使用
  /// （歌词服务先于下载服务构建，避免两者互为依赖）。
  Future<LyricsResult?> localLyricsFor(Track track) =>
      readDownloadedLyrics(_storage, track);

  // 内部：守卫与记录

  /// 发布公共 Downloads 副本（best-effort）。
  ///
  /// 平台不支持（非 Android）/ 设置关闭 / 失败一律返回 null，调用方继续
  /// 落库（公共副本只是发布副本，不参与播放取链）。
  Future<String?> _publishPublicCopy(
      String filePath, String displayName) async {
    if (!_publisher.supported) return null;
    if (!(_settings?.publishToPublicDir ?? true)) return null;
    try {
      final uri = await _publisher.publish(
        sourcePath: filePath,
        displayName: displayName,
        mimeType: audioMimeTypeForPath(filePath),
      );
      if (uri == null) {
        _logger.warning('公共目录发布失败: $displayName');
      } else {
        _logger.info('公共目录发布完成: $uri');
      }
      return uri;
    } catch (e) {
      _logger.warning('公共目录发布失败: $e');
      return null;
    }
  }

  /// 回收公共 Downloads 副本（best-effort：失败只记日志）。
  Future<void> _removePublicCopy(String uri) async {
    if (!_publisher.supported) return;
    try {
      if (!await _publisher.remove(uri)) {
        _logger.warning('公共副本删除失败: $uri');
      }
    } catch (e) {
      _logger.warning('公共副本删除失败: $e');
    }
  }

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
      artist: track.artistLabel,
      album: track.album ?? '',
      coverUrl: track.artwork?.uri.toString(),
      durationMs: track.duration?.inMilliseconds,
      raw: Map<String, dynamic>.from(track.payload),
      quality: existing?.quality ?? '',
      filePath: existing?.filePath,
      sizeBytes: existing?.sizeBytes ?? 0,
      lyricPath: lyricPath ?? existing?.lyricPath,
      coverPath: coverPath ?? existing?.coverPath,
      publicUri: existing?.publicUri,
      imported: existing?.imported ?? false,
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
  ///
  /// 命名与完整判据的唯一实现在 `AudioCacheStore`（见
  /// `CacheService.audioStore`）；存在性探测走 [DownloadStorage]——与随后
  /// 拷贝缓存文件的是同一个文件系统视图。
  Future<String?> _completeAudioCachePath(Track track, String quality) async {
    final cache = _cacheService;
    if (cache == null) return null;
    return cache.audioStore.hitPathForTrack(
      track,
      quality: quality,
      fileExists: _storage.fileExists,
    );
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
      final response = await _dio
          .get<ResponseBody>(
            url,
            options: Options(
              responseType: ResponseType.stream,
              // 与封面显示同一套请求头（浏览器 UA + 平台 Referer）。
              headers: ArtworkCache.headersFor(url),
            ),
          )
          .timeout(const Duration(seconds: 30));
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 300) return null;
      final builder = BytesBuilder(copy: false);
      var total = 0;
      await for (final chunk in streamBody(response).stream) {
        total += chunk.length;
        if (total > _maxCoverBytes) return null;
        builder.add(chunk);
      }
      if (total == 0) return null;
      final bytes = builder.takeBytes();
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
    _updateNotificationProgress(key, received, total);
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

  // 内部：系统下载通知（Android 前台服务）

  /// 批量通知 id：整批共享一条「N/N」通知。
  static const String _batchNotificationId = 'batch';

  /// 通知进度节流间隔：系统对通知更新有频率限制（前台服务通知尤其），进度按
  /// 「首个分片 / 距上次 ≥500ms / 已到最后一个分片」推送；UI 进度不受影响。
  static const int _notificationIntervalMs = 500;

  /// 通知最近推送时间（键 = 通知 id），只服务节流。
  final Map<String, int> _notificationSentAt = {};

  /// 已起过通知的 id：收尾只收自己起过的，中途关掉开关也不会残留。
  final Set<String> _startedNotifications = {};

  /// 批量通知上下文（null = 无批量在跑）。
  _BatchNotificationContext? _batch;

  bool get _notificationsOn =>
      _notifications.supported && (_settings?.notifications ?? true);

  /// 单任务通知 id：一条下载一条通知，收尾时按同一 id 移除。
  static String _taskNotificationId(String key) => 'track:$key';

  /// 起单任务通知（批量中的当前曲目由批量通知统一表达，避免 N 条通知连闪）。
  void _startTaskNotification(String key, Track track) {
    if (!_notificationsOn) return;
    if (_batch?.activeKey == key) return;
    final id = _taskNotificationId(key);
    _notificationSentAt.remove(id);
    _startedNotifications.add(id);
    unawaited(_notifications.start(
      id: id,
      title: track.title,
      subtitle: track.artistLabel,
    ));
  }

  /// 收单任务通知（完成 / 失败 / 取消同一条路径：收尾并移除）。
  ///
  /// 不受「通知开关」影响：只收自己起过的，中途关掉开关也不残留。
  void _stopTaskNotification(String key) {
    if (_batch?.activeKey == key) return;
    final id = _taskNotificationId(key);
    _notificationSentAt.remove(id);
    if (!_startedNotifications.remove(id)) return;
    unawaited(_notifications.stop(id));
  }

  /// 批量通知进入下一首：[start] 建立通知，其余用 update 顺延序号与进度条。
  void _notifyBatchItem(_BatchNotificationContext batch, Track track) {
    final id = _batchNotificationId;
    _notificationSentAt.remove(id);
    _startedNotifications.add(id);
    if (batch.started) {
      unawaited(_notifications.update(
        id: id,
        title: track.title,
        subtitle: track.artistLabel,
        index: batch.index,
        total: batch.total,
        // max 传 0：新任务总大小未知，进度条回到不确定态。
        progress: 0,
        max: 0,
      ));
    } else {
      unawaited(_notifications.start(
        id: id,
        title: track.title,
        subtitle: track.artistLabel,
        index: batch.index,
        total: batch.total,
      ));
      batch.started = true;
    }
  }

  /// 批量结束：移除批量通知（批内单任务通知本来就没起过）。
  ///
  /// 同 [_stopTaskNotification]：收尾不受「通知开关」影响。
  void _stopBatchNotification() {
    _notificationSentAt.remove(_batchNotificationId);
    if (!_startedNotifications.remove(_batchNotificationId)) return;
    unawaited(_notifications.stop(_batchNotificationId));
  }

  /// 进度 → 通知（单任务或批量：按「当前曲目是否属于批量」路由）。
  void _updateNotificationProgress(String key, int received, int? total) {
    if (!_notificationsOn) return;
    final batch = _batch;
    final inBatch = batch?.activeKey == key;
    final id = inBatch ? _batchNotificationId : _taskNotificationId(key);
    final now = _clock();
    final last = _notificationSentAt[id];
    final complete = total != null && total > 0 && received >= total;
    if (last != null && !complete && now - last < _notificationIntervalMs) {
      return;
    }
    _notificationSentAt[id] = now;
    unawaited(_notifications.update(
      id: id,
      progress: received,
      max: total,
    ));
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
      if (index > 999) {
        return '$desired (${DateTime.now().millisecondsSinceEpoch})';
      }
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
      'artist': track.artistLabel,
      'title': track.title,
      'album': track.album ?? '',
    });
    return sanitizeFileName(raw);
  }

  /// `{歌手} - {歌名}`；无歌手只用歌名；非法字符替换、空白折叠、限长。
  @visibleForTesting
  static String baseNameFor(Track track) {
    final artist = track.artistLabel;
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

  /// 可下载 / 可导入的音频后缀（小写、不含点）。
  ///
  /// 唯一来源：直链扩展名推断（[extensionFor]）与本地导入校验共用。
  static const Set<String> audioExtensions = {
    'mp3',
    'flac',
    'm4a',
    'aac',
    'ogg',
    'oga',
    'opus',
    'wav',
    'ape',
    'wma',
    'mka',
    'mp4',
  };

  /// 扩展名：URL 路径里的音频后缀优先，否则按音质推断（默认 mp3）。
  @visibleForTesting
  static String extensionFor(Uri url, String quality) {
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

  /// 公共目录发布用的音频 MIME 类型（MediaStore 按它归类；未知回退
  /// `application/octet-stream`）。
  @visibleForTesting
  static String audioMimeTypeForPath(String path) {
    final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
    return switch (ext) {
      'mp3' => 'audio/mpeg',
      'flac' => 'audio/flac',
      'm4a' || 'mp4' => 'audio/mp4',
      'aac' => 'audio/aac',
      'ogg' || 'oga' => 'audio/ogg',
      'opus' => 'audio/opus',
      'wav' => 'audio/wav',
      'ape' => 'audio/x-ape',
      'wma' => 'audio/x-ms-wma',
      'mka' => 'audio/x-matroska',
      _ => 'application/octet-stream',
    };
  }
}

/// 批量下载的通知上下文（整批共享一条「N/N」通知）。
class _BatchNotificationContext {
  _BatchNotificationContext({required this.total});

  /// 入参曲目总数（跳过项也占位：序号 = 曲目在入参里的位置）。
  final int total;

  /// 当前曲目序号（从 1 起）。
  int index = 0;

  /// 当前曲目的原音源键（批内单任务通知按它抑制）。
  String? activeKey;

  /// 批量通知是否已建立（首条用 start，其余用 update 避免重复建通知）。
  bool started = false;
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
