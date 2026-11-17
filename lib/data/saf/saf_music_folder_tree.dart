/// SAF 树枚举端口实现：locator 原样是 `content://` 文档 URI。
library;

import '../../domain/ports/music_folder_tree.dart';
import '../files/local_locator.dart';
import 'saf_bridge.dart';

class SafMusicFolderTree implements MusicFolderTree {
  SafMusicFolderTree(this._bridge);

  final SafBridge _bridge;

  @override
  Future<String?> displayName(String root) async {
    final stat = await _safeStat(root);
    if (stat != null && stat.displayName.trim().isNotEmpty) {
      return stat.displayName;
    }
    return contentDisplayNameOf(root);
  }

  @override
  Future<FolderTreeEntry?> stat(
    String locator, {
    String relativePath = '',
  }) async {
    final stat = await _safeStat(locator);
    if (stat == null) return null;
    return FolderTreeEntry(
      locator: locator,
      canonicalLocator: locator,
      displayName: stat.displayName.isNotEmpty
          ? stat.displayName
          : (contentDisplayNameOf(locator) ?? ''),
      relativePath: relativePath,
      isDirectory: stat.isDirectory,
      sizeBytes: stat.sizeBytes,
      mtimeMs: stat.mtimeMs,
    );
  }

  @override
  Future<String> canonicalLocator(String locator) async => locator;

  @override
  Stream<FolderTreeEvent> walk(
    String root, {
    int maxDepth = 32,
    bool Function()? isCancelled,
  }) async* {
    final SafDocument? rootStat;
    try {
      rootStat = await _bridge.stat(root);
    } on SafBridgeException catch (e) {
      throw FolderTreeUnavailable(
        permissionDenied: e.kind == SafFailureKind.permissionDenied,
        cause: e,
      );
    }
    if (rootStat == null || !rootStat.isDirectory) {
      throw const FolderTreeUnavailable(permissionDenied: false);
    }
    try {
      await for (final event in _bridge.listTree(
        root,
        maxDepth: maxDepth,
        isCancelled: isCancelled,
      )) {
        switch (event) {
          case SafTreeEntry entry:
            yield FolderTreeEntryFound(
              FolderTreeEntry(
                locator: entry.uri,
                canonicalLocator: entry.uri,
                displayName: entry.displayName,
                relativePath: entry.relativePath,
                isDirectory: entry.isDirectory,
                sizeBytes: entry.sizeBytes,
                mtimeMs: entry.mtimeMs,
              ),
            );
          case SafTreeSkipped(:final reason):
            yield FolderTreeSkipped(_skipReason(reason));
        }
      }
    } on SafBridgeException catch (e) {
      // 遍历中途整个树失效（权限撤销 / provider 掉线）：整轮作废，
      // 调用方不会把它名下的记录标缺失。
      throw FolderTreeUnavailable(
        permissionDenied: e.kind == SafFailureKind.permissionDenied,
        cause: e,
      );
    }
  }

  Future<SafDocument?> _safeStat(String uri) async {
    try {
      return await _bridge.stat(uri);
    } on SafBridgeException {
      return null;
    }
  }

  static FolderTreeSkipReason _skipReason(String reason) => switch (reason) {
    'hidden' => FolderTreeSkipReason.hidden,
    'depthExceeded' => FolderTreeSkipReason.depthExceeded,
    'symlinkCycle' => FolderTreeSkipReason.symlinkCycle,
    _ => FolderTreeSkipReason.unreadable,
  };
}
