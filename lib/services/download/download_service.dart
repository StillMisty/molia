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
///   播放取链只认数据库记录，永远不会读到半成品；音频 `.part` 写完后、
///   rename 前写一条文件型提交日志（应用支持目录 `download_journal/`），
///   写失败则在 rename 前中止，落库后删除；启动时补回 rename 后未落库的
///   记录（**不是队列持久化**）；
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
/// 本文件只做编排（下载一首 / 一批）；各 module 各有一份唯一实现：
/// - 任务队列：`download_queue.dart`（严格串行 FIFO / 去重 / 取消 / 重试 /
///   进度通道）；
/// - 提交日志：`download_journal.dart`（rename 前写 pending、启动恢复）；
/// - 命名 / 放置：`download_file_layout.dart`（模板 + sanitize + ` (2)` 去重 +
///   sidecar 路径约定）；
/// - 任务产物：`download_task_artifacts.dart`（活跃输出登记 + sidecar 写入）；
/// - 记录装配：`download_record_assembler.dart`（部分状态 → `DownloadedTrack`）；
/// - 记录写入：`download_record_store.dart`（drift 行 + 内存记录 + marker
///   三步的唯一写入顺序）；
/// - 通知 presenter：`download_notification_presenter.dart`（id 分配 / 批量
///   共享一条 / 系统频率节流 / 收尾不残留；端口由组合根注入）；
/// - 下载请求：`download_requests.dart`（单曲 / 歌词 / 封面 / 批量的资格
///   判定、入队等待与类型化结果入口；曲目菜单 / 分享 / 本地数据页 / 管理页
///   共用）。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../../data/catalog/catalog_service.dart';
import '../../data/downloads/audio_tag_reader.dart';
import '../covers/cover_image_format.dart';
import '../../data/downloads/audio_tag_writer.dart';
import '../../data/downloads/download_notifications.dart';
import '../../data/downloads/download_storage.dart';
import '../../data/downloads/downloads_publisher.dart';
import '../../data/downloads/downloads_repository.dart';
import '../../data/downloads/local_lyrics.dart';
import '../../data/http/app_dio.dart';
import '../../data/local_identity.dart';
import '../../domain/models/download.dart';
import '../../domain/models/failure.dart';
import '../../domain/models/track.dart';
import '../../managers/artwork_cache.dart';
import '../../models/lyrics_result.dart';
import '../../services/cache_service.dart';
import '../local/local_write_gate.dart';
import '../local/music_folder_scanner.dart';
import '../covers/cover_bytes_downloader.dart';
import '../covers/cover_resolution.dart';
import '../../sources/source_track.dart' show pickQualityFor;
import 'download_file_layout.dart';
import 'download_journal.dart';
import 'download_maintenance.dart';
import 'download_manager.dart';
import 'download_notification_presenter.dart';
import 'download_queue.dart';
import 'download_record_assembler.dart';
import 'download_record_store.dart';
import 'download_records.dart';
import 'download_requests.dart';
import 'download_settings.dart';
import 'download_task_artifacts.dart';

export 'download_queue.dart';
export 'download_task_artifacts.dart' show DownloadLyrics;

/// 下载时原生取词（组合根注入：`LyricsService.getLyrics` 适配，缓存优先）。
typedef DownloadLyricsResolver = Future<DownloadLyrics?> Function(Track track);

/// 下载时封面 URL 解析（组合根注入：`SourceManager.fetchPic` 适配）。
typedef DownloadArtworkResolver = Future<String?> Function(Track track);

