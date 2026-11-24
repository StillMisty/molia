/// 本地曲库的编排层：音乐文件夹配置 + 扫描 + 监听 + 缺文件检查。
///
/// 页面只跟这个模块交互（开始 / 取消 / 进度 / 摘要），不直接拼扫描器与
/// 监听器；设备本地状态（模式、智能列表）仍由 UI 持有。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/files/local_locator.dart';
import '../../providers/snapshot_source.dart';
import '../download/missing_file_probe.dart';
import 'music_folder_scanner.dart';
import 'music_folder_watcher.dart';
import 'music_folders.dart';

/// 本地曲库服务对 UI 暴露的不可变快照（扫描进度不在其中）。
///
/// 扫描进度是高频数据，走 [LocalLibraryService.progressListenable]：页面只为
/// 那一行（或那一枚计数器）重建，扫描对象 / 文件夹列表变化才换快照。
@immutable
class LocalLibraryServiceState {
  const LocalLibraryServiceState({
    required this.initialized,
    required this.scanning,
    required this.scanningFolderId,
    required this.folders,
    required this.canWatchFolders,
    required this.canScanOnStartup,
    required this.canAddFolder,
  });

  final bool initialized;
  final bool scanning;

  /// 正在扫描的文件夹 id（未扫描时为空）。
  final String? scanningFolderId;

  /// 已配置的音乐文件夹（不可变列表）。
  final List<MusicFolder> folders;

  final bool canWatchFolders;
  final bool canScanOnStartup;
  final bool canAddFolder;
}

class LocalLibraryService implements SnapshotSource<LocalLibraryServiceState> {
  LocalLibraryService({
    required this.folders,
    required this.scanner,
    required this.probe,
    required this.watcher,
    bool? canWatch,
    bool? canScanOnStartup,
    bool? canAddFolder,
  }) : _canWatch = canWatch ?? _defaultCanWatch(),
       _canScanOnStartup = canScanOnStartup ?? _defaultCanScanOnStartup(),
       _canAddFolder = canAddFolder ?? _defaultCanAddFolder();

  final MusicFoldersStore folders;
  final MusicFolderScanner scanner;
  final MissingFileProbe probe;
  final MusicFolderWatcher watcher;
  final bool _canWatch;
  final bool _canScanOnStartup;
  final bool _canAddFolder;

  static bool _defaultCanWatch() => _isDesktop;

  /// 启动扫描只在桌面：Android 明确要求手动 / 中断续扫，iOS 不提供目录。
  static bool _defaultCanScanOnStartup() => _isDesktop;

  static bool _defaultCanAddFolder() =>
      _isDesktop || defaultTargetPlatform == TargetPlatform.android;

  static bool get _isDesktop =>
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS;

  bool _initialized = false;
  bool _scanning = false;
  String? _scanningFolderId;
  ScanCancellation? _cancellation;
  bool _disposed = false;

  final SnapshotSignal _changes = SnapshotSignal();

  /// 高频扫描进度通道（`null` = 未在扫描）；不进入快照。
  final ValueNotifier<ScanProgress?> _progressListenable =
      ValueNotifier<ScanProgress?>(null);

  bool get initialized => _initialized;
  bool get scanning => _scanning;
  String? get scanningFolderId => _scanningFolderId;
  bool get canWatchFolders => _canWatch;
  bool get canScanOnStartup => _canScanOnStartup;
  bool get canAddFolder => _canAddFolder;

  /// 当前扫描进度（未扫描时为 null）。
  ScanProgress? get progress => _progressListenable.value;

  /// 进度订阅面：只有扫描进度行订阅它。
  ValueListenable<ScanProgress?> get progressListenable => _progressListenable;

  @override
  LocalLibraryServiceState get state => LocalLibraryServiceState(
    initialized: _initialized,
    scanning: _scanning,
    scanningFolderId: _scanningFolderId,
    folders: List<MusicFolder>.unmodifiable(folders.folders),
    canWatchFolders: _canWatch,
    canScanOnStartup: _canScanOnStartup,
    canAddFolder: _canAddFolder,
  );

  @override
  Listenable get changes => _changes;

  void _publishProgress(ScanProgress? progress) {
    if (!_disposed) _progressListenable.value = progress;
  }

  Future<void> init() async {
    if (_initialized) return;
    await folders.load();
    _initialized = true;
    _changes.notify();
  }

