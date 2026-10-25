import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:logging/logging.dart';
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/models/track.dart';
import '../managers/artwork_cache.dart';
import '../playback/playback_power_policy.dart';
import '../theme/scheme_builder.dart';
import '../utils/local_image_provider.dart';
import 'app_presence.dart';
import 'covers/cover_resolution.dart';

/// 单张图像的取色结果：种子色 + 双亮度方案（一次提取，多处复用）。
class ArtworkPalette {
  const ArtworkPalette({
    required this.seed,
    required this.light,
    required this.dark,
  });

  /// 统一派生入口：[seed] 经 `buildColorScheme` 生成双亮度方案。
  factory ArtworkPalette.fromSeed(Color seed) => ArtworkPalette(
        seed: seed,
        light: buildColorScheme(seed, Brightness.light),
        dark: buildColorScheme(seed, Brightness.dark),
      );

  /// 图像（封面 / 系统壁纸）提取出的种子色。
  final Color seed;

  /// 浅色方案。
  final ColorScheme light;

  /// 深色方案。
  final ColorScheme dark;

  ColorScheme schemeFor(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;
}

/// 图像取色服务：像素 → 种子色 → 双亮度 ColorScheme，带 LRU 缓存。
///
/// 统一取色口径：全局主题「跟随封面 / 系统壁纸」、桌面歌词「跟随封面」、
/// 海报「跟随封面」全部查本服务，禁止任何模块自行提取像素。
///
/// - 封面走共享封面缓存（`artworkImageProvider`）：与封面显示同一份磁盘缓存
///   与请求头，不二次下载；解码统一缩到采样边长（100px），不把原图留在
///   Flutter 图片缓存里（显示面会按自己的有界尺寸单独解码）；
/// - 系统壁纸走 [loadLocalFile]（读盘字节 → 同一缩略解码路径，不解码全图）；
/// - 省流模式（`ArtworkCache` 网关只读本地缓存）下未命中会抛错：这里吞掉
///   并返回 null，调用方保持现色（不回退、不闪变）；
/// - 同 URL / 同路径并发请求合并为一次提取；LRU 上限 8 条；
/// - 启动预解析 [loadCached] 只吃本地已有封面（不触网），由组合根在
///   `runApp` 前调用，让首帧直接是封面色。
class ArtworkPaletteService {
  ArtworkPaletteService({
    this._maxCacheEntries = 8,
    this._providerFor =
        artworkImageProvider,
    this._cachedBytesFor =
        _cachedBytesFromStore,
    this._localFileBytesFor =
        _localFileBytesFromDisk,
  });

  static const int _quantizeColorCount = 128;

  /// 像素采样目标边长：取色只需色调，100x100 足够且快。
  static const int _sampleTargetSize = 100;

  /// 默认本地缓存字节读取（共享封面 CacheManager 的文件缓存）。
  static Future<Uint8List?> _cachedBytesFromStore(String url) =>
      ArtworkCache.instance.bytesOf(url);

