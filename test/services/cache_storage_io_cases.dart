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

  Future<File> writeFile(String relativePath, int sizeBytes) async {
    final file = File('${tempRoot.path}/$relativePath');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List<int>.filled(sizeBytes, 0));
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
}
