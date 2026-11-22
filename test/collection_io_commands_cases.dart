import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/collection_io_commands.dart';
import 'package:molia/services/playlist/playlist_import_service.dart';
import 'package:molia/services/save_as_types.dart';

void main() {
  group('文件导入', () {
    test('成功：解析 + 本机路径 + 复核后建列表并批量加入', () async {
      final files = _FakeFiles(
        text:
            '#EXTM3U\n'
            '#PLAYLIST:Trip\n'
            '#EXTINF:1,Song One\n'
            '#MOLIA:wy:1\n'
            'https://example.com/song/1\n'
            '/music/a.mp3\n',
      );
      final target = _FakeTarget(existing: ['Trip']);
      final importer = _FakeLocalImporter({
        '/music/a.mp3': _track('local', 'file:a'),
      });
      final service = PlaylistImportService(
        localImporter: importer,
        resolver: _FakeResolver({'wy:1': _track('wy', '1')}),
      );
      PlaylistImportPlan? reviewed;
      final commands = _commands(
        files: files,
        importService: service,
        importTarget: target,
        playlistNames: () => target.existing,
        review: (plan) async {
          reviewed = plan;
          return true;
        },
      );

      final outcome = await commands.importPlaylistFile(dialogTitle: '导入列表');

      expect(outcome, isA<CollectionPlaylistImportDone>());
      final done = outcome as CollectionPlaylistImportDone;
      expect(done.playlistId, 1);
      expect(done.name, 'Trip (2)', reason: '同名冲突按现有列表名追加后缀');
      expect(done.added, 2);
      expect(done.skipped, 0);
      expect(reviewed?.resolved, hasLength(2));
      expect(target.created, ['Trip (2)']);
      expect(target.addedBatches.single, hasLength(2));
      expect(files.pickCalls, 1);
      expect(files.readCalls, 1);
    });

    test('选择器取消：不读文件、不复核、不建列表', () async {
      final files = _FakeFiles(path: null);
      var reviewed = false;
      final target = _FakeTarget();
      final outcome = await _commands(
        files: files,
        importTarget: target,
        review: (_) async {
          reviewed = true;
          return true;
        },
      ).importPlaylistFile(dialogTitle: '导入列表');

      expect(outcome, isA<CollectionPlaylistImportCancelled>());
      expect(
        (outcome as CollectionPlaylistImportCancelled).reason,
        CollectionImportCancelReason.filePick,
      );
      expect(files.readCalls, 0);
      expect(reviewed, isFalse);
      expect(target.created, isEmpty);
    });

    test('选择器抛错：类型化失败，不读文件', () async {
      final files = _FakeFiles(pickError: StateError('picker'));
      final outcome = await _commands(files: files)
          .importPlaylistFile(dialogTitle: '导入列表');

      expect(outcome, isA<CollectionPlaylistImportFailed>());
      expect(files.readCalls, 0);
    });

    test('读取失败：类型化失败，不进入解析 / 不复核', () async {
      final files = _FakeFiles(readError: StateError('disk'));
      var reviewed = false;
      final outcome = await _commands(
        files: files,
        review: (_) async {
          reviewed = true;
          return true;
        },
      ).importPlaylistFile(dialogTitle: '导入列表');

      expect(outcome, isA<CollectionPlaylistImportFailed>());
      expect((outcome as CollectionPlaylistImportFailed).error, isNotNull);
      expect(reviewed, isFalse);
    });

    test('解析 / 计划阶段抛错：归为失败而不是抛到页面', () async {
      final files = _FakeFiles(text: '#MOLIA:wy:1\nhttps://example.com/1\n');
      final service = PlaylistImportService(
        localImporter: _FakeLocalImporter({}),
        resolver: _FakeResolver({}, error: StateError('lookup')),
      );
      final outcome = await _commands(
        files: files,
        importService: service,
      ).importPlaylistFile(dialogTitle: '导入列表');

      expect(outcome, isA<CollectionPlaylistImportFailed>());
    });

    test('空文件：空结果，与失败 / 取消区分', () async {
      final target = _FakeTarget();
      final outcome = await _commands(
        files: _FakeFiles(text: ''),
        importTarget: target,
      ).importPlaylistFile(dialogTitle: '导入列表');

      expect(outcome, isA<CollectionPlaylistImportEmpty>());
      expect(target.created, isEmpty);
    });

    test('复核未确认：取消，不建列表', () async {
      final target = _FakeTarget();
      final outcome = await _commands(
        files: _FakeFiles(text: '#MOLIA:wy:1\nhttps://example.com/1\n'),
        importService: PlaylistImportService(
          localImporter: _FakeLocalImporter({}),
          resolver: _FakeResolver({'wy:1': _track('wy', '1')}),
        ),
        importTarget: target,
        review: (_) async => false,
      ).importPlaylistFile(dialogTitle: '导入列表');

      expect(outcome, isA<CollectionPlaylistImportCancelled>());
      expect(
        (outcome as CollectionPlaylistImportCancelled).reason,
        CollectionImportCancelReason.review,
      );
      expect(target.created, isEmpty);
    });

    test('写库失败：新列表被回滚，结果为失败', () async {
      final target = _FakeTarget()..failAdd = true;
      final outcome = await _commands(
        files: _FakeFiles(text: '#MOLIA:wy:1\nhttps://example.com/1\n'),
        importService: PlaylistImportService(
          localImporter: _FakeLocalImporter({}),
          resolver: _FakeResolver({'wy:1': _track('wy', '1')}),
        ),
        importTarget: target,
      ).importPlaylistFile(dialogTitle: '导入列表');

      expect(outcome, isA<CollectionPlaylistImportFailed>());
      expect(target.created, ['list'], reason: '文件名是 #PLAYLIST 缺席时的回退名');
      expect(target.deleted, ['list'], reason: '服务负责删除刚建的空列表');
    });
  });

  group('链接导入', () {
    test('成功：返回列表与新增数', () async {
      final importer = _FakeLinkImporter(playlistId: 9, added: 3, total: 3);
      final outcome = await _commands(linkImporter: importer)
          .importFromLink(sourceKey: 'wy', rawId: 'abc', fallbackName: '导入的列表');

      expect(outcome, isA<CollectionLinkImportDone>());
      final done = outcome as CollectionLinkImportDone;
      expect(done.playlistId, 9);
      expect(done.added, 3);
      expect(importer.fallbackName, '导入的列表');
    });

    test('平台没有曲目：空结果', () async {
      final outcome = await _commands(
        linkImporter: _FakeLinkImporter(added: 0, total: 0),
      ).importFromLink(sourceKey: 'wy', rawId: 'abc', fallbackName: '列表');

      expect(outcome, isA<CollectionLinkImportEmpty>());
    });

    test('列表已包含全部曲目：新增加 0 单独区分', () async {
      final outcome = await _commands(
        linkImporter: _FakeLinkImporter(playlistId: 4, added: 0, total: 5),
      ).importFromLink(sourceKey: 'wy', rawId: 'abc', fallbackName: '列表');

      expect(outcome, isA<CollectionLinkImportAlreadyContains>());
      expect((outcome as CollectionLinkImportAlreadyContains).playlistId, 4);
    });

    test('拉取失败：类型化失败并保留原因', () async {
      final outcome = await _commands(
        linkImporter: _FakeLinkImporter(error: StateError('network')),
      ).importFromLink(sourceKey: 'wy', rawId: 'abc', fallbackName: '列表');

      expect(outcome, isA<CollectionLinkImportFailed>());
      expect((outcome as CollectionLinkImportFailed).error, isNotNull);
    });
  });

  group('导出', () {
    PlaylistInfo playlist() =>
        const PlaylistInfo(id: 1, name: 'Trip', createdAt: 1, syncId: 's1');

    test('M3U8 已保存：文件名 / MIME / 目录与成功路径透传', () async {
      final library = _FakeExportLibrary()
        ..pageUrls['wy:1'] = 'https://pages.example/1';
      final saver = _FakeSaver();
      final outcome = await _commands(exportLibrary: library, saver: saver)
          .exportPlaylist(
            playlist: playlist(),
            displayName: 'Trip',
            tracks: [_track('wy', '1')],
            format: CollectionExportFormat.m3u8,
            dialogTitle: '导出 M3U8',
          );

      expect(outcome, isA<CollectionExportSaved>());
      final saved = outcome as CollectionExportSaved;
      expect(saved.displayPath, '/tmp/Trip.m3u8');
      expect(saved.kind, SaveLocationKind.fileSystem);
      expect(saved.missingFiles, 0);
      expect(saver.fileName, 'Trip.m3u8');
      expect(saver.mimeType, 'audio/x-mpegurl');
      expect(saver.relativeDir, 'exports');
      expect(saver.dialogTitle, '导出 M3U8');
      final text = utf8.decode(saver.bytes!);
      expect(text, contains('#MOLIA:wy:1'));
      expect(text, contains('https://pages.example/1'));
    });

    test('M3U8 缺失文件：保存成功但带上缺失计数', () async {
      final files = _FakeFiles(existsResult: false);
      final local = PlaylistTrack(
        playlistId: 1,
        sourceKey: kLocalSourceKey,
        songId: 'file:a',
        title: 'Local',
        raw: const {'path': '/missing/a.mp3'},
        addedAt: 1,
      );
      final outcome =
          await _commands(
            files: files,
            exportLibrary: _FakeExportLibrary(),
            saver: _FakeSaver(),
          ).exportPlaylist(
            playlist: playlist(),
            displayName: 'Trip',
            tracks: [local],
            format: CollectionExportFormat.m3u8,
            dialogTitle: '导出 M3U8',
          );

      expect(outcome, isA<CollectionExportSaved>());
      expect((outcome as CollectionExportSaved).missingFiles, 1);
      expect(files.existsPaths, ['/missing/a.mp3']);
    });

    test('另存取消：取消结果，不提示失败', () async {
      final outcome =
          await _commands(
            exportLibrary: _FakeExportLibrary(),
            saver: _FakeSaver(result: const SaveAsCancelled()),
          ).exportPlaylist(
            playlist: playlist(),
            displayName: 'Trip',
            tracks: [_track('wy', '1')],
            format: CollectionExportFormat.m3u8,
            dialogTitle: '导出 M3U8',
          );

      expect(outcome, isA<CollectionExportCancelled>());
    });

    test('另存抛错：异常在命令边界收口为失败', () async {
      final outcome =
          await _commands(
            exportLibrary: _FakeExportLibrary(),
            saver: _FakeSaver(error: StateError('save')),
          ).exportPlaylist(
            playlist: playlist(),
            displayName: 'Trip',
            tracks: [_track('wy', '1')],
            format: CollectionExportFormat.m3u8,
            dialogTitle: '导出 M3U8',
          );

      expect(outcome, isA<CollectionExportFailed>());
      expect((outcome as CollectionExportFailed).error, isNotNull);
    });

    test('另存失败：类型化失败并保留原因', () async {
      final outcome =
          await _commands(
            exportLibrary: _FakeExportLibrary(),
            saver: _FakeSaver(result: const SaveAsFailed('disk')),
          ).exportPlaylist(
            playlist: playlist(),
            displayName: 'Trip',
            tracks: [_track('wy', '1')],
            format: CollectionExportFormat.m3u8,
            dialogTitle: '导出 M3U8',
          );

      expect(outcome, isA<CollectionExportFailed>());
      expect((outcome as CollectionExportFailed).error, 'disk');
    });

    test('Molia JSON：封面键推导 syncId，文件名与 MIME 正确', () async {
      final library = _FakeExportLibrary(coverKey: 'playlist:s1');
      final backup = _FakeBackup(json: '{"playlists":[]}');
      final saver = _FakeSaver(
        result: const SaveAsSaved(
          path: '/tmp/Trip.molia.json',
          displayPath: '/tmp/Trip.molia.json',
          kind: SaveLocationKind.fileSystem,
        ),
      );
      final outcome =
          await _commands(
            exportLibrary: library,
            backup: backup,
            saver: saver,
          ).exportPlaylist(
            playlist: playlist(),
            displayName: 'Trip',
            tracks: [_track('wy', '1')],
            format: CollectionExportFormat.molia,
            dialogTitle: '导出 Molia',
          );

      expect(outcome, isA<CollectionExportSaved>());
      expect(backup.playlistSyncId, 's1');
      expect(backup.coverKey, 'playlist:s1');
      expect(saver.fileName, 'Trip.molia.json');
      expect(saver.mimeType, 'application/json');
      expect(utf8.decode(saver.bytes!), '{"playlists":[]}');
    });

    test('同步引擎缺席：全保真导出失败，不写文件', () async {
      final saver = _FakeSaver();
      final outcome =
          await _commands(
            exportLibrary: _FakeExportLibrary(),
            saver: saver,
          ).exportPlaylist(
            playlist: playlist(),
            displayName: 'Trip',
            tracks: [_track('wy', '1')],
            format: CollectionExportFormat.molia,
            dialogTitle: '导出 Molia',
          );

      expect(outcome, isA<CollectionExportFailed>());
      expect(saver.bytes, isNull);
    });
  });

  group('批量下载', () {
    test('入队 0：入口成功但无候选，结果可区分', () async {
      final downloader = _FakeDownloader(enqueued: 0, done: 0, failed: 0);
      final enqueued = <int>[];
      var started = 0;
      final outcome = await _commands(downloader: downloader).downloadTracks(
        tracks: [_domainTrack('wy', '1')],
        confirm: () async => true,
        onEnqueued: enqueued.add,
        onStarted: () => started++,
      );

      expect(outcome, isA<CollectionBatchDownloadFinished>());
      final finished = outcome as CollectionBatchDownloadFinished;
      expect(finished.enqueued, 0);
      expect(enqueued, [0]);
      expect(started, 1, reason: '入口成功即算已开始，页面据此清选择');
      expect(downloader.startCalls, 1);
    });

    test('部分成功：完成 / 失败计数原样带回', () async {
      final downloader = _FakeDownloader(enqueued: 2, done: 1, failed: 1);
      final outcome = await _commands(downloader: downloader).downloadTracks(
        tracks: [_domainTrack('wy', '1'), _domainTrack('wy', '2')],
        confirm: () async => true,
      );

      expect(outcome, isA<CollectionBatchDownloadFinished>());
      final finished = outcome as CollectionBatchDownloadFinished;
      expect(finished.enqueued, 2);
      expect(finished.done, 1);
      expect(finished.failed, 1);
    });

    test('省流取消：不调批量入口，也不回调已开始', () async {
      final downloader = _FakeDownloader();
      var started = 0;
      final outcome = await _commands(downloader: downloader).downloadTracks(
        tracks: [_domainTrack('wy', '1')],
        confirm: () async => false,
        onStarted: () => started++,
      );

      expect(outcome, isA<CollectionBatchDownloadCancelled>());
      expect(downloader.startCalls, 0);
      expect(started, 0);
    });

    test('批量入口失败：类型化失败，不回调已开始', () async {
      final downloader = _FakeDownloader(error: StateError('queue'));
      var started = 0;
      final outcome = await _commands(downloader: downloader).downloadTracks(
        tracks: [_domainTrack('wy', '1')],
        confirm: () async => true,
        onStarted: () => started++,
      );

      expect(outcome, isA<CollectionBatchDownloadFailed>());
      expect((outcome as CollectionBatchDownloadFailed).error, isNotNull);
      expect(started, 0);
    });
  });
}