  /// 默认本地文件读取（系统壁纸：路径 → 字节；不存在 / 不可读返回 null）。
  static Future<Uint8List?> _localFileBytesFromDisk(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  final int _maxCacheEntries;

  /// 封面取图入口（默认共享封面缓存；测试注入纯色图）。
  final Future<ImageProvider> Function(String url) _providerFor;

  /// 本地缓存字节读取入口（启动预解析用；测试注入固定字节）。
  final Future<Uint8List?> Function(String url) _cachedBytesFor;

  /// 本地文件字节读取入口（系统壁纸用；测试注入固定字节）。
  final Future<Uint8List?> Function(String path) _localFileBytesFor;
  final LinkedHashMap<String, ArtworkPalette> _cache =
      LinkedHashMap<String, ArtworkPalette>();
  final Map<String, Future<ArtworkPalette?>> _inFlight = {};
  final Logger _logger = Logger('molia.artwork_palette_service');

  int get cacheSize => _cache.length;

  /// 读取（或提取）封面方案；失败返回 null（调用方保持现色）。
  Future<ArtworkPalette?> load(String url) =>
      _resolve(url, () => _extract(url));

  /// 本地图像文件取色（桌面系统壁纸）：读盘 → 缩略解码 → seed。
  ///
  /// 与封面共用同一 LRU / 并发合并：同一路径（浅 / 深壁纸常为同一文件）
  /// 第二次请求命中缓存，只读一次盘、只解码一次；读取 / 解码失败返回 null
  /// （调用方回退系统强调色）。
  Future<ArtworkPalette?> loadLocalFile(String path) =>
      _resolve(path, () => _extractLocalFile(path));

  /// 启动预解析：只吃本地已有封面（磁盘缓存 / 本地文件），未命中立即返回
  /// null，不发任何网络请求。
  ///
  /// 供组合根在 `runApp` 前调用：命中时首帧直接是封面色，不再先出基础配色
  /// （莫奈）再渐变；未命中/失败不等待网络，回退稳态链路
  /// （[ArtworkThemeSync] 在封面就绪后照常过渡）。
  Future<ArtworkPalette?> loadCached(String url) => _resolve(url, () async {
        // 本地下载封面（`file://`）本身就是本地文件：走统一取图路径。
        if (localFileImageProvider(url) != null) return _extract(url);
        final bytes = await _cachedBytesFor(url);
        if (bytes == null || bytes.isEmpty) return null;
        return _extractFromBytes(url, bytes);
      });

  /// 曲目取色：只接受解析器的真实封面（默认封面是占位，永不参与取色）。
  ///
  /// 返回 null 表示没有可取色的真实封面（调用方回退基础配色 / 保持现色）。
  Future<ArtworkPalette?> loadTrack(
    Track? track, {
    required CoverResolver covers,
  }) {
    final url = covers.realOf(track).url;
    if (url == null) return Future<ArtworkPalette?>.value(null);
    return load(url);
  }

  /// 启动预解析的曲目版本：同样只吃真实封面（见 [loadTrack]）。
  Future<ArtworkPalette?> loadCachedTrack(
    Track? track, {
    required CoverResolver covers,
  }) {
    final url = covers.realOf(track).url;
    if (url == null) return Future<ArtworkPalette?>.value(null);
    return loadCached(url);
  }

  /// LRU 命中 / 并发合并：同一 URL 的进行中提取只做一次。
  Future<ArtworkPalette?> _resolve(
    String url,
    Future<ArtworkPalette?> Function() extract,
  ) {
    final cached = _cache.remove(url);
    if (cached != null) {
      _cache[url] = cached; // 触碰 LRU 顺序
      return Future.value(cached);
    }
    final pending = _inFlight[url];
    if (pending != null) return pending;
    // 注意：whenComplete 的回调必须返回 void——返回 `_inFlight.remove(url)`
    // 会把「清理用的派生 future」指回自身，形成自引用死锁。
    final future = extract();
    _inFlight[url] = future;
    unawaited(future.whenComplete(() {
      _inFlight.remove(url);
    }));
    return future;
  }

  Future<ArtworkPalette?> _extract(String url) async {
    try {
      final imageProvider = await _providerFor(url);
      // 取色只需要 100px 的色调信息：把显示路径的原图解码降到采样尺寸。
      // 不缩放时一张 2000×2000 封面会在图片缓存里留 15MB，而取色结果只有
      // 几百字节；独立的小缓存键（约 40KB）也不会挤掉正在显示的封面。
      final sampleProvider = ResizeImage.resizeIfNeeded(
        _sampleTargetSize,
        null,
        imageProvider,
      );
      final pixels = await _extractPixels(sampleProvider);
      return await _paletteFromPixels(url, pixels);
    } catch (e) {
      // 省流未命中（ArtworkNetworkBlockedException）/ 网络失败 / 解码失败：
      // 保持现色，不打断主题与歌词显示。
      _logger.warning('封面取色失败（保持现色）: $e');
      return null;
    }
  }

  /// 本地字节 → 方案（封面缓存预解析 / 系统壁纸共用：不取图、不触网）。
  Future<ArtworkPalette?> _extractFromBytes(String url, Uint8List bytes) async {
    try {
      // 取色只需色调：按采样边长缩略解码，避免整图解码开销。
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: _sampleTargetSize,
      );
      final frame = await codec.getNextFrame();
      return await _paletteFromPixels(url, await _samplePixels(frame.image));
    } catch (e) {
      // 缓存文件 / 壁纸文件损坏、解码失败：返回 null，调用方回退稳态链路。
      _logger.warning('图像取色失败（保持现色）: $e');
      return null;
    }
  }

  /// 本地文件路径 → 字节 → 方案（系统壁纸取色；与封面共用缩略解码）。
  Future<ArtworkPalette?> _extractLocalFile(String path) async {
    try {
      final bytes = await _localFileBytesFor(path);
      if (bytes == null || bytes.isEmpty) return null;
      return await _extractFromBytes(path, bytes);
    } catch (e) {
      // 数据源读取失败（权限 / 文件消失）：返回 null，调用方回退强调色。
      _logger.warning('本地图像读取失败（保持现色）: $e');
      return null;
    }
  }

  /// 采样像素 → 量化 → 方案，并写入 LRU；无有效像素 / 量化失败返回 null。
  Future<ArtworkPalette?> _paletteFromPixels(
    String url,
    List<int> pixels,
  ) async {
    if (pixels.isEmpty) return null;
    final quantized =
        await QuantizerCelebi().quantize(pixels, _quantizeColorCount);
    final ranked = Score.score(quantized.colorToCount);
    if (ranked.isEmpty) return null;
    return _store(url, ArtworkPalette.fromSeed(Color(ranked.first)));
  }

