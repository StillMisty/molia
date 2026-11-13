import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/data/downloads/downloads_repository.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/services/local/music_folder_scanner.dart';
import 'package:molia/services/local/music_folder_watcher.dart';
import 'package:molia/services/download/download_records.dart';
import 'package:molia/services/download/missing_file_probe.dart';
import 'package:molia/services/local/local_library_service.dart';
import 'package:molia/services/local/local_write_gate.dart';
import 'package:molia/services/local/music_folders.dart';

import '../support/fake_download_storage.dart';
import '../support/memory_database.dart';

/// 音乐文件夹配置 / 扫描器 / 监听。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MusicFoldersStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('添加 / 去重 / 拒绝嵌套根，移除不碰磁盘', () async {
      final dir = await Directory.systemTemp.createTemp('molia_folders_');
      addTearDown(() => dir.delete(recursive: true));
      final store = MusicFoldersStore();
      await store.load();
      expect(await store.add(dir.path), MusicFolderAddResult.added);
      expect(store.folders, hasLength(1));
      expect(await store.add(dir.path), MusicFolderAddResult.duplicate);
      expect(
        await store.add('${dir.path}${Platform.pathSeparator}sub'),
        MusicFolderAddResult.nested,
      );
      expect(await store.add(dir.parent.path), MusicFolderAddResult.nested);
      expect(await store.add('relative/path'), MusicFolderAddResult.invalid);

      final id = store.folders.single.id;
      final file = File('${dir.path}/keep.mp3')..writeAsBytesSync([1, 2, 3]);
      await store.remove(id);
      expect(store.folders, isEmpty);
      expect(file.existsSync(), isTrue);

      // 配置落盘：新实例读到空配置（移除后）。
      final reloaded = MusicFoldersStore();
      await reloaded.load();
      expect(reloaded.folders, isEmpty);
    });

    test('扫描摘要持久化', () async {
      final store = MusicFoldersStore();
      await store.load();
      await store.add('/music');
      final id = store.folders.single.id;
      await store.setLastScan(
        id,
        const MusicFolderScanSummary(
          added: 2,
          updated: 1,
          skipped: 3,
          scannedAt: 99,
        ),
      );
      final reloaded = MusicFoldersStore();
      await reloaded.load();
      expect(reloaded.folders.single.lastScan!.added, 2);
      expect(reloaded.folders.single.lastScan!.skipped, 3);
    });
  });

  group('MusicFolderScanner', () {
    late Directory root;
    late _FakeTarget target;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('molia_scan_');
      target = _FakeTarget();
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    Future<File> write(
      String relative, {
      List<int>? bytes,
      int? mtimeMs,
    }) async {
      final file = File('${root.path}/$relative');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes ?? [1, 2, 3, 4]);
      if (mtimeMs != null) {
        await file.setLastModified(
          DateTime.fromMillisecondsSinceEpoch(mtimeMs),
        );
      }
      return file;
    }

    test('递归扫描：新增 / 跳过非音频、隐藏项、空文件，文件字节不变', () async {
      await write('Album/01.mp3');
      await write('Album/02.flac');
      await write('Album/cover.jpg');
      await write('.hidden/secret.mp3');
      await write('Album/.hidden.mp3');
      await write('Album/empty.mp3', bytes: const []);
      final before = await File('${root.path}/Album/01.mp3').readAsBytes();

      final scanner = MusicFolderScanner(target: target);
      final outcome = await scanner.scan(root.path);
      expect(outcome.added, 2);
      expect(outcome.skipped, 4);
      expect(outcome.cancelled, isFalse);
      expect(
        target.imports.map((path) => path.split('/').last),
        containsAll(['01.mp3', '02.flac']),
      );
      expect(target.imports, hasLength(2));
      expect(
        await File('${root.path}/Album/01.mp3').readAsBytes(),
        before,
        reason: '扫描不写用户文件',
      );
    });

    test('增量：未变化不读标签 / 不写库；mtime / size 变化只刷新', () async {
      final file = await write('a.mp3', mtimeMs: 1000);
      final scanner = MusicFolderScanner(target: target);
      await scanner.scan(root.path);
      expect(target.imports, hasLength(1));
      expect(target.refreshes, isEmpty);

      // 第二轮：完全相同 → 零写入。
      await scanner.scan(root.path);
      expect(target.imports, hasLength(1));
      expect(target.refreshes, isEmpty);

      // 改 mtime → 只刷新技术字段。
      await file.setLastModified(DateTime.fromMillisecondsSinceEpoch(2000));
      await scanner.scan(root.path);
      expect(target.imports, hasLength(1));
      expect(target.refreshes, hasLength(1));
      expect(target.refreshes.single.$2, 2000);
    });

    test('缺文件：成功枚举后标记；根目录不存在返回 unavailable 且不标记', () async {
      await write('a.mp3');
      final scanner = MusicFolderScanner(target: target);
      await scanner.scan(root.path);
      target.imported = [
        DownloadedTrack(
          originSourceKey: kLocalSourceKey,
          originSongId: 'file:x',
          title: 'a',
          filePath: '${root.path}/a.mp3',
          sizeBytes: 4,
          imported: true,
          localKey: 'file:x',
          downloadedAt: 1,
        ),
        DownloadedTrack(
          originSourceKey: kLocalSourceKey,
          originSongId: 'file:y',
          title: 'gone',
          filePath: '${root.path}/gone.mp3',
          sizeBytes: 4,
          imported: true,
          localKey: 'file:y',
          downloadedAt: 1,
        ),
      ];
      await scanner.scan(root.path);
      expect(target.missing.map((record) => record.localKey), ['file:y']);

      target.missing.clear();
      final outcome = await MusicFolderScanner(target: target)
          .scan('${root.path}-not-mounted');
      expect(outcome.unavailable, isTrue);
      expect(target.missing, isEmpty);
    });

    test('符号链接环终止；同一文件经链接与真实路径只导入一次', () async {
      await write('real/a.mp3');
      Link('${root.path}/cycle').createSync(root.path);
      Link('${root.path}/alias.mp3').createSync('${root.path}/real/a.mp3');
      final scanner = MusicFolderScanner(target: target);
      final outcome = await scanner.scan(root.path);
      expect(outcome.added, 1, reason: '链接与真实路径去重');
      expect(outcome.skipped, greaterThan(0), reason: '环与重复路径计入跳过');
    });

    test('深度上限：超过 32 层的文件计入跳过', () async {
      var deep = root.path;
      for (var i = 0; i < 34; i++) {
        deep = '$deep/d$i';
      }
      final file = File('$deep/deep.mp3');
      await file.parent.create(recursive: true);
      await file.writeAsBytes([1, 2, 3]);
      final outcome = await MusicFolderScanner(target: target).scan(root.path);
      expect(outcome.added, 0);
      expect(outcome.skipped, greaterThan(0));
    });

    test('取消：停止枚举，已提交批次保留', () async {
      final files = <File>[];
      for (var i = 0; i < 20; i++) {
        files.add(await write('a$i.mp3'));
      }
      final cancellation = ScanCancellation();
      var yielded = 0;
      final outcome = await MusicFolderScanner(
        target: target,
        lister: (directory) async* {
          if (directory.path == root.path) {
            for (final file in files) {
              if (yielded++ > 0) cancellation.cancel();
              yield file;
            }
            return;
          }
          yield* directory.list();
        },
      ).scan(root.path, cancellation: cancellation);
      expect(outcome.cancelled, isTrue);
      expect(outcome.added, 1);
      expect(target.imports, hasLength(1), reason: '已提交批次保留');
    });

    test('根目录枚举失败：整轮 unavailable，绝不标记缺失', () async {
      await write('a.mp3');
      target.imported = [
        DownloadedTrack(
          originSourceKey: kLocalSourceKey,
          originSongId: 'file:a',
          title: 'a',
          filePath: '${root.path}/a.mp3',
          sizeBytes: 4,
          imported: true,
          localKey: 'file:a',
          downloadedAt: 1,
        ),
      ];
      final outcome = await MusicFolderScanner(
        target: target,
        lister: (directory) {
          if (directory.path == root.path) {
            throw const FileSystemException('permission denied');
          }
          return directory.list();
        },
      ).scan(root.path);
      expect(outcome.unavailable, isTrue);
      expect(target.missing, isEmpty);
      expect(target.imports, isEmpty);
    });

    test('符号链接根：重复扫描不重复导入，删除后能标记缺失', () async {
      final real = Directory('${root.path}/real')..createSync();
      await write('real/a.mp3');
      final link = Link('${root.path}/alias')..createSync(real.path);
      final scanner = MusicFolderScanner(target: target);
      await scanner.scan(link.path);
      expect(target.imports, hasLength(1));
      expect(target.imports.single, startsWith(link.path));
      await scanner.scan(link.path);
      expect(target.imports, hasLength(1), reason: '同一文件不重复导入');
      await File('${real.path}/a.mp3').delete();
      await scanner.scan(link.path);
      expect(target.missing, hasLength(1));
    });

    test('文件符号链接：保存第一次发现的链接路径，不替换成目标', () async {
      final real = await write('real.mp3');
      final alias = Link('${root.path}/alias.mp3')..createSync(real.path);
      final outcome = await MusicFolderScanner(
        target: target,
        lister: (directory) async* {
          if (directory.path == root.path) {
            yield alias;
            yield real;
            return;
          }
          yield* directory.list();
        },
      ).scan(root.path);
      expect(outcome.added, 1);
      expect(target.imports.single, alias.path);
    });

    test('大量文件：按 ≤200 条批次提交', () async {
      for (var i = 0; i < 210; i++) {
        await write('bulk/$i.mp3', bytes: [i + 1]);
      }
      final outcome = await MusicFolderScanner(target: target).scan(root.path);
      expect(outcome.added, 210);
      expect(target.imports, hasLength(210));
      expect(target.batches.every((size) => size <= 200), isTrue);
      expect(target.batches.fold<int>(0, (sum, size) => sum + size), 210);
      expect(target.batches.length, greaterThanOrEqualTo(2));
    });

    test('只扫描指定路径（监听事件）：不遍历整棵树、不标缺失', () async {
      await write('a.mp3');
      await write('b.mp3');
      await MusicFolderScanner(target: target).scan(root.path);
      target.imports.clear();
      await File('${root.path}/a.mp3')
          .setLastModified(DateTime.fromMillisecondsSinceEpoch(3000));
      await MusicFolderScanner(target: target)
          .scanPaths(root.path, ['${root.path}/a.mp3']);
      expect(target.imports, isEmpty);
      expect(target.refreshes, hasLength(1));
      expect(target.refreshes.single.$1.filePath, '${root.path}/a.mp3');
      expect(target.missing, isEmpty);
    });

    test('大小写策略可注入：不敏感时同目录同名只导入一次', () async {
      await write('A.mp3');
      await write('a.mp3');
      final sensitive = await MusicFolderScanner(target: _FakeTarget())
          .scan(root.path);
      expect(sensitive.added, 2);

      final folded = _FakeTarget();
      final outcome = await MusicFolderScanner(
        target: folded,
        // 只折叠文件名：临时目录本身可能含大写字母，整路径折叠会让 stat 失败。
        pathKey: (path) =>
            '${p.dirname(path)}/${p.basename(path).toLowerCase()}',
      ).scan(root.path);
      // ignore: avoid_print
      expect(outcome.added, 1);
      expect(outcome.skipped, greaterThan(0));
    });
  });

  group('LocalWriteGate', () {
    test('并发任务串行执行，失败不阻断后续任务', () async {
      final gate = LocalWriteGate();
      final log = <String>[];
      final first = gate.run(() async {
        log.add('a-start');
        await Future<void>.delayed(const Duration(milliseconds: 5));
        log.add('a-end');
      });
      final failing = gate.run(() async {
        log.add('b');
        throw StateError('boom');
      });
      final last = gate.run(() async => log.add('c'));
      await expectLater(failing, throwsStateError);
      await Future.wait([first, last]);
      expect(log, ['a-start', 'a-end', 'b', 'c']);
    });
  });

  group('LocalLibraryService platform rules', () {
    test('不允许添加文件夹时返回 invalid；启动扫描受平台开关控制', () async {
      SharedPreferences.setMockInitialValues({});
      final db = openMemoryDatabase();
      addTearDown(db.close);
      final storage = FakeDownloadStorage();
      final records = DownloadRecords(supported: true, initialized: true);
      final probe = MissingFileProbe(
        records: records,
        repository: DownloadsRepository(databaseProvider: () => db),
        storage: storage,
      );
      final folders = MusicFoldersStore();
      await folders.load();
      final target = _FakeTarget();
      final service = LocalLibraryService(
        folders: folders,
        scanner: MusicFolderScanner(target: target),
        probe: probe,
        watcher: MusicFolderWatcher(onTrigger: (paths) async {}),
        canWatch: false,
        canScanOnStartup: false,
        canAddFolder: false,
      );
      expect(await service.addFolder('/music'), MusicFolderAddResult.invalid);
      // 手动把配置塞进去（模拟另一台设备同步过来的旧配置），启动仍不扫描。
      await folders.add('/music');
      await service.startAfterFirstFrame();
      expect(target.imports, isEmpty);
      expect(service.canAddFolder, isFalse);
      expect(service.canWatchFolders, isFalse);
    });
  });

  group('MusicFolderWatcher', () {
    test('连续事件防抖成一次触发；stop 后不再触发', () {
      fakeAsync((async) {
        final controller = StreamController<FileSystemEvent>.broadcast();
        final events = <String>[];
        final watcher = MusicFolderWatcher(
          watch: (root) => controller.stream,
          onTrigger: (paths) async =>
              events.add(paths == null ? 'full' : 'path'),
        );
        watcher.start(['/music']);
        controller
          ..add(FileSystemCreateEvent('/music/a.mp3', false))
          ..add(FileSystemModifyEvent('/music/b.mp3', false, false));
        async.elapse(const Duration(seconds: 1));
        expect(events, isEmpty);
        async.elapse(const Duration(seconds: 1));
        expect(events, ['path']);

        watcher.stop();
        controller.add(FileSystemCreateEvent('/music/c.mp3', false));
        async.elapse(const Duration(seconds: 3));
        expect(events, ['path']);
        controller.close();
      });
    });

    test('事件过多（无法定位）回退整树增量', () {
      fakeAsync((async) {
        final controller = StreamController<FileSystemEvent>.broadcast();
        final events = <String>[];
        final watcher = MusicFolderWatcher(
          watch: (root) => controller.stream,
          onTrigger: (paths) async =>
              events.add(paths == null ? 'full' : 'path'),
        );
        watcher.start(['/music']);
        for (var i = 0; i < 70; i++) {
          controller.add(FileSystemCreateEvent('/music/$i.mp3', false));
        }
        async.elapse(const Duration(seconds: 3));
        expect(events, ['full']);
        watcher.stop();
        controller.close();
      });
    });
  });
}

