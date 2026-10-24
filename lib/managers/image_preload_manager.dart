import 'dart:async';
import 'dart:collection';

import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';

import '../domain/models/track.dart';
import '../services/app_presence.dart';
import '../utils/playback_cover_decode.dart';
import 'artwork_cache.dart';

/// 预取去重键：同一 URL 的不同解码宽度是两条 ImageCache 条目。
typedef _PreloadKey = ({String url, int? memCacheWidth});

/// 图片预加载管理器：优先级队列、并发控制与 LRU 去重。
class ImagePreloadManager {
  static final ImagePreloadManager _instance = ImagePreloadManager._internal();
  factory ImagePreloadManager() => _instance;
  ImagePreloadManager._internal();

  final Logger _logger = Logger('molia.image_preload_manager');

  /// 窗口存在态：托盘 / 最小化期间不预取——预取只为「看得见的封面」服务，
  /// 后台期解码的图只会白占内存，恢复后由调用方补一次。
  final AppPresence _presence = AppPresence.instance;

  /// 已缓存的图片键（LRU 缓存）。
  ///
  /// 键必须带解码宽度：同一 URL 的 44dp 队列缩略图与播放页大图是两条
  /// ImageCache 条目，只按 URL 去重会让后到的一方拿不到预取。
  final LinkedHashMap<_PreloadKey, DateTime> _cachedUrls = LinkedHashMap();

  final Set<_PreloadKey> _loadingUrls = {};

  final List<_PreloadTask> _queue = [];

  static const int _maxCacheSize = 100;

  static const int _maxConcurrent = 3;

  /// 队列缩略图的解码边长，与 `TrackRow.defaultCoverSize` / `LibraryCoverThumb`
  /// 的 44 对齐；这里不 import widget 层，避免管理器反向依赖 UI。
  static const double _queueThumbSize = 44;

  int _currentConcurrent = 0;

  /// 入队预加载单张图片（内部使用）；[priority] 数值越大越优先。
  ///
  /// [memCacheWidth] 非空时按缩略图解码：队列 / 下一首预览只需要小图，预取
  /// 原图会白占图片缓存（实测滚动时可把缓存推到 70MB+）。
  void _enqueue(
    String? url,
    BuildContext context, {
    int priority = 0,
    int? memCacheWidth,
  }) {
    if (url == null || url.isEmpty) return;
    final key = (url: url, memCacheWidth: memCacheWidth);
    if (_cachedUrls.containsKey(key)) return;
    if (_loadingUrls.contains(key)) return;

    _queue.add(_PreloadTask(
      key: key,
      priority: priority,
      context: context,
    ));
    _queue.sort((a, b) => b.priority.compareTo(a.priority));

    _processQueue();
  }

  /// 预加载当前播放相关的图片
  Future<void> preloadPlaybackImages({
    required BuildContext context,
    String? currentAlbumArt,
    String? previousAlbumArt,
    String? nextAlbumArt,
    List<String?>? queueAlbumArts,
  }) async {
    // 后台期不排新任务，并把藏在队列里的旧任务一并作废：这些图此刻没有任何
    // 展示面（托盘隐藏时界面已休眠）。
    if (_presence.isBackgrounded) {
      _queue.clear();
      return;
    }
    // 先收集任务再统一入队：避免在 async gap 之后使用 context。
    final tasks = <({String url, int priority, int? memCacheWidth})>[];

    // 播放页三封面 / 顶栏 / 迷你条 / 飞行副本共用一个有界解码键。
    // 按原图预取会让每首 2000×2000 封面占 15MB，切十几首就打满缓存。
    final coverEdge = playbackCoverDecodeEdge(context);

    if (currentAlbumArt != null) {
      tasks.add((url: currentAlbumArt, priority: 100, memCacheWidth: coverEdge));
    }

    if (nextAlbumArt != null) {
      tasks.add((url: nextAlbumArt, priority: 90, memCacheWidth: coverEdge));
    }

    if (previousAlbumArt != null) {
      tasks.add((
        url: previousAlbumArt,
        priority: 80,
        memCacheWidth: coverEdge,
      ));
    }

    if (queueAlbumArts != null) {
      // 列表 / 队列缩略图是 44dp；预取原图会与 Thumb 的 ResizeImage 使用
      // 不同的 ImageCache 键，既不被列表复用，又占几 MB/张。
      final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
      final queueThumbWidth = (_queueThumbSize * dpr).round();
      for (var i = 0; i < queueAlbumArts.length && i < 5; i++) {
        final url = queueAlbumArts[i];
        if (url != null) {
          tasks.add((
            url: url,
            priority: 70 - i * 10,
            memCacheWidth: queueThumbWidth,
          ));
        }
      }
    }

    for (final task in tasks) {
      _enqueue(
        task.url,
        context,
        priority: task.priority,
        memCacheWidth: task.memCacheWidth,
      );
    }
  }