  /// 写入 LRU（超出上限淘汰最早条目）。
  ArtworkPalette _store(String url, ArtworkPalette palette) {
    _cache[url] = palette;
    if (_cache.length > _maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
    return palette;
  }

  /// 取图 → 采样像素。
  Future<List<int>> _extractPixels(ImageProvider imageProvider) async {
    final completer = Completer<ui.Image>();
    final stream = imageProvider.resolve(ImageConfiguration.empty);

    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (ImageInfo info, bool _) {
        completer.complete(info.image);
        stream.removeListener(listener);
      },
      onError: (Object exception, StackTrace? stackTrace) {
        completer.completeError(exception, stackTrace);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);

    return _samplePixels(await completer.future);
  }

  /// 采样像素（ARGB int 列表）：缩略采样 + 透明像素跳过。
  Future<List<int>> _samplePixels(ui.Image image) async {
    final width = image.width;
    final height = image.height;
    final stepX = (width / _sampleTargetSize).ceil().clamp(1, width);
    final stepY = (height / _sampleTargetSize).ceil().clamp(1, height);

    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) return const [];

    final pixels = <int>[];
    final bytes = byteData.buffer.asUint8List();
    for (var y = 0; y < height; y += stepY) {
      for (var x = 0; x < width; x += stepX) {
        final index = (y * width + x) * 4;
        if (index + 3 >= bytes.length) continue;
        final a = bytes[index + 3];
        if (a < 128) continue;
        final r = bytes[index];
        final g = bytes[index + 1];
        final b = bytes[index + 2];
        pixels.add((a << 24) | (r << 16) | (g << 8) | b);
      }
    }
    return pixels;
  }
}

/// 播放曲目 → 封面取色的接线：稳态延迟 + 过期丢弃 + 无封面回退。
///
/// 由 composition root 挂到 `PlaybackProvider` 上，因此任何页面/后台切歌都
/// 走同一条取色链路。
///
/// - 有封面：等待 [settleDelay]（连读切歌只取最后一首）后提取；提取失败
///   保持现色；
/// - 无封面：通知 [onCleared] 回退基础配色（与「有封面才覆盖」语义一致）；
/// - 结果过期（期间又切歌）直接丢弃；
/// - 没有展示面（桌面托盘隐藏 / 移动端退后台且没有桌面歌词）时只记 URL
///   不取色——取色要解码封面，后台没有任何消费面；恢复后补一次
///   （LRU 命中时等于零成本）。
class ArtworkThemeSync {
  ArtworkThemeSync({
    required this._load,
    required this._onPalette,
    required this._onCleared,
    this._settleDelay = const Duration(milliseconds: 500),
    AppPresence? presence,
    PlaybackPowerPolicy? mobilePowerPolicy,
  })  : _presence = presence ?? AppPresence.instance,
        _powerPolicy = mobilePowerPolicy {
    _presence.addListener(_onSurfaceChanged);
    _powerPolicy?.addListener(_onSurfaceChanged);
  }

  final Future<ArtworkPalette?> Function(String url) _load;
  final void Function(ArtworkPalette palette) _onPalette;
  final void Function() _onCleared;
  final Duration _settleDelay;
  final AppPresence _presence;

  /// 移动端前后台 / 桌面歌词策略：后台只有悬浮窗可能跟随封面配色时取色。
  final PlaybackPowerPolicy? _powerPolicy;

  String? _currentUrl;

  /// 最近一次成功取色并下发的 URL：后台期只记 URL 不取色，恢复时用它去重
  /// （同一 URL 不重复提取、不重复下发）。
  String? _appliedUrl;

  Timer? _timer;
  bool _disposed = false;

  /// 当前是否存在任何消费封面色板的面。
  ///
  /// 桌面看窗口存在态；移动端窗口态恒可见，改看生命周期——退后台后只有
  /// 桌面歌词悬浮窗仍需要「跟随封面」的颜色，通知锁屏不消费主题色。
  bool get _surfaceAvailable {
    if (_presence.isBackgrounded) return false;
    final policy = _powerPolicy;
    return policy == null || policy.canExtractArtworkPalette;
  }

  /// 播放快照里的当前封面地址变化时调用（null/空串 = 当前曲目无封面）。
  void onArtworkChanged(String? url) {
    if (_disposed) return;
    final normalized = url == null || url.isEmpty ? null : url;
    if (normalized == _currentUrl) return;
    _currentUrl = normalized;
    _timer?.cancel();
    _timer = null;
    if (normalized == null) {
      _appliedUrl = null;
      _onCleared();
      return;
    }
    if (!_surfaceAvailable) return;
    _timer = Timer(_settleDelay, () => _request(normalized));
  }

  /// 展示面恢复：对当前封面补一次取色（最后一次切歌可能发生在后台期）。
  void _onSurfaceChanged() {
    if (_disposed || !_surfaceAvailable) return;
    final url = _currentUrl;
    if (url == null || url == _appliedUrl) return;
    _timer?.cancel();
    _timer = null;
    unawaited(_request(url));
  }

  Future<void> _request(String url) async {
    final palette = await _load(url);
    if (_disposed || _currentUrl != url || palette == null) return;
    _appliedUrl = url;
    _onPalette(palette);
  }

  void dispose() {
    _disposed = true;
    _presence.removeListener(_onSurfaceChanged);
    _powerPolicy?.removeListener(_onSurfaceChanged);
    _timer?.cancel();
    _timer = null;
  }
}
