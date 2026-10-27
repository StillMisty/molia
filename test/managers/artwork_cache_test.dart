import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
// 测试直接用 flutter_cache_manager 的内存实现（传递依赖，不触网）。
// ignore: depend_on_referenced_packages
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
// CacheManager.getSingleFile 的 File 来自 package:file（传递依赖）。
// ignore: depend_on_referenced_packages
import 'package:file/file.dart' as pkg_file;
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/managers/artwork_cache.dart';
import 'package:molia/services/cache_service.dart';
import 'package:molia/services/cache_storage_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 纯内存 + 永远失败的 CacheManager：测试不触网、不落平台目录。
class _OfflineCacheManager extends CacheManager {
  _OfflineCacheManager({FileSystem? fileSystem})
      : super(Config(
          'artwork_cache_test_offline',
          repo: NonStoringObjectProvider(),
          fileSystem: fileSystem ?? MemoryCacheSystem(),
          fileService: HttpFileService(),
        ));

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    throw Exception('offline');
  }
}

/// 记录 getSingleFile 调用的内存 CacheManager（系统媒体会话封面本地化）。
class _RecordingCacheManager extends CacheManager {
  _RecordingCacheManager()
      : super(Config(
          'artwork_cache_test_recording',
          repo: _MemoryRepo(),
          fileSystem: MemoryCacheSystem(),
          fileService: HttpFileService(),
        ));

  int singleFileCalls = 0;
  Map<String, String>? lastHeaders;

  @override
  Future<pkg_file.File> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) async {
    singleFileCalls++;
    lastHeaders = headers;
    throw Exception('offline');
  }
}

/// 纯内存 repo：putFile / getFileFromCache 全链路可用，不触碰 sqflite。
class _MemoryRepo implements CacheInfoRepository {
  final Map<String, CacheObject> _store = {};

  /// `getAllObjects` 调用次数：`_pruneMissingEntries` 的唯一入口，用来断言
  /// 「这次 sweep 到底有没有扫描索引」。
  int getAllCalls = 0;

  @override
  Future<bool> open() async => true;

  @override
  Future<bool> close() async => true;

  @override
  Future<bool> exists() async => true;

  @override
  Future<CacheObject?> get(String key) async => _store[key];

  @override
  Future<dynamic> updateOrInsert(CacheObject cacheObject) async {
    _store[cacheObject.key] = cacheObject;
  }

  @override
  Future<CacheObject> insert(
    CacheObject cacheObject, {
    bool setTouchedToNow = true,
  }) async {
    _store[cacheObject.key] = cacheObject;
    return cacheObject;
  }

  @override
  Future<int> update(
    CacheObject cacheObject, {
    bool setTouchedToNow = true,
  }) async {
    _store[cacheObject.key] = cacheObject;
    return 1;
  }

  @override
  Future<int> delete(int id) async {
    final before = _store.length;
    _store.removeWhere((_, value) => value.id == id);
    return before - _store.length;
  }

  @override
  Future<int> deleteAll(Iterable<int> ids) async {
    final idSet = ids.toSet();
    final before = _store.length;
    _store.removeWhere((_, value) => idSet.contains(value.id));
    return before - _store.length;
  }

  @override
  Future<List<CacheObject>> getAllObjects() async {
    getAllCalls++;
    return _store.values.toList();
  }

  @override
  Future<List<CacheObject>> getObjectsOverCapacity(int capacity) async =>
      const [];

  @override
  Future<List<CacheObject>> getOldObjects(Duration maxAge) async => const [];

  @override
  Future<void> deleteDataFile() async {}
}

/// 按路径统计 `createFile` 调用的 FileSystem 包装：`createFile` 是逐条
/// `exists()` 的必经入口，用来验证存活集合内的条目零探测、集合外候选才复核。
class _CountingFileSystem implements FileSystem {
  _CountingFileSystem(this._inner);

  final FileSystem _inner;

  /// 相对路径 → 调用次数。
  final Map<String, int> createFileCounts = {};

