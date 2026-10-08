import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
// 测试直接用 flutter_cache_manager 的内存实现（传递依赖，不触网）。
// ignore: depend_on_referenced_packages
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/managers/artwork_cache.dart';
import 'package:molia/services/cache_service.dart';
import 'package:molia/services/cache_storage_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 纯内存 + 永远失败的 CacheManager：测试不触网、不落平台目录。
class _OfflineCacheManager extends CacheManager {
  _OfflineCacheManager()
      : super(Config(
          'artwork_cache_test_offline',
          repo: NonStoringObjectProvider(),
          fileSystem: MemoryCacheSystem(),
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

/// 纯内存 repo：putFile / getFileFromCache 全链路可用，不触碰 sqflite。
class _MemoryRepo implements CacheInfoRepository {
  final Map<String, CacheObject> _store = {};

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
  Future<List<CacheObject>> getAllObjects() async => _store.values.toList();

  @override
  Future<List<CacheObject>> getObjectsOverCapacity(int capacity) async =>
      const [];

  @override
  Future<List<CacheObject>> getOldObjects(Duration maxAge) async => const [];

  @override
  Future<void> deleteDataFile() async {}
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
}
