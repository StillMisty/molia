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
/// - 进度 / 取消 / 失败：全局严格串行单 worker（`download_queue.dart`），
///   每任务进度只经 [DownloadTask] 自己节流广播（100ms 合并；首个分片 /
///   100% / 终态立即送达），队列只在任务增删 / 状态变化时通知；排队任务
///   由队列移除，运行中取消走 dio `CancelToken`，半成品清理后抛
///   `cancelled` 失败（UI 静默）；
/// - 歌词/封面是 best-effort：失败不阻断音频下载，对应路径记为 null；
/// - 同一原曲只保留一条记录（下载前查重，重名文件自动 `(2)`、`(3)` 递增）；
/// - **系统通知**（Android）：音频下载任务起一条前台服务（dataSync）进度通知，
///   后台也能继续下载；批量下载整批共享一条「N/N」通知（批内单任务通知被
///   抑制）。通知是纯附加面：通道缺失 / 权限未授予 / 原生失败一律 no-op 只记
///   日志，下载本身与既有语义完全不变；歌词/封面这类秒级分项动作不发通知
///   （无进度可言，闪一下反而吵）。
///
/// 本文件只做编排（下载一首 / 一批）；四个 module 各有一份唯一实现：
/// - 任务队列：`download_queue.dart`（严格串行 FIFO / 去重 / 取消 / 重试 /
///   进度通道）；
/// - 命名 / 放置：`download_file_layout.dart`（模板 + sanitize + ` (2)` 去重 +
///   sidecar 路径约定）；
/// - 记录装配：`download_record_assembler.dart`（部分状态 → `DownloadedTrack`）；
/// - 通知 presenter：`download_notification_presenter.dart`（id 分配 / 批量
///   共享一条 / 系统频率节流 / 收尾不残留；端口由组合根注入）。
library;

import 'dart:async';

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
import '../covers/cover_bytes_downloader.dart';
import '../covers/cover_resolution.dart';
import '../../sources/source_track.dart' show pickQualityFor;
import 'download_file_layout.dart';
import 'download_notification_presenter.dart';
import 'download_queue.dart';
import 'download_record_assembler.dart';
import 'download_settings.dart';