/// 本地下载服务（`ChangeNotifier`：UI 用 `Selector` 订阅状态）。
class DownloadService extends DownloadManager
    implements DownloadMaintenance, LocalScanTarget {
  DownloadService({
    required this._catalog,
    required DownloadsRepository repository,
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
    LocalWriteGate? writeGate,
  }) : _writeGate = writeGate ?? LocalWriteGate(),
       _storage = storage,
       _dio = dio ?? createAppDio(),
       _settings = settings,
       _publisher = publisher ?? const NoopDownloadsPublisher(),
       _clock = clock,
       _layout = DownloadFileLayout(storage: storage, settings: settings),
       _assembler = DownloadRecordAssembler(clock: clock),
       _recordStore = DownloadRecordStore(
         repository: repository,
         journal: DownloadJournal(storage),
       ),
       _notifications = DownloadNotificationPresenter(
         notifications: notifications ?? createDownloadNotifications(),
         settings: settings,
         clock: clock,
       ) {
    _recordStore.records.addListener(_forwardRecords);
  }

  final CatalogService _catalog;
  final LocalWriteGate _writeGate;
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

  /// 记录写入模块：drift 仓库 + 内存记录 + 提交日志的唯一写入顺序。
  ///
  /// 服务只表达「保存 / 删除 / 待恢复」；页面经 Provider 读取 [records]，
  /// 不感知下载队列与文件布局。
  final DownloadRecordStore _recordStore;

  /// 记录通知转发：管理面监听者（能力位 / 就绪态）可只依赖
  /// [DownloadManager]；记录消费者直接监听 [records]。
  late final VoidCallback _forwardRecords = notifyListeners;

  /// 下载记录只读入口（组合根挂 Provider；测试直接读）。
  DownloadRecords get records => _recordStore.records;

  /// 运行中任务的 dio 取消令牌（只给网络下载用；排队取消由队列处理）。
  final Map<String, CancelToken> _tokens = {};

  /// 运行中任务已产生 / 即将产生的输出路径（音频 / `.part` / 歌词 / 翻译 /
  /// 封面）。落库前这些文件还不算「记录引用」，孤儿扫描必须避开它们。
  final DownloadActiveOutputs _activeOutputs = DownloadActiveOutputs();

  /// 产物写入器需要的记录端口（记录查询 / 分项 upsert 的适配）。
  late final DownloadArtifactRecords _artifactRecords =
      _ServiceDownloadArtifactRecords(this);

  /// 任务队列（严格串行单 worker；完成 / 取消即移除，失败保留供重试）。
  ///
  /// 延迟初始化：runner 是实例方法，构造器初始化列表里拿不到 `this`。
  late final DownloadQueue _queue = DownloadQueue(_runTask);

  /// dispose 后不再通知（运行中的 runner 可能晚于 service 销毁）。
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  /// 记录加载只做一次（幂等）；首帧后的启动尾巴与按需调用共用同一 Future。
  Future<void>? _initFuture;

  /// 下载目录是否可用（口径见 [DownloadRecords.supported]）。
  @override
  bool get supported => _recordStore.records.supported;

  /// 是否支持发布公共 Downloads 副本（仅 Android；UI 据此显隐发布设置 /
  /// 补发布入口）。
  @override
  bool get publisherSupported => _publisher.supported;

  /// 是否支持系统下载通知（仅 Android；UI 据此显隐「下载通知」开关）。
  @override
  bool get notificationsSupported => _notifications.supported;

  /// 记录是否已加载（启动时 [init] 一次）。
  @override
  bool get initialized => _recordStore.records.initialized;

  /// 任务结构变化（增删 / 状态切换）：页面任务区只监听这里。
  @override
  Listenable get taskChanges => _queue;

  /// 按状态分组的音频任务（运行在前），管理页不再逐条过滤三遍。
  @override
  DownloadTaskGroups get taskGroups {
    final groups = _queue.taskGroups;
    return (
      running: [
        for (final task in groups.running)
          if (task.kind == DownloadTaskKind.audio) task,
      ],
      queued: [
        for (final task in groups.queued)
          if (task.kind == DownloadTaskKind.audio) task,
      ],
      failed: [
        for (final task in groups.failed)
          if (task.kind == DownloadTaskKind.audio) task,
      ],
    );
  }

  /// 当前曲目的音频任务（排队 / 运行 / 失败）；本地曲目与分项任务返回 null。
  @override
  DownloadTask? taskForTrack(Track track) {
    if (track.id.sourceKey == kLocalSourceKey) return null;
    final task = _queue.taskFor(track.id.uri);
    return task?.kind == DownloadTaskKind.audio ? task : null;
  }

  /// 重试失败任务：新建一个不带批量位置的任务入队。
  ///
  /// 批量位置是「这一批」的上下文，重试发生在批次结束之后；沿用旧任务会让
  /// 通知 presenter 走已结束的批量分支（no-op），或污染另一条正在跑的批次。
  @override
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
  @override
  void dismissTask(DownloadTask task) => _queue.dismiss(task.key);

  /// 当前解析出的下载根目录（设置页展示；不可用返回 null）。
  @override
  Future<String?> rootPath() => _storage.downloadsRoot();

  /// 清扫崩溃遗留的半成品（`*.part`），返回删除数量。
  @override
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
  @override
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
    for (final record in _recordStore.records.downloads)
      ...DownloadFileLayout.referencedFiles(record),
    ..._activeOutputs.paths,
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
  @override
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

  /// 批量候选：排除本地曲目、已有音频下载、已有 active 音频任务，
  /// 按 `track.id.uri` 去重；`index` 是原入参位置（通知序号用）。
  @override
  List<({int index, Track track})> batchCandidates(Iterable<Track> tracks) {
    final items = tracks.toList();
    final seen = <String>{};
    final candidates = <({int index, Track track})>[];
    for (var index = 0; index < items.length; index++) {
      final track = items[index];
      // 资格判定与单曲请求共用同一实现（本地 / 已下载 / 进行中）。
      final status = downloadIntentStatusOf(
        track,
        records: _recordStore.records,
        supported: supported,
        task: taskForTrack(track),
      );
      if (status != DownloadIntentStatus.ready) continue;
      if (!seen.add(track.id.uri)) continue;
      candidates.add((index: index, track: track));
    }
    return candidates;
  }

  /// 批量下载：先一次性把全部任务放进队列，再在后台逐个等待结果。
  ///
  /// [onEnqueued] 在全部候选入队后、开始等待结果前调用，参数是实际新入队
  /// 数；页面据此提示「已加入下载队列」，与实际列表一致。
  ///
  /// 页面调用后立即拿到「已加入队列」的反馈，不再被整批 await 锁住；队列
  /// 本身严格串行（一次只跑一个）。不做断点续传（平台直链多为一次性签名
  /// 地址）；单项失败不影响后续，返回 `(下载数, 失败数)`，失败音频任务
  /// 留在管理页失败区可重试。
  ///
  /// 通知（Android）：整批共享一条「N/N」通知（曲目位置按入参序号），批内单任务
  /// 通知被抑制——顺序下载时逐条通知会闪成一串，一条批量通知更接近用户直觉。
  @override
  Future<(int, int)> downloadBatch(
    Iterable<Track> tracks, {
    void Function(int enqueued)? onEnqueued,
  }) async {
    // 物化入参只为「批量位置」计数（顺序与跳过判定完全不变）。
    final items = tracks.toList();
    await _ensureReady();
    // 已有批量在进行（并发调用）时不抢占通知：服务端只有一个批量 id。
    final batch = _notifications.beginBatch(items.length);
    // 入队后立刻给每个 future 挂错误处理：排队任务可能在轮到自己之前被
    // 取消，若等到按序 await 才监听，completeError 会变成未处理异步错误。
    // 结果：true = 成功，false = 失败，null = 已取消（不计入失败）。
    final outcomes = <Future<bool?>>[];
    try {
      final candidates = batchCandidates(items);
      for (final candidate in candidates) {
        final task = DownloadTask(
          track: candidate.track,
          kind: DownloadTaskKind.audio,
          quality: _pickQuality(candidate.track),
          batchIndex: batch ? candidate.index + 1 : null,
          batchTotal: batch ? items.length : null,
        );
        // enqueue 同步入队：所有任务在第一个 await 前全部可见。
        outcomes.add(
          _queue
              .enqueue(task)
              .then<bool?>(
                (_) => true,
                onError: (Object error) =>
                    error is SourceFailure &&
                        error.kind == FailureKind.cancelled
                    ? null
                    : false,
              ),
        );
      }
      onEnqueued?.call(outcomes.length);

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
  @override
  String defaultQualityFor(Track track) => _pickQuality(track);

  /// 记录加载完成的信号：首帧后的启动尾巴调用 [init]，播放取链与下载入口
  /// 在记录就绪前先等这里，避免把已下载曲目误判成在线曲目。
  @override
  Future<void> get ready => _initFuture ??= _init();

  /// 加载已有下载记录并探测存储可用性（幂等；首帧后调用一次）。
  ///
  /// 不放在 `runApp` 前：存储根解析、全量记录读取与 `.part` 清扫都是磁盘/DB
  /// 工作，不参与首帧内容。调用方在首帧后触发，UI 用 [initialized] 展示
  /// 加载态；[localUriFor] 等依赖记录的方法会自行等待 [ready]。
  @override
  Future<void> init() => ready;

  Future<void> _init() async {
    try {
      final supported = await _storage.downloadsRoot() != null;
      _recordStore.records.setSupported(supported);
      // 存储不可用时不触碰数据库：本机下载整体关闭。
      if (supported) {
        await _recordStore.load();
        // 先恢复「文件已 rename、记录未落库」的提交，再清扫 .part；否则
        // 恢复失败时 .part 与 marker 会被重复处理。
        await _recoverPendingDownloads();
        // 崩溃遗留的半成品（.part）清扫：失败仅记日志，不影响记录可用。
        final cleaned = await cleanupIncompleteDownloads();
        if (cleaned > 0) _logger.info('清理未完成的下载文件 $cleaned 个');
      }
    } catch (e) {
      _logger.warning('下载初始化失败: $e');
    } finally {
      _recordStore.records.markInitialized();
    }
  }

  /// 恢复 rename 后、落库前崩溃的音频下载。
  ///
  /// marker 只在「最终文件已就位、DB 记录未落」的窗口存在：文件不存在说明
  /// 崩溃在 rename 前（交给 `.part` 清扫），已有同 key 记录说明落库成功但
  /// marker 未删。两种情况都只删 marker，不覆盖已有记录。
  Future<void> _recoverPendingDownloads() async {
    final entries = await _recordStore.pending();
    var recovered = 0;
    for (final entry in entries) {
      final record = entry.record;
      try {
        final existing = _recordStore.records.recordFor(
          record.originSourceKey,
          record.originSongId,
        );
        // 只有「已有音频」才说明落库成功。分项记录（仅歌词 / 封面）不能
        // 代表音频已落库，marker 仍要用来恢复音频。
        if (existing != null && existing.hasAudio) {
          await _recordStore.removePending(entry.markerPath);
          continue;
        }
        final path = record.filePath;
        if (path == null || path.isEmpty || !await _storage.fileExists(path)) {
          await _recordStore.removePending(entry.markerPath);
          continue;
        }
        await _recordStore.save(record, clearJournal: true);
        recovered++;
      } catch (e) {
        // 保留 marker：下次启动再试；不能因为一条坏记录阻断整个初始化。
        _logger.warning('下载恢复失败（${record.key}）: $e');
      }
    }
    if (recovered > 0) _logger.info('恢复未落库的下载 $recovered 条');
  }

  /// 等待记录加载完成；已就绪时是同步空操作，不额外占用事件循环。
  Future<void> _ensureReady() async {
    if (!_recordStore.records.initialized) await ready;
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
  @override
  Future<void> download(
    Track track, {
    String? quality,
    bool includeLyrics = true,
    bool includeCover = true,
  }) async {
    final task = await enqueueDownload(
      track,
      quality: quality,
      includeLyrics: includeLyrics,
      includeCover: includeCover,
    );
    await task.done;
  }

  /// 入队音频下载并立即返回任务对象（请求层据此等待终态）。
  ///
  /// 资格判定与 `DownloadRequests` 共用 [downloadIntentStatusOf]：本地 /
  /// 已下载在这里再兜一次底（调用方可能绕过请求层），不重复维护规则。
  @override
  Future<DownloadTask> enqueueDownload(
    Track track, {
    String? quality,
    bool includeLyrics = true,
    bool includeCover = true,
  }) async {
    await _ensureReady();
    // supported 不在这里判：根目录可能在初始化后失效，统一由 _requireRoot
    // 给出 downloadUnsupported。
    final status = downloadIntentStatusOf(
      track,
      records: _recordStore.records,
      supported: true,
    );
    switch (status) {
      case DownloadIntentStatus.unsupported:
        throw downloadLocalTrackFailure;
      case DownloadIntentStatus.alreadyDownloaded:
        throw const SourceFailure(
          kind: FailureKind.unsupported,
          message: '该曲目已下载',
          l10nKey: 'downloadAlreadyExists',
        );
      case DownloadIntentStatus.ready:
      case DownloadIntentStatus.active:
        break;
    }
    await _requireRoot();
    final task = DownloadTask(
      track: track,
      kind: DownloadTaskKind.audio,
      quality: quality ?? _pickQuality(track),
      includeLyrics: includeLyrics,
      includeCover: includeCover,
    );
    // 已有同 key 活动任务时队列返回它的 future；入队已同步完成，先挂一个
    // ignore 监听，避免调用方只拿任务对象、晚些才 await 时出现未处理错误。
    _queue.enqueue(task).ignore();
    // 队列可能因同 key 活动任务而保留旧任务：返回真正在队列里的那个。
    return _queue.taskFor(task.key) ?? task;
  }

  /// 单独下载歌词（缓存优先）；无歌词抛 `downloadNoLyrics`。
  @override
  Future<void> downloadLyrics(Track track) async {
    await _ensureReady();
    _guardDownloadable(track);
    await _requireRoot();
    return _queue.enqueue(
      DownloadTask(track: track, kind: DownloadTaskKind.lyrics, quality: ''),
    );
  }

  /// 单独下载封面（缓存优先）；无封面抛 `downloadNoArtwork`。
  @override
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
    DownloadResolvedCover? cover;
    DownloadedTrack? pending;
    var journalWritten = false;
    int? partTotal;
    late final String root;
    late final String base;
    final artifacts = _newArtifacts();

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
        artifacts.register(filePath);
        artifacts.register(partPath);
        await _storage.copyFile(cached, partPath);
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
        artifacts.register(filePath);
        artifacts.register(partPath);
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
        partTotal = total;
        await _storage.writeStream(
          partPath,
          streamBody(response).stream,
          total: total,
          onProgress: (received, expected) =>
              _updateProgress(task, received, expected),
        );
      }

      final part = partPath;
      final size = await _storage.fileSize(part);
      _throwIfCancelled(cancelToken);

      // 3) 提交日志写在 rename 之前：崩溃时只要最终文件存在，启动就能把
      //    「文件已就位、记录未落库」的音频记录补回来。
      final targetPath = filePath;
      pending = _assembler.forAudioDownload(
        track: track,
        quality: resolvedQuality,
        filePath: targetPath,
        sizeBytes: size,
        previous: _recordStore.records.recordFor(
          track.id.sourceKey,
          track.id.id,
        ),
      );
      final journalOk = await _recordStore.markPending(pending);
      if (!journalOk) {
        throw const SourceFailure(
          kind: FailureKind.unknown,
          message: '无法写入下载记录，请重试',
          l10nKey: 'downloadFailed',
        );
      }
      journalWritten = true;
      _throwIfCancelled(cancelToken);
      await _storage.rename(part, targetPath);
      partPath = null;
      _updateProgress(task, size, partTotal);

      // 4) 离线歌词 / 封面（best-effort，失败不阻断音频下载）。
      if (task.includeLyrics) {
        lyrics = await _resolveLyrics(track);
        if (lyrics != null) {
          lyricPath = await artifacts.writeLyrics(
            root: root,
            base: base,
            lyrics: lyrics,
          );
        }
      }
      if (task.includeCover) {
        cover = await _resolveCover(track);
        if (cover != null) {
          coverPath = await artifacts.writeCover(
            root: root,
            base: base,
            cover: cover,
          );
        }
      }
      _throwIfCancelled(cancelToken);

      // 5) 标签嵌入（best-effort：失败保留 sidecar；可在下载设置关闭）。
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

      // 6) 公共目录发布（best-effort）：Android 拷进 MediaStore Downloads，
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
        previous: pending,
      );
      await _recordStore.save(record, clearJournal: true);
      _logger.info('下载完成: $key -> $filePath (${record.sizeLabel})');
      journalWritten = false;
    } catch (e) {
      if (journalWritten) {
        await _recordStore.removePendingByKey(key);
        journalWritten = false;
      }
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
      artifacts.close();
      _tokens.remove(key);
      // 批量中的当前曲目由批量通知统一表达（presenter 内部按 key 抑制）。
      _notifications.stopTask(key);
    }
  }

  /// 单独下载歌词：与音频共用同一条队列，避免分项记录写库与音频下载并发覆盖。
  Future<void> _runLyricsTask(DownloadTask task) async {
    final track = task.track;
    final artifacts = _newArtifacts();
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
      await artifacts.saveLyricsPart(track, root: root, lyrics: lyrics);
    } finally {
      artifacts.close();
    }
  }

  /// 单独下载封面：与音频共用同一条队列。
  Future<void> _runCoverTask(DownloadTask task) async {
    final track = task.track;
    final artifacts = _newArtifacts();
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
      await artifacts.saveCoverPart(track, root: root, cover: cover);
    } finally {
      artifacts.close();
    }
  }

  /// 单个任务的产物写入器：活跃输出 / 布局 / 记录 / 标签端口显式注入。
  DownloadTaskArtifacts _newArtifacts() => DownloadTaskArtifacts(
    outputs: _activeOutputs,
    layout: _layout,
    records: _artifactRecords,
    embedTags: _embedTagsFromFiles,
  );

  /// 取消当前曲目的下载（UI 入口）：先撤排队任务，运行中再撤 dio 请求。
  @override
  void cancelTrack(Track track) {
    if (track.id.sourceKey == kLocalSourceKey) return;
    final key = track.id.uri;
    if (_queue.cancelQueued(key)) return;
    _tokens[key]?.cancel();
  }

  /// 重定位（「重新选择文件」）：只改路径 / 大小 / 修改时间并清除缺失状态。
  ///
  /// 导入保留 `localKey` 与全部引用；下载副本保留原音源键。文件不存在 /
  /// 后缀不在音频集合内 / 记录没有音频时返回对应结果，不改任何状态。
  @override
  Future<LocalRelocateResult> relocate(
    DownloadedTrack record,
    String newPath,
  ) => _writeGate.run(() => _relocate(record, newPath));

  Future<LocalRelocateResult> _relocate(
    DownloadedTrack record,
    String newPath,
  ) async {
    final path = p.normalize(newPath.trim());
    final extension = p.extension(path).toLowerCase();
    if (path.isEmpty ||
        !DownloadFileLayout.audioExtensions.contains(
          extension.replaceFirst('.', ''),
        )) {
      return LocalRelocateResult.unsupportedFormat;
    }
    final size = await _storage.fileSize(path);
    if (size <= 0) return LocalRelocateResult.fileMissing;
    final mtime = await _storage.fileMtime(path);
    await _recordStore.relocate(
      record,
      path: path,
      sizeBytes: size,
      mtimeMs: mtime,
    );
    return LocalRelocateResult.relocated;
  }

  /// 删除下载：先删数据库记录（避免残留半删记录），再删音频 / 歌词 / 封面文件
  /// 与公共 Downloads 副本（发布副本随下载一起回收；失败只记日志）。
  ///
  /// 本地导入（`imported`）是就地引用：只移除记录，**不动用户原文件**。
  @override
  Future<void> delete(DownloadedTrack record) async {
    await _recordStore.deleteRecord(record);
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
  }

  /// 导入本地音频文件（就地引用：不复制、不移动，删除记录不动原文件）。
  ///
  /// 记录使用稳定本地身份 `localKey = file:<uuid>`（`originSongId` 镜像它），
  /// 同路径重复导入复用已有 `localKey`（幂等，收藏 / 列表引用不变）；标题 /
  /// 歌手 / 专辑读文件标签（mp3 / flac，见 `audio_tag_reader.dart`），其余
  /// 格式按 `歌手 - 歌名` 文件名兜底。
  ///
  /// 返回 `(导入数, 跳过数)`：路径为空 / 文件不存在 / 非音频后缀 /
  /// 存储不可用计入跳过。
  @override
  Future<(int, int)> importLocalFiles(Iterable<String> paths) =>
      _writeGate.run(() => _importLocalFiles(paths));

  Future<(int, int)> _importLocalFiles(Iterable<String> paths) async {
    await _ensureReady();
    var imported = 0;
    var skipped = 0;
    if (!_recordStore.records.supported) return (0, paths.length);
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
      // 重复导入复用稳定身份，只刷新元数据；扫描的新文件走 importFile。
      await _importLocalFile(path, sizeBytes: size);
      imported++;
    }
    return (imported, skipped);
  }

  @override
  Future<DownloadedTrack?> refreshLocalMetadata(DownloadedTrack record) =>
      _writeGate.run(() async {
        final path = record.filePath;
        if (path == null || path.isEmpty) return null;
        final extension = p.extension(path).toLowerCase();
        if (!DownloadFileLayout.audioExtensions.contains(
          extension.replaceFirst('.', ''),
        )) {
          return null;
        }
        final size = await _storage.fileSize(path);
        if (size <= 0) return null;
        final head =
            await _storage.readHead(path, kAudioTagReadLimit) ?? Uint8List(0);
        final tags = readAudioTags(head, extension: extension, fileSize: size);
        final fallback = splitFileNameMetadata(
          p.basenameWithoutExtension(path),
        );
        final updated = record.copyWith(
          title: tags.title ?? fallback.title,
          artist: tags.artist ?? fallback.artist,
          album: tags.album ?? record.album,
          durationMs: tags.durationMs,
          sizeBytes: size,
          mtimeMs: await _storage.fileMtime(path),
          clearMissingAt: !await _storage.fileExists(path) ? false : true,
        );
        await _recordStore.save(updated);
        return updated;
      });

  /// 扫描器端口：当前全部导入记录。
  @override
  Future<List<DownloadedTrack>> listImported() async {
    await _ensureReady();
    return [
      for (final record in _recordStore.records.downloads)
        if (record.imported) record,
    ];
  }

  /// 扫描器端口：新文件 import（读标签，生成 / 复用稳定身份）。
  @override
  Future<void> importFile(
    String path, {
    required int sizeBytes,
    required int mtimeMs,
  }) => _writeGate.run(() async {
    await _ensureReady();
    await _importLocalFile(path, sizeBytes: sizeBytes, mtimeMs: mtimeMs);
  });

  /// 扫描器端口：已有文件只刷新技术字段（标题等用户可见元数据不动）。
  @override
  Future<void> refreshFile(
    DownloadedTrack record, {
    required int sizeBytes,
    required int mtimeMs,
  }) => _writeGate.run(() async {
    final path = record.filePath;
    if (path == null || path.isEmpty) return;
    await _recordStore.relocate(
      record,
      path: path,
      sizeBytes: sizeBytes,
      mtimeMs: mtimeMs,
    );
  });

  /// 扫描器端口：提交一个增量批次（≤200 条），整批排在同一写队列里。
  @override
  Future<void> commitBatch(
    List<LocalScanChange> changes,
  ) => _writeGate.run(() async {
    for (final change in changes) {
      switch (change) {
        case LocalScanImport(:final path, :final sizeBytes, :final mtimeMs):
          await _importLocalFile(path, sizeBytes: sizeBytes, mtimeMs: mtimeMs);
        case LocalScanRefresh(:final record, :final sizeBytes, :final mtimeMs):
          final path = record.filePath;
          if (path == null || path.isEmpty) continue;
          await _recordStore.relocate(
            record,
            path: path,
            sizeBytes: sizeBytes,
            mtimeMs: mtimeMs,
          );
        case LocalScanMissing(:final record):
          if (!record.hasAudio || record.isMissing) continue;
          await _recordStore.markMissing(
            record,
            missingAt: DateTime.now().millisecondsSinceEpoch,
          );
      }
    }
  });

  /// 扫描器端口：根目录成功枚举后仍找不到的文件标记缺失。
  @override
  Future<void> markMissing(DownloadedTrack record) => _writeGate.run(() async {
    if (!record.hasAudio || record.isMissing) return;
    final missingAt = DateTime.now().millisecondsSinceEpoch;
    await _recordStore.markMissing(record, missingAt: missingAt);
  });

  /// 单文件导入的唯一实现（手动导入 / 扫描共用）。
  ///
  /// [mtimeMs] 未给时现读；同路径旧记录复用 `localKey`。
  Future<DownloadedTrack> _importLocalFile(
    String path, {
    required int sizeBytes,
    int? mtimeMs,
  }) async {
    final extension = p.extension(path).toLowerCase();
    final head =
        await _storage.readHead(path, kAudioTagReadLimit) ?? Uint8List(0);
    final tags = readAudioTags(head, extension: extension, fileSize: sizeBytes);
    final fallback = splitFileNameMetadata(p.basenameWithoutExtension(path));
    final existing =
        _recordStore.records.importedRecordForPath(path) ??
        await _recordStore.findImportedByPath(path);
    final record = _assembler.forLocalImport(
      filePath: path,
      sizeBytes: sizeBytes,
      title: tags.title ?? fallback.title,
      artist: tags.artist ?? fallback.artist,
      album: tags.album ?? '',
      durationMs: tags.durationMs,
      // 同路径重复导入必须复用旧身份，否则收藏 / 列表会变成失效引用。
      localKey: existing?.localKey ?? newLocalKey(),
      mtimeMs: mtimeMs ?? await _storage.fileMtime(path),
    );
    await _recordStore.save(record);
    return record;
  }

  /// 补发布：把已有音频但还没有公共副本的记录发布到公共 Downloads。
  ///
  /// 返回 `(发布数, 失败数)`。平台不支持（非 Android）时返回 `(0, 0)`。
  @override
  Future<(int, int)> publishMissingPublicCopies() async {
    if (!_publisher.supported) return (0, 0);
    await _ensureReady();
    var published = 0;
    var failed = 0;
    for (final record in _recordStore.records.downloads) {
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
      await _recordStore.save(updated);
      published++;
    }
    return (published, failed);
  }

  /// 播放取链优先命中本地副本：下载记录 → 完整缓存（缓存 = 已下载）。
  ///
  /// 本地曲目（`sourceKey = local`）返回 null——由 `local` 音源自身解析；
  /// 只有歌词 / 封面的分项记录（无音频）返回 null。[quality] 为本次播放
  /// 实际选择的音质（精确命中优先，未命中回退其它已缓存音质），缓存命中时
  /// 直接返回 `file://`，离线可播、不再取链。
  @override
  Future<Uri?> localUriFor(Track track, {String? quality}) async {
    if (track.id.sourceKey == kLocalSourceKey) return null;
    await _ensureReady();
    final record = _recordStore.records.recordFor(
      track.id.sourceKey,
      track.id.id,
    );
    final path = record?.filePath;
    if (path != null && path.isNotEmpty && await _storage.fileExists(path)) {
      return Uri.file(path);
    }
    final qualities = <String>[
      if (quality != null && quality.isNotEmpty) quality,
      ..._audioCacheQualityCandidates(track),
    ];
    for (final candidate in qualities) {
      final cached = await _completeAudioCachePath(track, candidate);
      if (cached == null) continue;
      // 零字节文件不算可播放副本。
      if (await _storage.fileSize(cached) <= 0) continue;
      return Uri.file(cached);
    }
    return null;
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
    if (track.id.sourceKey == kLocalSourceKey ||
        track.origin == TrackOrigin.localFile) {
      throw downloadLocalTrackFailure;
    }
  }

  Future<String> _requireRoot() async {
    final root = await _storage.downloadsRoot();
    if (root == null) throw downloadUnsupportedFailure;
    return root;
  }

  /// 分项写入后的记录更新（保留既有音频 / 另一分项字段）。
  Future<void> _upsertPart(
    Track track, {
    String? lyricPath,
    String? coverPath,
  }) async {
    final existing = _recordStore.records.recordFor(
      track.id.sourceKey,
      track.id.id,
    );
    final record = _assembler.forPartialDownload(
      track,
      existing: existing,
      lyricPath: lyricPath,
      coverPath: coverPath,
    );
    await _recordStore.save(record);
  }

  /// 已有音频时把（sidecar 里的）歌词 / 封面补写进标签。
  Future<void> _embedTagsFromFiles(Track track) async {
    if (!(_settings?.embedTags ?? true)) return;
    final record = _recordStore.records.recordForTrack(track);
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
  Future<DownloadResolvedCover?> _resolveCover(Track track) async {
    final covers = _coverResolver;
    final real = covers?.realOf(track);
    if (covers != null && real?.isCustom == true) {
      try {
        final bytes = await covers.readCustomCoverBytes(track);
        if (bytes != null && bytes.isNotEmpty) {
          return DownloadResolvedCover(
            bytes: bytes,
            url: null,
            mimeType: CoverImageFormats.detect(bytes)?.mimeType ?? 'image/jpeg',
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
          return DownloadResolvedCover(
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

  Future<DownloadResolvedCover?> _downloadCoverBytes(String url) async {
    final bytes = await downloadCoverBytes(_dio, url, cache: _artworkCache);
    if (bytes == null) return null;
    return DownloadResolvedCover(
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
        reservedPaths: [
          for (final record in _recordStore.records.downloads) record.filePath,
        ],
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
    if (_disposed) return;
    _disposed = true;
    for (final token in _tokens.values) {
      token.cancel();
    }
    _tokens.clear();
    _queue.dispose();
    _recordStore.records.removeListener(_forwardRecords);
    _recordStore.records.dispose();
    super.dispose();
  }
}

/// 记录端口的服务侧适配：产物写入器只经接口查询记录 / 做分项 upsert。
class _ServiceDownloadArtifactRecords implements DownloadArtifactRecords {
  _ServiceDownloadArtifactRecords(this._service);

  final DownloadService _service;

  @override
  DownloadedTrack? recordForTrack(Track track) =>
      _service._recordStore.records.recordForTrack(track);

  @override
  Future<void> upsertPart(
    Track track, {
    String? lyricPath,
    String? coverPath,
  }) => _service._upsertPart(track, lyricPath: lyricPath, coverPath: coverPath);
}
