import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart' show ImageProvider, VoidCallback;
// flutter_cache_manager 是 cached_network_image 的传递依赖；封面缓存门面
// 需要直接使用其 CacheManager/Config/ImageCacheManager。
// ignore: depend_on_referenced_packages
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:logger/logger.dart';

import '../services/cache_service.dart';
import 'artwork_cache_fs.dart';

/// 封面缓存管理器：统一请求头（修 CDN 403）+ 共享持久 CacheManager。
///
/// - **403 修复**：网易云等平台 CDN 对 Dart 默认 UA 返回 403；统一附带
///   浏览器 UA 与平台 Referer（126.net → music.163.com 等）；
/// - **持久缓存**：CacheManager 使用应用支持目录下的 `artwork_cache`
///   （`PersistentArtworkFileSystem`），stalePeriod / 容量在创建时从
///   [CacheService] 策略读取；
/// - **策略即时生效**：封面淘汰统一由 [CacheService.enforceArtworkPolicy]
///   的 sweep 执行（manager 的 repo 内部淘汰查询已置空，避免创建时固化
///   的配置与运行期策略打架）；监听策略变更立即 sweep，图片加载完成后
///   按 5 分钟节流再 sweep，控制单次会话内的增长；
/// - **Web**：无持久文件系统，使用 flutter_cache_manager 的内存实现。
class ArtworkCache {
  ArtworkCache({
    CacheService? cacheService,
    CacheManager? managerOverride,
    CacheInfoRepository? repoOverride,
  })  : _cacheService = cacheService ?? CacheService.instance,
        _managerOverride = managerOverride,
        _repoOverride = repoOverride {
    _repo = repoOverride;
    _cacheService.addPolicyListener(_onPolicyChanged);
    _cacheService.addClearListener(_onPartitionCleared);
  }

  /// 全局单例（UI 组件默认入口）。
  static final ArtworkCache instance = ArtworkCache();

  /// 省流模式网关（composition root 注入）：返回 true 时封面只用本地缓存，
  /// 不发起任何网络请求。null / false 表示不限制（默认行为不变）。
  bool Function()? networkImageBlocked;

  /// CacheManager 的 cacheKey（同时是数据库名 / 目录名标识）。
  static const String cacheKey = 'molia_artwork_cache';

  /// 浏览器 UA：CDN 防盗链校验通过（实测 Dart 默认 UA 会 403）。
  static const String browserUserAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  static const Duration _sweepMinInterval = Duration(minutes: 5);

  final CacheService _cacheService;
  final CacheManager? _managerOverride;
  final CacheInfoRepository? _repoOverride;
  final Logger _logger = Logger();

  /// 真实 repo（索引）：sweep / clear 直接删文件后用它清理失效条目。
  CacheInfoRepository? _repo;

  Future<CacheManager>? _managerFuture;
  Future<CacheManager?>? _managerOrNullFuture;
  CacheManager? _resolvedManager;
  DateTime _lastSweep = DateTime.fromMillisecondsSinceEpoch(0);
  bool _sweeping = false;

  /// 共享 CacheManager（测试可注入 [managerOverride] 走内存实现）。
  Future<CacheManager> get manager {
    final override = _managerOverride;
    if (override != null) return Future.value(override);
    return _managerFuture ??= _createManager().then((manager) {
      _resolvedManager = manager;
      return manager;
    });
  }

  /// 已解析完成的共享 CacheManager；未解析时返回 null。
  ///
  /// 供共享元素飞行副本这类「必须在首帧同步拿到 provider」的场景使用：
  /// 命中 Flutter ImageCache 时图片同步出帧，不经过 FutureBuilder 占位。
  CacheManager? get managerSync => _managerOverride ?? _resolvedManager;

  /// 与 [manager] 相同，但构造失败时返回 null（调用方回退默认实现）。
  ///
  /// **Future 必须缓存**：`AppNetworkImage` 把它交给 `FutureBuilder`，而
  /// FutureBuilder 在 future 身份变化时会回到 waiting 并渲染占位——若每次
  /// build 都新建 Future，封面会在每次重建（如切歌动画逐帧重建）闪深色占位。
  Future<CacheManager?> managerOrNull() =>
      _managerOrNullFuture ??= _resolveManagerOrNull();

  Future<CacheManager?> _resolveManagerOrNull() async {
    try {
      return await manager;
    } catch (e) {
      _logger.w('封面 CacheManager 不可用: $e');
      return null;
    }
  }

