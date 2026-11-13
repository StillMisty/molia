/// 本地曲库的编排层：音乐文件夹配置 + 扫描 + 监听 + 缺文件检查。
///
/// 页面只跟这个模块交互（开始 / 取消 / 进度 / 摘要），不直接拼扫描器与
/// 监听器；设备本地状态（模式、智能列表）仍由 UI 持有。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../download/missing_file_probe.dart';
import 'music_folder_scanner.dart';
import 'music_folder_watcher.dart';
import 'music_folders.dart';

class LocalLibraryService extends ChangeNotifier {
  LocalLibraryService({
    required this.folders,
    required this.scanner,
    required this.probe,
    required this.watcher,
    bool Function()? canWatch,
  }) : _canWatch = canWatch ?? _defaultCanWatch;

  final MusicFoldersStore folders;
  final MusicFolderScanner scanner;
  final MissingFileProbe probe;
  final MusicFolderWatcher watcher;
  final bool Function() _canWatch;

  static bool _defaultCanWatch() =>
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS;

  bool _initialized = false;
  bool _scanning = false;
  String? _scanningFolderId;
  ScanProgress? _progress;
  ScanCancellation? _cancellation;

  bool get initialized => _initialized;
  bool get scanning => _scanning;
  String? get scanningFolderId => _scanningFolderId;
  ScanProgress? get progress => _progress;
  bool get canWatchFolders => _canWatch();

  Future<void> init() async {
    if (_initialized) return;
    await folders.load();
    _initialized = true;
    notifyListeners();
  }

  Future<MusicFolderAddResult> addFolder(String path) async {
    final result = await folders.add(path);
    if (result == MusicFolderAddResult.added) {
      final added = folders.folders.last;
      await scanFolder(added.id);
    }
    return result;
  }

  Future<void> removeFolder(String id) async {
    if (_scanningFolderId == id) _cancellation?.cancel();
    await folders.remove(id);
    final roots = [for (final folder in folders.folders) folder.root];
    await watcher.stop();
    watcher.start(roots);
    notifyListeners();
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

  Future<void> scanAll() => _run(folders.folders);

  /// 启动 idle 尾巴：加载配置 → 顺序扫描 → 监听（失败静默降级）。
  Future<void> startAfterFirstFrame() async {
    await init();
    await scanAll();
    if (canWatchFolders) {
      watcher.start([for (final folder in folders.folders) folder.root]);
    }
  }

  /// 显式「检查文件」（设置页 / 缺文件列表入口）。
  Future<MissingProbeResult> checkFiles() => probe.probeAll();

  void cancelScan() => _cancellation?.cancel();

  Future<void> _run(Iterable<MusicFolder> targets) async {
    if (_scanning || targets.isEmpty) return;
    _scanning = true;
    _cancellation = ScanCancellation();
    try {
      for (final folder in targets) {
        if (_cancellation!.isCancelled) break;
        _scanningFolderId = folder.id;
        _progress = ScanProgress(processed: 0, directory: folder.root);
        notifyListeners();
        final outcome = await scanner.scan(
          folder.root,
          cancellation: _cancellation,
          onProgress: (progress) {
            _progress = progress;
            notifyListeners();
          },
        );
        await folders.setLastScan(
          folder.id,
          MusicFolderScanSummary(
            added: outcome.added,
            updated: outcome.updated,
            skipped: outcome.skipped,
            cancelled: outcome.cancelled,
            unavailable: outcome.unavailable,
            scannedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
      // 扫描成功后再做一轮批量探测（同一串行入口，避免互相覆盖）。
      await probe.probeAll();
    } finally {
      _scanning = false;
      _scanningFolderId = null;
      _progress = null;
      _cancellation = null;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    unawaited(watcher.stop());
    super.dispose();
  }
}
