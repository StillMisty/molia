/// 封面风格缓存：按「封面 URL + 风格 + 边长」缓存派生图，内存 LRU。
///
/// - **只存展示派生图**：不落盘、不写自定义封面 / 同步目录；进程退出即释放。
/// - **边长分桶**：64 / 128 / 256 / 512 / 768，播放页大图上限 768；同一张封面
///   在不同尺寸位置（列表 40dp / 播放页大图）不会反复生成同一份大图。
/// - **并发去重**：同一 key 的多个请求共享一个 future，列表几十行同时出现时
///   只解码 / 处理一次。
/// - **约 24MB 字节预算**：按 PNG 字节计，超出后淘汰最久未用的条目；单张
///   超大图允许短暂超出后再被后续插入淘汰。
/// - **失败返回 null**：取图失败 / 省流无缓存 / 图片不可解码都回退原图，
///   不阻塞播放，也不把失败永久缓存（下次可见时仍可重试）。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../domain/models/cover_style.dart';
import '../../managers/artwork_cache.dart';
import 'cover_style_processor.dart';

/// 封面原始字节读取口（测试注入 fake，避免触网 / 读盘）。
typedef CoverStyleSourceLoader = Future<Uint8List?> Function(String url);

/// 默认取图：data URL / file:// / 网络封面。
///
/// 网络封面走 [ArtworkCache.cachedFilePath]（统一 UA / Referer 与省流网关），
/// 不绕过既有封面缓存；省流且无本地缓存时返回 null。
Future<Uint8List?> loadCoverStyleSource(String url) async {
  if (url.isEmpty) return null;
  final uri = Uri.tryParse(url);
  if (uri != null) {
    if (uri.scheme == 'data') {
      try {
        return uri.data?.contentAsBytes();
      } catch (_) {
        return null;
      }
    }
    if (uri.scheme == 'file') {
      try {
        final file = File(uri.toFilePath());
        if (!await file.exists()) return null;
        return await file.readAsBytes();
      } catch (_) {
        return null;
      }
    }
  }
  try {
    final path = await ArtworkCache.instance.cachedFilePath(url);
    if (path == null) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    return await file.readAsBytes();
  } catch (_) {
    return null;
  }
}

/// 派生图内存缓存（ChangeNotifier：插入 / 淘汰时通知展示层）。
class CoverStyleCache extends ChangeNotifier {
  CoverStyleCache({
    CoverStyleProcessorPort? processor,
    CoverStyleSourceLoader? sourceLoader,
    this.maxBytes = defaultMaxBytes,
    this.sourceMaxBytes = defaultSourceMaxBytes,
  }) : _processor = processor ?? CoverStyleProcessor(),
       _sourceLoader = sourceLoader ?? loadCoverStyleSource;

  /// 约 24MB 的派生图预算：只影响展示缓存，不影响原图封面缓存策略。
  static const int defaultMaxBytes = 24 * 1024 * 1024;

  /// 原始封面字节预算：同一封面多风格预览时只读一次盘。
  static const int defaultSourceMaxBytes = 12 * 1024 * 1024;

  /// 边长分桶（物理像素）。播放页大图上限 768。
  static const List<int> edgeBuckets = [64, 128, 256, 512, 768];

  final CoverStyleProcessorPort _processor;
  final CoverStyleSourceLoader _sourceLoader;
  final int maxBytes;
  final int sourceMaxBytes;

  final LinkedHashMap<String, Uint8List> _entries = LinkedHashMap();
  final Map<String, Future<Uint8List?>> _inflight = {};
  int _byteCount = 0;

  final LinkedHashMap<String, Uint8List> _sources = LinkedHashMap();
  final Map<String, Future<Uint8List?>> _sourceInflight = {};
  int _sourceByteCount = 0;

  /// 当前缓存字节数（测试 / 诊断用）。
  int get byteCount => _byteCount;

  /// 当前源字节缓存占用（测试 / 诊断用）。
  int get sourceByteCount => _sourceByteCount;

  /// 当前条目数（测试 / 诊断用）。
  int get entryCount => _entries.length;

  /// 把物理像素边长归入固定桶：小于 64 向上取 64，大于 768 封顶 768。
  static int bucketFor(int edge) {
    for (final bucket in edgeBuckets) {
      if (edge <= bucket) return bucket;
    }
    return edgeBuckets.last;
  }