  Future<CacheManager> _createManager() async {
    final maxObjects = await _cacheService.artworkMaxObjects();
    final staleDays = await _cacheService.artworkStaleDays();
    String? directoryPath;
    try {
      directoryPath = await _cacheService.artworkCacheDirPath();
    } catch (_) {
      // 平台通道不可用（测试）→ 使用默认实现。
    }
    final repo = _repoOverride ?? createArtworkRepository(cacheKey);
    _repo = repo;
    final config = Config(
      cacheKey,
      stalePeriod: Duration(
        days: staleDays > 0 ? staleDays : CacheService.defaultArtworkStaleDays,
      ),
      maxNrOfCacheObjects: maxObjects > 0
          ? maxObjects
          : CacheService.defaultArtworkMaxObjects,
      // 内部淘汰查询置空：封面淘汰统一由 CacheService 的 sweep 按运行期
      // 策略执行（manager 配置在创建时固化，策略变更后两者会互相打架）。
      repo: _PolicyNeutralRepository(repo),
      fileSystem: createArtworkFileSystem(cacheKey, directoryPath),
    );
    final manager = ArtworkCacheManager(
      config,
      onUsed: _maybeSweep,
      networkBlocked: () => networkImageBlocked?.call() ?? false,
    );
    // 启动（首次取 manager）时按当前策略 sweep 一次。
    unawaited(_sweepNow());
    return manager;
  }

  /// 统一图片请求头：浏览器 UA + 平台 Referer。
  static Map<String, String> headersFor(String url) {
    final headers = <String, String>{'User-Agent': browserUserAgent};
    final referer = refererFor(url);
    if (referer != null) headers['Referer'] = referer;
    return headers;
  }

  /// 按封面 URL 主机名映射平台 Referer；未知平台返回 null。
  static String? refererFor(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return null;
    if (host.contains('126.net') || host.contains('163.com')) {
      return 'https://music.163.com/';
    }
    if (host.contains('qq.com')) return 'https://y.qq.com/';
    if (host.contains('kugou.com')) return 'https://www.kugou.com/';
    if (host.contains('kuwo.cn')) return 'https://www.kuwo.cn/';
    if (host.contains('migu.cn') || host.contains('1073.cn')) {
      return 'https://music.migu.cn/';
    }
    return null;
  }

  /// 统一 ImageProvider（带 headers + 共享 cacheManager）。
  Future<ImageProvider> imageProvider(
    String url, {
    int? maxWidth,
    int? maxHeight,
  }) async {
    return CachedNetworkImageProvider(
      url,
      headers: headersFor(url),
      cacheManager: await managerOrNull(),
      maxWidth: maxWidth,
      maxHeight: maxHeight,
    );
  }

  /// 立即按当前策略 sweep 一次（策略变更 / 启动 / 定期触发）。
  Future<void> enforcePolicyNow() => _sweepNow();

  void _onPolicyChanged(CachePartition partition) {
    if (partition != CachePartition.artwork) return;
    unawaited(_handleArtworkPolicyChanged());
  }

  /// 分区被 UI 清理后同步索引（CacheStorage 直接删文件，不经过 manager）。
  void _onPartitionCleared(CachePartition partition) {
    if (partition != CachePartition.artwork) return;
    unawaited(_pruneMissingEntries());
  }

  Future<void> _handleArtworkPolicyChanged() async {
    // 淘汰统一由 sweep 按最新策略执行；manager 的 repo 已禁用内部淘汰，
    // 因此无需重建（避免同 key DB 双写竞态）。
    await _sweepNow();
  }

  /// 图片加载完成后的节流 sweep（5 分钟一次）。
  void _maybeSweep() {
    final now = DateTime.now();
    if (now.difference(_lastSweep) < _sweepMinInterval) return;
    unawaited(_sweepNow());
  }

  Future<void> _sweepNow() async {
    if (_sweeping) return;
    _sweeping = true;
    _lastSweep = DateTime.now();
    try {
      await _cacheService.enforceArtworkPolicy();
      // sweep 直接删文件（不经过 manager）：同步清理索引中的失效条目，
      // 否则命中会返回指向缺失文件的 FileInfo（封面失败且不再回源）。
      await _pruneMissingEntries();
    } finally {
      _sweeping = false;
    }
  }

  /// 清理索引中「文件已不存在」的条目（sweep / clear 之后的索引修复）。
  Future<void> _pruneMissingEntries() async {
    final repo = _repo;
    if (repo == null) return;
    final manager = await managerOrNull();
    if (manager == null) return;
    try {
      final objects = await repo.getAllObjects();
      if (objects.isEmpty) return;
      final missing = <int>[];
      for (final object in objects) {
        if (object.id == null) continue;
        final file = await manager.config.fileSystem
            .createFile(object.relativePath);
        if (!await file.exists()) missing.add(object.id!);
      }
      if (missing.isEmpty) return;
      final deleted = await repo.deleteAll(missing);
      _logger.i('封面缓存索引清理 $deleted 个失效条目');
    } catch (e) {
      _logger.w('封面缓存索引清理失败: $e');
    }
  }
}