CollectionIoCommands _commands({
  _FakeFiles? files,
  PlaylistImportService? importService,
  PlaylistImportTarget? importTarget,
  Iterable<String> Function()? playlistNames,
  CollectionImportReview? review,
  CollectionLinkImporter? linkImporter,
  CollectionExportLibrary? exportLibrary,
  CollectionPlaylistBackup? backup,
  CollectionExportSaver? saver,
  CollectionBatchDownloader? downloader,
}) {
  final source = files ?? _FakeFiles();
  return CollectionIoCommands(
    filePicker: source,
    fileReader: source,
    importService:
        importService ??
        PlaylistImportService(
          localImporter: _FakeLocalImporter({}),
          resolver: _FakeResolver({}),
        ),
    importTarget: importTarget ?? _FakeTarget(),
    playlistNames: playlistNames ?? () => const [],
    reviewImport: review ?? (_) async => true,
    linkImporter: linkImporter,
    exportLibrary: exportLibrary,
    backup: backup,
    saver: saver,
    downloader: downloader,
  );
}

PlaylistTrack _track(String source, String id) => PlaylistTrack(
  playlistId: 0,
  sourceKey: source,
  songId: id,
  title: 'Song $id',
  addedAt: 1,
);

Track _domainTrack(String source, String id) => Track(
  id: TrackId(source, id),
  title: 'Song $id',
  origin: TrackOrigin.builtin,
);

