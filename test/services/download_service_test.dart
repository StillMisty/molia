import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/data/downloads/download_notifications.dart';
import 'package:molia/data/downloads/downloads_repository.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/services/audio_cache_store.dart';
import 'package:molia/services/cache_service.dart';
import 'package:molia/services/cache_storage.dart';
import 'package:molia/data/downloads/downloads_publisher.dart';
import 'package:molia/services/covers/cover_resolution.dart';
import 'package:molia/services/download/download_journal.dart';
import 'package:molia/services/download/download_service.dart';
import 'package:molia/services/download/download_settings.dart';

import '../support/fake_cover_index.dart';
import '../support/fake_download_notifications.dart';
import '../support/fake_download_storage.dart';
import '../support/fake_downloads_publisher.dart';
import '../support/fake_music_source.dart';
import '../support/memory_database.dart';
import '../support/mock_dio.dart';

/// 下载服务：成功落盘 + 离线歌词/封面、进度、取消、失败清理、重名、删除。
void main() {
  late MoliaDatabase db;
  late DownloadsRepository repository;
  late FakeDownloadStorage storage;
  late FakeMusicSource kwSource;
  late FakeMusicSource txSource;

  Track makeTrack({
    String sourceKey = 'kw',
    String songId = '1',
    String title = '测试歌曲',
    String artist = '歌手',
  }) => Track(
    id: TrackId(sourceKey, songId),
    title: title,
    artists: [Artist(name: artist)],
    album: '专辑',
    duration: const Duration(minutes: 3),
    origin: TrackOrigin.builtin,
    qualities: const [
      AudioQuality(type: '320k'),
      AudioQuality(type: '128k'),
    ],
    payload: {'songmid': songId},
  );

  DownloadService makeService({
    Dio? dio,
    DownloadLyricsResolver? lyrics,
    DownloadArtworkResolver? artwork,
    CoverResolver? coverResolver,
    DownloadSettings? settings,
    DownloadsPublisher? publisher,
    DownloadNotifications? notifications,
    CacheService? cacheService,
    int Function()? clock,
  }) {
    final registry = FakeSourceRegistry({'kw': kwSource, 'tx': txSource});
    return DownloadService(
      catalog: CatalogService(registry: registry),
      repository: repository,
      storage: storage,
      dio:
          dio ??
          mockDio((options) => textResponse('unexpected', statusCode: 500)),
      lyricsResolver: lyrics,
      artworkResolver: artwork,
      coverResolver: coverResolver,
      settings: settings,
      publisher: publisher,
      notifications: notifications,
      cacheService: cacheService,
      preferredQuality: () => '320k',
      clock: clock ?? () => 1000,
    );
  }

  setUp(() {
    db = openMemoryDatabase();
    repository = DownloadsRepository(databaseProvider: () => db);
    storage = FakeDownloadStorage();
    kwSource = FakeMusicSource('kw')
      ..resolveUrl = 'https://cdn.example.com/a.mp3';
    txSource = FakeMusicSource('tx')
      ..resolveUrl = 'https://cdn.example.com/b.mp3';
  });

  tearDown(() async {
    await repository.dispose();
    await db.close();
  });

  /// 等任务入队并开始运行（队列 worker 在 microtask 里启动）。
  Future<DownloadTask> waitForRunningTask(
    DownloadService service,
    Track track,
  ) async {
    for (var i = 0; i < 100; i++) {
      final task = service.taskForTrack(track);
      if (task != null && task.status == DownloadTaskStatus.running) {
        return task;
      }
      await Future<void>.delayed(Duration.zero);
    }
    throw StateError('任务未开始运行');
  }

  /// 任务列表（运行 → 等待 → 失败），替代已删除的测试专用 `tasks` 成员。
  List<DownloadTask> audioTasksOf(DownloadService service) => [
    ...service.taskGroups.running,
    ...service.taskGroups.queued,
    ...service.taskGroups.failed,
  ];

  test('下载成功：音频落盘 + 记录入库 + 离线歌词/封面 + 本地副本优先取链', () async {
    final dio = mockDio((options) {
      if (options.uri.path.endsWith('.mp3')) {
        return bytesResponse(
          [1, 2, 3, 4],
          headers: {
            'content-length': ['4'],
          },
        );
      }
      if (options.uri.path.endsWith('cover.jpg')) {
        return bytesResponse([9, 9, 9, 9, 9]);
      }
      return textResponse('not found', statusCode: 404);
    });
    final service = makeService(
      dio: dio,
      lyrics: (track) async =>
          const DownloadLyrics(lyric: '[00:01]原文', translation: '[00:01]译文'),
      artwork: (track) async => 'https://img.example.com/cover.jpg',
    );
    await service.init();
    expect(service.supported, isTrue);

    final track = makeTrack();
    await service.download(track);

    final record = service.records.recordFor('kw', '1');
    expect(record, isNotNull);
    expect(record!.filePath, '/downloads/歌手 - 测试歌曲.mp3');
    expect(record.sizeBytes, 4);
    expect(record.quality, '320k');
    expect(record.lyricPath, '/downloads/lyrics/歌手 - 测试歌曲.lrc');
    expect(record.translationLyricPath, '/downloads/lyrics/歌手 - 测试歌曲.t.lrc');
    expect(record.coverPath, '/downloads/covers/歌手 - 测试歌曲.jpg');
    // 音频文件尾部是下载内容（头部是写入的 ID3 标签）。
    final audioBytes = storage.files[record.filePath!]!;
    expect(audioBytes.sublist(audioBytes.length - 4), [1, 2, 3, 4]);
    expect(storage.files[record.lyricPath], isNotNull);
    expect(storage.files[record.translationLyricPath], isNotNull);
    expect(storage.files[record.coverPath], isNotNull);
    // 成功落库后提交日志不应留下 marker。
    expect(
      storage.files.keys.where((path) => path.startsWith('/download_journal/')),
      isEmpty,
    );
    // 取链音质跟随偏好。
    expect(kwSource.lastResolveQuality?.type, '320k');
    // 落库（重新读库确认）。
    expect(await repository.findByOrigin('kw', '1'), isNotNull);
    // 播放取链优先命中本地副本。
    expect(await service.localUriFor(track), Uri.file(record.filePath!));
    // 已下载状态与本地曲目还原。
    expect(service.records.recordForTrack(track)!.key, 'kw:1');
    final local = record.localTrack!;
    expect(local.id.sourceKey, kLocalSourceKey);
    expect(local.id.id, 'kw:1');
    expect(local.origin, TrackOrigin.localFile);
    expect(local.payload['path'], record.filePath);
    // 离线歌词读取。
    final lyrics = await service.localLyricsFor(local);
    expect(lyrics!.lyric, '[00:01]原文');
    expect(lyrics.translation, '[00:01]译文');
  });

  test('自定义封面：下载封面与标签使用它，不再取网络图', () async {
    var artworkCalls = 0;
    final coverIndex = FakeCoverIndex(
      customUrls: const {'kw:1': 'file:///tmp/custom-cover.jpg'},
      customBytes: {
        'kw:1': Uint8List.fromList([7, 7, 7, 7]),
      },
    );
    final service = makeService(
      dio: mockDio((options) {
        if (options.uri.path.endsWith('.mp3')) {
          return bytesResponse([1, 2, 3, 4]);
        }
        return textResponse('not found', statusCode: 404);
      }),
      coverResolver: CoverResolver(coverIndex),
      artwork: (track) async {
        artworkCalls++;
        return 'https://img.example.com/should-not-be-used.jpg';
      },
    );
    await service.init();

    final track = makeTrack();
    await service.download(track, includeLyrics: false);

    final record = service.records.recordFor('kw', '1');
    expect(record, isNotNull);
    expect(record!.coverPath, '/downloads/covers/歌手 - 测试歌曲.jpg');
    expect(storage.files[record.coverPath], [7, 7, 7, 7]);
    expect(artworkCalls, 0);
  });

  test('默认封面不参与下载：没有真实封面时不写封面', () async {
    final coverIndex = FakeCoverIndex(
      defaultUrl: 'file:///tmp/default-cover.jpg',
    );
    var artworkCalls = 0;
    final service = makeService(
      dio: mockDio((options) {
        if (options.uri.path.endsWith('.mp3')) {
          return bytesResponse([1, 2, 3, 4]);
        }
        return textResponse('not found', statusCode: 404);
      }),
      coverResolver: CoverResolver(coverIndex),
      artwork: (track) async {
        artworkCalls++;
        return null;
      },
    );
    await service.init();

    await service.download(makeTrack(), includeLyrics: false);

    final record = service.records.recordFor('kw', '1');
    expect(record, isNotNull);
    expect(record!.coverPath, isNull, reason: '默认封面只是展示占位');
    expect(artworkCalls, 1, reason: '仍走真实取图端口（这里返回空）');
    expect(coverIndex.readCount, 0, reason: '默认封面没有自定义字节可读');
  });

  test('进度广播：首个进度可见；完成后状态清空', () async {
    final controller = StreamController<Uint8List>();
    final dio = mockDio(
      (options) => ResponseBody(
        controller.stream,
        200,
        headers: {
          'content-length': ['131072'],
        },
      ),
    );
    final service = makeService(dio: dio);
    await service.init();

    final track = makeTrack();
    final future = service.download(track);
    final task = await waitForRunningTask(service, track);
    final progressSeen = Completer<DownloadProgress>();
    task.addListener(() {
      final progress = task.progress;
      if (progress.receivedBytes >= 64 * 1024 && !progressSeen.isCompleted) {
        progressSeen.complete(progress);
      }
    });

    // 第一块 64KB：首个进度不受时间窗口限制，立即可见。
    controller.add(Uint8List(64 * 1024));
    final midway = await progressSeen.future;
    expect(midway.receivedBytes, 64 * 1024);
    expect(midway.fraction, closeTo(0.5, 0.001));
    expect(midway.percent, 50);

    controller.add(Uint8List(64 * 1024));
    await controller.close();
    await future;
    expect(service.taskForTrack(track), isNull);
    expect(service.records.recordFor('kw', '1'), isNotNull);
  });

  test('进度广播：快速分片按时间合并，首个与收尾 100% 仍立即送达', () async {
    final controller = StreamController<Uint8List>();
    var now = 1000;
    final dio = mockDio(
      (options) => ResponseBody(
        controller.stream,
        200,
        headers: {
          'content-length': ['400'],
        },
      ),
    );
    final service = makeService(dio: dio, clock: () => now);
    await service.init();

    final track = makeTrack();
    final future = service.download(track);
    final task = await waitForRunningTask(service, track);
    final notified = <int>[];
    task.addListener(() {
      // 收尾时的状态通知不算进度（终态由 status 单独表达）。
      if (task.status == DownloadTaskStatus.running) {
        notified.add(task.progress.receivedBytes);
      }
    });

    // 四个分片在同一毫秒内到达：中间进度合并，只保留首个与终态。
    controller.add(Uint8List(100));
    controller.add(Uint8List(100));
    controller.add(Uint8List(100));
    controller.add(Uint8List(100));
    await controller.close();
    await future;

    expect(notified, [100, 400], reason: '100ms 内合并，100% 不被节流吞掉');
    expect(service.taskForTrack(track), isNull);
  });

  test('进度广播：超过 100ms 窗口的中间进度照常送达', () async {
    final controller = StreamController<Uint8List>();
    var now = 1000;
    final dio = mockDio(
      (options) => ResponseBody(
        controller.stream,
        200,
        headers: {
          'content-length': ['400'],
        },
      ),
    );
    final service = makeService(dio: dio, clock: () => now);
    await service.init();

    final track = makeTrack();
    final future = service.download(track);
    final task = await waitForRunningTask(service, track);
    final notified = <int>[];
    task.addListener(() {
      if (task.status == DownloadTaskStatus.running) {
        notified.add(task.progress.receivedBytes);
      }
    });

    /// 等分片被写流消费后再推进时钟（时钟读数与分片处理顺序一一对应）。
    Future<void> waitForChunk(int received) async {
      while (storage.lastProgressReceived != received) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    controller.add(Uint8List(100)); // 1000：首个进度（立即送达）
    await waitForChunk(100);
    now += 40;
    controller.add(Uint8List(100)); // 1040：窗口内（合并）
    await waitForChunk(200);
    now += 120;
    controller.add(Uint8List(100)); // 1160：距上次通知 160ms（送达）
    await waitForChunk(300);
    controller.add(Uint8List(100)); // 1160：已收满（立即送达）
    await waitForChunk(400);
    await controller.close();
    await future;

    expect(notified, [100, 300, 400]);
  });

  test('取消：清理半成品、不落记录、抛 cancelled 失败', () async {
    final gate = Completer<void>();
    Stream<Uint8List> slowStream() async* {
      yield Uint8List(100);
      await gate.future;
      yield Uint8List(100);
    }

    final dio = mockDio(
      (options) => ResponseBody(
        slowStream(),
        200,
        headers: {
          'content-length': ['1000'],
        },
      ),
    );
    final service = makeService(dio: dio);
    await service.init();

    final track = makeTrack();
    final future = service.download(track);
    // 先挂错误断言（避免下载先于断言完成被判未处理异步错误）。
    final expectation = expectLater(
      future,
      throwsA(
        predicate((e) => e is SourceFailure && e.kind == FailureKind.cancelled),
      ),
    );
    await waitForRunningTask(service, track);
    expect(service.taskForTrack(track), isNotNull);

    service.cancelTrack(track);
    gate.complete();

    await expectation;
    expect(service.records.recordFor('kw', '1'), isNull);
    expect(await repository.findByOrigin('kw', '1'), isNull);
    expect(storage.files, isEmpty);
    expect(storage.deleted.where((path) => path.endsWith('.part')), isNotEmpty);
  });

  test('下载失败（HTTP 500）：抛 network 失败、无残留文件与记录', () async {
    final dio = mockDio((options) => textResponse('err', statusCode: 500));
    final service = makeService(dio: dio);
    await service.init();
    final track = makeTrack();

    await expectLater(
      service.download(track),
      throwsA(
        predicate((e) => e is SourceFailure && e.kind == FailureKind.network),
      ),
    );
    expect(service.records.recordFor('kw', '1'), isNull);
    expect(storage.files, isEmpty);
    expect(service.taskForTrack(track)?.status, DownloadTaskStatus.failed);
    expect(
      service.taskForTrack(track)?.isActive,
      isFalse,
      reason: '失败任务不再对外暴露最后进度',
    );
  });

  test('重名策略：不同原曲同标题自动追加 (2)', () async {
    final dio = mockDio(
      (options) => bytesResponse(
        [1, 2],
        headers: {
          'content-length': ['2'],
        },
      ),
    );
    final service = makeService(dio: dio);
    await service.init();

    await service.download(makeTrack(sourceKey: 'kw', songId: '1'));
    await service.download(makeTrack(sourceKey: 'tx', songId: '2'));

    expect(
      service.records.recordFor('kw', '1')!.filePath,
      '/downloads/歌手 - 测试歌曲.mp3',
    );
    expect(
      service.records.recordFor('tx', '2')!.filePath,
      '/downloads/歌手 - 测试歌曲 (2).mp3',
    );
  });

  test('重复下载 / 本地曲目 / 平台不支持：抛可读 unsupported 失败', () async {
    final dio = mockDio(
      (options) => bytesResponse(
        [1],
        headers: {
          'content-length': ['1'],
        },
      ),
    );
    final service = makeService(dio: dio);
    await service.init();
    final track = makeTrack();
    await service.download(track);

    await expectLater(
      service.download(track),
      throwsA(
        predicate(
          (e) =>
              e is SourceFailure &&
              e.kind == FailureKind.unsupported &&
              e.l10nKey == 'downloadAlreadyExists',
        ),
      ),
    );
    await expectLater(
      service.download(service.records.recordFor('kw', '1')!.localTrack!),
      throwsA(
        predicate(
          (e) => e is SourceFailure && e.l10nKey == 'downloadLocalTrack',
        ),
      ),
    );

    final unavailable = DownloadService(
      catalog: CatalogService(registry: FakeSourceRegistry({'kw': kwSource})),
      repository: repository,
      storage: FakeDownloadStorage(available: false),
      dio: dio,
    );
    await unavailable.init();
    expect(unavailable.supported, isFalse);
    await expectLater(
      unavailable.download(track),
      throwsA(
        predicate(
          (e) => e is SourceFailure && e.l10nKey == 'downloadUnsupported',
        ),
      ),
    );
  });

  test('删除：清记录 + 清音频/歌词/封面文件', () async {
    final dio = mockDio((options) {
      if (options.uri.path.endsWith('.mp3')) {
        return bytesResponse(
          [1, 2],
          headers: {
            'content-length': ['2'],
          },
        );
      }
      return bytesResponse([9]);
    });
    final service = makeService(
      dio: dio,
      lyrics: (track) async => const DownloadLyrics(lyric: 'lrc'),
      artwork: (track) async => 'https://img.example.com/cover.jpg',
    );
    await service.init();
    final track = makeTrack();
    await service.download(track);
    final record = service.records.recordFor('kw', '1')!;

    await service.delete(record);

    expect(service.records.recordFor('kw', '1'), isNull);
    expect(await repository.findByOrigin('kw', '1'), isNull);
    expect(storage.files.containsKey(record.filePath!), isFalse);
    expect(storage.files.containsKey(record.lyricPath), isFalse);
    expect(storage.files.containsKey(record.translationLyricPath), isFalse);
    expect(storage.files.containsKey(record.coverPath), isFalse);
  });

  test('init 加载已有记录（跨启动恢复）', () async {
    await repository.insert(
      DownloadedTrack(
        originSourceKey: 'kw',
        originSongId: '9',
        title: '已有下载',
        filePath: '/downloads/已有下载.mp3',
        sizeBytes: 10,
        downloadedAt: 500,
      ),
    );

    final service = makeService();
    await service.init();

    expect(service.initialized, isTrue);
    expect(service.records.downloads, hasLength(1));
    expect(service.records.recordFor('kw', '9')!.title, '已有下载');
  });

  test('崩溃恢复：journal + 最终文件存在时补记录并删 marker', () async {
    final journal = DownloadJournal(storage);
    final pending = DownloadedTrack(
      originSourceKey: 'kw',
      originSongId: 'recover',
      title: '恢复歌曲',
      filePath: '/downloads/恢复歌曲.mp3',
      sizeBytes: 2,
      quality: '320k',
      raw: const {'songmid': 'recover'},
      downloadedAt: 700,
    );
    storage.files[pending.filePath!] = [1, 2];
    await journal.write(pending);

    final service = makeService();
    await service.init();

    expect(service.records.recordFor('kw', 'recover')!.title, '恢复歌曲');
    expect(await repository.findByOrigin('kw', 'recover'), isNotNull);
    expect(await journal.readAll(), isEmpty);
  });

  test('崩溃恢复：marker 无最终文件时只清理 marker', () async {
    final journal = DownloadJournal(storage);
    await journal.write(
      DownloadedTrack(
        originSourceKey: 'kw',
        originSongId: 'missing',
        title: '未完成',
        filePath: '/downloads/未完成.mp3',
        sizeBytes: 2,
        downloadedAt: 700,
      ),
    );

    final service = makeService();
    await service.init();

    expect(service.records.recordFor('kw', 'missing'), isNull);
    expect(await journal.readAll(), isEmpty);
  });

  test('崩溃恢复：同 key 分项记录不阻塞音频恢复，且保留歌词路径', () async {
    final journal = DownloadJournal(storage);
    final existing = DownloadedTrack(
      originSourceKey: 'kw',
      originSongId: 'partial',
      title: '分项记录',
      lyricPath: '/downloads/lyrics/分项记录.lrc',
      downloadedAt: 600,
    );
    await repository.insert(existing);
    final pending = DownloadedTrack(
      originSourceKey: 'kw',
      originSongId: 'partial',
      title: '分项记录',
      filePath: '/downloads/分项记录.mp3',
      sizeBytes: 2,
      lyricPath: existing.lyricPath,
      downloadedAt: 700,
    );
    storage.files[pending.filePath!] = [1, 2];
    expect(await journal.write(pending), isTrue);

    final service = makeService();
    await service.init();

    final record = service.records.recordFor('kw', 'partial')!;
    expect(record.filePath, pending.filePath);
    expect(record.lyricPath, existing.lyricPath);
    expect(await journal.readAll(), isEmpty);
  });

  test('提交日志不可用：rename 前中止，无最终文件 / 记录 / marker', () async {
    storage.journalRootPath = null;
    final dio = mockDio(
      (options) => bytesResponse(
        [1, 2],
        headers: {
          'content-length': ['2'],
        },
      ),
    );
    final service = makeService(dio: dio);
    await service.init();
    final track = makeTrack();

    await expectLater(
      service.download(track),
      throwsA(
        predicate((e) => e is SourceFailure && e.l10nKey == 'downloadFailed'),
      ),
    );
    expect(service.records.recordFor('kw', '1'), isNull);
    expect(storage.files.containsKey('/downloads/歌手 - 测试歌曲.mp3'), isFalse);
    expect(storage.files, isEmpty);
  });

  test('崩溃恢复：同 key 已有记录时只清理 marker', () async {
    final journal = DownloadJournal(storage);
    final record = DownloadedTrack(
      originSourceKey: 'kw',
      originSongId: 'already',
      title: '已落库',
      filePath: '/downloads/已落库.mp3',
      sizeBytes: 2,
      downloadedAt: 700,
    );
    await repository.insert(record);
    storage.files[record.filePath!] = [1, 2];
    await journal.write(record);

    final service = makeService();
    await service.init();

    expect(service.records.downloads, hasLength(1));
    expect(service.records.recordFor('kw', 'already')!.title, '已落库');
    expect(await journal.readAll(), isEmpty);
  });

  group('导入本地文件', () {
    /// 最小 ID3v2.3 标签 + 音频字节（TIT2/TPE1，UTF-16+BOM 文本）。
    List<int> localMp3({required String title, required String artist}) {
      List<int> frame(String id, String text) {
        final body = <int>[
          0x01, 0xFF, 0xFE, // UTF-16LE + BOM
          for (final unit in text.codeUnits) ...[unit & 0xFF, unit >> 8],
        ];
        return [
          ...ascii.encode(id),
          (body.length >> 24) & 0xFF,
          (body.length >> 16) & 0xFF,
          (body.length >> 8) & 0xFF,
          body.length & 0xFF,
          0x00,
          0x00,
          ...body,
        ];
      }

      final body = [...frame('TIT2', title), ...frame('TPE1', artist)];
      return [
        0x49, 0x44, 0x33, 0x03, 0x00, 0x00,
        (body.length >> 21) & 0x7F,
        (body.length >> 14) & 0x7F,
        (body.length >> 7) & 0x7F,
        body.length & 0x7F,
        ...body,
        // 音频：一个 128kbps / 44100Hz 的 MPEG1 Layer III 帧头。
        0xFF, 0xFB, 0x90, 0x00,
        for (var i = 0; i < 400; i++) 0x00,
      ];
    }

    test('读标签落记录：就地引用（imported）+ 原文件不动', () async {
      storage.files['/music/歌手 - 歌名.mp3'] = localMp3(
        title: '标签标题',
        artist: '标签歌手',
      );
      final service = makeService();
      await service.init();

      final (imported, skipped) = await service.importLocalFiles([
        '/music/歌手 - 歌名.mp3',
      ]);

      expect((imported, skipped), (1, 0));
      final record = service.records.downloads.single;
      expect(record.imported, isTrue);
      expect(record.title, '标签标题', reason: '优先读文件标签');
      expect(record.artist, '标签歌手');
      expect(record.filePath, '/music/歌手 - 歌名.mp3');
      expect(record.sizeBytes, storage.files['/music/歌手 - 歌名.mp3']!.length);
      expect(record.localTrack?.id.sourceKey, kLocalSourceKey);
      expect(record.localTrack?.payload['path'], '/music/歌手 - 歌名.mp3');
      // 落库（跨启动恢复）且原文件保留。
      expect(
        await repository.findByOrigin(kLocalSourceKey, '/music/歌手 - 歌名.mp3'),
        isNotNull,
      );
      expect(storage.files.containsKey('/music/歌手 - 歌名.mp3'), isTrue);
    });

    test('无标签：文件名兜底拆「歌手 - 歌名」', () async {
      storage.files['/music/老王 - 晚风.mp3'] = [1, 2, 3, 4];
      final service = makeService();
      await service.init();

      await service.importLocalFiles(['/music/老王 - 晚风.mp3']);

      final record = service.records.downloads.single;
      expect(record.title, '晚风');
      expect(record.artist, '老王');
      expect(record.durationMs, isNull);
    });

    test('跳过：非音频后缀 / 文件不存在 / 重复导入幂等', () async {
      storage.files['/music/a.mp3'] = localMp3(title: 'A', artist: 'B');
      final service = makeService();
      await service.init();

      final result = await service.importLocalFiles([
        '/music/a.mp3',
        '/music/cover.jpg',
        '/music/missing.mp3',
      ]);

      expect(result, (1, 2));
      expect(service.records.downloads, hasLength(1));

      // 重复导入同一路径：同键替换，不新增记录。
      final again = await service.importLocalFiles(['/music/a.mp3']);
      expect(again.$1, 1);
      expect(service.records.downloads, hasLength(1));
    });

    test('存储不可用（无文件系统）：全部跳过', () async {
      storage.available = false;
      final service = makeService();
      await service.init();

      expect(await service.importLocalFiles(['/music/a.mp3']), (0, 1));
      expect(service.records.downloads, isEmpty);
    });

    test('删除导入项：只移除记录，不删原文件', () async {
      storage.files['/music/a.mp3'] = localMp3(title: 'A', artist: 'B');
      final service = makeService();
      await service.init();
      await service.importLocalFiles(['/music/a.mp3']);
      final record = service.records.downloads.single;

      await service.delete(record);

      expect(service.records.downloads, isEmpty);
      expect(
        await repository.findByOrigin(kLocalSourceKey, '/music/a.mp3'),
        isNull,
      );
      expect(
        storage.files.containsKey('/music/a.mp3'),
        isTrue,
        reason: '不动原文件',
      );
      expect(storage.deleted, isEmpty, reason: '不触发任何删除');
    });

    test('补发布：跳过导入项', () async {
      storage.files['/music/a.mp3'] = localMp3(title: 'A', artist: 'B');
      final publisher = FakeDownloadsPublisher();
      final service = makeService(publisher: publisher);
      await service.init();
      await service.importLocalFiles(['/music/a.mp3']);

      expect(await service.publishMissingPublicCopies(), (0, 0));
      expect(publisher.published, isEmpty);
      expect(storage.files.containsKey('/music/a.mp3'), isTrue);
    });
  });

  test('指定音质下载：取链使用所选音质，记录写入所选音质', () async {
    final dio = mockDio(
      (options) => bytesResponse(
        [1, 2],
        headers: {
          'content-length': ['2'],
        },
      ),
    );
    final service = makeService(dio: dio);
    await service.init();

    await service.download(makeTrack(), quality: '128k');
    expect(kwSource.lastResolveQuality?.type, '128k');
    expect(service.records.recordFor('kw', '1')!.quality, '128k');
  });

  test('音频缓存命中：直接拷贝到下载目录，不取链 / 不请求网络', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final cacheService = CacheService(
      storage: _FakeCacheStorage(audioDir: '/cache/audio'),
      prefs: prefs,
    );
    final dio = mockDio(
      (options) => textResponse('should not be requested', statusCode: 500),
    );
    final service = DownloadService(
      catalog: CatalogService(registry: FakeSourceRegistry({'kw': kwSource})),
      repository: repository,
      storage: storage,
      dio: dio,
      cacheService: cacheService,
      preferredQuality: () => '320k',
      clock: () => 1000,
    );
    await service.init();

    final cacheName = AudioCacheStore.key(
      sourceKey: 'kw',
      songId: '1',
      quality: '320k',
    );
    storage.files['/cache/audio/$cacheName'] = [7, 7, 7];

    await service.download(makeTrack());
    final record = service.records.recordFor('kw', '1')!;
    expect(record.filePath, '/downloads/歌手 - 测试歌曲.mp3');
    final copied = storage.files[record.filePath]!;
    expect(copied.sublist(copied.length - 3), [7, 7, 7]);
    expect(record.sizeBytes, 3);
  });

  test('音频缓存半成品（同名 .part）：不视为命中，回退网络下载', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final cacheService = CacheService(
      storage: _FakeCacheStorage(audioDir: '/cache/audio'),
      prefs: prefs,
    );
    final dio = mockDio(
      (options) => bytesResponse(
        [1, 2],
        headers: {
          'content-length': ['2'],
        },
      ),
    );
    final service = makeService(dio: dio, cacheService: cacheService);
    await service.init();

    final cacheName = AudioCacheStore.key(
      sourceKey: 'kw',
      songId: '1',
      quality: '320k',
    );
    storage.files['/cache/audio/$cacheName'] = [7, 7, 7];
    storage.files['/cache/audio/$cacheName.part'] = [7];

    await service.download(makeTrack());
    final record = service.records.recordFor('kw', '1')!;
    final downloaded = storage.files[record.filePath]!;
    expect(downloaded.sublist(downloaded.length - 2), [1, 2], reason: '回退网络下载');
  });

  test('缓存 = 已下载：完整缓存命中本地取链（音质回退），.part 不算', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final cacheStorage = _FakeCacheStorage(audioDir: '/cache/audio');
    final cacheService = CacheService(storage: cacheStorage, prefs: prefs);
    final service = makeService(cacheService: cacheService);
    await service.init();

    final track = makeTrack();
    final name320 = AudioCacheStore.key(
      sourceKey: 'kw',
      songId: '1',
      quality: '320k',
    );
    final name128 = AudioCacheStore.key(
      sourceKey: 'kw',
      songId: '1',
      quality: '128k',
    );

    expect(await service.localUriFor(track), isNull);

    // 只有 128k 完整缓存：探测顺序（偏好 320k 在前）回退到 128k。
    storage.files['/cache/audio/$name128'] = [1, 2, 3];
    final hit = await service.localUriFor(track);
    expect(hit, isNotNull);
    expect(hit!.toFilePath(), '/cache/audio/$name128');

    // 320k 出现完整文件但仍有 `.part` 半成品：不视为命中，仍回退 128k。
    storage.files['/cache/audio/$name320'] = [7, 7, 7, 7];
    storage.files['/cache/audio/$name320.part'] = [7];
    expect(
      (await service.localUriFor(track))!.toFilePath(),
      '/cache/audio/$name128',
    );

    // 指定音质同样走回退链；精确命中 128k。
    expect(
      (await service.localUriFor(track, quality: '128k'))!.toFilePath(),
      '/cache/audio/$name128',
    );
  });

  test('缓存 = 已下载：localUriFor 下载记录优先，其次完整缓存（离线可播）', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final cacheStorage = _FakeCacheStorage(audioDir: '/cache/audio');
    final cacheService = CacheService(storage: cacheStorage, prefs: prefs);
    final service = makeService(cacheService: cacheService);
    await service.init();

    final track = makeTrack();
    expect(await service.localUriFor(track), isNull);

    // 完整缓存：直接 file://（不触网、不要求下载记录）。
    final cacheName = AudioCacheStore.key(
      sourceKey: 'kw',
      songId: '1',
      quality: '320k',
    );
    storage.files['/cache/audio/$cacheName'] = [1, 2, 3];
    final cachedUri = await service.localUriFor(track, quality: '320k');
    expect(cachedUri!.isScheme('file'), isTrue);
    expect(cachedUri.toFilePath(), '/cache/audio/$cacheName');

    // 已有下载记录：记录优先于缓存。
    await service.download(track, includeLyrics: false, includeCover: false);
    final record = service.records.recordFor('kw', '1')!;
    final downloadedUri = await service.localUriFor(track, quality: '320k');
    expect(downloadedUri!.toFilePath(), record.filePath);
  });

  test('分项下载：先歌词 / 封面，再音频补齐且不丢分项', () async {
    final dio = mockDio((options) {
      if (options.uri.path.endsWith('cover.jpg')) {
        return bytesResponse([9, 9, 9]);
      }
      return bytesResponse(
        [1, 2],
        headers: {
          'content-length': ['2'],
        },
      );
    });
    final service = makeService(
      dio: dio,
      lyrics: (track) async => const DownloadLyrics(lyric: '[00:01]词'),
      artwork: (track) async => 'https://img.example.com/cover.jpg',
    );
    await service.init();
    final track = makeTrack();

    await service.downloadLyrics(track);
    var record = service.records.recordFor('kw', '1')!;
    expect(record.hasAudio, isFalse);
    expect(record.hasLyrics, isTrue);
    expect(record.lyricPath, '/downloads/lyrics/歌手 - 测试歌曲.lrc');

    await service.downloadCover(track);
    record = service.records.recordFor('kw', '1')!;
    expect(record.hasCover, isTrue);
    expect(record.coverPath, '/downloads/covers/歌手 - 测试歌曲.jpg');

    // 再下音频（不带分项）：既有歌词 / 封面保留。
    await service.download(track, includeLyrics: false, includeCover: false);
    record = service.records.recordFor('kw', '1')!;
    expect(record.hasAudio, isTrue);
    expect(record.hasLyrics, isTrue);
    expect(record.hasCover, isTrue);
    expect(record.filePath, '/downloads/歌手 - 测试歌曲.mp3');
  });

  test('分项下载：无歌词 / 无封面时抛可读失败', () async {
    final service = makeService();
    await service.init();
    final track = makeTrack();

    await expectLater(
      service.downloadLyrics(track),
      throwsA(
        predicate((e) => e is SourceFailure && e.l10nKey == 'downloadNoLyrics'),
      ),
    );
    await expectLater(
      service.downloadCover(track),
      throwsA(
        predicate(
          (e) => e is SourceFailure && e.l10nKey == 'downloadNoArtwork',
        ),
      ),
    );
  });

  test('文件名模板：按下载设置生成基名', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = DownloadSettings();
    await settings.init();
    await settings.setFilenameTemplate('{title} - {artist}');
    final dio = mockDio(
      (options) => bytesResponse(
        [1, 2],
        headers: {
          'content-length': ['2'],
        },
      ),
    );
    final service = makeService(dio: dio, settings: settings);
    await service.init();

    await service.download(makeTrack());
    expect(
      service.records.recordFor('kw', '1')!.filePath,
      '/downloads/测试歌曲 - 歌手.mp3',
    );
  });

  test('标签嵌入开关关闭：文件保持原始下载内容', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = DownloadSettings();
    await settings.init();
    await settings.setEmbedTags(false);
    final dio = mockDio(
      (options) => bytesResponse(
        [1, 2],
        headers: {
          'content-length': ['2'],
        },
      ),
    );
    final service = makeService(dio: dio, settings: settings);
    await service.init();

    await service.download(makeTrack());
    final record = service.records.recordFor('kw', '1')!;
    expect(storage.files[record.filePath], [1, 2]);
  });

  test('文件维护：半成品清扫 / 孤儿文件扫描与删除', () async {
    final service = makeService();
    await service.init();
    // 预置：一个已完成文件 + 一个半成品 + 一个孤儿。
    storage.files['/downloads/歌手 - 测试歌曲.mp3'] = [1];
    storage.files['/downloads/歌手 - 测试歌曲.mp3.part'] = [2];
    storage.files['/downloads/orphan.mp3'] = [3];
    storage.files['/downloads/lyrics/orphan.lrc'] = [4];

    final cleaned = await service.cleanupIncompleteDownloads();
    expect(cleaned, 1);
    expect(storage.files.containsKey('/downloads/歌手 - 测试歌曲.mp3.part'), isFalse);

    final orphans = await service.orphanFiles();
    expect(
      orphans,
      containsAll(['/downloads/orphan.mp3', '/downloads/lyrics/orphan.lrc']),
    );
    expect(orphans, contains('/downloads/歌手 - 测试歌曲.mp3'));

    final deleted = await service.deleteOrphanFiles();
    expect(deleted, 3);
    expect(storage.files.keys, isEmpty);
  });

  test('文件维护：运行中任务的输出不算孤儿，也不会被残留清理删除', () async {
    final controller = StreamController<Uint8List>();
    final lyricsGate = Completer<DownloadLyrics?>();
    final dio = mockDio(
      (options) => ResponseBody(
        controller.stream,
        200,
        headers: {
          'content-length': ['2'],
        },
      ),
    );
    final service = makeService(dio: dio, lyrics: (track) => lyricsGate.future);
    await service.init();

    final track = makeTrack();
    final future = service.download(track);
    await waitForRunningTask(service, track);
    const audioPath = '/downloads/歌手 - 测试歌曲.mp3';
    // 网络流收尾后音频改名；歌词解析仍被挂起，记录尚未落库：此时文件只能
    // 靠活跃输出集合保护。
    controller.add(Uint8List.fromList([1, 2]));
    await controller.close();
    for (var i = 0; i < 100 && !storage.files.containsKey(audioPath); i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(storage.files.containsKey(audioPath), isTrue);
    expect(
      service.taskForTrack(track)?.status,
      DownloadTaskStatus.running,
      reason: '歌词解析仍被挂起',
    );

    expect(await service.orphanFiles(), isNot(contains(audioPath)));
    expect(
      await service.deleteOrphanFiles(paths: [audioPath]),
      0,
      reason: '活跃输出不参与残留清理',
    );
    expect(storage.files.containsKey(audioPath), isTrue);

    storage.files['/downloads/notes.txt'] = [1];
    expect(await service.deleteOrphanFiles(paths: ['/downloads/notes.txt']), 0);
    expect(storage.files.containsKey('/downloads/notes.txt'), isTrue);

    lyricsGate.complete(const DownloadLyrics(lyric: '[00:01]原文'));
    await future;

    expect(await service.orphanFiles(), isEmpty);
  });

  test('文件维护：按扫描批次删除，跳过已引用与不可识别文件', () async {
    final service = makeService();
    await service.init();
    storage.files['/downloads/keep.mp3'] = [1, 2];
    storage.files['/downloads/orphan.mp3'] = [3];
    storage.files['/downloads/notes.txt'] = [4];
    await service.importLocalFiles(['/downloads/keep.mp3']);

    final orphans = await service.orphanFiles();
    expect(orphans, ['/downloads/orphan.mp3']);
    expect(
      await service.deleteOrphanFiles(
        paths: [...orphans, '/downloads/keep.mp3', '/downloads/notes.txt'],
      ),
      1,
    );
    expect(storage.files.containsKey('/downloads/keep.mp3'), isTrue);
    expect(storage.files.containsKey('/downloads/notes.txt'), isTrue);
    expect(storage.files.containsKey('/downloads/orphan.mp3'), isFalse);
  });

  test('孤儿文件：已被记录引用的文件不算孤儿', () async {
    final dio = mockDio((options) {
      if (options.uri.path.endsWith('cover.jpg')) {
        return bytesResponse([9, 9, 9]);
      }
      return bytesResponse(
        [1, 2],
        headers: {
          'content-length': ['2'],
        },
      );
    });
    final service = makeService(
      dio: dio,
      lyrics: (track) async => const DownloadLyrics(lyric: '[00:01]词'),
      artwork: (track) async => 'https://img.example.com/cover.jpg',
    );
    await service.init();
    await service.download(makeTrack());

    expect(await service.orphanFiles(), isEmpty);
  });

  test('批量候选：跳过本地 / 已下载 / active / 重复 key，保留原入参位置', () async {
    final controller = StreamController<Uint8List>();
    final dio = mockDio(
      (options) => ResponseBody(
        controller.stream,
        200,
        headers: {
          'content-length': ['2'],
        },
      ),
    );
    await repository.insert(
      DownloadedTrack(
        originSourceKey: 'kw',
        originSongId: 'downloaded',
        title: '已下载',
        filePath: '/downloads/downloaded.mp3',
        sizeBytes: 1,
        downloadedAt: 1,
      ),
    );
    final service = makeService(dio: dio);
    await service.init();

    final downloaded = makeTrack(
      sourceKey: 'kw',
      songId: 'downloaded',
      title: '已下载',
    );
    const local = Track(
      id: TrackId('local', '/downloads/downloaded.mp3'),
      title: '本地',
      origin: TrackOrigin.localFile,
      payload: {'path': '/downloads/downloaded.mp3'},
    );
    final active = makeTrack(sourceKey: 'tx', songId: 'active');
    final target = makeTrack(sourceKey: 'kw', songId: 'target');

    final activeFuture = service.download(active);
    unawaited(activeFuture.catchError((_) {}));
    await waitForRunningTask(service, active);

    final candidates = service.batchCandidates([
      downloaded,
      local,
      active,
      target,
      target,
    ]);
    expect(candidates, hasLength(1));
    expect(candidates.single.index, 3, reason: 'index 是原入参位置');
    expect(candidates.single.track.id, target.id);

    // 清理进行中的任务：dispose 会取消 token 并停止队列通知；不再等待
    // 已废弃的任务 future。
    service.dispose();
    unawaited(controller.close());
  });

  test('批量取消排队任务：不产生未处理错误，取消不计失败', () async {
    final first = StreamController<Uint8List>();
    final dio = mockDio((options) {
      if (options.uri.path.endsWith('a.mp3')) {
        return ResponseBody(
          first.stream,
          200,
          headers: {
            'content-length': ['2'],
          },
        );
      }
      return textResponse('unexpected', statusCode: 500);
    });
    final service = makeService(dio: dio);
    await service.init();

    final kw = makeTrack(sourceKey: 'kw', songId: '1');
    final tx = makeTrack(sourceKey: 'tx', songId: '2');
    final batch = service.downloadBatch([kw, tx]);
    await waitForRunningTask(service, kw);

    // 第二条还在排队：取消它的 completeError 必须已有 listener。
    service.cancelTrack(tx);
    expect(service.taskForTrack(tx), isNull);

    first.add(Uint8List.fromList([1, 2]));
    await first.close();

    expect(await batch, (1, 0));
    expect(service.records.recordFor('kw', '1'), isNotNull);
    expect(service.records.recordFor('tx', '2'), isNull);
  });

  test('批量失败任务重试：批次结束后走单任务通知', () async {
    var txCalls = 0;
    final notifications = FakeDownloadNotifications();
    final dio = mockDio((options) {
      if (!options.uri.path.endsWith('b.mp3')) {
        return textResponse('unexpected', statusCode: 500);
      }
      txCalls++;
      if (txCalls == 1) return textResponse('err', statusCode: 500);
      return bytesResponse(
        [1, 2],
        headers: {
          'content-length': ['2'],
        },
      );
    });
    final service = makeService(dio: dio, notifications: notifications);
    await service.init();

    final track = makeTrack(sourceKey: 'tx', songId: '2');
    expect(await service.downloadBatch([track]), (0, 1));
    expect(
      notifications.events.where((event) => event.id == 'batch'),
      isNotEmpty,
    );
    notifications.events.clear();

    final failed = audioTasksOf(service).single;
    expect(failed.status, DownloadTaskStatus.failed);
    final retried = service.retryTask(failed);
    // 重试任务不带旧的批量位置，入队即替换失败任务。
    expect(audioTasksOf(service).single, isNot(same(failed)));
    await retried;

    expect(notifications.events.first.method, 'start');
    expect(notifications.events.first.id, 'track:tx:2');
    expect(notifications.events.first.index, isNull);
    expect(
      notifications.events.where((event) => event.id == 'batch'),
      isEmpty,
      reason: '批次已结束，重试不得再进批量通知',
    );
    expect(notifications.events.last.method, 'stop');
    expect(notifications.events.last.id, 'track:tx:2');
  });

  test('批量下载：先一次性入队全部，页面立即看到运行 + 等待任务', () async {
    final first = StreamController<Uint8List>();
    final second = StreamController<Uint8List>();
    final dio = mockDio((options) {
      if (options.uri.path.endsWith('a.mp3')) {
        return ResponseBody(
          first.stream,
          200,
          headers: {
            'content-length': ['2'],
          },
        );
      }
      if (options.uri.path.endsWith('b.mp3')) {
        return ResponseBody(
          second.stream,
          200,
          headers: {
            'content-length': ['2'],
          },
        );
      }
      return textResponse('not found', statusCode: 404);
    });
    final service = makeService(dio: dio);
    await service.init();

    final kw = makeTrack(sourceKey: 'kw', songId: '1');
    final tx = makeTrack(sourceKey: 'tx', songId: '2');
    int? enqueued;
    final batch = service.downloadBatch([
      kw,
      tx,
    ], onEnqueued: (count) => enqueued = count);
    await waitForRunningTask(service, kw);

    // 第一条还在下载，第二条已经在等待列表（不是等第一条完成后才入队）。
    expect(enqueued, 2, reason: '回调在全部入队后、等待结果前触发');
    expect(
      [for (final task in audioTasksOf(service)) task.status],
      [DownloadTaskStatus.running, DownloadTaskStatus.queued],
    );
    expect(audioTasksOf(service).map((task) => task.track.id), [kw.id, tx.id]);

    first.add(Uint8List.fromList([1, 2]));
    await first.close();
    await waitForRunningTask(service, tx);
    second.add(Uint8List.fromList([3, 4]));
    await second.close();

    expect(await batch, (2, 0));
  });

  test('批量下载：顺序执行，跳过已下载与本地曲目', () async {
    final dio = mockDio(
      (options) => bytesResponse(
        [1, 2],
        headers: {
          'content-length': ['2'],
        },
      ),
    );
    final service = makeService(dio: dio);
    await service.init();

    // 先下载 kw:1（批内应被跳过）。
    await service.download(makeTrack());
    const local = Track(
      id: TrackId('local', 'kw:9'),
      title: '本地',
      origin: TrackOrigin.localFile,
      payload: {'path': '/downloads/x.mp3'},
    );
    final (done, failed) = await service.downloadBatch([
      makeTrack(),
      makeTrack(sourceKey: 'tx', songId: '2'),
      local,
    ]);
    expect(done, 1);
    expect(failed, 0);
    expect(service.records.recordFor('tx', '2')?.hasAudio, isTrue);
  });

  test('任务列表：tasks / taskForTrack 暴露曲目与进度，完成后清空', () async {
    final controller = StreamController<Uint8List>();
    final dio = mockDio(
      (options) => ResponseBody(
        controller.stream,
        200,
        headers: {
          'content-length': ['65536'],
        },
      ),
    );
    final service = makeService(dio: dio);
    await service.init();

    final track = makeTrack();
    final download = service.download(track);
    final task = await waitForRunningTask(service, track);
    expect(audioTasksOf(service).single.track.id, track.id);
    expect(identical(service.taskForTrack(track), task), isTrue);

    controller.add(Uint8List.fromList(List.filled(65536, 0)));
    await controller.close();
    await download;
    expect(audioTasksOf(service), isEmpty);
    expect(service.taskForTrack(track), isNull);
  });

  test('系统通知：单任务 start → 进度 update（节流）→ stop', () async {
    final controller = StreamController<Uint8List>();
    var now = 1000;
    final dio = mockDio(
      (options) => ResponseBody(
        controller.stream,
        200,
        headers: {
          'content-length': ['131072'],
        },
      ),
    );
    final notifications = FakeDownloadNotifications();
    final service = makeService(
      dio: dio,
      notifications: notifications,
      clock: () => now,
    );
    await service.init();

    final track = makeTrack();
    final download = service.download(track);
    final task = await waitForRunningTask(service, track);
    expect(notifications.methods, ['start']);
    expect(notifications.events.single.id, 'track:kw:1');
    expect(notifications.events.single.title, '测试歌曲');
    expect(notifications.events.single.subtitle, '歌手');

    Future<List<(int?, int?)>> updatePayloads() async => [
      for (final event in notifications.events)
        if (event.method == 'update') (event.progress, event.max),
    ];

    /// 等 UI 进度推进到 [received]：通知推送在同一处、先于 UI 进度发出。
    Future<void> waitForProgress(int received) async {
      final reached = Completer<void>();
      void listener() {
        final progress = task.progress;
        if (progress.receivedBytes >= received && !reached.isCompleted) {
          reached.complete();
        }
      }

      task.addListener(listener);
      listener();
      await reached.future;
      task.removeListener(listener);
    }

    /// 等分片被写流消费：UI 进度另有 100ms 时间节流，不能用它判断处理进度。
    Future<void> waitForChunk(int received) async {
      while (storage.lastProgressReceived != received) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    // 首个分片无条件推送。
    controller.add(Uint8List(32 * 1024));
    await waitForProgress(32 * 1024);
    expect(await updatePayloads(), [(32 * 1024, 131072)]);
    // 500ms 窗口内不再推送。
    controller.add(Uint8List(32 * 1024));
    await waitForChunk(64 * 1024);
    expect(await updatePayloads(), [(32 * 1024, 131072)]);
    // 窗口过后推送新进度。
    now += 600;
    controller.add(Uint8List(32 * 1024));
    await waitForProgress(96 * 1024);
    expect(await updatePayloads(), [(32 * 1024, 131072), (96 * 1024, 131072)]);
    // 已到最后一个分片：节流不再拦住收尾进度。
    controller.add(Uint8List(32 * 1024));
    await waitForProgress(131072);
    expect(await updatePayloads(), [
      (32 * 1024, 131072),
      (96 * 1024, 131072),
      (131072, 131072),
    ]);

    await controller.close();
    await download;
    expect(notifications.methods.last, 'stop');
    expect(notifications.events.last.id, 'track:kw:1');
  });

  test('系统通知：失败与取消同样收尾移除（不残留通知）', () async {
    final failed = FakeDownloadNotifications();
    final failingService = makeService(
      dio: mockDio((options) => textResponse('err', statusCode: 500)),
      notifications: failed,
    );
    await failingService.init();
    await expectLater(
      failingService.download(makeTrack()),
      throwsA(isA<SourceFailure>()),
    );
    expect(failed.methods, ['start', 'stop']);

    // 取消：dio 卡在流里，取消后走 cancelled 路径，通知同样收尾。
    final gate = Completer<void>();
    Stream<Uint8List> slowStream() async* {
      yield Uint8List(100);
      await gate.future;
      yield Uint8List(100);
    }

    final cancelled = FakeDownloadNotifications();
    final service = makeService(
      dio: mockDio(
        (options) => ResponseBody(
          slowStream(),
          200,
          headers: {
            'content-length': ['1000'],
          },
        ),
      ),
      notifications: cancelled,
    );
    await service.init();
    final track = makeTrack();
    final future = service.download(track);
    final expectation = expectLater(
      future,
      throwsA(
        predicate((e) => e is SourceFailure && e.kind == FailureKind.cancelled),
      ),
    );
    await waitForRunningTask(service, track);
    service.cancelTrack(track);
    gate.complete();
    await expectation;
    expect(cancelled.methods, ['start', 'stop']);
  });

  test('系统通知：开关关闭 / 平台不支持时不发通知', () async {
    final dio = mockDio(
      (options) => bytesResponse(
        [1, 2],
        headers: {
          'content-length': ['2'],
        },
      ),
    );
    SharedPreferences.setMockInitialValues({});
    final settings = DownloadSettings();
    await settings.init();
    await settings.setNotifications(false);
    final disabled = FakeDownloadNotifications();
    final offService = makeService(
      dio: dio,
      notifications: disabled,
      settings: settings,
    );
    await offService.init();
    expect(offService.notificationsSupported, isTrue);
    await offService.download(makeTrack());
    expect(disabled.events, isEmpty);

    final unsupported = FakeDownloadNotifications(supported: false);
    final desktopService = makeService(dio: dio, notifications: unsupported);
    await desktopService.init();
    expect(desktopService.notificationsSupported, isFalse);
    await desktopService.download(makeTrack(sourceKey: 'tx', songId: '2'));
    expect(unsupported.events, isEmpty);
  });

  test('系统通知：批量共享一条「N/N」通知，批内单任务通知被抑制', () async {
    final dio = mockDio(
      (options) => bytesResponse(
        [1, 2],
        headers: {
          'content-length': ['2'],
        },
      ),
    );
    final notifications = FakeDownloadNotifications();
    final service = makeService(dio: dio, notifications: notifications);
    await service.init();

    // 列表第一首先下过：批量里被跳过，但序号仍占位。
    await service.download(makeTrack());
    notifications.events.clear();
    const local = Track(
      id: TrackId('local', 'kw:9'),
      title: '本地',
      origin: TrackOrigin.localFile,
      payload: {'path': '/downloads/x.mp3'},
    );
    final second = makeTrack(sourceKey: 'tx', songId: '2', title: '第二首');

    final (done, failed) = await service.downloadBatch([
      local,
      makeTrack(),
      second,
      second,
    ]);
    expect((done, failed), (1, 0));
    // 只有尝试下载的第三项起通知，序号按原入参位置（「第 3/4 首」）。
    expect(notifications.events.first.method, 'start');
    expect(notifications.events.first.id, 'batch');
    expect(notifications.events.first.title, '第二首');
    expect(notifications.events.first.index, 3);
    expect(notifications.events.first.total, 4);
    expect(notifications.events.last.method, 'stop');
    expect(notifications.events.last.id, 'batch');
    expect(
      notifications.events.where((event) => event.id.startsWith('track:')),
      isEmpty,
      reason: '批内不另发单任务通知',
    );
  });

  test('公共目录发布：音频拷进公共 Downloads，URI 落库', () async {
    final publisher = FakeDownloadsPublisher();
    final dio = mockDio(
      (options) => bytesResponse(
        [1, 2],
        headers: {
          'content-length': ['2'],
        },
      ),
    );
    final service = makeService(dio: dio, publisher: publisher);
    await service.init();
    expect(service.publisherSupported, isTrue);

    await service.download(makeTrack());
    final record = service.records.recordFor('kw', '1')!;
    expect(record.publicUri, 'content://media/external/downloads/1');
    expect(record.hasPublicCopy, isTrue);
    // 发布的是应用目录里的最终文件（标签嵌入之后），不是半成品。
    expect(publisher.published, [record.filePath]);
    expect(publisher.displayNames, ['歌手 - 测试歌曲.mp3']);
    expect(publisher.mimeTypes, ['audio/mpeg']);
    // 落库（重新读库确认 publicUri 持久化）。
    expect(
      (await repository.findByOrigin('kw', '1'))!.publicUri,
      'content://media/external/downloads/1',
    );
  });

  test('公共目录发布失败：下载照常成功，publicUri 为空', () async {
    final publisher = FakeDownloadsPublisher(failPublish: true);
    final dio = mockDio(
      (options) => bytesResponse(
        [1, 2],
        headers: {
          'content-length': ['2'],
        },
      ),
    );
    final service = makeService(dio: dio, publisher: publisher);
    await service.init();

    await service.download(makeTrack());
    final record = service.records.recordFor('kw', '1')!;
    expect(record.hasAudio, isTrue);
    expect(record.publicUri, null);
  });

  test('公共目录发布关闭 / 平台不支持：不调用发布器', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = DownloadSettings();
    await settings.init();
    await settings.setPublishToPublicDir(false);
    final publisher = FakeDownloadsPublisher();
    final dio = mockDio(
      (options) => bytesResponse(
        [1, 2],
        headers: {
          'content-length': ['2'],
        },
      ),
    );
    final service = makeService(
      dio: dio,
      settings: settings,
      publisher: publisher,
    );
    await service.init();
    await service.download(makeTrack());
    expect(service.records.recordFor('kw', '1')!.publicUri, null);
    expect(publisher.published, isEmpty);

    // 非 Android（发布器不支持）：同样 no-op，且 supported 为 false。
    final unsupported = makeService(
      dio: dio,
      publisher: FakeDownloadsPublisher(supported: false),
    );
    await unsupported.init();
    await unsupported.download(makeTrack(sourceKey: 'tx', songId: '2'));
    expect(unsupported.publisherSupported, isFalse);
    expect(unsupported.records.recordFor('tx', '2')!.publicUri, null);
  });

  test('删除下载：回收公共副本（不支持时跳过）', () async {
    final publisher = FakeDownloadsPublisher();
    final dio = mockDio(
      (options) => bytesResponse(
        [1, 2],
        headers: {
          'content-length': ['2'],
        },
      ),
    );
    final service = makeService(dio: dio, publisher: publisher);
    await service.init();
    await service.download(makeTrack());
    final record = service.records.recordFor('kw', '1')!;

    await service.delete(record);
    expect(publisher.removed, ['content://media/external/downloads/1']);
  });

  test('补发布：跳过已有副本，发布缺失记录', () async {
    final publisher = FakeDownloadsPublisher();
    // 已有音频但无公共副本（旧版本留下的记录）。
    storage.files['/downloads/旧歌.mp3'] = [1];
    await repository.insert(
      DownloadedTrack(
        originSourceKey: 'kw',
        originSongId: '9',
        title: '旧歌',
        filePath: '/downloads/旧歌.mp3',
        sizeBytes: 1,
        downloadedAt: 500,
      ),
    );
    // 文件缺失的记录：计入失败。
    await repository.insert(
      DownloadedTrack(
        originSourceKey: 'tx',
        originSongId: '8',
        title: '丢失',
        filePath: '/downloads/丢失.mp3',
        sizeBytes: 1,
        downloadedAt: 400,
      ),
    );

    final dio = mockDio(
      (options) => bytesResponse(
        [1, 2],
        headers: {
          'content-length': ['2'],
        },
      ),
    );
    final service = makeService(dio: dio, publisher: publisher);
    await service.init();
    await service.download(makeTrack(sourceKey: 'kw', songId: '1'));
    expect(publisher.published, hasLength(1)); // 下载时发布的那条

    final (published, failed) = await service.publishMissingPublicCopies();
    expect((published, failed), (1, 1));
    expect(
      service.records.recordFor('kw', '9')!.publicUri,
      'content://media/external/downloads/2',
    );
    expect(
      (await repository.findByOrigin('kw', '9'))!.publicUri,
      'content://media/external/downloads/2',
    );
    expect(service.records.recordFor('tx', '8')!.publicUri, null);
  });

  test('音频 MIME 类型映射（公共目录发布用）', () {
    expect(DownloadService.audioMimeTypeForPath('/a/b.mp3'), 'audio/mpeg');
    expect(DownloadService.audioMimeTypeForPath('/a/b.FLAC'), 'audio/flac');
    expect(DownloadService.audioMimeTypeForPath('/a/b.m4a'), 'audio/mp4');
    expect(DownloadService.audioMimeTypeForPath('/a/b.opus'), 'audio/opus');
    expect(
      DownloadService.audioMimeTypeForPath('/a/b.unknown'),
      'application/octet-stream',
    );
  });
}

