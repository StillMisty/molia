/// 收藏页合集 I/O 编排：文件导入 / 链接导入 / 导出 / 批量下载 → 类型化结果。
///
/// 为什么单独一层：这些流程原先写在收藏页 State 里，选文件、读盘、解析、复核、
/// 写库、另存、批量入队与 `mounted` 检查缠在一起，失败只能各自 snackbar，
/// 纯单测必须挂 widget 树。这里把「选什么 → 解析什么 → 谁确认 → 写到哪」
/// 收进窄端口，页面只保留弹层 / 文案 / 触感 / 清选择；异常在命令边界统一
/// 收口成结果，不再有原始异常逃进 `unawaited`。
///
/// 模块不读 BuildContext、不 import widgets：生产端口由页面按 context 组装，
/// 单测用假端口直接断言结果（取消 / 空 / 失败 / 部分成功各自可区分）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import '../domain/models/download.dart';
import '../domain/models/library.dart';
import '../domain/models/playlist_cover_keys.dart';
import '../domain/models/track.dart';
import '../services/download/download_intent.dart';
import '../services/download/download_manager.dart';
import '../services/download/download_records.dart';
import '../services/playlist/playlist_export_builder.dart';
import '../services/playlist/playlist_file_codec.dart';
import '../services/playlist/playlist_import_service.dart';
import '../services/save_as_types.dart';
import '../utils/file_name.dart';
import 'discover_provider.dart';
import 'library_provider.dart';
import 'sync_provider.dart';

/// 选文件端口：返回文件绝对路径；取消返回 null；抛错 = 选择器不可用。
abstract interface class CollectionPlaylistFilePicker {
  Future<String?> pick({required String dialogTitle});
}

/// 本机文本读取端口：向导出的缺失文件计数提供存在性判断。
abstract interface class CollectionPlaylistFileReader {
  Future<String> readText(String path);

  Future<bool> exists(String path);
}

/// 导入复核确认：页面接复核弹层，false = 用户放弃（不创建列表）。
typedef CollectionImportReview = Future<bool> Function(PlaylistImportPlan plan);

/// 平台歌单 / 收藏夹链接导入端口（生产实现包住 DiscoverProvider）。
abstract interface class CollectionLinkImporter {
  Future<({int playlistId, int added, int total})> importFromLink(
    String sourceKey,
    String rawId, {
    required String fallbackName,
  });
}

/// 导出所需的资料库读取面：平台页地址 / 下载记录 / 封面键。
abstract interface class CollectionExportLibrary {
  String? platformPageUrlOf(PlaylistTrack track);

  DownloadedTrack? downloadedRecordOf(PlaylistTrack track);

  /// 补齐并返回列表封面键；失败返回 null。
  Future<String?> ensurePlaylistCoverKey(int playlistId);
}

/// 全保真导出端口（同步引擎未装配时为 null）。
abstract interface class CollectionPlaylistBackup {
  Future<String> exportPlaylistJson({
    required String playlistSyncId,
    String? coverKey,
  });
}

/// 另存端口（另存服务未装配时为 null；取消 / 失败按 [SaveAsResult] 原样返回）。
abstract interface class CollectionExportSaver {
  Future<SaveAsResult> saveBytes({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String relativeDir,
    String? dialogTitle,
  });
}

/// 批量下载端口（批量入队 / 候选过滤 / 结果统计仍由下载服务唯一实现）。
abstract interface class CollectionBatchDownloader {
  Future<DownloadBatchStart> startBatch(
    List<Track> tracks, {
    void Function(int enqueued)? onEnqueued,
  });
}

/// 导出格式：与导出弹层的选项一一对应，但命令层不依赖 widget 枚举。
enum CollectionExportFormat { m3u8, molia }

/// 文件导入取消原因（页面都静默，区分只用于测试与诊断）。
enum CollectionImportCancelReason {
  /// 文件选择器取消 / 没选文件。
  filePick,

  /// 复核弹层未确认。
  review,

  /// 流程中途页面已卸载（不再做剩余 I/O）。
  abandoned,
}

/// 文件导入结果。
sealed class CollectionPlaylistImportOutcome {
  const CollectionPlaylistImportOutcome();
}

/// 已创建列表并批量加入曲目。
final class CollectionPlaylistImportDone
    extends CollectionPlaylistImportOutcome {
  const CollectionPlaylistImportDone({
    required this.playlistId,
    required this.name,
    required this.added,
    required this.skipped,
  });

  final int playlistId;
  final String name;
  final int added;
  final int skipped;
}

