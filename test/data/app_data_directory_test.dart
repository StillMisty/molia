/// 应用数据目录 helper：Windows 旧目录迁移（复制 / 不覆盖 / 失败回退）。
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/downloads/download_storage_io.dart';
import 'package:molia/data/files/app_data_directory.dart';

void main() {
  late Directory root;
  late Directory legacy;
  late Directory target;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('molia_app_data_');
    legacy = Directory('${root.path}/roaming')..createSync(recursive: true);
    target = Directory('${root.path}/local')..createSync(recursive: true);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('目录选择：Windows 用 LocalAppData，其余平台用应用支持目录', () async {
    final local = Directory('${root.path}/localappdata')..createSync();
    final support = Directory('${root.path}/support')..createSync();

    final windows = await appDataDirectory(
      platform: TargetPlatform.windows,
      windowsDirectory: () async => local,
      supportDirectory: () async => support,
    );
    expect(windows.path, local.path);
    expect(
      await legacyAppDataDirectory(
        platform: TargetPlatform.windows,
        supportDirectory: () async => support,
      ),
      support,
    );

    final linux = await appDataDirectory(
      platform: TargetPlatform.linux,
      windowsDirectory: () async => local,
      supportDirectory: () async => support,
    );
    expect(linux.path, support.path);
    expect(
      await legacyAppDataDirectory(
        platform: TargetPlatform.linux,
        supportDirectory: () async => support,
      ),
      isNull,
    );
  });

  test('LocalAppData 解析失败：回退应用支持目录', () async {
    final support = Directory('${root.path}/support')..createSync();
    final fallback = await appDataDirectory(
      platform: TargetPlatform.windows,
      windowsDirectory: () async => throw const FileSystemException('denied'),
      supportDirectory: () async => support,
    );
    expect(fallback.path, support.path);
  });

  test('主库迁移：DB + wal + shm 一起复制，旧库保留', () async {
    final db = File('${legacy.path}/molia_database_v2.sqlite')
      ..writeAsStringSync('db');
    final wal = File('${db.path}-wal')..writeAsStringSync('wal');
    final shm = File('${db.path}-shm')..writeAsStringSync('shm');

    expect(
      await migrateLegacyDatabaseFile(
        targetDirectory: target,
        legacyDirectory: legacy,
        fileName: 'molia_database_v2',
      ),
      isTrue,
    );

    expect(
      File('${target.path}/molia_database_v2.sqlite').readAsStringSync(),
      'db',
    );
    expect(
      File('${target.path}/molia_database_v2.sqlite-wal').readAsStringSync(),
      'wal',
    );
    expect(
      File('${target.path}/molia_database_v2.sqlite-shm').readAsStringSync(),
      'shm',
    );
    // 旧库保留作回退 / 备份。
    expect(db.existsSync(), isTrue);
    expect(wal.existsSync(), isTrue);
    expect(shm.existsSync(), isTrue);
  });

  test('主库迁移：新目录已有库时直接跳过，不覆盖', () async {
    File('${legacy.path}/molia_database_v2.sqlite').writeAsStringSync('legacy');
    File('${target.path}/molia_database_v2.sqlite').writeAsStringSync('new');

    expect(
      await migrateLegacyDatabaseFile(
        targetDirectory: target,
        legacyDirectory: legacy,
        fileName: 'molia_database_v2',
      ),
      isTrue,
    );
    expect(
      File('${target.path}/molia_database_v2.sqlite').readAsStringSync(),
      'new',
    );
  });

  test('主库迁移失败：返回 false（调用方回退旧目录），不留半成品', () async {
    File('${legacy.path}/molia_database_v2.sqlite').writeAsStringSync('db');
    // 目标路径被一个同名文件占住：创建目录失败。
    final blocked = File('${root.path}/blocked')..writeAsStringSync('x');

    expect(
      await migrateLegacyDatabaseFile(
        targetDirectory: Directory('${blocked.path}/local'),
        legacyDirectory: legacy,
        fileName: 'molia_database_v2',
      ),
      isFalse,
    );
  });

  test('下载 journal 迁移失败：回退旧 journal 根，旧记录仍可达', () async {
    final oldJournal = Directory('${legacy.path}/download_journal')
      ..createSync(recursive: true);
    File('${oldJournal.path}/a.json').writeAsStringSync('{}');
    // 目标路径被同名文件占住 → Directory.create 失败 → 迁移返回 false。
    File('${target.path}/download_journal').writeAsStringSync('blocked');

    final storage = IoDownloadStorage(
      supportDirectory: () async => target,
      legacyDirectory: () async => legacy,
    );
    expect(
      await storage.journalRoot(),
      '${legacy.path}/download_journal',
      reason: '迁移失败不能让旧 journal 不可达',
    );
    expect(File('${oldJournal.path}/a.json').existsSync(), isTrue);
  });

  test('单文件迁移：目标不存在才复制，失败保留旧文件', () async {
    final source = File('${legacy.path}/lx_sources.json')
      ..writeAsStringSync('{"scripts":[]}');

    expect(
      await migrateLegacyFileIfNeeded(
        targetDirectory: target,
        relativePath: 'lx_sources.json',
        legacyDirectory: legacy,
      ),
      isTrue,
    );
    expect(
      File('${target.path}/lx_sources.json').readAsStringSync(),
      '{"scripts":[]}',
    );
    expect(source.existsSync(), isTrue);
  });

  test('目录迁移：补齐缺失文件、跳过已存在文件', () async {
    final oldDir = Directory('${legacy.path}/download_journal')
      ..createSync(recursive: true);
    File('${oldDir.path}/a.json').writeAsStringSync('old-a');
    File('${oldDir.path}/b.json').writeAsStringSync('old-b');
    final newDir = Directory('${target.path}/download_journal')
      ..createSync(recursive: true);
    File('${newDir.path}/a.json').writeAsStringSync('new-a');

    expect(
      await migrateLegacyDirectoryIfNeeded(
        targetDirectory: target,
        relativePath: 'download_journal',
        legacyDirectory: legacy,
      ),
      isTrue,
    );
    expect(File('${newDir.path}/a.json').readAsStringSync(), 'new-a');
    expect(File('${newDir.path}/b.json').readAsStringSync(), 'old-b');
    expect(File('${oldDir.path}/a.json').existsSync(), isTrue);
  });
}
