import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:molia/data/downloads/download_storage.dart';
import 'package:molia/data/downloads/downloads_repository.dart';
import 'package:molia/data/downloads/download_storage_saf.dart';
import 'package:molia/data/files/local_locator.dart';
import 'package:molia/data/saf/saf_bridge.dart';
import 'package:molia/data/saf/saf_music_folder_tree.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/ports/music_folder_tree.dart';
import 'package:molia/services/download/download_records.dart';
import 'package:molia/services/download/missing_file_probe.dart';
import 'package:molia/services/local/music_folder_scanner.dart';

import '../support/fake_download_storage.dart';
import '../support/memory_database.dart';

/// SAF bridge / 树 / 存储装饰器 / 扫描器：不依赖 Android 运行时。
void main() {
  const root = 'content://test.documents/tree/primary%3AMusic';
  const songUri =
      'content://test.documents/tree/primary%3AMusic/document/primary%3AMusic%2FAlbum%2Fsong.mp3';

  group('local locator', () {
    test('content:// 与桌面路径分区：树 URI / 文档 id / 展示名', () {
      expect(isContentLocator(songUri), isTrue);
      expect(contentTreeUriOf(songUri), contains('/tree/'));
      expect(contentTreeUriOf(root), contains('/tree/'));
      expect(contentDisplayNameOf(root), 'Music');
      expect(contentDisplayNameOf(songUri), 'song.mp3');
      expect(audioExtensionOfLocator(songUri), 'mp3');
      expect(audioBaseNameOfLocator(songUri), 'song');
      expect(isLocatorUnder(root, songUri), isTrue);
      expect(
        isLocatorUnder(root, '$root/document/primary%3AOther%2Fx.mp3'),
        isFalse,
      );
      expect(isLocatorUnder('/music', '/music/a.mp3'), isTrue);
      expect(isLocatorUnder('/music', '/music2/a.mp3'), isFalse);
      expect(folderDisplayName(root, storedName: 'My music'), 'My music');
      expect(folderDisplayName(root), 'Music');
      expect(folderDisplayName('/music'), '/music');
      expect(playableUriForLocator(songUri).scheme, 'content');
      expect(playableUriForLocator('/music/a.mp3').scheme, 'file');
    });
  });

  group('SafMusicFolderTree', () {
    test('根显示名 / 条目映射 / 跳过原因', () async {
      final bridge = _FakeSafBridge()
        ..documents[root] = const SafDocument(
          uri: root,
          displayName: 'Music',
          isDirectory: true,
          sizeBytes: 0,
          mtimeMs: 0,
        )
        ..treeEvents[root] = const [
          SafTreeEntry(
            uri: songUri,
            displayName: 'song.mp3',
            relativePath: 'Album/song.mp3',
            isDirectory: false,
            sizeBytes: 42,
            mtimeMs: 1234,
          ),
          SafTreeEntry(
            uri: '$root/document/primary%3AMusic%2FAlbum',
            displayName: 'Album',
            relativePath: 'Album',
            isDirectory: true,
            sizeBytes: 0,
            mtimeMs: 0,
          ),
          SafTreeSkipped('hidden', '.trash'),
          SafTreeSkipped('depthExceeded', 'deep'),
          SafTreeSkipped('unreadable', 'locked'),
        ];
      final tree = SafMusicFolderTree(bridge);

      expect(await tree.displayName(root), 'Music');
      expect(await tree.displayName('$root/document/nothing'), 'nothing');

      final events = await tree.walk(root).toList();
      final entries = events.whereType<FolderTreeEntryFound>().toList();
      expect(entries, hasLength(2));
      expect(entries.first.entry.locator, songUri);
      expect(entries.first.entry.sizeBytes, 42);
      expect(entries.first.entry.relativePath, 'Album/song.mp3');
      expect(entries.last.entry.isDirectory, isTrue);
      final skips = events
          .whereType<FolderTreeSkipped>()
          .map((event) => event.reason)
          .toList();
      expect(skips, [
        FolderTreeSkipReason.hidden,
        FolderTreeSkipReason.depthExceeded,
        FolderTreeSkipReason.unreadable,
      ]);
    });

    test('授权撤销 / 根不存在 → FolderTreeUnavailable 且保留权限语义', () async {
      final denied = _FakeSafBridge()
        ..statError = const SafBridgeException(SafFailureKind.permissionDenied);
      await expectLater(
        SafMusicFolderTree(denied).walk(root).toList(),
        throwsA(
          predicate((e) => e is FolderTreeUnavailable && e.permissionDenied),
        ),
      );

      final missing = _FakeSafBridge();
      await expectLater(
        SafMusicFolderTree(missing).walk(root).toList(),
        throwsA(
          predicate((e) => e is FolderTreeUnavailable && !e.permissionDenied),
        ),
      );
    });
  });

  group('SafDownloadStorage', () {
    test('content:// 路由到 bridge；普通路径仍走 dart:io 实现', () async {
      final inner = FakeDownloadStorage()
        ..files['/downloads/a.mp3'] = [1, 2, 3]
        ..directories.add('/downloads');
      final bridge = _FakeSafBridge()
        ..documents[root] = const SafDocument(
          uri: root,
          displayName: 'Music',
          isDirectory: true,
          sizeBytes: 0,
          mtimeMs: 0,
        )
        ..documents[songUri] = const SafDocument(
          uri: songUri,
          displayName: 'song.mp3',
          isDirectory: false,
          sizeBytes: 4,
          mtimeMs: 99,
        )
        ..bytes[songUri] = Uint8List.fromList([10, 20, 30, 40]);
      final storage = SafDownloadStorage(inner, bridge);

      expect(await storage.fileExists(songUri), isTrue);
      expect(await storage.fileSize(songUri), 4);
      expect(await storage.fileMtime(songUri), 99);
      expect(await storage.locatorReachable(songUri), isTrue);
      expect(await storage.readHead(songUri, 2), [10, 20]);
      expect(await storage.readRange(songUri, 1, 2), [20, 30]);
      final streamed = <int>[];
      await for (final chunk in await storage.readStream(songUri)) {
        streamed.addAll(chunk);
      }
      expect(streamed, [10, 20, 30, 40]);

      expect(await storage.fileExists('/downloads/a.mp3'), isTrue);
      expect(await storage.readHead('/downloads/a.mp3', 2), [1, 2]);
      expect(await storage.locatorReachable('/downloads/a.mp3'), isTrue);

      // 树根消失 = 整个文件夹不可用：文件探测据此保留记录。
      bridge.documents.remove(root);
      expect(await storage.locatorReachable(songUri), isFalse);
    });

    test('SAF 只读：写操作不落到用户文档，删除不碰 provider', () async {
      final inner = FakeDownloadStorage();
      final bridge = _FakeSafBridge();
      final storage = SafDownloadStorage(inner, bridge);
      await storage.deleteQuietly(songUri);
      await storage.rename(songUri, '$songUri.bak');
      expect(inner.deleted, isEmpty);
      await expectLater(
        storage.writeBytes(songUri, [1]),
        throwsUnsupportedError,
      );
    });

    test('工厂按注入 bridge 决定是否装饰', () {
      expect(createDownloadStorage(), isNot(isA<SafDownloadStorage>()));
      expect(
        createDownloadStorage(safBridge: _FakeSafBridge()),
        isA<SafDownloadStorage>(),
      );
    });
  });

  group('SAF 缺文件探测', () {
    test('文件缺失标 missing；树根撤销时保留记录', () async {
      final db = openMemoryDatabase();
      addTearDown(db.close);
      final bridge = _FakeSafBridge()
        ..documents[root] = const SafDocument(
          uri: root,
          displayName: 'Music',
          isDirectory: true,
          sizeBytes: 0,
          mtimeMs: 0,
        );
      final storage = SafDownloadStorage(FakeDownloadStorage(), bridge);
      final records = DownloadRecords(
        supported: true,
        initialized: true,
        records: const [
          DownloadedTrack(
            originSourceKey: kLocalSourceKey,
            originSongId: 'file:saf',
            title: 'song',
            filePath: songUri,
            sizeBytes: 4,
            imported: true,
            localKey: 'file:saf',
            downloadedAt: 1,
          ),
        ],
      );
      final probe = MissingFileProbe(
        records: records,
        repository: DownloadsRepository(databaseProvider: () => db),
        storage: storage,
      );

      // 树可读 + 文件不在 → 标缺失。
      final first = await probe.probeAll();
      expect(first.changed, 1);
      expect(records.downloads.single.isMissing, isTrue);

      // 树根也消失（授权撤销）→ 不改整库状态。
      records.put(records.downloads.single.copyWith(clearMissingAt: true));
      bridge.documents.remove(root);
      final second = await probe.probeAll();
      expect(second.changed, 0);
      expect(records.downloads.single.isMissing, isFalse);
    });
  });

  group('SAF 扫描', () {
    test('导入 content:// locator，未变化不刷新，删文件后标缺失', () async {
      final bridge = _FakeSafBridge()
        ..documents[root] = const SafDocument(
          uri: root,
          displayName: 'Music',
          isDirectory: true,
          sizeBytes: 0,
          mtimeMs: 0,
        )
        ..treeEvents[root] = const [
          SafTreeEntry(
            uri: songUri,
            displayName: 'song.mp3',
            relativePath: 'song.mp3',
            isDirectory: false,
            sizeBytes: 4,
            mtimeMs: 1000,
          ),
        ];
      final target = _FakeTarget();
      final scanner = MusicFolderScanner(
        target: target,
        tree: SafMusicFolderTree(bridge),
      );

      final first = await scanner.scan(root);
      expect(first.added, 1);
      expect(target.imports.single, songUri);

      // 未变化：不读标签、不写库。
      final second = await scanner.scan(root);
      expect(second.added, 0);
      expect(second.updated, 0);
      expect(target.imports, hasLength(1));
      expect(target.refreshes, isEmpty);

      // 文件消失但树仍可用 → 标缺失。
      bridge.treeEvents[root] = const [];
      final third = await scanner.scan(root);
      expect(third.unavailable, isFalse);
      expect(target.missing.single.filePath, songUri);
    });

    test('树授权撤销：整轮 unavailable + accessRevoked，绝不标缺失', () async {
      final bridge = _FakeSafBridge()
        ..documents[root] = const SafDocument(
          uri: root,
          displayName: 'Music',
          isDirectory: true,
          sizeBytes: 0,
          mtimeMs: 0,
        )
        ..treeEvents[root] = const [
          SafTreeEntry(
            uri: songUri,
            displayName: 'song.mp3',
            relativePath: 'song.mp3',
            isDirectory: false,
            sizeBytes: 4,
            mtimeMs: 1000,
          ),
        ];
      final target = _FakeTarget();
      final scanner = MusicFolderScanner(
        target: target,
        tree: SafMusicFolderTree(bridge),
      );
      await scanner.scan(root);
      target.imports.clear();

      // 下一轮 provider 拒绝访问根。
      bridge.statError = const SafBridgeException(
        SafFailureKind.permissionDenied,
      );
      final outcome = await scanner.scan(root);
      expect(outcome.unavailable, isTrue);
      expect(outcome.accessRevoked, isTrue);
      expect(target.imports, isEmpty);
      expect(target.missing, isEmpty);
    });
  });
}