  void _processQueue() {
    // 后台期队列不消费（可能在预取途中进入后台）。
    if (_presence.isBackgrounded) {
      _queue.clear();
      return;
    }
    while (_currentConcurrent < _maxConcurrent && _queue.isNotEmpty) {
      final task = _queue.removeAt(0);

      if (_cachedUrls.containsKey(task.key) ||
          _loadingUrls.contains(task.key)) {
        continue;
      }

      _currentConcurrent++;
      _loadingUrls.add(task.key);

      _loadImage(task).then((_) {
        _currentConcurrent--;
        _loadingUrls.remove(task.key);
        _processQueue();
      }).catchError((e) {
        _currentConcurrent--;
        _loadingUrls.remove(task.key);
        _logger.warning('预加载图片失败: ${task.key.url}, 错误: $e');
        _processQueue();
      });
    }
  }

  Future<void> _loadImage(_PreloadTask task) async {
    if (!task.context.mounted) return;

    final imageProvider = await artworkImageProvider(task.key.url);
    if (!task.context.mounted) return;
    final provider = ResizeImage.resizeIfNeeded(
      task.key.memCacheWidth,
      null,
      imageProvider,
    );
    await precacheImage(provider, task.context);

    // 预取途中进入后台：刚落的 keepAlive 条目马上摘掉——托盘期没有任何
    // 展示面，留着只会占内存（恢复后按需重解）。
    if (_presence.isBackgrounded) {
      await provider.evict();
      return;
    }
    _addToCache(task.key);
  }

  void _addToCache(_PreloadKey key) {
    // 如果已存在，先移除（为了更新 LRU 顺序）
    _cachedUrls.remove(key);

    _cachedUrls[key] = DateTime.now();

    while (_cachedUrls.length > _maxCacheSize) {
      _cachedUrls.remove(_cachedUrls.keys.first);
    }
  }
}

class _PreloadTask {
  final _PreloadKey key;
  final int priority;
  final BuildContext context;

  _PreloadTask({
    required this.key,
    required this.priority,
    required this.context,
  });
}

/// 专辑封面预加载策略
class AlbumArtPreloadStrategy {
  AlbumArtPreloadStrategy({this.coverUrlResolver});

  final ImagePreloadManager _manager = ImagePreloadManager();

  /// 封面 URL 解析（自定义封面优先）；null = 只用曲目自带 artwork。
  final String? Function(Track? track)? coverUrlResolver;

  /// 从领域曲目提取封面 URL（无封面返回 null）。
  String? albumArtOf(Track? track) {
    final resolved = coverUrlResolver?.call(track);
    if (resolved != null && resolved.isNotEmpty) return resolved;
    final artwork = track?.artwork;
    if (artwork == null) return null;
    final url = artwork.uri.toString();
    return url.isEmpty ? null : url;
  }

  /// 预加载播放相关的封面
  Future<void> preloadForPlayback({
    required BuildContext context,
    Track? currentTrack,
    Track? nextTrack,
    List<Track>? upcomingTracks,
  }) async {
    final queueArts = upcomingTracks?.take(5).map(albumArtOf).toList();

    await _manager.preloadPlaybackImages(
      context: context,
      currentAlbumArt: albumArtOf(currentTrack),
      nextAlbumArt: albumArtOf(nextTrack),
      queueAlbumArts: queueArts,
    );
  }
}