  int get createFileCalls =>
      createFileCounts.values.fold(0, (sum, count) => sum + count);

  @override
  Future<pkg_file.File> createFile(String name) {
    createFileCounts.update(name, (count) => count + 1, ifAbsent: () => 1);
    return _inner.createFile(name);
  }
}

Future<void> _waitUntil(
  Future<bool> Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  fail('等待条件超时');
}

/// 记录封面 sweep 调用次数的真实存储（临时目录 + 真实删文件）。
class _SweepCountingStorage extends IoCacheStorage {
  _SweepCountingStorage({
    required String audioDir,
    required String artworkDir,
  }) : super(
          audioDirOverride: audioDir,
          artworkDirOverride: artworkDir,
        );

  int sweepCalls = 0;
  int deletedFiles = 0;

  @override
  Future<CacheSweepResult> sweepArtwork(
    String dirPath, {
    required int maxObjects,
    required int staleDays,
  }) async {
    final result = await super.sweepArtwork(
      dirPath,
      maxObjects: maxObjects,
      staleDays: staleDays,
    );
    sweepCalls++;
    deletedFiles += result.deleted;
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late CacheService cacheService;
  late _OfflineCacheManager manager;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    cacheService = CacheService(
      prefs: prefs,
      storage: IoCacheStorage(
        audioDirOverride: '${Directory.systemTemp.path}/unused_audio',
        artworkDirOverride: '${Directory.systemTemp.path}/unused_artwork',
      ),
    );
    manager = _OfflineCacheManager();
  });

  group('headersFor：修复 CDN 403', () {
    test('126.net 带浏览器 UA + 网易云 Referer', () {
      final headers = ArtworkCache.headersFor(
          'https://p1.music.126.net/abc.jpg?param=300y300');
      expect(headers['User-Agent'], ArtworkCache.browserUserAgent);
      expect(headers['User-Agent'], contains('Mozilla/5.0'));
      expect(headers['User-Agent'], contains('Chrome/120'));
      expect(headers['Referer'], 'https://music.163.com/');
    });

    test('qq / kugou / kuwo / migu 映射到各自平台', () {
      expect(
        ArtworkCache.headersFor('https://y.qq.com/music/photo.jpg')['Referer'],
        'https://y.qq.com/',
      );
      expect(
        ArtworkCache.headersFor('https://imge.kugou.com/x.jpg')['Referer'],
        'https://www.kugou.com/',
      );
      expect(
        ArtworkCache.headersFor('https://img2.kuwo.cn/x.jpg')['Referer'],
        'https://www.kuwo.cn/',
      );
      expect(
        ArtworkCache.headersFor('https://img01.1073.cn/x.jpg')['Referer'],
        'https://music.migu.cn/',
      );
    });

    test('未知域名 / 非法 URL 只带 UA', () {
      final unknown = ArtworkCache.headersFor('https://example.com/a.jpg');
      expect(unknown['User-Agent'], ArtworkCache.browserUserAgent);
      expect(unknown.containsKey('Referer'), isFalse);

      final invalid = ArtworkCache.headersFor('not a url');
      expect(invalid['User-Agent'], ArtworkCache.browserUserAgent);
      expect(invalid.containsKey('Referer'), isFalse);
    });
  });

  group('imageProvider', () {
    test('provider 携带统一 headers 与共享 cacheManager', () async {
      final cache =
          ArtworkCache(cacheService: cacheService, managerOverride: manager);
      final provider = await cache.imageProvider(
        'https://p1.music.126.net/x.jpg',
        maxWidth: 300,
      ) as CachedNetworkImageProvider;

      expect(provider.headers?['User-Agent'], ArtworkCache.browserUserAgent);
      expect(provider.headers?['Referer'], 'https://music.163.com/');
      expect(provider.cacheManager, same(manager));
      expect(provider.maxWidth, 300);
    });

    test('managerOrNull 返回同一 Future 实例（FutureBuilder 身份稳定）', () async {
      // 每次 build 新建 Future 会让 FutureBuilder 重置回 waiting 并渲染占位；
      // 切歌动画逐帧重建 = 整段动画深色（「切歌黑图」）。这里锁死身份稳定。
      final cache =
          ArtworkCache(cacheService: cacheService, managerOverride: manager);

      final first = cache.managerOrNull();
      final second = cache.managerOrNull();

      expect(identical(first, second), isTrue);
      expect(await first, same(manager));
    });
  });

  group('策略即时生效（监听 CacheService）', () {
    test('修改上限/过期天数后立即 sweep，无需重启', () async {
      final tempRoot = await Directory.systemTemp.createTemp('artwork_sweep_');
      addTearDown(() async {
        if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
      });
      final artworkDir = '${tempRoot.path}/artwork';
      final storage = IoCacheStorage(
        audioDirOverride: '${tempRoot.path}/audio',
        artworkDirOverride: artworkDir,
      );
      final service = CacheService(prefs: prefs, storage: storage);
      // 注册监听（ArtworkCache 构造时挂到传入的 service 上）。
      ArtworkCache(cacheService: service, managerOverride: manager);

      Future<File> write(String name, {required Duration age}) async {
        final file = File('$artworkDir/$name');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(List<int>.filled(10, 0));
        await file.setLastModified(DateTime.now().subtract(age));
        return file;
      }

      final stale =
          await write('stale.jpg', age: const Duration(days: 400));
      final keep1 = await write('keep1.jpg', age: const Duration(days: 2));
      final keep2 = await write('keep2.jpg', age: const Duration(hours: 1));

      // staleDays=365 → 立即删 stale。
      await service.setArtworkStaleDays(365);
      await _waitUntil(() async => !await stale.exists());

      // maxObjects=1 → 立即再删最旧的 keep1。
      await service.setArtworkMaxObjects(1);
      await _waitUntil(() async => !await keep1.exists());
      expect(await keep2.exists(), isTrue);

      final usage = await service.usage(CachePartition.artwork);
      expect(usage.count, 1);
    });
  });

  group('封面索引（sweep/clear 联动）', () {
    test('sweep 后清理索引中文件已缺失的条目', () async {
      final repo = _MemoryRepo();
      final fileSystem = manager.config.fileSystem;
      final present = await fileSystem.createFile('present.jpg');
      await present.writeAsBytes([1, 2, 3]);

      Future<void> seed(int id, String relativePath) async {
        await repo.insert(CacheObject(
          'https://p1.music.126.net/$relativePath',
          relativePath: relativePath,
          validTill: DateTime.now().add(const Duration(days: 1)),
          id: id,
        ));
      }

      await seed(1, 'present.jpg');
      await seed(2, 'missing.jpg');

      final cache = ArtworkCache(
        cacheService: cacheService,
        managerOverride: manager,
        repoOverride: repo,
      );
      await cache.enforcePolicyNow();

      final remaining = await repo.getAllObjects();
      expect(remaining.map((o) => o.relativePath), ['present.jpg']);
    });

    test('clean sweep 修复外部删除，只复核快照外候选', () async {
      final tempRoot = await Directory.systemTemp.createTemp('artwork_prune_');
      addTearDown(() async {
        if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
      });
      final artworkDir = '${tempRoot.path}/artwork';
      final storage = _SweepCountingStorage(
        audioDir: '${tempRoot.path}/audio',
        artworkDir: artworkDir,
      );
      // 真实缓存目录只剩 present.jpg：missing.jpg 已被系统 / 其它进程直接删除，
      // 本次 sweep 自己一个文件都没删。
      final present = File('$artworkDir/present.jpg');
      await present.parent.create(recursive: true);
      await present.writeAsBytes([1, 2, 3]);

      final service = CacheService(prefs: prefs, storage: storage);
      final repo = _MemoryRepo();
      Future<void> seed(int id, String relativePath) => repo.insert(CacheObject(
            'https://p1.music.126.net/$relativePath',
            relativePath: relativePath,
            validTill: DateTime.now().add(const Duration(days: 1)),
            id: id,
          ));
      await seed(1, 'present.jpg');
      await seed(2, 'missing.jpg');

      final memoryFileSystem = MemoryCacheSystem();
      // 模拟扫描快照之后 manager 才下载并插入的索引：文件真实存在，但不在
      // surviving 集合里（清单一扫完就插入索引的竞态）。
      final fresh = await memoryFileSystem.createFile('fresh.jpg');
      await fresh.writeAsBytes([4, 5, 6]);
      final fileSystem = _CountingFileSystem(memoryFileSystem);
      final manager = _OfflineCacheManager(fileSystem: fileSystem);
      await seed(3, 'fresh.jpg');
      final cache = ArtworkCache(
        cacheService: service,
        managerOverride: manager,
        repoOverride: repo,
      );

      // 策略变更走非强制 sweep，与启动 / 5 分钟节流是同一条 _sweepNow 路径。
      await service.setArtworkStaleDays(30);
      await _waitUntil(() async =>
          repo.getAllCalls == 1 &&
          await repo.get('https://p1.music.126.net/missing.jpg') == null);
      // 等 _sweepNow 的 finally 复位 _sweeping 再走显式入口。
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(storage.deletedFiles, 0, reason: '本次 sweep 没删任何文件');
      expect(repo.getAllCalls, 1, reason: 'clean sweep 也要对齐索引');
      // 只复核不在快照里的条目：外部删除的 missing + 竞态新增的 fresh。
      expect(fileSystem.createFileCounts['missing.jpg'], 1);
      expect(fileSystem.createFileCounts['fresh.jpg'], 1);
      // 快照内的 present 不做任何文件探测。
      expect(fileSystem.createFileCounts['present.jpg'], isNull);
      expect(await repo.get('https://p1.music.126.net/present.jpg'), isNotNull);
      expect(
        await repo.get('https://p1.music.126.net/fresh.jpg'),
        isNotNull,
        reason: '扫描后新写入的索引不能被误删',
      );

      // 显式入口同样只复核快照外候选。
      await seed(4, 'missing2.jpg');
      await cache.enforcePolicyNow();
      expect(storage.sweepCalls, 2);
      expect(repo.getAllCalls, 2);
      expect(fileSystem.createFileCounts['present.jpg'], isNull);
      expect(fileSystem.createFileCounts['fresh.jpg'], 2);
      expect(fileSystem.createFileCounts['missing2.jpg'], 1);
      expect(
        await repo.get('https://p1.music.126.net/missing2.jpg'),
        isNull,
      );

      // 分区被 UI 清理（CacheStorage 直删文件，不经过 manager）没有扫描结果，
      // 退回逐条探测，仍要清掉索引。
      await service.clear(CachePartition.artwork);
      await _waitUntil(() async =>
          repo.getAllCalls == 3 &&
          await repo.get('https://p1.music.126.net/present.jpg') == null);
      expect(fileSystem.createFileCounts['present.jpg'], 1);
      expect(fileSystem.createFileCounts['fresh.jpg'], 3);
    });

    test('相对路径分隔符归一化：索引的 \\ 与扫描的 / 视为同一文件', () async {
      final tempRoot = await Directory.systemTemp.createTemp('artwork_sep_');
      addTearDown(() async {
        if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
      });
      final artworkDir = '${tempRoot.path}/artwork';
      final storage = _SweepCountingStorage(
        audioDir: '${tempRoot.path}/audio',
        artworkDir: artworkDir,
      );
      // 真实目录用平台分隔符；索引里模拟 Windows 风格的 `\`。
      final present = File('$artworkDir/nested/present.jpg');
      await present.parent.create(recursive: true);
      await present.writeAsBytes([1, 2, 3]);

      final service = CacheService(prefs: prefs, storage: storage);
      final repo = _MemoryRepo();
      await repo.insert(CacheObject(
        'https://p1.music.126.net/nested/present.jpg',
        relativePath: 'nested\\present.jpg',
        validTill: DateTime.now().add(const Duration(days: 1)),
        id: 1,
      ));
      final fileSystem = _CountingFileSystem(MemoryCacheSystem());
      final cache = ArtworkCache(
        cacheService: service,
        managerOverride: _OfflineCacheManager(fileSystem: fileSystem),
        repoOverride: repo,
      );

      await cache.enforcePolicyNow();
      expect(
        await repo.get('https://p1.music.126.net/nested/present.jpg'),
        isNotNull,
        reason: '归一化后应命中存活集合，不能被当成缺失',
      );
      expect(
        fileSystem.createFileCalls,
        0,
        reason: '命中存活集合的条目不该再做文件探测',
      );
    });

    test('扫描不完整且非强制 sweep 不误删索引；显式入口逐条兜底', () async {
      final tempRoot =
          await Directory.systemTemp.createTemp('artwork_prune_failed_');
      addTearDown(() async {
        if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
      });
      // 封面目录从不创建：sweep 没扫到 ≠ 缓存全空。
      final storage = _SweepCountingStorage(
        audioDir: '${tempRoot.path}/audio',
        artworkDir: '${tempRoot.path}/missing_artwork',
      );
      final service = CacheService(prefs: prefs, storage: storage);
      final repo = _MemoryRepo();
      final present = await manager.config.fileSystem.createFile('present.jpg');
      await present.writeAsBytes([1, 2, 3]);
      await repo.insert(CacheObject(
        'https://p1.music.126.net/present.jpg',
        relativePath: 'present.jpg',
        validTill: DateTime.now().add(const Duration(days: 1)),
        id: 1,
      ));
      final cache = ArtworkCache(
        cacheService: service,
        managerOverride: manager,
        repoOverride: repo,
      );

      await service.setArtworkStaleDays(30);
      await _waitUntil(() async => storage.sweepCalls == 1);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(storage.deletedFiles, 0);
      expect(repo.getAllCalls, 0, reason: '没扫到目录不能当成缓存全空');

      // 显式入口：扫描失败时退回逐条 exists()，文件还在就不删索引。
      await cache.enforcePolicyNow();
      expect(storage.sweepCalls, 2);
      expect(repo.getAllCalls, 1);
      expect(await repo.get('https://p1.music.126.net/present.jpg'), isNotNull);
    });
  });

  group('真实 manager（内存 repo + 临时持久目录）', () {
    test('使用持久目录写入；内部淘汰查询被置空（交给 sweep）', () async {
      final tempRoot = await Directory.systemTemp.createTemp('artwork_manager_');
      addTearDown(() async {
        if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
      });
      final artworkDir = '${tempRoot.path}/artwork';
      final service = CacheService(
        prefs: prefs,
        storage: IoCacheStorage(
          audioDirOverride: '${tempRoot.path}/audio',
          artworkDirOverride: artworkDir,
        ),
      );
      final cache = ArtworkCache(
        cacheService: service,
        repoOverride: NonStoringObjectProvider(),
      );

      final manager = await cache.manager;
      expect(manager, isA<ArtworkCacheManager>());
      expect(manager.config.repo.getObjectsOverCapacity(0), completion(isEmpty));
      expect(
          manager.config.repo.getOldObjects(Duration.zero), completion(isEmpty));

      final file = await manager.putFile(
        'https://p1.music.126.net/manager.jpg',
        Uint8List.fromList([1, 2, 3]),
        key: 'manager-key',
        fileExtension: 'jpg',
      );
      expect(file.path, startsWith(artworkDir));
      expect(await file.exists(), isTrue);
    });
  });

  group('系统媒体会话封面本地化（cachedFilePath）', () {
    late _RecordingCacheManager manager;

    setUp(() {
      manager = _RecordingCacheManager();
    });

    tearDown(() => manager.dispose());

    test('命中持久缓存：直接返回本地文件路径', () async {
      final cache = ArtworkCache(
        cacheService: cacheService,
        managerOverride: manager,
      );
      const url = 'https://p1.music.126.net/media-cached.jpg';
      final file = await manager.putFile(
        url,
        Uint8List.fromList([1, 2, 3]),
        fileExtension: 'jpg',
      );

      expect(await cache.cachedFilePath(url), file.path);
      expect(manager.singleFileCalls, 0);
    });

    test('未命中 + 下载：带浏览器 UA 请求头（修复 CDN 403）', () async {
      final cache = ArtworkCache(
        cacheService: cacheService,
        managerOverride: manager,
      );
      const url = 'https://p1.music.126.net/media-miss.jpg';

      expect(await cache.cachedFilePath(url), isNull);
      expect(manager.singleFileCalls, 1);
      expect(manager.lastHeaders?['User-Agent'], ArtworkCache.browserUserAgent);
      expect(manager.lastHeaders?['Referer'], 'https://music.163.com/');
    });

    test('省流网关开启：未命中不触网（getSingleFile 不被调用）', () async {
      final cache = ArtworkCache(
        cacheService: cacheService,
        managerOverride: manager,
      )..networkImageBlocked = () => true;
      const url = 'https://p1.music.126.net/media-blocked.jpg';

      expect(await cache.cachedFilePath(url), isNull);
      expect(manager.singleFileCalls, 0);
    });
  });

  group('省流网关（networkBlocked）', () {
    late ArtworkCacheManager manager;

    setUp(() {
      manager = ArtworkCacheManager(
        Config(
          'artwork_blocked_test',
          repo: _MemoryRepo(),
          fileSystem: MemoryCacheSystem(),
          fileService: HttpFileService(),
        ),
        onUsed: () {},
        networkBlocked: () => true,
      );
    });

    tearDown(() => manager.dispose());

    test('网关开启 + 未缓存：直接报错（不发起网络请求）', () async {
      await expectLater(
        manager.getFileStream('https://p1.music.126.net/not_cached.jpg'),
        emitsError(isA<ArtworkNetworkBlockedException>()),
      );
    });

    test('网关开启 + 已缓存：返回缓存文件（过期也不触发网络刷新）', () async {
      const url = 'https://p1.music.126.net/cached.jpg';
      final file = await manager.putFile(
        url,
        Uint8List.fromList([1, 2, 3]),
        fileExtension: 'jpg',
        maxAge: const Duration(seconds: -1), // 故意过期：省流下仍直接返回
      );
      expect(await file.exists(), isTrue);

      final events = await manager.getFileStream(url).toList();
      expect(events, hasLength(1));
      final info = events.single as FileInfo;
      expect(info.source, FileSource.Cache);
      expect(info.file.path, file.path);
    });
  });

  group('单曲封面缓存（remove / usageOf）', () {
    test('删除命中缓存的文件并清空占用；未命中返回 false', () async {
      final tempRoot = await Directory.systemTemp.createTemp('artwork_remove_');
      addTearDown(() async {
        if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
      });
      final service = CacheService(
        prefs: prefs,
        storage: IoCacheStorage(
          audioDirOverride: '${tempRoot.path}/audio',
          artworkDirOverride: '${tempRoot.path}/artwork',
        ),
      );
      final cache = ArtworkCache(
        cacheService: service,
        repoOverride: NonStoringObjectProvider(),
      );
      const url = 'https://p1.music.126.net/single.jpg';
      final manager = await cache.manager;
      final file = await manager.putFile(
        url,
        Uint8List.fromList([1, 2, 3, 4, 5]),
        fileExtension: 'jpg',
      );
      expect(await file.exists(), isTrue);

      final usage = await cache.usageOf(url);
      expect(usage, const CacheUsage(bytes: 5, count: 1));

      expect(await cache.remove(url), isTrue);
      expect(await file.exists(), isFalse);
      expect(await cache.usageOf(url), CacheUsage.zero);

      // 未缓存再删：false（不是错误）。
      expect(await cache.remove(url), isFalse);
    });
  });
}