export 'download_queue.dart';

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
    required this._catalog,
    required this._repository,
    required DownloadStorage storage,
    Dio? dio,
    this._lyricsResolver,
    this._artworkResolver,
    this._coverResolver,
    this._cacheService,
    this._artworkCache,
    DownloadSettings? settings,
    DownloadsPublisher? publisher,
    DownloadNotifications? notifications,
    this._preferredQuality,
    int Function()? clock,
  }) : _storage = storage,
       _dio = dio ?? createAppDio(),
       _settings = settings,
       _publisher = publisher ?? const NoopDownloadsPublisher(),
       _clock = clock,
       _layout = DownloadFileLayout(storage: storage, settings: settings),
       _assembler = DownloadRecordAssembler(clock: clock),
       _notifications = DownloadNotificationPresenter(
         notifications: notifications ?? createDownloadNotifications(),
         settings: settings,
         clock: clock,
       );

  final CatalogService _catalog;
  final DownloadsRepository _repository;
  final DownloadStorage _storage;
  final Dio _dio;
  final DownloadLyricsResolver? _lyricsResolver;
  final DownloadArtworkResolver? _artworkResolver;
  final CoverResolver? _coverResolver;
  final CacheService? _cacheService;
  final ArtworkCache? _artworkCache;
  final DownloadSettings? _settings;

  /// 公共 Downloads 发布器（组合根注入 `createDownloadsPublisher()`；
  /// 未注入 / 非 Android 时为空实现，发布整体 no-op）。
  final DownloadsPublisher _publisher;

  final String Function()? _preferredQuality;

  /// UI 进度节流用的毫秒时间源（测试注入；缺省墙钟）。
  ///
  /// 只服务 [DownloadTask.reportProgress] 的合并窗口，不参与下载时间 /
  /// 记录时间。
  final int Function()? _clock;

  /// 文件名 / 放置模块：命名、去重与 sidecar 路径约定的唯一实现（见
  /// `download_file_layout.dart`）。
  final DownloadFileLayout _layout;

  /// 记录装配模块：部分状态 → `DownloadedTrack` 的唯一装配点（见
  /// `download_record_assembler.dart`）。
  final DownloadRecordAssembler _assembler;

  /// 通知 presenter 模块：id 分配、批量共享、系统频率节流与收尾不残留的
  /// 唯一实现（见 `download_notification_presenter.dart`；端口由组合根注入
  /// `createDownloadNotifications()`，未注入 / 非 Android 时整体 no-op）。
  final DownloadNotificationPresenter _notifications;

  final Logger _logger = Logger('molia.download_service');

  /// 已下载记录（键 = 原音源曲目键 `sourceKey:songId`）。
  Map<String, DownloadedTrack> _records = {};

  /// 运行中任务的 dio 取消令牌（只给网络下载用；排队取消由队列处理）。
  final Map<String, CancelToken> _tokens = {};

  /// 运行中任务已产生 / 即将产生的输出路径（音频 / `.part` / 歌词 / 翻译 /
  /// 封面）。落库前这些文件还不算「记录引用」，孤儿扫描必须避开它们。
  final Set<String> _activeOutputPaths = <String>{};

  /// 记录排序列表缓存：记录变更时失效，避免每次读取都复制 + 排序。
  List<DownloadedTrack>? _downloadsCache;

  /// 任务队列（严格串行单 worker；完成 / 取消即移除，失败保留供重试）。
  ///
  /// 延迟初始化：runner 是实例方法，构造器初始化列表里拿不到 `this`。
  late final DownloadQueue _queue = DownloadQueue(_runTask);

  bool _supported = false;
  bool _initialized = false;

  /// 记录加载只做一次（幂等）；首帧后的启动尾巴与按需调用共用同一 Future。
  Future<void>? _initFuture;

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

  /// 全部下载（下载时间倒序；缓存不可变列表，记录变更时失效）。
  List<DownloadedTrack> get downloads {
    final cached = _downloadsCache;
    if (cached != null) return cached;
    final list = List<DownloadedTrack>.of(_records.values)
      ..sort((a, b) {
        final byTime = b.downloadedAt.compareTo(a.downloadedAt);
        return byTime != 0 ? byTime : b.key.compareTo(a.key);
      });
    return _downloadsCache = List<DownloadedTrack>.unmodifiable(list);
  }

  /// 记录变化后失效排序缓存（写 `_records` 的所有路径都必须调用）。
  void _invalidateDownloadsCache() => _downloadsCache = null;

  /// 按原音源曲目键查询下载记录。
  DownloadedTrack? recordFor(String sourceKey, String songId) =>
      _records['$sourceKey:$songId'];

  /// 当前播放曲目的下载记录：本地曲目按自身 id 反查，在线曲目按原音源键。
  DownloadedTrack? recordForTrack(Track track) {
    if (track.id.sourceKey == kLocalSourceKey) return _records[track.id.id];
    return _records['${track.id.sourceKey}:${track.id.id}'];
  }

  /// 当前曲目的下载进度；未在下载（或已失败 / 完成）返回 null。
  ///
  /// 保留给既有调用方 / 测试：进度通道已拆到 [DownloadTask]，新 UI 直接
  /// 监听任务本身（见 [taskForTrack]）。
  DownloadProgress? progressForTrack(Track track) =>
      taskForTrack(track)?.progress;

  /// 任务结构变化（增删 / 状态切换）：页面任务区只监听这里。
  Listenable get taskChanges => _queue;

  /// 下载管理页可见的音频任务（运行 / 排队 / 失败；不展示已完成）。
  List<DownloadTask> get tasks => [
    for (final task in _queue.tasks)
      if (task.kind == DownloadTaskKind.audio) task,
  ];

  /// 当前曲目的音频任务（排队 / 运行 / 失败）；本地曲目与分项任务返回 null。
  DownloadTask? taskForTrack(Track track) {
    if (track.id.sourceKey == kLocalSourceKey) return null;
    final task = _queue.taskFor(track.id.uri);
    return task?.kind == DownloadTaskKind.audio ? task : null;
  }

  /// 重试失败任务：新建一个不带批量位置的任务入队。
  ///
  /// 批量位置是「这一批」的上下文，重试发生在批次结束之后；沿用旧任务会让
  /// 通知 presenter 走已结束的批量分支（no-op），或污染另一条正在跑的批次。
  Future<void> retryTask(DownloadTask task) {
    if (task.isActive) return task.done;
    return _queue.enqueue(
      DownloadTask(
        track: task.track,
        kind: task.kind,
        quality: task.quality,
        includeLyrics: task.includeLyrics,
        includeCover: task.includeCover,
      ),
    );
  }

  /// 从失败区移除任务（不重试）。
  void dismissTask(DownloadTask task) => _queue.dismiss(task.key);

  /// 当前解析出的下载根目录（设置页展示；不可用返回 null）。
  Future<String?> rootPath() => _storage.downloadsRoot();

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
  ///
  /// 只收应用可识别的文件（音频扩展名 / `.lrc` 与 `.t.lrc` / 封面图片）：
  /// 下载根目录在桌面默认就是用户的公共下载目录下 `Molia/`，用户可能自己
  /// 往里放 `notes.txt` 等文件；「清理残留」只清应用写过的格式，任意文件
  /// 不参与判定与删除。运行中任务的输出（落库前）也不参与。
  Future<List<String>> orphanFiles() async {
    await _ensureReady();
    final root = await _storage.downloadsRoot();
    if (root == null) return const [];
    final protected = _protectedPaths();
    try {
      final files = await _storage.listFiles(root);
      return [
        for (final path in files)
          if (!path.endsWith(downloadPartSuffix) &&
              !protected.contains(path) &&
              _isRecognizedDownloadFile(path))
            path,
      ];
    } catch (e) {
      _logger.warning('孤儿文件扫描失败: $e');
      return const [];
    }
  }

  /// 当前不能被当作孤儿删除的路径：记录引用 + 运行中任务的输出。
  Set<String> _protectedPaths() => {
    for (final record in _records.values)
      ...DownloadFileLayout.referencedFiles(record),
    ..._activeOutputPaths,
  };

  /// 应用会写入下载根目录的文件格式（孤儿候选的安全白名单）。
  static bool _isRecognizedDownloadFile(String path) {
    final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
    return DownloadFileLayout.audioExtensions.contains(ext) ||
        ext == 'lrc' ||
        _coverImageExtensions.contains(ext);
  }

  static const Set<String> _coverImageExtensions = {
    'jpg',
    'jpeg',
    'png',
    'webp',
    'gif',
    'bmp',
  };

  /// 删除孤儿文件，返回实际删除数量。
  ///
  /// [paths] 非空时删除弹层里看到的那批路径（不再重新扫描）；删除前按当前
  /// 记录引用与运行中任务输出再校验一次，避免把扫描后刚被引用的文件删掉。
  Future<int> deleteOrphanFiles({Iterable<String>? paths}) async {
    await _ensureReady();
    final root = await _storage.downloadsRoot();
    if (root == null) return 0;
    final candidates = paths == null
        ? await orphanFiles()
        : <String>{...paths}.toList();
    final protected = _protectedPaths();
    final normalizedRoot = p.normalize(root);
    var deleted = 0;
    for (final path in candidates) {
      final normalized = p.normalize(path);
      if (!p.isWithin(normalizedRoot, normalized) ||
          !_isRecognizedDownloadFile(normalized) ||
          protected.contains(normalized)) {
        continue;
      }
      await _storage.deleteQuietly(normalized);
      deleted++;
    }
    return deleted;
  }

  /// 批量下载：先一次性把全部任务放进队列，再在后台逐个等待结果。
  ///
  /// 页面调用后立即拿到「已加入队列」的反馈，不再被整批 await 锁住；队列
  /// 本身严格串行（一次只跑一个）。不做断点续传（平台直链多为一次性签名
  /// 地址）；单项失败不影响后续，返回 `(下载数, 失败数)`，失败音频任务
  /// 留在管理页失败区可重试。
  ///
  /// 通知（Android）：整批共享一条「N/N」通知（曲目位置按入参序号），批内单任务
  /// 通知被抑制——顺序下载时逐条通知会闪成一串，一条批量通知更接近用户直觉。
  Future<(int, int)> downloadBatch(Iterable<Track> tracks) async {
    // 物化入参只为「批量位置」计数（顺序与跳过判定完全不变）。
    final items = tracks.toList();
    await _ensureReady();
    // 已有批量在进行（并发调用）时不抢占通知：服务端只有一个批量 id。
    final batch = _notifications.beginBatch(items.length);
    // 入队后立刻给每个 future 挂错误处理：排队任务可能在轮到自己之前被
    // 取消，若等到按序 await 才监听，completeError 会变成未处理异步错误。
    // 结果：true = 成功，false = 失败，null = 已取消（不计入失败）。
    final outcomes = <Future<bool?>>[];
    final seen = <String>{};
    try {
      for (var index = 0; index < items.length; index++) {
        final track = items[index];
        if (recordForTrack(track)?.hasAudio ?? false) continue;
        if (track.id.sourceKey == kLocalSourceKey) continue;
        // 入参重复：队列本来会同 key 去重，这里跳过避免重复计数。
        if (!seen.add(track.id.uri)) continue;
        final task = DownloadTask(
          track: track,
          kind: DownloadTaskKind.audio,
          quality: _pickQuality(track),
          batchIndex: batch ? index + 1 : null,
          batchTotal: batch ? items.length : null,
        );
        // enqueue 同步入队：所有任务在第一个 await 前全部可见。
        outcomes.add(
          _queue.enqueue(task).then<bool?>(
            (_) => true,
            onError: (Object error) =>
                error is SourceFailure &&
                    error.kind == FailureKind.cancelled
                ? null
                : false,
          ),
        );
      }

      var done = 0;
      var failed = 0;
      for (final outcome in outcomes) {
        switch (await outcome) {
          case true:
            done++;
          case false:
            failed++;
          case null:
            break;
        }
      }
      return (done, failed);
    } finally {
      if (batch) _notifications.endBatch();
    }
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

  /// 记录加载完成的信号：首帧后的启动尾巴调用 [init]，播放取链与下载入口
  /// 在记录就绪前先等这里，避免把已下载曲目误判成在线曲目。
  Future<void> get ready => _initFuture ??= _init();

  /// 加载已有下载记录并探测存储可用性（幂等；首帧后调用一次）。
  ///
  /// 不放在 `runApp` 前：存储根解析、全量记录读取与 `.part` 清扫都是磁盘/DB
  /// 工作，不参与首帧内容。调用方在首帧后触发，UI 用 [initialized] 展示
  /// 加载态；[localUriFor] 等依赖记录的方法会自行等待 [ready]。
  Future<void> init() => ready;

  Future<void> _init() async {
    try {
      _supported = await _storage.downloadsRoot() != null;
      // 存储不可用时不触碰数据库：本机下载整体关闭。
      if (_supported) {
        final records = await _repository.listAll();
        _records = {for (final record in records) record.key: record};
        _invalidateDownloadsCache();
        // 崩溃遗留的半成品（.part）清扫：失败仅记日志，不影响记录可用。
        final cleaned = await cleanupIncompleteDownloads();
        if (cleaned > 0) _logger.info('清理未完成的下载文件 $cleaned 个');
      }
    } catch (e) {
      _logger.warning('下载初始化失败: $e');
    } finally {
      _initialized = true;
      notifyListeners();
    }
  }

  /// 等待记录加载完成；已就绪时是同步空操作，不额外占用事件循环。
  Future<void> _ensureReady() async {
    if (!_initialized) await ready;
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
    await _ensureReady();
    _guardDownloadable(track);
    final key = track.id.uri;
    if (_records[key]?.hasAudio ?? false) {
      throw const SourceFailure(
        kind: FailureKind.unsupported,
        message: '该曲目已下载',
        l10nKey: 'downloadAlreadyExists',
      );
    }
    await _requireRoot();
    final task = DownloadTask(
      track: track,
      kind: DownloadTaskKind.audio,
      quality: quality ?? _pickQuality(track),
      includeLyrics: includeLyrics,
      includeCover: includeCover,
    );
    return _queue.enqueue(task);
  }

  /// 单独下载歌词（缓存优先）；无歌词抛 `downloadNoLyrics`。
  Future<void> downloadLyrics(Track track) async {
    await _ensureReady();
    _guardDownloadable(track);
    await _requireRoot();
    return _queue.enqueue(
      DownloadTask(track: track, kind: DownloadTaskKind.lyrics, quality: ''),
    );
  }

  /// 单独下载封面（缓存优先）；无封面抛 `downloadNoArtwork`。
  Future<void> downloadCover(Track track) async {
    await _ensureReady();
    _guardDownloadable(track);
    await _requireRoot();
    return _queue.enqueue(
      DownloadTask(track: track, kind: DownloadTaskKind.cover, quality: ''),
    );
  }

  /// 队列执行入口：按任务种类路由到对应编排。
  Future<void> _runTask(DownloadTask task) => switch (task.kind) {
    DownloadTaskKind.audio => _runAudioTask(task),
    DownloadTaskKind.lyrics => _runLyricsTask(task),
    DownloadTaskKind.cover => _runCoverTask(task),
  };

  /// 完整音频下载：取链 / 缓存拷贝 / 分项 / 标签 / 发布 / 落库。
  /// 失败归一为 [SourceFailure]，由队列决定保留还是移除任务。
  Future<void> _runAudioTask(DownloadTask task) async {
    final track = task.track;
    final key = task.key;
    final resolvedQuality = task.quality;
    final cancelToken = CancelToken();
    _tokens[key] = cancelToken;
    if (task.batchIndex != null && task.batchTotal != null) {
      _notifications.enterBatch(
        index: task.batchIndex!,
        key: key,
        track: track,
      );
    } else {
      _notifications.startTask(key, track);
    }

    String? partPath;
    String? filePath;
    String? lyricPath;
    String? coverPath;
    DownloadLyrics? lyrics;
    _ResolvedCover? cover;
    late final String root;
    late final String base;
    final outputs = <String>{};
    void registerOutput(String? path) {
      if (path == null || path.isEmpty) return;
      outputs.add(path);
      _activeOutputPaths.add(path);
    }

    try {
      root = await _requireRoot();
      // 1) 缓存优先：完整缓存文件直接拷贝，不触网。
      final cached = await _completeAudioCachePath(track, resolvedQuality);
      if (cached != null) {
        _logger.info('音频缓存命中，直接拷贝: $cached');
        final extension = DownloadFileLayout.extensionForTrack(
          track,
          resolvedQuality,
        );
        base = await _audioBaseName(root, track, extension);
        filePath = DownloadFileLayout.audioPath(root, base, extension);
        partPath = DownloadFileLayout.partPath(filePath);
        registerOutput(filePath);
        registerOutput(partPath);
        await _storage.copyFile(cached, partPath);
        await _storage.rename(partPath, filePath);
        partPath = null;
        _updateProgress(task, await _storage.fileSize(filePath), null);
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
        final extension = DownloadFileLayout.extensionFor(url, resolvedQuality);
        base = await _audioBaseName(root, track, extension);
        filePath = DownloadFileLayout.audioPath(root, base, extension);
        partPath = DownloadFileLayout.partPath(filePath);
        registerOutput(filePath);
        registerOutput(partPath);
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
              _updateProgress(task, received, expected),
        );
        _throwIfCancelled(cancelToken);
        await _storage.rename(partPath, filePath);
        partPath = null;
      }

      final size = await _storage.fileSize(filePath);
      _throwIfCancelled(cancelToken);

      // 3) 离线歌词 / 封面（best-effort，失败不阻断音频下载）。
      if (task.includeLyrics) {
        lyrics = await _resolveLyrics(track);
        if (lyrics != null) {
          final expectedLyricPath = DownloadFileLayout.lyricsPath(root, base);
          registerOutput(expectedLyricPath);
          registerOutput(translationLyricPathOf(expectedLyricPath));
          lyricPath = await _layout.writeLyrics(
            root,
            base,
            lyric: lyrics.lyric,
            translation: lyrics.translation,
          );
        }
      }
      if (task.includeCover) {
        cover = await _resolveCover(track);
        if (cover != null) {
          final expectedCoverPath = DownloadFileLayout.coverPath(
            root,
            base,
            cover.url ?? '',
          );
          registerOutput(expectedCoverPath);
          coverPath = await _layout.writeCover(
            root: root,
            base: base,
            coverUrl: cover.url ?? '',
            bytes: cover.bytes,
          );
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
      final record = _assembler.forAudioDownload(
        track: track,
        quality: resolvedQuality,
        filePath: filePath,
        sizeBytes: size,
        lyricPath: lyricPath,
        coverPath: coverPath,
        publicUri: publicUri,
        previous: previous,
      );
      await _repository.insert(record);
      _records[key] = record;
      _invalidateDownloadsCache();
      notifyListeners();
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
      _activeOutputPaths.removeAll(outputs);
      _tokens.remove(key);
      // 批量中的当前曲目由批量通知统一表达（presenter 内部按 key 抑制）。
      _notifications.stopTask(key);
    }
  }

  /// 单独下载歌词：与音频共用同一条队列，避免分项记录写库与音频下载并发覆盖。
  Future<void> _runLyricsTask(DownloadTask task) async {
    final track = task.track;
    final outputs = <String>{};
    void registerOutput(String? path) {
      if (path == null || path.isEmpty) return;
      outputs.add(path);
      _activeOutputPaths.add(path);
    }

    try {
      final root = await _requireRoot();
      final lyrics = await _resolveLyrics(track);
      if (lyrics == null || lyrics.lyric.trim().isEmpty) {
        throw const SourceFailure(
          kind: FailureKind.unsupported,
          message: '未找到歌词',
          l10nKey: 'downloadNoLyrics',
        );
      }
      final existing = recordForTrack(track);
      final base = await _layout.partBaseName(
        root: root,
        track: track,
        audioPath: existing?.filePath,
        existingPath: existing?.lyricPath,
        subdir: downloadsLyricsDirName,
        extension: 'lrc',
      );
      final expectedPath = DownloadFileLayout.lyricsPath(root, base);
      registerOutput(expectedPath);
      registerOutput(translationLyricPathOf(expectedPath));
      final path = await _layout.writeLyrics(
        root,
        base,
        lyric: lyrics.lyric,
        translation: lyrics.translation,
      );
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
    } finally {
      _activeOutputPaths.removeAll(outputs);
    }
  }

  /// 单独下载封面：与音频共用同一条队列。
  Future<void> _runCoverTask(DownloadTask task) async {
    final track = task.track;
    final outputs = <String>{};
    void registerOutput(String? path) {
      if (path == null || path.isEmpty) return;
      outputs.add(path);
      _activeOutputPaths.add(path);
    }

    try {
      final root = await _requireRoot();
      final cover = await _resolveCover(track);
      if (cover == null) {
        throw const SourceFailure(
          kind: FailureKind.unsupported,
          message: '没有封面',
          l10nKey: 'downloadNoArtwork',
        );
      }
      final coverUrl = cover.url ?? '';
      final existing = recordForTrack(track);
      final base = await _layout.partBaseName(
        root: root,
        track: track,
        audioPath: existing?.filePath,
        existingPath: existing?.coverPath,
        subdir: downloadsCoversDirName,
        extension: DownloadFileLayout.coverExtension(coverUrl),
      );
      registerOutput(DownloadFileLayout.coverPath(root, base, coverUrl));
      final path = await _layout.writeCover(
        root: root,
        base: base,
        coverUrl: coverUrl,
        bytes: cover.bytes,
      );
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
    } finally {
      _activeOutputPaths.removeAll(outputs);
    }
  }

  /// 取消下载（无进行中任务时空操作）：先撤排队任务，运行中再撤 dio 请求。
  void cancel(String sourceKey, String songId) {
    final key = '$sourceKey:$songId';
    if (_queue.cancelQueued(key)) return;
    _tokens[key]?.cancel();
  }

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
    _invalidateDownloadsCache();
    if (!record.imported) {
      // 记录引用的文件集（音频 / 歌词 / 翻译边车 / 封面）：约定见放置模块。
      for (final path in DownloadFileLayout.referencedFiles(record)) {
        await _storage.deleteQuietly(path);
      }
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
    await _ensureReady();
    var imported = 0;
    var skipped = 0;
    if (!_supported) return (0, paths.length);
    for (final rawPath in paths) {
      final path = p.normalize(rawPath.trim());
      // 后缀不带点（`audioExtensions` 约定）；标签解析要带点的原始后缀。
      final extension = p.extension(path).toLowerCase();
      final extensionName = extension.replaceFirst('.', '');
      if (path.isEmpty ||
          !DownloadFileLayout.audioExtensions.contains(extensionName)) {
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
      final record = _assembler.forLocalImport(
        filePath: path,
        sizeBytes: size,
        title: tags.title ?? fallback.title,
        artist: tags.artist ?? fallback.artist,
        album: tags.album ?? '',
        durationMs: tags.durationMs,
      );
      await _repository.insert(record);
      _records[record.key] = record;
      _invalidateDownloadsCache();
      imported++;
    }
    if (imported > 0) notifyListeners();
    return (imported, skipped);
  }

  /// 补发布：把已有音频但还没有公共副本的记录发布到公共 Downloads。
  ///
  /// 返回 `(发布数, 失败数)`。平台不支持（非 Android）时返回 `(0, 0)`。
  Future<(int, int)> publishMissingPublicCopies() async {
    if (!_publisher.supported) return (0, 0);
    await _ensureReady();
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
      final updated = _assembler.republished(record, uri);
      await _repository.insert(updated);
      _records[record.key] = updated;
      _invalidateDownloadsCache();
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
    await _ensureReady();
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
    String filePath,
    String displayName,
  ) async {
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
    final record = _assembler.forPartialDownload(
      track,
      existing: existing,
      lyricPath: lyricPath,
      coverPath: coverPath,
    );
    await _repository.insert(record);
    _records[key] = record;
    _invalidateDownloadsCache();
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

  /// 封面字节：自定义封面优先；否则曲目主图 + 降级链先查缓存，未命中再
  /// 取图并回填缓存。全局默认封面不参与下载（它只是展示占位）：
  /// [CoverResolver.realOf] 永远不会返回默认封面。
  Future<_ResolvedCover?> _resolveCover(Track track) async {
    final covers = _coverResolver;
    final real = covers?.realOf(track);
    if (covers != null && real?.isCustom == true) {
      try {
        final bytes = await covers.readCustomCoverBytes(track);
        if (bytes != null && bytes.isNotEmpty) {
          return _ResolvedCover(
            bytes: bytes,
            url: null,
            mimeType: 'image/jpeg',
          );
        }
      } catch (e) {
        _logger.warning('读取自定义封面失败: $e');
      }
    }
    final artwork = track.artwork;
    // 真实封面只可能是自定义 / 原始；自定义字节读取失败时回到原始封面链，
    // 不把自定义文件地址当网络图去下载。
    final urls = <String>{
      if (real?.isOriginal == true) real!.url!,
      if (artwork != null) artwork.uri.toString(),
      if (artwork != null)
        for (final fallback in artwork.fallbacks) fallback.toString(),
    }.where((url) => url.isNotEmpty).toList();
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

  Future<_ResolvedCover?> _downloadCoverBytes(String url) async {
    final bytes = await downloadCoverBytes(_dio, url, cache: _artworkCache);
    if (bytes == null) return null;
    return _ResolvedCover(
      bytes: bytes,
      url: url,
      mimeType: _mimeTypeForPath(url),
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

  int _nowMs() => _clock?.call() ?? DateTime.now().millisecondsSinceEpoch;

  /// 进度双通道：系统通知逐分片上报（presenter 自己 500ms 节流）；UI 进度
  /// 只进任务自身并做 100ms 合并——队列与服务都不在进度时通知。
  void _updateProgress(DownloadTask task, int received, int? total) {
    _notifications.reportProgress(task.key, received, total);
    task.reportProgress(received, total, nowMs: _nowMs());
  }

  Future<void> _cleanupFailedDownload({
    String? partPath,
    String? filePath,
    String? lyricPath,
    String? coverPath,
  }) async {
    final files = DownloadFileLayout.failedDownloadFiles(
      partPath: partPath,
      filePath: filePath,
      lyricPath: lyricPath,
      coverPath: coverPath,
    );
    for (final path in files) {
      await _storage.deleteQuietly(path);
    }
  }

  String _pickQuality(Track track) {
    final preferred = _preferredQuality?.call() ?? '320k';
    final types = [
      for (final quality in track.qualities)
        if (quality.type.isNotEmpty) quality.type,
    ];
    return pickQualityFor(types, preferred);
  }

  /// 音频唯一基名：磁盘与下载记录双重查重（命名 / 放置模块）。
  Future<String> _audioBaseName(String root, Track track, String extension) =>
      _layout.uniqueBaseName(
        root: root,
        desiredBase: _layout.baseNameFor(track),
        extension: extension,
        reservedPaths: [for (final record in _records.values) record.filePath],
      );

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

  @override
  void dispose() {
    for (final token in _tokens.values) {
      token.cancel();
    }
    _tokens.clear();
    _queue.dispose();
    super.dispose();
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