class _FakeFiles
    implements CollectionPlaylistFilePicker, CollectionPlaylistFileReader {
  _FakeFiles({
    this.path = '/tmp/list.m3u8',
    this.text = '',
    this.pickError,
    this.readError,
    this.existsResult = true,
  });

  String? path;
  String text;
  Object? pickError;
  Object? readError;
  bool existsResult;
  int pickCalls = 0;
  int readCalls = 0;
  final List<String> existsPaths = [];

  @override
  Future<String?> pick({required String dialogTitle}) async {
    pickCalls++;
    final error = pickError;
    if (error != null) throw error;
    return path;
  }

  @override
  Future<String> readText(String path) async {
    readCalls++;
    final error = readError;
    if (error != null) throw error;
    return text;
  }

  @override
  Future<bool> exists(String path) async {
    existsPaths.add(path);
    return existsResult;
  }
}

class _FakeLocalImporter implements PlaylistLocalImporter {
  _FakeLocalImporter(this.paths);

  final Map<String, PlaylistTrack?> paths;

  @override
  Future<PlaylistTrack?> importPath(String path) async => paths[path];
}

class _FakeResolver implements PlaylistKeyResolver {
  _FakeResolver(this.keys, {this.error});

  final Map<String, PlaylistTrack?> keys;
  final Object? error;