/// 用户取消（选择器 / 复核）或流程被放弃。
final class CollectionPlaylistImportCancelled
    extends CollectionPlaylistImportOutcome {
  const CollectionPlaylistImportCancelled(this.reason);

  final CollectionImportCancelReason reason;
}

/// 文件里没有任何条目（空列表 / 空文件）。
final class CollectionPlaylistImportEmpty
    extends CollectionPlaylistImportOutcome {
  const CollectionPlaylistImportEmpty();
}

/// 选择 / 读取 / 解析 / 写库失败（原始异常只用于日志与测试）。
final class CollectionPlaylistImportFailed
    extends CollectionPlaylistImportOutcome {
  const CollectionPlaylistImportFailed([this.error]);

  final Object? error;
}

/// 链接导入结果。
sealed class CollectionLinkImportOutcome {
  const CollectionLinkImportOutcome();
}

/// 拉到曲目并写入列表。
final class CollectionLinkImportDone extends CollectionLinkImportOutcome {
  const CollectionLinkImportDone({
    required this.playlistId,
    required this.added,
  });

  final int playlistId;
  final int added;
}

/// 平台没有返回任何曲目。
final class CollectionLinkImportEmpty extends CollectionLinkImportOutcome {
  const CollectionLinkImportEmpty();
}

/// 列表已包含全部曲目（新增 0 条）。
final class CollectionLinkImportAlreadyContains
    extends CollectionLinkImportOutcome {
  const CollectionLinkImportAlreadyContains(this.playlistId);

  final int playlistId;
}

/// 拉取 / 写入失败（平台失败与未知异常在页面用同一条文案）。
final class CollectionLinkImportFailed extends CollectionLinkImportOutcome {
  const CollectionLinkImportFailed([this.error]);

  final Object? error;
}

/// 导出结果。
sealed class CollectionExportOutcome {
  const CollectionExportOutcome();
}

/// 已写出文件；[missingFiles] 只对 M3U8 有意义。
final class CollectionExportSaved extends CollectionExportOutcome {
  const CollectionExportSaved({
    required this.displayPath,
    required this.kind,
    this.missingFiles = 0,
  });

  final String displayPath;
  final SaveLocationKind kind;
  final int missingFiles;
}

/// 用户在系统另存对话框取消。
final class CollectionExportCancelled extends CollectionExportOutcome {
  const CollectionExportCancelled();
}

/// 构建 / 导出 / 写入失败。
final class CollectionExportFailed extends CollectionExportOutcome {
  const CollectionExportFailed([this.error]);

  final Object? error;
}

/// 批量下载结果。
sealed class CollectionBatchDownloadOutcome {
  const CollectionBatchDownloadOutcome();
}

/// 用户取消省流确认，或没有输入曲目。
final class CollectionBatchDownloadCancelled
    extends CollectionBatchDownloadOutcome {
  const CollectionBatchDownloadCancelled();
}

/// 批量入口已跑完；[enqueued] 可为 0（没有可下载候选）。
final class CollectionBatchDownloadFinished
    extends CollectionBatchDownloadOutcome {
  const CollectionBatchDownloadFinished({
    required this.enqueued,
    required this.done,
    required this.failed,
  });

  final int enqueued;
  final int done;
  final int failed;
}

/// 批量入口抛错（不允许 / 存储不可用等，文案由页面映射）。
final class CollectionBatchDownloadFailed
    extends CollectionBatchDownloadOutcome {
  const CollectionBatchDownloadFailed(this.error);

  final Object error;
}