/// 封面 ImageProvider 快捷入口（等价于 `ArtworkCache.instance.imageProvider`）。
///
/// 统一携带浏览器 UA + 平台 Referer 与共享持久 CacheManager。
Future<ImageProvider> artworkImageProvider(
  String url, {
  int? maxWidth,
  int? maxHeight,
}) =>
    ArtworkCache.instance.imageProvider(
      url,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
    );

/// 省流模式拦截封面网络请求时抛出的错误：由 `CachedNetworkImage` 的
/// errorWidget 回退为占位图标（本地无缓存时的预期路径）。
class ArtworkNetworkBlockedException implements Exception {
  const ArtworkNetworkBlockedException(this.url);

  final String url;

  @override
  String toString() => 'ArtworkNetworkBlockedException: $url';
}

/// 带「使用回调」的 CacheManager：支持磁盘缩放（ImageCacheManager mixin），
/// 每次文件流结束通知 [ArtworkCache] 做节流 sweep。
///
/// [networkBlocked] 为省流网关：返回 true 时只读本地缓存，未命中直接
/// 抛 [ArtworkNetworkBlockedException]，不做任何网络请求（含后台刷新）。
class ArtworkCacheManager extends CacheManager with ImageCacheManager {
  ArtworkCacheManager(
    super.config, {
    required VoidCallback onUsed,
    bool Function()? networkBlocked,
  })  : _onUsed = onUsed,
        _networkBlocked = networkBlocked ?? (() => false);

  final VoidCallback _onUsed;
  final bool Function() _networkBlocked;

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) {
    if (_networkBlocked()) {
      return _cachedOnlyStream(url, key);
    }
    return super
        .getFileStream(
          url,
          key: key,
          headers: headers,
          withProgress: withProgress,
        )
        .transform(
          StreamTransformer<FileResponse, FileResponse>.fromHandlers(
            handleDone: (sink) {
              _onUsed();
              sink.close();
            },
          ),
        );
  }

  /// 仅本地缓存：命中（含内存缓存，不校验新鲜度、不触发后台刷新）时返回
  /// 缓存文件；未命中抛出 [ArtworkNetworkBlockedException]。
  Stream<FileResponse> _cachedOnlyStream(String url, String? key) async* {
    final cached = await getFileFromCache(key ?? url);
    if (cached == null) {
      throw ArtworkNetworkBlockedException(url);
    }
    yield cached;
  }
}

/// 元数据代理：读写全部委托真实 repo，但把「超容量 / 过期」查询置空。
///
/// flutter_cache_manager 的 CacheStore 会按创建时固化的 `maxNrOfCacheObjects`
/// / `stalePeriod` 自行删除文件；封面淘汰改由 [CacheService.enforceArtworkPolicy]
/// 的 sweep 按运行期策略统一执行，因此这里禁用其内部淘汰，避免双重淘汰与
/// 策略变更后的过度删除。
class _PolicyNeutralRepository implements CacheInfoRepository {
  _PolicyNeutralRepository(this._inner);

  final CacheInfoRepository _inner;

  @override
  Future<bool> open() => _inner.open();

  @override
  Future<dynamic> updateOrInsert(CacheObject cacheObject) =>
      _inner.updateOrInsert(cacheObject);

  @override
  Future<CacheObject> insert(
    CacheObject cacheObject, {
    bool setTouchedToNow = true,
  }) =>
      _inner.insert(cacheObject, setTouchedToNow: setTouchedToNow);

  @override
  Future<CacheObject?> get(String key) => _inner.get(key);

  @override
  Future<int> delete(int id) => _inner.delete(id);

  @override
  Future<int> deleteAll(Iterable<int> ids) => _inner.deleteAll(ids);

  @override
  Future<int> update(
    CacheObject cacheObject, {
    bool setTouchedToNow = true,
  }) =>
      _inner.update(cacheObject, setTouchedToNow: setTouchedToNow);

  @override
  Future<List<CacheObject>> getAllObjects() => _inner.getAllObjects();

  @override
  Future<List<CacheObject>> getObjectsOverCapacity(int capacity) async =>
      const [];

  @override
  Future<List<CacheObject>> getOldObjects(Duration maxAge) async => const [];

  @override
  Future<bool> close() => _inner.close();

  @override
  Future<bool> exists() => _inner.exists();

  @override
  Future<void> deleteDataFile() => _inner.deleteDataFile();
}
