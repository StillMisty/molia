/// 应用数据目录的唯一解析入口（数据库 / 缓存 / 用户数据 / 日志 / 锁文件）。
///
/// **Windows 规范**：本机、当前用户、不随账号漫游、可能很大的数据（SQLite、
/// 缓存、下载记录、日志、会话）放 LocalAppData；Roaming 只放小的用户偏好
/// （设置仍在 SharedPreferences 的 Roaming 目录）。
///
/// 其余平台继续用应用支持目录：它是本机持久目录，不会被系统当缓存清理。
/// Windows 新目录 = `getApplicationCacheDirectory()`（path_provider 返回
/// `%LOCALAPPDATA%\top.stillmisty\molia`），旧目录 = 应用支持目录
/// （`%APPDATA%\top.stillmisty\molia`）。迁移只复制用户数据，不复制可丢弃的
/// 缓存，也不删除旧目录（保留作回退 / 备份）。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final Logger _logger = Logger('molia.app_data');

bool _usesSeparateLegacyDirectory(TargetPlatform platform) =>
    !kIsWeb && platform == TargetPlatform.windows;

/// 是否存在与新版数据目录不同的旧目录（仅 Windows）。
bool get hasSeparateLegacyDirectory =>
    _usesSeparateLegacyDirectory(defaultTargetPlatform);

/// 应用数据目录（新位置）。
///
/// [platform] / [windowsDirectory] / [supportDirectory] 仅测试注入目录解析
/// （生产不传）。
Future<Directory> appDataDirectory({
  TargetPlatform? platform,
  Future<Directory> Function()? windowsDirectory,
  Future<Directory> Function()? supportDirectory,
}) async {
  final support = supportDirectory ?? getApplicationSupportDirectory;
  if (!_usesSeparateLegacyDirectory(platform ?? defaultTargetPlatform)) {
    return support();
  }
  try {
    return await (windowsDirectory ?? getApplicationCacheDirectory)();
  } catch (e) {
    // LocalAppData 不可用（受限环境 / 平台异常）：退回旧目录，至少能启动。
    _logger.warning('LocalAppData 不可用，回退应用支持目录：$e');
    return support();
  }
}

/// 旧版应用支持目录（Windows = Roaming）；非 Windows / 不可用返回 null。
///
/// [platform] / [supportDirectory] 仅测试注入。
Future<Directory?> legacyAppDataDirectory({
  TargetPlatform? platform,
  Future<Directory> Function()? supportDirectory,
}) async {
  if (!_usesSeparateLegacyDirectory(platform ?? defaultTargetPlatform)) {
    return null;
  }
  try {
    return await (supportDirectory ?? getApplicationSupportDirectory)();
  } catch (e) {
    _logger.warning('读取旧应用支持目录失败：$e');
    return null;
  }
}

/// 主库迁移：旧目录有库、新目录没有时，把 DB + `-wal` + `-shm` 复制到新目录。
///
/// 先复制到临时名，再按「wal / shm → 主库」的顺序 rename：主库最后出现，
/// 进程在任意一步被杀，下次启动只要看不到新主库就会重试。旧文件保留，
/// 复制失败也不能让应用打不开库——调用方回退旧目录并在下次启动重试。
Future<bool> migrateLegacyDatabaseFile({
  required Directory targetDirectory,
  required Directory legacyDirectory,
  required String fileName,
}) async {
  if (_sameDirectory(targetDirectory, legacyDirectory)) return true;
  final source = File(p.join(legacyDirectory.path, '$fileName.sqlite'));
  final target = File(p.join(targetDirectory.path, '$fileName.sqlite'));
  if (!await _exists(source) || await _exists(target)) return true;

  final suffix = '.migrating-${DateTime.now().microsecondsSinceEpoch}';
  File temp(String path) => File('$path$suffix');
  final sourceWal = File('${source.path}-wal');
  final sourceShm = File('${source.path}-shm');
  final targetWal = File('${target.path}-wal');
  final targetShm = File('${target.path}-shm');
  final tempWal = temp(targetWal.path);
  final tempShm = temp(targetShm.path);
  final tempDb = temp(target.path);

  try {
    await targetDirectory.create(recursive: true);
    await source.copy(tempDb.path);
    if (await _exists(sourceWal)) await sourceWal.copy(tempWal.path);
    if (await _exists(sourceShm)) await sourceShm.copy(tempShm.path);

    // sidecar 先就位、主库最后 rename：只要主库存在，配对的 WAL 已经完整。
    if (await _exists(tempWal)) await tempWal.rename(targetWal.path);
    if (await _exists(tempShm)) await tempShm.rename(targetShm.path);
    await tempDb.rename(target.path);
    _logger.info('本地数据库已迁移到 LocalAppData：${target.path}');
    return true;
  } catch (e) {
    _logger.warning('本地数据库迁移失败（继续使用旧目录）：$e');
    for (final file in [tempDb, tempWal, tempShm, targetWal, targetShm]) {
      await _deleteQuietly(file);
    }
    return false;
  }
}

