import 'dart:async';
import 'dart:collection';

import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';

import '../domain/models/track.dart';
import '../services/app_presence.dart';
import 'artwork_cache.dart';

/// 图片预加载管理器：优先级队列、并发控制与 LRU 去重。
class ImagePreloadManager {
  static final ImagePreloadManager _instance = ImagePreloadManager._internal();
  factory ImagePreloadManager() => _instance;
  ImagePreloadManager._internal();

  final Logger _logger = Logger('molia.image_preload_manager');

  /// 窗口存在态：托盘 / 最小化期间不预取——预取只为「看得见的封面」服务，
  /// 后台期解码的图只会白占内存，恢复后由调用方补一次。
  final AppPresence _presence = AppPresence.instance;

  /// 已缓存的图片 URL（LRU 缓存）
  final LinkedHashMap<String, DateTime> _cachedUrls = LinkedHashMap();

  final Set<String> _loadingUrls = {};

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
    if (_cachedUrls.containsKey(url)) return;
    if (_loadingUrls.contains(url)) return;

    _queue.add(_PreloadTask(
      url: url,
      priority: priority,
      context: context,
      memCacheWidth: memCacheWidth,
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

    if (currentAlbumArt != null) {
      tasks.add((url: currentAlbumArt, priority: 100, memCacheWidth: null));
    }

    if (nextAlbumArt != null) {
      tasks.add((url: nextAlbumArt, priority: 90, memCacheWidth: null));
    }

    if (previousAlbumArt != null) {
      tasks.add((url: previousAlbumArt, priority: 80, memCacheWidth: null));
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

      if (_cachedUrls.containsKey(task.url) ||
          _loadingUrls.contains(task.url)) {
        continue;
      }

      _currentConcurrent++;
      _loadingUrls.add(task.url);

      _loadImage(task).then((_) {
        _currentConcurrent--;
        _loadingUrls.remove(task.url);
        _processQueue();
      }).catchError((e) {
        _currentConcurrent--;
        _loadingUrls.remove(task.url);
        _logger.warning('预加载图片失败: ${task.url}, 错误: $e');
        _processQueue();
      });
    }
  }

  Future<void> _loadImage(_PreloadTask task) async {
    if (!task.context.mounted) return;

    final imageProvider = await artworkImageProvider(task.url);
    if (!task.context.mounted) return;
    final provider = ResizeImage.resizeIfNeeded(
      task.memCacheWidth,
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
    _addToCache(task.url);
  }

  void _addToCache(String url) {
    // 如果已存在，先移除（为了更新 LRU 顺序）
    _cachedUrls.remove(url);

    _cachedUrls[url] = DateTime.now();

    while (_cachedUrls.length > _maxCacheSize) {
      _cachedUrls.remove(_cachedUrls.keys.first);
    }
  }
}

class _PreloadTask {
  final String url;
  final int priority;
  final BuildContext context;
  final int? memCacheWidth;

  _PreloadTask({
    required this.url,
    required this.priority,
    required this.context,
    this.memCacheWidth,
  });
}

/// 专辑封面预加载策略
class AlbumArtPreloadStrategy {
  final ImagePreloadManager _manager = ImagePreloadManager();

  /// 从领域曲目提取封面 URL（无封面返回 null）。
  String? albumArtOf(Track? track) {
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
