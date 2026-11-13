import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/domain/models/download.dart';
import 'package:molia/services/local/music_folder_scanner.dart';
import 'package:molia/services/local/music_folder_watcher.dart';
import 'package:molia/services/local/music_folders.dart';

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
      expect(target.imports.map((path) => path.split('/').last), [
        '01.mp3',
        '02.flac',
      ]);
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
      for (var i = 0; i < 20; i++) {
        await write('a$i.mp3');
      }
      final cancellation = ScanCancellation();
      target.onImport = () => cancellation.cancel();
      final outcome = await MusicFolderScanner(target: target)
          .scan(root.path, cancellation: cancellation);
      expect(outcome.cancelled, isTrue);
      expect(outcome.added, 1);
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

  group('MusicFolderWatcher', () {
    test('连续事件防抖成一次触发；stop 后不再触发', () {
      fakeAsync((async) {
        final controller = StreamController<FileSystemEvent>.broadcast();
        final events = <String>[];
        final watcher = MusicFolderWatcher(
          watch: (root) => controller.stream,
          onTrigger: () async => events.add('trigger'),
        );
        watcher.start(['/music']);
        controller
          ..add(FileSystemCreateEvent('/music/a.mp3', false))
          ..add(FileSystemModifyEvent('/music/b.mp3', false, false));
        async.elapse(const Duration(seconds: 1));
        expect(events, isEmpty);
        async.elapse(const Duration(seconds: 1));
        expect(events, ['trigger']);

        watcher.stop();
        controller.add(FileSystemCreateEvent('/music/c.mp3', false));
        async.elapse(const Duration(seconds: 3));
        expect(events, ['trigger']);
        controller.close();
      });
    });
  });
}

class _FakeTarget implements LocalScanTarget {
  final List<String> imports = [];
  final List<(DownloadedTrack, int, int)> refreshes = [];
  final List<DownloadedTrack> missing = [];
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
}