class _FakeTarget implements LocalScanTarget {
  final List<String> imports = [];
  final List<(DownloadedTrack, int, int)> refreshes = [];
  final List<DownloadedTrack> missing = [];
  final List<int> batches = [];
  List<DownloadedTrack> imported = [];
  void Function()? onImport;

  @override
  Future<List<DownloadedTrack>> listImported() async => imported;

  @override
  Future<void> importFile(
    String path, {
    required int sizeBytes,
    required int mtimeMs,
  }) async {
    imports.add(path);
    imported = [
      ...imported,
      DownloadedTrack(
        originSourceKey: kLocalSourceKey,
        originSongId: 'file:$path',
        title: path.split('/').last,
        filePath: path,
        sizeBytes: sizeBytes,
        imported: true,
        localKey: 'file:$path',
        mtimeMs: mtimeMs,
        downloadedAt: 1,
      ),
    ];
    onImport?.call();
  }

  @override
  Future<void> refreshFile(
    DownloadedTrack record, {
    required int sizeBytes,
    required int mtimeMs,
  }) async {
    refreshes.add((record, mtimeMs, sizeBytes));
  }

  @override
  Future<void> markMissing(DownloadedTrack record) async {
    missing.add(record);
  }

  @override
  Future<void> commitBatch(List<LocalScanChange> changes) async {
    batches.add(changes.length);
    for (final change in changes) {
      switch (change) {
        case LocalScanImport(:final path, :final sizeBytes, :final mtimeMs):
          await importFile(path, sizeBytes: sizeBytes, mtimeMs: mtimeMs);
        case LocalScanRefresh(:final record, :final sizeBytes, :final mtimeMs):
          await refreshFile(record, sizeBytes: sizeBytes, mtimeMs: mtimeMs);
        case LocalScanMissing(:final record):
          await markMissing(record);
      }
    }
  }
}