  /// 逻辑边长 × DPR → 物理像素桶。
  static int edgeForLogical(double logicalEdge, double devicePixelRatio) {
    final physical = (logicalEdge * devicePixelRatio).round();
    return bucketFor(physical);
  }

  /// 缓存 key（稳定、可直接断言）：风格 id + 桶 + URL。
  static String keyFor(String url, CoverStyle style, int edge) =>
      '${style.id}|${bucketFor(edge)}|$url';

  /// 同步读取已缓存派生图；命中会刷新 LRU。未命中 / 原图返回 null。
  Uint8List? peek(String url, CoverStyle style, int edge) {
    if (!style.isStylized || url.isEmpty) return null;
    final key = keyFor(url, style, edge);
    final cached = _entries.remove(key);
    if (cached == null) return null;
    _entries[key] = cached;
    return cached;
  }

  /// 取得派生图：命中直接返回；未命中则取原图 → 处理 → 入缓存。
  ///
  /// 同一 key 的并发请求共享同一个 future；任何失败都返回 null。
  Future<Uint8List?> obtain(String url, CoverStyle style, {required int edge}) {
    if (!style.isStylized || url.isEmpty) return Future.value();
    final key = keyFor(url, style, edge);
    final cached = peek(url, style, edge);
    if (cached != null) return Future.value(cached);
    final inflight = _inflight[key];
    if (inflight != null) return inflight;
    final future = _loadAndRender(url, style, bucketFor(edge), key);
    _inflight[key] = future;
    future.whenComplete(() {
      if (identical(_inflight[key], future)) _inflight.remove(key);
    });
    return future;
  }

  Future<Uint8List?> _loadAndRender(
    String url,
    CoverStyle style,
    int edge,
    String key,
  ) async {
    try {
      final source = await _loadSource(url);
      if (source == null || source.isEmpty) return null;
      final rendered = await _processor.process(
        source,
        style: style,
        edge: edge,
      );
      if (rendered == null || rendered.isEmpty) return null;
      _put(key, rendered);
      return rendered;
    } catch (_) {
      return null;
    }
  }

  /// 同一 URL 的源字节只读一次盘：风格选择面板会连续请求 8 种风格，
  /// 每一种都重新读整张封面会把磁盘 I/O 放大数倍。
  Future<Uint8List?> _loadSource(String url) {
    final cached = _sources.remove(url);
    if (cached != null) {
      _sources[url] = cached; // 触碰 LRU 顺序
      return Future.value(cached);
    }
    final inflight = _sourceInflight[url];
    if (inflight != null) return inflight;
    final future = _readSource(url);
    _sourceInflight[url] = future;
    future.whenComplete(() {
      if (identical(_sourceInflight[url], future)) _sourceInflight.remove(url);
    });
    return future;
  }

  Future<Uint8List?> _readSource(String url) async {
    final source = await _sourceLoader(url);
    if (source == null || source.isEmpty) return null;
    _putSource(url, source);
    return source;
  }

  void _putSource(String url, Uint8List bytes) {
    final previous = _sources.remove(url);
    if (previous != null) _sourceByteCount -= previous.length;
    _sources[url] = bytes;
    _sourceByteCount += bytes.length;
    while (_sourceByteCount > sourceMaxBytes && _sources.isNotEmpty) {
      final oldest = _sources.keys.first;
      final removed = _sources.remove(oldest);
      if (removed != null) _sourceByteCount -= removed.length;
    }
  }

  void _put(String key, Uint8List bytes) {
    final previous = _entries.remove(key);
    if (previous != null) _byteCount -= previous.length;
    _entries[key] = bytes;
    _byteCount += bytes.length;
    while (_byteCount > maxBytes && _entries.isNotEmpty) {
      final oldestKey = _entries.keys.first;
      final removed = _entries.remove(oldestKey);
      if (removed != null) _byteCount -= removed.length;
    }
    notifyListeners();
  }

  /// 清空所有派生图与源字节（测试 / 内存压力场景）。
  void clear() {
    final hadEntries = _entries.isNotEmpty;
    _entries.clear();
    _byteCount = 0;
    _sources.clear();
    _sourceByteCount = 0;
    if (hadEntries) notifyListeners();
  }
}