/// 假缓存存储：音频目录可控（音频缓存命中测试用）。
class _FakeCacheStorage implements CacheStorage {
  _FakeCacheStorage({this.audioDir = '/cache/audio'});

  final String? audioDir;

  /// 目录列举结果（缓存索引测试注入）：文件名 → 字节数。
  Map<String, int> files = const {};

  @override
  Future<String?> audioCacheDir() async => audioDir;

  @override
  Future<String?> artworkCacheDir() async => null;

  @override
  Future<int?> totalSpaceBytes() async => null;

  @override
  Future<CacheUsage> usage(String dirPath) async => CacheUsage.zero;

  @override
  Future<Map<String, int>> listFiles(String dirPath) async => files;

  @override
  Future<int> deleteWhere(
    String dirPath, {
    required bool Function(String fileName) test,
  }) async => 0;

  @override
  Future<CacheDeleteResult> deleteMatching(
    String dirPath, {
    required String prefix,
    Duration protectAge = Duration.zero,
  }) async => const CacheDeleteResult();

  @override
  Future<void> clear(String dirPath) async {}

  @override
  Future<int> enforceAudioLimit(
    String dirPath, {
    required int maxBytes,
    required Duration protectAge,
  }) async => 0;

  @override
  Future<CacheSweepResult> sweepArtwork(
    String dirPath, {
    required int maxObjects,
    required int staleDays,
  }) async => CacheSweepResult.failed;
}