/// 合集 I/O 编排：端口进，类型化结果出。
///
/// 页面每次动作现建一个实例（端口按当时 context 组装）；弹层、文案、触感、
/// 选择清空仍由页面决定。
final class CollectionIoCommands {
  CollectionIoCommands({
    required this._filePicker,
    required this._fileReader,
    required this._importService,
    required this._importTarget,
    required this._playlistNames,
    required this._reviewImport,
    this._linkImporter,
    this._exportLibrary,
    this._backup,
    this._saver,
    this._downloader,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final CollectionPlaylistFilePicker _filePicker;
  final CollectionPlaylistFileReader _fileReader;
  final PlaylistImportService _importService;
  final PlaylistImportTarget _importTarget;

  /// 提交时现读列表名：复核期间用户可能新建过同名列表。
  final Iterable<String> Function() _playlistNames;
  final CollectionImportReview _reviewImport;
  final CollectionLinkImporter? _linkImporter;
  final CollectionExportLibrary? _exportLibrary;
  final CollectionPlaylistBackup? _backup;
  final CollectionExportSaver? _saver;
  final CollectionBatchDownloader? _downloader;
  final DateTime Function() _clock;

  /// M3U / M3U8 / PLS：选文件 → 读文本 → 解析 → 复核 → 创建列表并批量加入。
  ///
  /// [isActive] 由页面传 `mounted` 检查：页面卸载后不再做解析 / 复核 / 写库，
  /// 与原来分段的 `mounted` 守卫同一语义。
  Future<CollectionPlaylistImportOutcome> importPlaylistFile({
    required String dialogTitle,
    bool Function()? isActive,
  }) async {
    final String? path;
    try {
      path = await _filePicker.pick(dialogTitle: dialogTitle);
    } catch (error) {
      return CollectionPlaylistImportFailed(error);
    }
    if (path == null || !(isActive?.call() ?? true)) {
      return const CollectionPlaylistImportCancelled(
        CollectionImportCancelReason.filePick,
      );
    }

    final String text;
    try {
      text = await _fileReader.readText(path);
    } catch (error) {
      return CollectionPlaylistImportFailed(error);
    }
    if (!(isActive?.call() ?? true)) {
      return const CollectionPlaylistImportCancelled(
        CollectionImportCancelReason.abandoned,
      );
    }

    final PlaylistImportPlan plan;
    try {
      final parsed = parsePlaylistFile(
        text,
        fileName: p.basename(path),
        baseDirectory: p.dirname(path),
      );
      if (parsed.entries.isEmpty && parsed.problems.isEmpty) {
        return const CollectionPlaylistImportEmpty();
      }
      plan = await _importService.plan(
        parsed,
        fallbackName: p.basenameWithoutExtension(path),
        addedAt: _clock().millisecondsSinceEpoch,
      );
    } catch (error) {
      return CollectionPlaylistImportFailed(error);
    }
    if (!(isActive?.call() ?? true)) {
      return const CollectionPlaylistImportCancelled(
        CollectionImportCancelReason.abandoned,
      );
    }

    final bool confirmed;
    try {
      confirmed = await _reviewImport(plan);
    } catch (error) {
      return CollectionPlaylistImportFailed(error);
    }
    if (!confirmed || !(isActive?.call() ?? true)) {
      return const CollectionPlaylistImportCancelled(
        CollectionImportCancelReason.review,
      );
    }

    try {
      final result = await _importService.commit(
        plan: plan,
        target: _importTarget,
        existingNames: _playlistNames(),
      );
      return CollectionPlaylistImportDone(
        playlistId: result.playlistId,
        name: result.name,
        added: result.added,
        skipped: result.skipped,
      );
    } catch (error) {
      return CollectionPlaylistImportFailed(error);
    }
  }

  /// 内置平台歌单 / 收藏夹链接导入：拉详情并写入本地列表。
  Future<CollectionLinkImportOutcome> importFromLink({
    required String sourceKey,
    required String rawId,
    required String fallbackName,
  }) async {
    final importer = _linkImporter;
    if (importer == null) {
      return const CollectionLinkImportFailed();
    }
    try {
      final result = await importer.importFromLink(
        sourceKey,
        rawId,
        fallbackName: fallbackName,
      );
      if (result.total == 0) return const CollectionLinkImportEmpty();
      if (result.added == 0) {
        return CollectionLinkImportAlreadyContains(result.playlistId);
      }
      return CollectionLinkImportDone(
        playlistId: result.playlistId,
        added: result.added,
      );
    } catch (error) {
      return CollectionLinkImportFailed(error);
    }
  }

  /// 导出当前列表：M3U8（本机路径 + Molia 键）或 `.molia.json` 全保真文件。
  ///
  /// [dialogTitle] 由页面给（桌面另存对话框标题），命令层不持有 l10n 文案。
  Future<CollectionExportOutcome> exportPlaylist({
    required PlaylistInfo playlist,
    required String displayName,
    required List<PlaylistTrack> tracks,
    required CollectionExportFormat format,
    required String dialogTitle,
  }) async {
    final saver = _saver;
    final library = _exportLibrary;
    if (saver == null || library == null) {
      return const CollectionExportFailed();
    }
    try {
      switch (format) {
        case CollectionExportFormat.m3u8:
          final export = await PlaylistExportBuilder(
            pageUrlOf: library.platformPageUrlOf,
            downloadedRecordOf: library.downloadedRecordOf,
            fileExists: _fileReader.exists,
          ).buildM3u8(name: displayName, tracks: tracks);
          final result = await saver.saveBytes(
            fileName:
                '${sanitizeFileName(displayName, fallback: 'playlist')}.m3u8',
            bytes: Uint8List.fromList(utf8.encode(export.text)),
            mimeType: 'audio/x-mpegurl',
            relativeDir: saveAsExportsDirName,
            dialogTitle: dialogTitle,
          );
          return _exportResultOf(result, missingFiles: export.missingFiles);
        case CollectionExportFormat.molia:
          final backup = _backup;
          if (backup == null) return const CollectionExportFailed();
          final coverKey = await library.ensurePlaylistCoverKey(playlist.id);
          if (coverKey == null) return const CollectionExportFailed();
          // 封面键通常是 `playlist:<syncId>`；不是列表键时沿用原行为直接当
          // syncId 用，避免导出端比同步端多一条拒绝路径。
          final syncId = playlistSyncIdFromCoverKey(coverKey) ?? coverKey;
          final json = await backup.exportPlaylistJson(
            playlistSyncId: syncId,
            coverKey: playlist.effectiveCoverKey ?? coverKey,
          );
          final result = await saver.saveBytes(
            fileName:
                '${sanitizeFileName(displayName, fallback: 'playlist')}.molia.json',
            bytes: Uint8List.fromList(utf8.encode(json)),
            mimeType: 'application/json',
            relativeDir: saveAsExportsDirName,
            dialogTitle: dialogTitle,
          );
          return _exportResultOf(result);
      }
    } catch (error) {
      return CollectionExportFailed(error);
    }
  }

  /// 批量下载：空输入 / 省流取消都不触发批量入口。
  ///
  /// [onEnqueued] 保留批量入口的即时回调（页面据此提示「已入队 N」）；
  /// [onStarted] 在入口成功返回时调用，页面用它清选择（与取消严格区分）。
  Future<CollectionBatchDownloadOutcome> downloadTracks({
    required List<Track> tracks,
    required Future<bool> Function() confirm,
    void Function(int enqueued)? onEnqueued,
    void Function()? onStarted,
  }) async {
    if (tracks.isEmpty) {
      return const CollectionBatchDownloadCancelled();
    }
    final downloader = _downloader;
    if (downloader == null) {
      return CollectionBatchDownloadFailed(StateError('下载服务不可用'));
    }
    try {
      if (!await confirm()) {
        return const CollectionBatchDownloadCancelled();
      }
    } catch (error) {
      return CollectionBatchDownloadFailed(error);
    }
    try {
      final result = await downloader.startBatch(
        tracks,
        onEnqueued: onEnqueued,
      );
      onStarted?.call();
      return CollectionBatchDownloadFinished(
        enqueued: result.enqueued,
        done: result.done,
        failed: result.failed,
      );
    } catch (error) {
      return CollectionBatchDownloadFailed(error);
    }
  }

  CollectionExportOutcome _exportResultOf(
    SaveAsResult result, {
    int missingFiles = 0,
  }) => switch (result) {
    SaveAsSaved(:final displayPath, :final kind) => CollectionExportSaved(
      displayPath: displayPath,
      kind: kind,
      missingFiles: missingFiles,
    ),
    SaveAsCancelled() => const CollectionExportCancelled(),
    SaveAsFailed(:final error) => CollectionExportFailed(error),
  };
}

/// 生产选文件 / 读文本端口：文件选择器 + 本机 UTF-8（容错解码）。
final class FilePickerCollectionPlaylistFiles
    implements CollectionPlaylistFilePicker, CollectionPlaylistFileReader {
  const FilePickerCollectionPlaylistFiles();

  @override
  Future<String?> pick({required String dialogTitle}) async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['m3u', 'm3u8', 'pls'],
      dialogTitle: dialogTitle,
    );
    return files.isEmpty ? null : files.first.path;
  }