  Future<MusicFolderAddResult> addFolder(String locator) async {
    if (!_canAddFolder) return MusicFolderAddResult.invalid;
    // provider 显示名在添加时就取一次；取不到先存 null，扫描时再补。
    final displayName = isContentLocator(locator)
        ? await _displayNameOf(locator)
        : null;
    final result = await folders.add(locator, displayName: displayName);
    if (result != MusicFolderAddResult.added) return result;
    final added = folders.folders.last;
    final outcome = await _run([added]);
    if (outcome?.unavailable ?? false) {
      // 选中的树无法枚举：不保留一个永远读不到的条目。
      await folders.remove(added.id);
      return MusicFolderAddResult.unreadable;
    }
    return result;
  }

  Future<void> removeFolder(String id) async {
    if (_scanningFolderId == id) _cancellation?.cancel();
    await folders.remove(id);
    await watcher.stop();
    watcher.start([
      for (final folder in folders.folders)
        if (!isContentLocator(folder.root)) folder.root,
    ]);
    _changes.notify();
  }

  Future<void> scanFolder(String id) async {
    if (_scanning) return;
    MusicFolder? folder;
    for (final candidate in folders.folders) {
      if (candidate.id == id) {
        folder = candidate;
        break;
      }
    }
    if (folder == null) return;
    await _run([folder]);
  }

  Future<void> scanAll() async {
    await _run(folders.folders);
  }

  /// 监听事件：能定位到路径时只 stat 这些路径；否则整树增量。
  Future<void> scanEventPaths(Set<String>? paths) async {
    if (paths == null || paths.isEmpty) {
      await scanAll();
      return;
    }
    for (final folder in folders.folders) {
      if (isContentLocator(folder.root)) continue;
      final matched = {
        for (final path in paths)
          if (isLocatorUnder(folder.root, path)) path,
      };
      if (matched.isEmpty) continue;
      await scanner.scanPaths(folder.root, matched);
    }
  }

  /// 启动 idle 尾巴：加载配置 → 顺序扫描 → 监听（失败静默降级）。
  Future<void> startAfterFirstFrame() async {
    await init();
    // 桌面顺序扫描（扫描收尾自带一轮探测）；Android / iOS 不静默扫描，
    // 至少执行一次空闲缺文件探测；没有任何文件夹时也必须探测。
    if (_canScanOnStartup) {
      await scanAll();
    }
    if (!_canScanOnStartup || folders.folders.isEmpty) {
      await probe.probeAll();
    }
    if (canWatchFolders) {
      watcher.start([
        for (final folder in folders.folders)
          if (!isContentLocator(folder.root)) folder.root,
      ]);
    }
  }

  /// 显式「检查文件」（设置页 / 缺文件列表入口）。
  Future<MissingProbeResult> checkFiles() => probe.probeAll();

  void cancelScan() => _cancellation?.cancel();

  Future<FolderScanOutcome?> _run(Iterable<MusicFolder> targets) async {
    if (_scanning || targets.isEmpty) return null;
    _scanning = true;
    _cancellation = ScanCancellation();
    FolderScanOutcome? lastOutcome;
    var anyUnavailable = false;
    try {
      for (final folder in targets) {
        if (_cancellation!.isCancelled) break;
        _scanningFolderId = folder.id;
        _publishProgress(ScanProgress(processed: 0, directory: folder.root));
        _changes.notify();
        final outcome = await scanner.scan(
          folder.root,
          cancellation: _cancellation,
          onProgress: _publishProgress,
        );
        lastOutcome = outcome;
        if (outcome.unavailable) anyUnavailable = true;
        if (isContentLocator(folder.root)) {
          final displayName = await _displayNameOf(folder.root);
          if (displayName != null) {
            await folders.setDisplayName(folder.id, displayName);
          }
        }
        await folders.setLastScan(
          folder.id,
          MusicFolderScanSummary(
            added: outcome.added,
            updated: outcome.updated,
            skipped: outcome.skipped,
            cancelled: outcome.cancelled,
            unavailable: outcome.unavailable,
            accessRevoked: outcome.accessRevoked,
            scannedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
      // 扫描成功后再做一轮批量探测（同一串行入口，避免互相覆盖）。
      // 有根不可用（离线卷 / SAF 授权撤销）时跳过：容器状态未知，不能据此
      // 把记录标成缺失。
      if (!anyUnavailable) await probe.probeAll();
    } finally {
      _scanning = false;
      _scanningFolderId = null;
      _publishProgress(null);
      _cancellation = null;
      _changes.notify();
    }
    return lastOutcome;
  }

  Future<String?> _displayNameOf(String root) async {
    try {
      return await scanner.displayName(root);
    } catch (_) {
      // provider 查询失败只损失标题；扫描会再试。
      return null;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(watcher.stop());
    _progressListenable.dispose();
  }
}
