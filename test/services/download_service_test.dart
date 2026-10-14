import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/data/downloads/downloads_repository.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/services/cache_service.dart';
import 'package:molia/services/cache_storage.dart';
import 'package:molia/services/download/download_service.dart';
import 'package:molia/services/download/download_settings.dart';

import '../support/fake_download_storage.dart';
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
  }) =>
      Track(
        id: TrackId(sourceKey, songId),
        title: title,
        artists: [Artist(name: artist)],
        album: '专辑',
        duration: const Duration(minutes: 3),
        origin: TrackOrigin.builtin,
        qualities: const [AudioQuality(type: '320k'), AudioQuality(type: '128k')],
        payload: {'songmid': songId},
      );

  DownloadService makeService({
    Dio? dio,
    DownloadLyricsResolver? lyrics,
    DownloadArtworkResolver? artwork,
    DownloadSettings? settings,
  }) {
    final registry = FakeSourceRegistry({
      'kw': kwSource,
      'tx': txSource,
    });
    return DownloadService(
      catalog: CatalogService(registry: registry),
      repository: repository,
      storage: storage,
      dio: dio ??
          mockDio((options) => textResponse('unexpected', statusCode: 500)),
      lyricsResolver: lyrics,
      artworkResolver: artwork,
      settings: settings,
      preferredQuality: () => '320k',
      clock: () => 1000,
    );
  }

  setUp(() {
    db = openMemoryDatabase();
    repository = DownloadsRepository(databaseProvider: () => db);
    storage = FakeDownloadStorage();
    kwSource = FakeMusicSource('kw')..resolveUrl = 'https://cdn.example.com/a.mp3';
    txSource = FakeMusicSource('tx')..resolveUrl = 'https://cdn.example.com/b.mp3';
  });

  tearDown(() async {
    await repository.dispose();
    await db.close();
  });

  test('下载成功：音频落盘 + 记录入库 + 离线歌词/封面 + 本地副本优先取链', () async {
    final dio = mockDio((options) {
      if (options.uri.path.endsWith('.mp3')) {
        return bytesResponse(
          [1, 2, 3, 4],
          headers: {'content-length': ['4']},
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

    final record = service.recordFor('kw', '1');
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
    // 取链音质跟随偏好。
    expect(kwSource.lastResolveQuality?.type, '320k');
    // 落库（重新读库确认）。
    expect(await repository.findByOrigin('kw', '1'), isNotNull);
    // 播放取链优先命中本地副本。
    expect(await service.localUriFor(track), Uri.file(record.filePath!));
    // 已下载状态与本地曲目还原。
    expect(service.recordForTrack(track)!.key, 'kw:1');
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

  test('进度广播：累计 32KB 通知一次；完成后状态清空', () async {
    final controller = StreamController<Uint8List>();
    final dio = mockDio(
      (options) => ResponseBody(
        controller.stream,
        200,
        headers: {'content-length': ['131072']},
      ),
    );
    final service = makeService(dio: dio);
    await service.init();

    final track = makeTrack();
    final progressSeen = Completer<DownloadProgress>();
    service.addListener(() {
      final progress = service.progressForTrack(track);
      if (progress != null &&
          progress.receivedBytes >= 64 * 1024 &&
          !progressSeen.isCompleted) {
        progressSeen.complete(progress);
      }
    });

    final future = service.download(track);
    // 第一块 64KB：越过 32KB 节流阈值，进度可见。
    controller.add(Uint8List(64 * 1024));
    final midway = await progressSeen.future;
    expect(midway.receivedBytes, 64 * 1024);
    expect(midway.fraction, closeTo(0.5, 0.001));
    expect(midway.percent, 50);

    controller.add(Uint8List(64 * 1024));
    await controller.close();
    await future;
    expect(service.progressForTrack(track), isNull);
    expect(service.recordFor('kw', '1'), isNotNull);
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
        headers: {'content-length': ['1000']},
      ),
    );
    final service = makeService(dio: dio);
    await service.init();

    final track = makeTrack();
    final future = service.download(track);
    // 先挂错误断言（避免下载先于断言完成被判未处理异步错误）。
    final expectation = expectLater(
      future,
      throwsA(predicate(
        (e) => e is SourceFailure && e.kind == FailureKind.cancelled,
      )),
    );
    await Future<void>.delayed(Duration.zero);
    expect(service.progressForTrack(track), isNotNull);

    service.cancelTrack(track);
    gate.complete();

    await expectation;
    expect(service.recordFor('kw', '1'), isNull);
    expect(await repository.findByOrigin('kw', '1'), isNull);
    expect(storage.files, isEmpty);
    expect(
      storage.deleted.where((path) => path.endsWith('.part')),
      isNotEmpty,
    );
  });

  test('下载失败（HTTP 500）：抛 network 失败、无残留文件与记录', () async {
    final dio = mockDio((options) => textResponse('err', statusCode: 500));
    final service = makeService(dio: dio);
    await service.init();

    await expectLater(
      service.download(makeTrack()),
      throwsA(predicate(
        (e) => e is SourceFailure && e.kind == FailureKind.network,
      )),
    );
    expect(service.recordFor('kw', '1'), isNull);
    expect(storage.files, isEmpty);
  });

  test('重名策略：不同原曲同标题自动追加 (2)', () async {
    final dio = mockDio(
      (options) => bytesResponse(
        [1, 2],
        headers: {'content-length': ['2']},
      ),
    );
    final service = makeService(dio: dio);
    await service.init();

    await service.download(makeTrack(sourceKey: 'kw', songId: '1'));
    await service.download(makeTrack(sourceKey: 'tx', songId: '2'));

    expect(service.recordFor('kw', '1')!.filePath,
        '/downloads/歌手 - 测试歌曲.mp3');
    expect(service.recordFor('tx', '2')!.filePath,
        '/downloads/歌手 - 测试歌曲 (2).mp3');
  });

  test('重复下载 / 本地曲目 / 平台不支持：抛可读 unsupported 失败', () async {
    final dio = mockDio(
      (options) => bytesResponse([1], headers: {'content-length': ['1']}),
    );
    final service = makeService(dio: dio);
    await service.init();
    final track = makeTrack();
    await service.download(track);

    await expectLater(
      service.download(track),
      throwsA(predicate(
        (e) => e is SourceFailure &&
            e.kind == FailureKind.unsupported &&
            e.l10nKey == 'downloadAlreadyExists',
      )),
    );
    await expectLater(
      service.download(service.recordFor('kw', '1')!.localTrack!),
      throwsA(predicate(
        (e) => e is SourceFailure && e.l10nKey == 'downloadLocalTrack',
      )),
    );

    final unavailable = DownloadService(
      catalog: CatalogService(
        registry: FakeSourceRegistry({'kw': kwSource}),
      ),
      repository: repository,
      storage: FakeDownloadStorage(available: false),
      dio: dio,
    );
    await unavailable.init();
    expect(unavailable.supported, isFalse);
    await expectLater(
      unavailable.download(track),
      throwsA(predicate(
        (e) => e is SourceFailure && e.l10nKey == 'downloadUnsupported',
      )),
    );
  });

  test('删除：清记录 + 清音频/歌词/封面文件', () async {
    final dio = mockDio((options) {
      if (options.uri.path.endsWith('.mp3')) {
        return bytesResponse([1, 2], headers: {'content-length': ['2']});
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
    final record = service.recordFor('kw', '1')!;

    await service.delete(record);

    expect(service.recordFor('kw', '1'), isNull);
    expect(await repository.findByOrigin('kw', '1'), isNull);
    expect(storage.files.containsKey(record.filePath!), isFalse);
    expect(storage.files.containsKey(record.lyricPath), isFalse);
    expect(storage.files.containsKey(record.translationLyricPath), isFalse);
    expect(storage.files.containsKey(record.coverPath), isFalse);
  });

  test('init 加载已有记录（跨启动恢复）', () async {
    await repository.insert(DownloadedTrack(
      originSourceKey: 'kw',
      originSongId: '9',
      title: '已有下载',
      filePath: '/downloads/已有下载.mp3',
      sizeBytes: 10,
      downloadedAt: 500,
    ));

    final service = makeService();
    await service.init();

    expect(service.initialized, isTrue);
    expect(service.downloads, hasLength(1));
    expect(service.recordFor('kw', '9')!.title, '已有下载');
  });

  test('文件名与扩展名工具函数', () {
    expect(
      DownloadService.baseNameFor(makeTrack(title: 'A/B:C*D?E"F<G>H|I')),
      '歌手 - A_B_C_D_E_F_G_H_I',
    );
    expect(
      DownloadService.baseNameFor(Track(
        id: const TrackId('kw', '1'),
        title: '  多   空格  ',
        origin: TrackOrigin.builtin,
      )),
      '多 空格',
    );
    expect(DownloadService.sanitizeFileName('///'), '___');
    expect(DownloadService.sanitizeFileName('   '), 'unknown');

    expect(
      DownloadService.extensionFor(Uri.parse('https://x/a.flac?q=1'), '320k'),
      'flac',
    );
    expect(
      DownloadService.extensionFor(Uri.parse('https://x/a'), 'flac'),
      'flac',
    );
    expect(
      DownloadService.extensionFor(Uri.parse('https://x/a.m3u8'), '128k'),
      'mp3',
    );
  });

  test('指定音质下载：取链使用所选音质，记录写入所选音质', () async {
    final dio = mockDio(
      (options) => bytesResponse([1, 2], headers: {'content-length': ['2']}),
    );
    final service = makeService(dio: dio);
    await service.init();

    await service.download(makeTrack(), quality: '128k');
    expect(kwSource.lastResolveQuality?.type, '128k');
    expect(service.recordFor('kw', '1')!.quality, '128k');
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

    final cacheName = CacheService.audioCacheKey(
      sourceKey: 'kw',
      songId: '1',
      quality: '320k',
    );
    storage.files['/cache/audio/$cacheName'] = [7, 7, 7];

    await service.download(makeTrack());
    final record = service.recordFor('kw', '1')!;
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
      (options) => bytesResponse([1, 2], headers: {'content-length': ['2']}),
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

    final cacheName = CacheService.audioCacheKey(
      sourceKey: 'kw',
      songId: '1',
      quality: '320k',
    );
    storage.files['/cache/audio/$cacheName'] = [7, 7, 7];
    storage.files['/cache/audio/$cacheName.part'] = [7];

    await service.download(makeTrack());
    final record = service.recordFor('kw', '1')!;
    final downloaded = storage.files[record.filePath]!;
    expect(
      downloaded.sublist(downloaded.length - 2),
      [1, 2],
      reason: '回退网络下载',
    );
  });

  test('分项下载：先歌词 / 封面，再音频补齐且不丢分项', () async {
    final dio = mockDio((options) {
      if (options.uri.path.endsWith('cover.jpg')) {
        return bytesResponse([9, 9, 9]);
      }
      return bytesResponse([1, 2], headers: {'content-length': ['2']});
    });
    final service = makeService(
      dio: dio,
      lyrics: (track) async => const DownloadLyrics(lyric: '[00:01]词'),
      artwork: (track) async => 'https://img.example.com/cover.jpg',
    );
    await service.init();
    final track = makeTrack();

    await service.downloadLyrics(track);
    var record = service.recordFor('kw', '1')!;
    expect(record.hasAudio, isFalse);
    expect(record.hasLyrics, isTrue);
    expect(record.lyricPath, '/downloads/lyrics/歌手 - 测试歌曲.lrc');

    await service.downloadCover(track);
    record = service.recordFor('kw', '1')!;
    expect(record.hasCover, isTrue);
    expect(record.coverPath, '/downloads/covers/歌手 - 测试歌曲.jpg');

    // 再下音频（不带分项）：既有歌词 / 封面保留。
    await service.download(track, includeLyrics: false, includeCover: false);
    record = service.recordFor('kw', '1')!;
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
      throwsA(predicate(
        (e) => e is SourceFailure && e.l10nKey == 'downloadNoLyrics',
      )),
    );
    await expectLater(
      service.downloadCover(track),
      throwsA(predicate(
        (e) => e is SourceFailure && e.l10nKey == 'downloadNoArtwork',
      )),
    );
  });

  test('文件名模板：按下载设置生成基名', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = DownloadSettings();
    await settings.init();
    await settings.setFilenameTemplate('{title} - {artist}');
    final dio = mockDio(
      (options) => bytesResponse([1, 2], headers: {'content-length': ['2']}),
    );
    final service = makeService(dio: dio, settings: settings);
    await service.init();

    await service.download(makeTrack());
    expect(
      service.recordFor('kw', '1')!.filePath,
      '/downloads/测试歌曲 - 歌手.mp3',
    );
  });

  test('标签嵌入开关关闭：文件保持原始下载内容', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = DownloadSettings();
    await settings.init();
    await settings.setEmbedTags(false);
    final dio = mockDio(
      (options) => bytesResponse([1, 2], headers: {'content-length': ['2']}),
    );
    final service = makeService(dio: dio, settings: settings);
    await service.init();

    await service.download(makeTrack());
    final record = service.recordFor('kw', '1')!;
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
    expect(orphans, containsAll(['/downloads/orphan.mp3', '/downloads/lyrics/orphan.lrc']));
    expect(orphans, contains('/downloads/歌手 - 测试歌曲.mp3'));

    final deleted = await service.deleteOrphanFiles();
    expect(deleted, 3);
    expect(storage.files.keys, isEmpty);
  });

  test('孤儿文件：已被记录引用的文件不算孤儿', () async {
    final dio = mockDio((options) {
      if (options.uri.path.endsWith('cover.jpg')) {
        return bytesResponse([9, 9, 9]);
      }
      return bytesResponse([1, 2], headers: {'content-length': ['2']});
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

  test('批量下载：顺序执行，跳过已下载与本地曲目', () async {
    final dio = mockDio(
      (options) => bytesResponse([1, 2], headers: {'content-length': ['2']}),
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
    expect(service.recordFor('tx', '2')?.hasAudio, isTrue);
  });

  test('进行中任务：activeTasks 暴露曲目与进度，完成后清空', () async {
    final controller = StreamController<Uint8List>();
    final dio = mockDio(
      (options) => ResponseBody(
        controller.stream,
        200,
        headers: {'content-length': ['65536']},
      ),
    );
    final service = makeService(dio: dio);
    await service.init();

    final track = makeTrack();
    final download = service.download(track);
    await Future<void>.delayed(Duration.zero);
    expect(service.activeTasks.single.$1.id, track.id);

    controller.add(Uint8List.fromList(List.filled(65536, 0)));
    await controller.close();
    await download;
    expect(service.activeTasks, isEmpty);
  });

}

/// 假缓存存储：音频目录可控（音频缓存命中测试用）。
class _FakeCacheStorage implements CacheStorage {
  _FakeCacheStorage({this.audioDir = '/cache/audio'});

  final String? audioDir;

  @override
  Future<String?> audioCacheDir() async => audioDir;

  @override
  Future<String?> artworkCacheDir() async => null;

  @override
  Future<int?> totalSpaceBytes() async => null;

  @override
  Future<CacheUsage> usage(String dirPath) async => CacheUsage.zero;

  @override
  Future<CacheUsage> usageMatching(
    String dirPath, {
    required String prefix,
  }) async =>
      CacheUsage.zero;

  @override
  Future<CacheDeleteResult> deleteMatching(
    String dirPath, {
    required String prefix,
    Duration protectAge = Duration.zero,
  }) async =>
      const CacheDeleteResult();

  @override
  Future<void> clear(String dirPath) async {}

  @override
  Future<int> enforceAudioLimit(
    String dirPath, {
    required int maxBytes,
    required Duration protectAge,
  }) async =>
      0;

  @override
  Future<int> sweepArtwork(
    String dirPath, {
    required int maxObjects,
    required int staleDays,
  }) async =>
      0;
}