  @override
  Future<String> readText(String path) async {
    final bytes = await File(path).readAsBytes();
    return utf8.decode(bytes, allowMalformed: true);
  }

  @override
  Future<bool> exists(String path) => File(path).exists();
}

/// 本机路径导入端口：复用下载服务的导入路径与稳定身份。
final class DownloadRecordsPlaylistLocalImporter
    implements PlaylistLocalImporter {
  const DownloadRecordsPlaylistLocalImporter(this._records, this._downloads);

  final DownloadRecords? _records;
  final DownloadManager? _downloads;

  @override
  Future<PlaylistTrack?> importPath(String path) async {
    final normalized = p.normalize(path);
    final existing = _records?.importedRecordForPath(normalized);
    if (existing != null) {
      return existing.toPlaylistTrack(
        addedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }
    final downloads = _downloads;
    if (downloads == null) return null;
    final (imported, _) = await downloads.importLocalFiles([normalized]);
    if (imported == 0) return null;
    final record = _records?.importedRecordForPath(normalized);
    return record?.toPlaylistTrack(
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }
}

/// `#MOLIA` 键解析：下载记录 → 播放历史 → 库内列表，全部只查本机。
final class LibraryPlaylistKeyResolver implements PlaylistKeyResolver {
  const LibraryPlaylistKeyResolver(this._provider, this._records);

  final LibraryProvider _provider;
  final DownloadRecords? _records;

  @override
  Future<PlaylistTrack?> resolve(String moliaKey) async {
    final split = moliaKey.indexOf(':');
    if (split <= 0 || split >= moliaKey.length - 1) return null;
    final sourceKey = moliaKey.substring(0, split);
    final songId = moliaKey.substring(split + 1);
    final record = _records?.recordFor(sourceKey, songId);
    if (record != null) {
      return record.toPlaylistTrack(
        addedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }
    return _provider.findTrackByKey(sourceKey, songId);
  }
}

/// 导入执行端口：只经 provider 的公开写入口；失败交给服务清理空列表。
final class LibraryProviderPlaylistImportTarget
    implements PlaylistImportTarget {
  const LibraryProviderPlaylistImportTarget(this._provider);

  final LibraryProvider _provider;

  @override
  Future<int> createPlaylist(String name) => _provider.createPlaylist(name);

  @override
  Future<int> addTracks(int playlistId, List<PlaylistTrack> tracks) async {
    final outcome = await _provider.addTracksToPlaylist(playlistId, tracks);
    if (outcome.isFailure) throw outcome.error ?? StateError('add failed');
    return outcome.changed;
  }

  @override
  Future<void> deletePlaylist(int playlistId) async {
    final outcome = await _provider.deletePlaylist(playlistId);
    if (outcome.isFailure) throw outcome.error ?? StateError('delete failed');
  }
}

/// [CollectionExportLibrary] 的生产实现：转发资料库 / 下载记录读取。
final class LibraryProviderCollectionExportLibrary
    implements CollectionExportLibrary {
  const LibraryProviderCollectionExportLibrary(this._provider, this._records);

  final LibraryProvider _provider;
  final DownloadRecords? _records;

  @override
  String? platformPageUrlOf(PlaylistTrack track) =>
      _provider.trackFromPlaylistTrack(track).platformPageUrl;

  @override
  DownloadedTrack? downloadedRecordOf(PlaylistTrack track) =>
      _records?.recordFor(track.sourceKey, track.songId);

  @override
  Future<String?> ensurePlaylistCoverKey(int playlistId) =>
      _provider.ensurePlaylistCoverKey(playlistId);
}

/// [CollectionPlaylistBackup] 的生产实现：同步引擎的全保真导出。
final class SyncCollectionPlaylistBackup implements CollectionPlaylistBackup {
  const SyncCollectionPlaylistBackup(this._sync);

  final SyncProvider _sync;

  @override
  Future<String> exportPlaylistJson({
    required String playlistSyncId,
    String? coverKey,
  }) => _sync.commands.backup.exportPlaylistJson(
    playlistSyncId: playlistSyncId,
    coverKey: coverKey,
  );
}

/// [CollectionExportSaver] 的生产实现：转发另存服务。
final class SaveAsCollectionExportSaver implements CollectionExportSaver {
  const SaveAsCollectionExportSaver(this._saveAs);

  final SaveAs _saveAs;

  @override
  Future<SaveAsResult> saveBytes({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String relativeDir = '',
    String? dialogTitle,
  }) => _saveAs.saveBytes(
    fileName: fileName,
    bytes: bytes,
    mimeType: mimeType,
    relativeDir: relativeDir,
    dialogTitle: dialogTitle,
  );
}

/// [CollectionBatchDownloader] 的生产实现：转发下载意图入口。
final class LauncherCollectionBatchDownloader
    implements CollectionBatchDownloader {
  const LauncherCollectionBatchDownloader(this._launcher);

  final DownloadLauncher _launcher;

  @override
  Future<DownloadBatchStart> startBatch(
    List<Track> tracks, {
    void Function(int enqueued)? onEnqueued,
  }) => _launcher.startBatch(tracks, onEnqueued: onEnqueued);
}

/// [CollectionLinkImporter] 的生产实现：转发发现页的链接导入。
final class DiscoverCollectionLinkImporter implements CollectionLinkImporter {
  const DiscoverCollectionLinkImporter(this._discover);

  final DiscoverProvider _discover;

  @override
  Future<({int playlistId, int added, int total})> importFromLink(
    String sourceKey,
    String rawId, {
    required String fallbackName,
  }) => _discover.importPlaylistFromLink(
    sourceKey,
    rawId,
    fallbackName: fallbackName,
  );
}
