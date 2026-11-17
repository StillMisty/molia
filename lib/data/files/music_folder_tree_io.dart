/// `dart:io` 的文件夹树实现：桌面完整保留原有扫描规则。
///
/// - 深度上限（默认 32）与符号链接环检测；
/// - 隐藏文件 / 目录跳过；
/// - 每个目录按 locator 排序后再处理，保证同一棵树的顺序确定；
/// - 符号链接文件保存第一次发现的链接路径，`canonicalLocator` 用于去重。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/ports/music_folder_tree.dart';

class IoMusicFolderTree implements MusicFolderTree {
  IoMusicFolderTree({Stream<FileSystemEntity> Function(Directory)? lister})
    : _lister = lister ?? _defaultLister;

  /// 目录枚举 seam（测试注入不可读根 / 权限失败）。
  final Stream<FileSystemEntity> Function(Directory directory) _lister;

  static Stream<FileSystemEntity> _defaultLister(Directory directory) =>
      directory.list(followLinks: false);

  @override
  Future<String?> displayName(String root) async {
    final name = p.basename(p.normalize(root));
    return name.isEmpty ? null : name;
  }

  @override
  Future<FolderTreeEntry?> stat(
    String locator, {
    String relativePath = '',
  }) async {
    try {
      final type = await FileSystemEntity.type(locator);
      if (type == FileSystemEntityType.notFound) return null;
      if (type == FileSystemEntityType.directory) {
        return FolderTreeEntry(
          locator: locator,
          canonicalLocator: locator,
          displayName: p.basename(locator),
          relativePath: relativePath,
          isDirectory: true,
        );
      }
      final file = File(locator);
      final canonical = await file.resolveSymbolicLinks();
      final canonicalStat = await File(canonical).stat();
      return FolderTreeEntry(
        locator: locator,
        canonicalLocator: canonical,
        displayName: p.basename(locator),
        relativePath: relativePath,
        isDirectory: false,
        sizeBytes: canonicalStat.size,
        mtimeMs: canonicalStat.modified.millisecondsSinceEpoch,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String> canonicalLocator(String locator) =>
      Directory(locator).resolveSymbolicLinks();

  @override
  Stream<FolderTreeEvent> walk(
    String root, {
    int maxDepth = 32,
    bool Function()? isCancelled,
  }) async* {
    final rootDir = Directory(root);
    if (!await rootDir.exists()) {
      throw const FolderTreeUnavailable(permissionDenied: false);
    }
    final String rootCanonical;
    try {
      rootCanonical = p.normalize(await rootDir.resolveSymbolicLinks());
    } catch (e) {
      throw FolderTreeUnavailable(permissionDenied: false, cause: e);
    }
    final visited = <String>{rootCanonical};
    yield* _walkDirectory(
      rootDir,
      relativePath: '',
      depth: 0,
      maxDepth: maxDepth,
      visited: visited,
      isCancelled: isCancelled,
    );
  }

  Stream<FolderTreeEvent> _walkDirectory(
    Directory directory, {
    required String relativePath,
    required int depth,
    required int maxDepth,
    required Set<String> visited,
    required bool Function()? isCancelled,
  }) async* {
    if (isCancelled?.call() == true) return;
    final List<FileSystemEntity> entries;
    try {
      entries = await _lister(directory).toList();
    } catch (_) {
      // 根目录枚举失败交给 walk 的调用方（scanner）当作 unavailable；
      // 子目录失败只跳过该子树。
      if (depth == 0) {
        // 桌面没有「持久授权」概念：根不可读只按暂时不可用处理。
        throw const FolderTreeUnavailable(permissionDenied: false);
      }
      yield const FolderTreeSkipped(FolderTreeSkipReason.unreadable);
      return;
    }
    entries.sort((a, b) => a.path.compareTo(b.path));
    for (final entity in entries) {
      if (isCancelled?.call() == true) return;
      final name = p.basename(entity.path);
      if (name.startsWith('.')) {
        yield const FolderTreeSkipped(FolderTreeSkipReason.hidden);
        continue;
      }
      final childRelative = relativePath.isEmpty ? name : '$relativePath/$name';
      if (entity is Directory) {
        if (depth + 1 > maxDepth) {
          yield const FolderTreeSkipped(FolderTreeSkipReason.depthExceeded);
          continue;
        }
        String canonical;
        try {
          canonical = p.normalize(await entity.resolveSymbolicLinks());
        } catch (_) {
          yield const FolderTreeSkipped(FolderTreeSkipReason.unreadable);
          continue;
        }
        if (!visited.add(canonical)) {
          yield const FolderTreeSkipped(FolderTreeSkipReason.symlinkCycle);
          continue;
        }
        yield FolderTreeEntryFound(
          FolderTreeEntry(
            locator: entity.path,
            canonicalLocator: canonical,
            displayName: name,
            relativePath: childRelative,
            isDirectory: true,
          ),
        );
        yield* _walkDirectory(
          entity,
          relativePath: childRelative,
          depth: depth + 1,
          maxDepth: maxDepth,
          visited: visited,
          isCancelled: isCancelled,
        );
        continue;
      }
      if (entity is Link) {
        final String resolved;
        try {
          resolved = await entity.resolveSymbolicLinks();
        } catch (_) {
          yield const FolderTreeSkipped(FolderTreeSkipReason.unreadable);
          continue;
        }
        final type = await FileSystemEntity.type(resolved, followLinks: true);
        if (type == FileSystemEntityType.directory) {
          if (depth + 1 > maxDepth) {
            yield const FolderTreeSkipped(FolderTreeSkipReason.depthExceeded);
            continue;
          }
          final canonical = p.normalize(resolved);
          if (!visited.add(canonical)) {
            yield const FolderTreeSkipped(FolderTreeSkipReason.symlinkCycle);
            continue;
          }
          yield FolderTreeEntryFound(
            FolderTreeEntry(
              locator: entity.path,
              canonicalLocator: canonical,
              displayName: name,
              relativePath: childRelative,
              isDirectory: true,
            ),
          );
          yield* _walkDirectory(
            Directory(resolved),
            relativePath: childRelative,
            depth: depth + 1,
            maxDepth: maxDepth,
            visited: visited,
            isCancelled: isCancelled,
          );
          continue;
        }
        yield* _fileEntry(
          entity.path,
          canonicalLocator: resolved,
          displayName: name,
          relativePath: childRelative,
        );
        continue;
      }
      yield* _fileEntry(
        entity.path,
        displayName: name,
        relativePath: childRelative,
      );
    }
  }

  Stream<FolderTreeEvent> _fileEntry(
    String locator, {
    String? canonicalLocator,
    required String displayName,
    required String relativePath,
  }) async* {
    try {
      final canonical = p.normalize(
        canonicalLocator ?? await File(locator).resolveSymbolicLinks(),
      );
      final stat = await File(canonical).stat();
      yield FolderTreeEntryFound(
        FolderTreeEntry(
          locator: locator,
          canonicalLocator: canonical,
          displayName: displayName,
          relativePath: relativePath,
          isDirectory: false,
          sizeBytes: stat.size,
          mtimeMs: stat.modified.millisecondsSinceEpoch,
        ),
      );
    } catch (_) {
      yield const FolderTreeSkipped(FolderTreeSkipReason.unreadable);
    }
  }
}
