/// 应用数据目录的唯一解析入口（数据库 / 缓存 / 用户数据 / 日志 / 锁文件）。
///
/// **Windows 规范**：本机、当前用户、不随账号漫游、可能很大的数据（SQLite、
/// 缓存、下载记录、日志、会话、单实例锁）放 LocalAppData；Roaming 只放小的
/// 用户偏好（设置仍在 SharedPreferences 的 Roaming 目录）。旧 Roaming 锁只在
/// 升级守卫里读取一次，不是主锁路径。
///
/// 其余平台继续用应用支持目录：它是本机持久目录，不会被系统当缓存清理。
/// Windows 新目录 = `getApplicationCacheDirectory()`（path_provider 返回
/// `%LOCALAPPDATA%\top.stillmisty\molia`），旧目录 = 应用支持目录
/// （`%APPDATA%\top.stillmisty\molia`）。用户数据与缓存目录迁移，旧目录保留
/// 作回退 / 备份；缓存优先整体 rename，避免已缓存音频被重新下载。
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

/// 缓存目录名（音频 / 封面 / 歌词）：Windows 升级时移动 / 合并到新目录。
const List<String> legacyCacheDirectoryNames = [
  'audio_cache',
  'artwork_cache',
  'lyrics_cache',
];

/// Windows 升级：把旧 Roaming 缓存目录移到 LocalAppData。
///
/// 为什么缓存也要迁移：音频缓存里是整首已下载的音频（FLAC 24–40MB）。只换
/// 路径不迁移会让 `localUriFor` 未命中并重新下载整首，形成持续写盘 / 流量
/// 回归。目标目录不存在时优先 `Directory.rename`（同卷零内容写），失败才
/// 回退逐个复制；目标已存在时只补齐缺失文件（优先 rename，失败 copy），
/// 不覆盖新数据。幂等、失败只日志，绝不阻断启动。
///
/// [moveDirectory] / [moveFile] 仅测试注入；生产使用真实 rename。
Future<bool> migrateLegacyCacheDirectories({
  Directory? targetDirectory,
  Directory? legacyDirectory,
  TargetPlatform? platform,
  Future<void> Function(Directory source, String targetPath)? moveDirectory,
  Future<void> Function(File source, String targetPath)? moveFile,
}) async {
  if (!_usesSeparateLegacyDirectory(platform ?? defaultTargetPlatform)) {
    return true;
  }
  final target = targetDirectory ?? await appDataDirectory(platform: platform);
  final legacy =
      legacyDirectory ?? await legacyAppDataDirectory(platform: platform);
  if (legacy == null || _sameDirectory(target, legacy)) return true;

  final moveDir = moveDirectory ??
      (source, targetPath) => source.rename(targetPath);
  final move = moveFile ?? (source, targetPath) => source.rename(targetPath);
  var ok = true;
  for (final name in legacyCacheDirectoryNames) {
    if (!await _migrateLegacyCacheDirectory(
      source: Directory(p.join(legacy.path, name)),
      target: Directory(p.join(target.path, name)),
      moveDirectory: moveDir,
      moveFile: move,
    )) {
      ok = false;
    }
  }
  return ok;
}

Future<bool> _migrateLegacyCacheDirectory({
  required Directory source,
  required Directory target,
  required Future<void> Function(Directory source, String targetPath)
      moveDirectory,
  required Future<void> Function(File source, String targetPath) moveFile,
}) async {
  try {
    if (!await source.exists()) return true;
    if (!await target.exists()) {
      try {
        await target.parent.create(recursive: true);
        // 同卷整体移动：只改目录项，不重写几十 MB 缓存内容。
        await moveDirectory(source, target.path);
        _logger.info('缓存目录已整体迁移：${target.path}');
        return true;
      } catch (e) {
        _logger.info('缓存目录整体移动失败，改为逐个文件补齐：${source.path}：$e');
        await target.create(recursive: true);
      }
    } else {
      await target.create(recursive: true);
    }

    var ok = true;
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
        try {
          await moveFile(entity, destination.path);
        } catch (_) {
          // 跨卷 / 被占用：复制保留旧文件，下次启动目标已存在会跳过。
          await entity.copy(destination.path);
        }
      } catch (e) {
        ok = false;
        _logger.warning('迁移缓存文件失败：${entity.path}：$e');
      }
    }
    if (ok) _logger.info('缓存目录已合并到新目录：${target.path}');
    return ok;
  } catch (e) {
    _logger.warning('迁移缓存目录失败（保留旧目录）：${source.path}：$e');
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