/// 复制旧目录里的一个文件到新目录（目标不存在时）；返回是否可继续使用新路径。
Future<bool> migrateLegacyFileIfNeeded({
  required Directory targetDirectory,
  required String relativePath,
  Directory? legacyDirectory,
}) async {
  final legacy = legacyDirectory ?? await legacyAppDataDirectory();
  if (legacy == null || _sameDirectory(targetDirectory, legacy)) return true;
  final source = File(p.join(legacy.path, relativePath));
  final target = File(p.join(targetDirectory.path, relativePath));
  if (!await _exists(source) || await _exists(target)) return true;
  try {
    await target.parent.create(recursive: true);
    final temp = File('${target.path}.migrating');
    await source.copy(temp.path);
    await temp.rename(target.path);
    _logger.info('用户数据已迁移到 LocalAppData：$relativePath');
    return true;
  } catch (e) {
    _logger.warning('迁移用户数据失败（保留旧文件）：$relativePath：$e');
    return false;
  }
}

/// 复制旧目录树到新目录（已存在的文件跳过，不覆盖新数据）。
///
/// 返回是否全部复制成功；失败时已复制的文件保留，调用方据此决定是否改写
/// 索引路径（不能把索引指向不存在的文件）。
Future<bool> migrateLegacyDirectoryIfNeeded({
  required Directory targetDirectory,
  required String relativePath,
  Directory? legacyDirectory,
}) async {
  final legacy = legacyDirectory ?? await legacyAppDataDirectory();
  if (legacy == null || _sameDirectory(targetDirectory, legacy)) return true;
  final source = Directory(p.join(legacy.path, relativePath));
  final target = Directory(p.join(targetDirectory.path, relativePath));
  if (!await source.exists()) return true;
  var ok = true;
  try {
    await target.create(recursive: true);
    await for (final entity in source.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final relative = p.relative(entity.path, from: source.path);
      final destination = File(p.join(target.path, relative));
      if (await _exists(destination)) continue;
      try {
        await destination.parent.create(recursive: true);
        await entity.copy(destination.path);
      } catch (e) {
        ok = false;
        _logger.warning('迁移目录文件失败：${entity.path}：$e');
      }
    }
    if (ok) _logger.info('用户数据目录已迁移到 LocalAppData：$relativePath');
    return ok;
  } catch (e) {
    _logger.warning('迁移用户数据目录失败（保留旧目录）：$relativePath：$e');
    return false;
  }
}

bool _sameDirectory(Directory a, Directory b) =>
    p.normalize(p.absolute(a.path)) == p.normalize(p.absolute(b.path));

Future<bool> _exists(File file) async {
  try {
    return await file.exists();
  } catch (_) {
    return false;
  }
}

Future<void> _deleteQuietly(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {
    // 清理临时文件失败不影响回退：下次启动会按主库缺失重试。
  }
}