  @override
  Future<PlaylistTrack?> resolve(String moliaKey) async {
    final failure = error;
    if (failure != null) throw failure;
    return keys[moliaKey];
  }
}

class _FakeTarget implements PlaylistImportTarget {
  _FakeTarget({this.existing = const []});

  final List<String> existing;
  final List<String> created = [];
  final List<List<PlaylistTrack>> addedBatches = [];
  final List<String> deleted = [];
  bool failAdd = false;

  @override
  Future<int> addTracks(int playlistId, List<PlaylistTrack> tracks) async {
    if (failAdd) throw StateError('add failed');
    addedBatches.add(tracks);
    return tracks.length;
  }

  @override
  Future<int> createPlaylist(String name) async {
    created.add(name);
    return created.length;
  }

  @override
  Future<void> deletePlaylist(int playlistId) async {
    deleted.add(created[playlistId - 1]);
  }
}

class _FakeLinkImporter implements CollectionLinkImporter {
  _FakeLinkImporter({
    this.playlistId = 1,
    this.added = 1,
    this.total = 1,
    this.error,
  });

  final int playlistId;
  final int added;
  final int total;
  final Object? error;
  String? fallbackName;

  @override
  Future<({int playlistId, int added, int total})> importFromLink(
    String sourceKey,
    String rawId, {
    required String fallbackName,
  }) async {
    this.fallbackName = fallbackName;
    final failure = error;
    if (failure != null) throw failure;
    return (playlistId: playlistId, added: added, total: total);
  }
}