class _FakeSafBridge implements SafBridge {
  final Map<String, SafDocument> documents = {};
  final Map<String, List<SafTreeEvent>> treeEvents = {};
  final Map<String, Uint8List> bytes = {};
  SafBridgeException? statError;

  @override
  Future<SafDocument?> stat(String uri) async {
    final error = statError;
    if (error != null) throw error;
    return documents[uri];
  }

  @override
  Stream<SafTreeEvent> listTree(
    String uri, {
    required int maxDepth,
    bool Function()? isCancelled,
  }) async* {
    final error = statError;
    if (error != null) throw error;
    for (final event in treeEvents[uri] ?? const <SafTreeEvent>[]) {
      if (isCancelled?.call() == true) return;
      yield event;
    }
  }

  @override
  Future<Uint8List?> readHead(String uri, int length) async {
    final data = bytes[uri];
    if (data == null) return null;
    return Uint8List.sublistView(
      data,
      0,
      length < data.length ? length : data.length,
    );
  }

  @override
  Future<Uint8List?> readRange(String uri, int start, int length) async {
    final data = bytes[uri];
    if (data == null || start > data.length) return null;
    final end = start + length < data.length ? start + length : data.length;
    return Uint8List.sublistView(data, start, end);
  }
}

class _FakeTarget implements LocalScanTarget {
  final List<String> imports = [];
  final List<(DownloadedTrack, int, int)> refreshes = [];
  final List<DownloadedTrack> missing = [];
  List<DownloadedTrack> imported = [];

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
        title: 'song',
        filePath: path,
        sizeBytes: sizeBytes,
        imported: true,
        localKey: 'file:$path',
        mtimeMs: mtimeMs,
        downloadedAt: 1,
      ),
    ];
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
