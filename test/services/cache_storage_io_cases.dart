import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/cache_storage_io.dart';
import 'package:molia/services/cache_types.dart';

/// [IoCacheStorage] 的真实文件系统行为：目录扫描（usage / listFiles）。
///
/// 扫描在短命 isolate 中执行，因此这里用真实临时目录断言「跨 isolate 回传的
/// 字节 / 文件数 / 文件名表」与原主 isolate 实现一致，并覆盖目录缺失 / 不可读
/// 的降级路径。
void main() {
  late Directory tempRoot;
  late IoCacheStorage storage;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('cache_storage_io_test_');
    storage = IoCacheStorage(
      audioDirOverride: '${tempRoot.path}/audio_cache',
      artworkDirOverride: '${tempRoot.path}/artwork_cache',
    );
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  Future<File> writeFile(
    String relativePath,
    int sizeBytes, {
    Duration age = Duration.zero,
  }) async {
    final file = File('${tempRoot.path}/$relativePath');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List<int>.filled(sizeBytes, 0));
    if (age > Duration.zero) {
      await file.setLastModified(DateTime.now().subtract(age));
    }
    return file;
  }

  group('usage', () {
    test('递归统计多文件与嵌套目录的字节 / 文件数', () async {
      final dir = '${tempRoot.path}/audio_cache';
      await writeFile('audio_cache/a', 100);
      await writeFile('audio_cache/b.part', 250);
      await writeFile('audio_cache/nested/c', 7);
      await writeFile('audio_cache/nested/deeper/d', 0);

      expect(
        await storage.usage(dir),
        const CacheUsage(bytes: 357, count: 4),
      );
    });

    test('目录不存在 / 路径不是目录：zero', () async {
      expect(
        await storage.usage('${tempRoot.path}/missing'),
        CacheUsage.zero,
      );

      final file = await writeFile('plain_file', 10);
      expect(await storage.usage(file.path), CacheUsage.zero);
    });

    test('目录不可读：zero（root 无视权限位时跳过）', () async {
      if (Platform.isWindows) return; // Windows 权限模型不同。

      final dir = Directory('${tempRoot.path}/locked')
        ..createSync(recursive: true);
      await writeFile('locked/a', 100);
      final chmod = await Process.run('chmod', ['000', dir.path]);
      addTearDown(() => Process.run('chmod', ['700', dir.path]));
      if (chmod.exitCode != 0) return;

      // root 无视权限位：确认目录确实枚举失败，再断言降级结果。
      try {
        dir.listSync();
        return;
      } catch (_) {
        // 预期不可读。
      }

      expect(await storage.usage(dir.path), CacheUsage.zero);
      expect(await storage.listFiles(dir.path), isEmpty);
    });

  });

  group('listFiles', () {
    test('递归列举嵌套文件：文件名 → 字节数', () async {
      final dir = '${tempRoot.path}/artwork_cache';
      await writeFile('artwork_cache/a.jpg', 100);
      await writeFile('artwork_cache/b.jpg', 250);
      await writeFile('artwork_cache/ab/c.jpg', 7);
      await writeFile('artwork_cache/ab/cd/d.jpg', 0);

      expect(await storage.listFiles(dir), {
        'a.jpg': 100,
        'b.jpg': 250,
        'c.jpg': 7,
        'd.jpg': 0,
      });
    });

    test('目录不存在 / 路径不是目录：空表', () async {
      expect(await storage.listFiles('${tempRoot.path}/missing'), isEmpty);

      final file = await writeFile('plain_file', 10);
      expect(await storage.listFiles(file.path), isEmpty);
    });
  });

  group('sweepArtwork', () {
    test('先删过期（含嵌套目录），再按 mtime 从旧到新删超量', () async {
      final dir = '${tempRoot.path}/artwork_cache';
      final stale = await writeFile(
        'artwork_cache/nested/stale.jpg',
        10,
        age: const Duration(days: 400),
      );
      final oldest = await writeFile(
        'artwork_cache/oldest.jpg',
        10,
        age: const Duration(days: 3),
      );
      final middle = await writeFile(
        'artwork_cache/middle.jpg',
        10,
        age: const Duration(days: 2),
      );
      final newest = await writeFile(
        'artwork_cache/newest.jpg',
        10,
        age: const Duration(hours: 1),
      );

      // staleDays=365 先删 stale；剩余 3 个，maxObjects=2 再删最旧的 oldest。
      final result =
          await storage.sweepArtwork(dir, maxObjects: 2, staleDays: 365);
      expect(result.deleted, 2);
      // 存活集合供调用方一次对齐索引（相对缓存目录）。
      expect(result.remainingRelativePaths, {'middle.jpg', 'newest.jpg'});
      expect(await stale.exists(), isFalse);
      expect(await oldest.exists(), isFalse);
      expect(await middle.exists(), isTrue);
      expect(await newest.exists(), isTrue);
    });

    test('目录不存在 / 根目录不可读：未完整扫描（remaining 为 null）', () async {
      final missing = await storage.sweepArtwork(
        '${tempRoot.path}/missing',
        maxObjects: 1,
        staleDays: 1,
      );
      expect(missing.deleted, 0);
      expect(
        missing.remainingRelativePaths,
        isNull,
        reason: '没扫到目录不能当成「缓存全空」清索引',
      );

      if (Platform.isWindows) return; // Windows 权限模型不同。
      final dir = Directory('${tempRoot.path}/locked')
        ..createSync(recursive: true);
      await writeFile('locked/a.jpg', 10);
      final chmod = await Process.run('chmod', ['000', dir.path]);
      addTearDown(() => Process.run('chmod', ['700', dir.path]));
      if (chmod.exitCode != 0) return;
      try {
        dir.listSync();
        return; // root 无视权限位。
      } catch (_) {
        // 预期不可读。
      }

      final locked =
          await storage.sweepArtwork(dir.path, maxObjects: 1, staleDays: 1);
      expect(locked.deleted, 0);
      expect(locked.remainingRelativePaths, isNull);
    });

    test('两个维度都为 0 不删除，仍返回存活集合', () async {
      final old = await writeFile(
        'artwork_cache/old.jpg',
        10,
        age: const Duration(days: 999),
      );
      final result = await storage.sweepArtwork(
        '${tempRoot.path}/artwork_cache',
        maxObjects: 0,
        staleDays: 0,
      );
      expect(result.deleted, 0);
      expect(result.remainingRelativePaths, {'old.jpg'});
      expect(await old.exists(), isTrue);
    });

    test('嵌套文件相对路径统一用 /（跨平台一致）', () async {
      await writeFile('artwork_cache/keep/a.jpg', 10);
      await writeFile('artwork_cache/keep/deeper/b.jpg', 10);

      final result = await storage.sweepArtwork(
        '${tempRoot.path}/artwork_cache',
        maxObjects: 0,
        staleDays: 0,
      );
      expect(result.remainingRelativePaths, {
        'keep/a.jpg',
        'keep/deeper/b.jpg',
      });
    });
  });
}