class _FakeExportLibrary implements CollectionExportLibrary {
  _FakeExportLibrary({this.coverKey = 'playlist:s1'});

  String? coverKey;
  final Map<String, String?> pageUrls = {};
  final Map<String, DownloadedTrack?> records = {};

  @override
  String? platformPageUrlOf(PlaylistTrack track) => pageUrls[track.key];

  @override
  DownloadedTrack? downloadedRecordOf(PlaylistTrack track) =>
      records[track.key];

  @override
  Future<String?> ensurePlaylistCoverKey(int playlistId) async => coverKey;
}

class _FakeBackup implements CollectionPlaylistBackup {
  _FakeBackup({this.json = '{}'});

  final String json;
  String? playlistSyncId;
  String? coverKey;

  @override
  Future<String> exportPlaylistJson({
    required String playlistSyncId,
    String? coverKey,
  }) async {
    this.playlistSyncId = playlistSyncId;
    this.coverKey = coverKey;
    return json;
  }
}

class _FakeSaver implements CollectionExportSaver {
  _FakeSaver({
    this.result = const SaveAsSaved(
      path: '/tmp/Trip.m3u8',
      displayPath: '/tmp/Trip.m3u8',
      kind: SaveLocationKind.fileSystem,
    ),
    this.error,
  });

  final SaveAsResult result;
  final Object? error;
  String? fileName;
  Uint8List? bytes;
  String? mimeType;
  String? relativeDir;
  String? dialogTitle;

  @override
  Future<SaveAsResult> saveBytes({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String relativeDir = '',
    String? dialogTitle,
  }) async {
    final failure = error;
    if (failure != null) throw failure;
    this.fileName = fileName;
    this.bytes = bytes;
    this.mimeType = mimeType;
    this.relativeDir = relativeDir;
    this.dialogTitle = dialogTitle;
    return result;
  }
}

class _FakeDownloader implements CollectionBatchDownloader {
  _FakeDownloader({
    this.enqueued = 1,
    this.done = 1,
    this.failed = 0,
    this.error,
  });

  final int enqueued;
  final int done;
  final int failed;
  final Object? error;
  int startCalls = 0;

  @override
  Future<CollectionBatchStart> startBatch(
    List<Track> tracks, {
    void Function(int enqueued)? onEnqueued,
  }) async {
    startCalls++;
    final failure = error;
    if (failure != null) throw failure;
    onEnqueued?.call(enqueued);
    return CollectionBatchStart(enqueued: enqueued, done: done, failed: failed);
  }
}
